# =============================================================================
# 00_sample.R — THE ONE PLACE THE ANALYSIS SAMPLE IS DEFINED
#
# Every other script in this folder starts with source() of this file, so they
# all use exactly the same cases. To change the sample, change it here only.
#
# BASE SAMPLE (always): civil cases filed in 2016 and 2017 (case number year
#   16 or 17), OPEN OR CLOSED when SCALES collected them (case_closed says which),
#   minus habeas (28 USC 2241, 2254, 2255, including suffixed codes like 2241fd)
#   and prisoner civil rights (42 USC 1983pr; plain 42:1983 is kept), plus cases whose
#   nature of suit is a habeas or prisoner-petition code (463, 510-560; section 2),
#   minus MDL member cases (SCALES is_mdl OR FJC ORIGIN 6 / 13) and cases that
#   ended by MDL transfer out (FJC DISP 10), with duplicate cases removed,
#   minus OVERLONG cases (longer than the duration cap, or still pending at the
#   FJC date) - Josh, 24 Oct 2026. The last two select on the outcome.
#
# POPULATION: choose one BEFORE running any script, e.g.
#     population <- "fee_requests"
#     source("~/scales_setup/r/02_data_checks.R")
#   "all"           the whole base sample (the default if you don't set it)
#   "fee_requests"  base-sample cases with at least one attorney's-fee request,
#                   as found by 99_fee_search.R (run that once with
#                   population "all" first; it writes fee_request_cases.csv)
#   "fee_shifting"  base-sample cases whose cause of action or nature of suit
#                   is listed in r/fee_shifting_codes.csv (you fill that in)
# Each population has its OWN holdout split, made by 03_holdout.R and saved as
# ~/scales_project/holdout_split_<population>.csv.
#
# Creates these DuckDB views (use them inside SQL, e.g.
#   dbGetQuery(con, "SELECT ... FROM analysis_fjc")):
#   civil_cases, non_habeas_cases, analysis_cases_raw (MDL removed),
#   analysis_cases_keyed                                       steps toward the base
#   mdl_flagged          the MDL flags for every non-habeas case (for checks)
#   all_cases_dedup      one row per case (duplicates removed)
#   case_duration        duration variables for every de-duplicated case
#   all_cases            THE BASE SAMPLE: all_cases_dedup minus overlong cases
#   analysis_cases       THE CHOSEN POPULATION, plus is_holdout
#   best_link            each base-sample case's best FJC record (fjc_rank = 1)
#   analysis_fjc         analysis_cases + FJC outcome fields + the DURATION
#                        variables (section 7) + covariates (section 7b and
#                        case_features.parquet from 01_build_features.R)
#   train_cases, train_fjc   the same, training cases only (is_holdout = FALSE);
#                        empty until 03_holdout.R has been run for this population
#
# Reads the Parquet tables in ~/scales_project/parquet; nothing is changed on disk.
# =============================================================================

library(duckdb)

if (!exists("population")) population <- "all"
stopifnot("population must be \"all\", \"fee_requests\" or \"fee_shifting\"" =
            population %in% c("all", "fee_requests", "fee_shifting"))

r_dir       <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
project_dir <- path.expand(Sys.getenv("SCALES_PROJECT", "~/scales_project"))
pq          <- file.path(project_dir, "parquet")
fee_request_file <- file.path(project_dir, "fee_request_cases.csv")
fee_codes_file   <- file.path(r_dir, "fee_shifting_codes.csv")
split_file       <- file.path(project_dir, sprintf("holdout_split_%s.csv", population))
# A split made before populations existed was saved as holdout_split.csv; it
# belongs to the "all" population.
legacy_split <- file.path(project_dir, "holdout_split.csv")
if (population == "all" && !file.exists(split_file) && file.exists(legacy_split)) split_file <- legacy_split

# ---- Dependent variable: duration, capped -----------------------------------
# Every case could be followed at least from 31 Dec 2017 to the date the FJC
# data run to, so durations longer than that are recorded as "longer than the
# cap". fjc_data_through is the FJC file's coverage date, from its download page
# ("Cases terminated ... through June 30, 2026"); change it if the FJC file is
# updated and step 05 is re-run.
# These are set from this file EVERY time it runs (an earlier version only set
# them if they didn't exist yet, so an old value could linger in an R session).
# To try a different value on purpose, set duration_cap_start_override and/or
# fjc_data_through_override before sourcing.
duration_cap_start <- as.Date("2017-12-31")   # Josh, 24 Oct 2026 (was 2017-12-30)
fjc_data_through   <- as.Date("2026-06-30")
if (exists("duration_cap_start_override")) duration_cap_start <- as.Date(duration_cap_start_override)
if (exists("fjc_data_through_override"))   fjc_data_through   <- as.Date(fjc_data_through_override)
duration_cap_days <- as.integer(fjc_data_through - duration_cap_start)   # 3103 days

# Reuse the connection if this file has already been run in this R session.
# Newer versions of the duckdb package ask (in RStudio) where to keep their
# helper files; shared_home = FALSE answers "a temporary folder" so the script
# never stops to ask. Older versions don't have that option, hence the check.
if (!exists("con") || !dbIsValid(con)) {
  drv <- if ("shared_home" %in% names(formals(duckdb))) duckdb(shared_home = FALSE) else duckdb()
  con <- dbConnect(drv)
}

# ---- 1. 2016-17 civil cases, with cause split into title and section ----------
# Open and closed cases are both kept (until 15 Oct 2026 only closed ones were).
# case_closed = SCALES recorded the case as closed when it collected it (2016
# cases mostly early 2020, 2017 cases mid-2021). Open cases have no SCALES
# termination date; their FJC record (to mid-2026) may show a later one.
# cause "28:1332 Diversity-Breach of Contract" -> cause_title 28, cause_section "1332"
# (leading zeros dropped; letters after the number kept, e.g. "1983pr").
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW civil_cases AS
  SELECT *,
    coalesce(lower(trim(case_status)), '') = 'closed' AS case_closed,
    TRY_CAST(NULLIF(regexp_extract(cause, '^ *0*([0-9]+) *:', 1), '') AS INTEGER) AS cause_title,
    NULLIF(regexp_extract(cause, ': *0*([0-9A-Za-z]+)', 1), '') AS cause_section
  FROM '%s/cases.parquet'
  WHERE case_type = 'cv' AND year_dir IN ('16', '17')", pq))

# ---- 2. Drop habeas and prisoner civil rights, then MDL members ----------------
# coalesce(..., false) keeps cases with no cause listed instead of dropping them.
# Nature-of-suit exclusion for habeas and prisoner cases the cause rules miss
# (Josh, 25 Oct 2026, AFTER the split). 02_data_checks.R tested each CANDIDATE code first:
# excluding them removes training and holdout cases in proportion (changes 55, 57).
# The split is not redrawn - the same rule applies to both sides. Codes in
# exclude_nos_codes are dropped; the check keeps reporting their balance.
#   463 Habeas Corpus - Alien Detainee   510 Motions to Vacate Sentence
#   530 Habeas Corpus - General          535 Habeas Corpus - Death Penalty
#   540 Mandamus & Other (prisoner)      550 Prisoner: Civil Rights
#   555 Prison Condition                 560 Civil Detainee - Conditions of Confinement
candidate_nos_codes <- c("463", "510", "530", "535", "540", "550", "555", "560")
exclude_nos_codes   <- candidate_nos_codes # all 8 applied (Josh, 25 Oct 2026, change 57: balanced, |z| <= 2.4)
nos_rule <- if (length(exclude_nos_codes))
  sprintf("\n     OR regexp_extract(nature_suit, '^\\s*([0-9]{3})', 1) IN (%s)",
          paste0("'", exclude_nos_codes, "'", collapse = ", ")) else ""
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW non_habeas_cases AS
  SELECT * FROM civil_cases
  WHERE NOT coalesce(
        (cause_title = 28 AND regexp_matches(cause_section, '^(2241|2254|2255)([a-z]|$)'))
     OR (cause_title = 42 AND cause_section = '1983pr')%s, false)", nos_rule))
# MDL member cases are excluded (Josh, 24 Oct 2026): their timing is driven by
# the MDL, and members of one MDL often end together, which would put near-twins
# on both sides of the holdout split. MDL = SCALES is_mdl OR FJC ORIGIN 6 (MDL
# transfer in) / 13 (MDL originating here): neither source is complete alone.
# Also excluded (Josh, 24 Oct 2026): cases that ENDED by MDL transfer OUT (FJC
# DISP 10) - sent to an MDL court, so not a real ending here; they are MDL-bound
# cases that neither source flags as MDL members on this side.
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW mdl_flagged AS
  SELECT n.ucid,
         coalesce(n.is_mdl, false) OR coalesce(trim(l.ORIGIN) IN ('6', '13'), false) AS is_mdl_any,
         coalesce(n.is_mdl, false) AS scales_mdl, coalesce(trim(l.ORIGIN) IN ('6', '13'), false) AS fjc_mdl,
         coalesce(trim(l.DISP) = '10', false) AS mdl_transfer_out
  FROM non_habeas_cases n
  LEFT JOIN (SELECT ucid, ORIGIN, DISP FROM '%s/scales_fjc_link.parquet' WHERE fjc_rank = 1) l USING (ucid)", pq))
dbExecute(con, "CREATE OR REPLACE TEMP VIEW analysis_cases_raw AS
  SELECT n.* FROM non_habeas_cases n JOIN mdl_flagged m USING (ucid)
  WHERE NOT m.is_mdl_any AND NOT m.mdl_transfer_out")

# ---- 3. Remove duplicate cases ------------------------------------------------
# case_number_key = court | office | 2-digit year + 5-digit sequence, built from
# the ucid ("ilnd;;1:16-cv-04871" -> "ilnd|1|1604871"), the same key used to
# match the FJC data. It catches the same ucid listed twice AND the same case
# under two spellings of its ucid. A ucid that doesn't fit the usual pattern is
# its own key, so it is never merged with another case.
dbExecute(con, "CREATE OR REPLACE TEMP VIEW analysis_cases_keyed AS
  SELECT *,
    CASE WHEN regexp_matches(ucid, ';;[0-9A-Za-z]+:[0-9]{2}-cv-[0-9]+')
         THEN court || '|'
              || coalesce(nullif(ltrim(upper(regexp_extract(ucid, ';;([0-9A-Za-z]+):', 1)), '0'), ''), '0')
              || '|' || regexp_extract(ucid, ':([0-9]{2})-cv-', 1)
              || lpad(regexp_extract(ucid, '-cv-([0-9]+)', 1), 5, '0')
         ELSE ucid END AS case_number_key
  FROM analysis_cases_raw")

# One row per case number - the one with the most docket entries, then the
# most recently downloaded, then the first ucid alphabetically.
dbExecute(con, "CREATE OR REPLACE TEMP VIEW all_cases_dedup AS
  SELECT * EXCLUDE (dup_rank) FROM (
    SELECT *, row_number() OVER (PARTITION BY case_number_key
                ORDER BY n_docket_entries DESC NULLS LAST, download_timestamp DESC NULLS LAST,
                         ucid, archive_path) AS dup_rank
    FROM analysis_cases_keyed)
  WHERE dup_rank = 1")

# ---- 3a. Best FJC match for each case (fjc_rank = 1) ----------------------------
# Cases with no FJC match keep their SCALES columns; the FJC columns are empty.
# If one FJC record is the best match for two different cases, it can't tell
# them apart, so neither case gets FJC data (both stay in the sample).
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW best_link AS
  SELECT l.* FROM '%s/scales_fjc_link.parquet' l
  WHERE l.fjc_rank = 1 AND l.ucid IN (SELECT ucid FROM all_cases_dedup)", pq))
dbExecute(con, "CREATE OR REPLACE TEMP VIEW best_link_unique AS
  SELECT * FROM best_link
  WHERE fjc_row NOT IN (SELECT fjc_row FROM best_link GROUP BY 1 HAVING count(*) > 1)")

# ---- 3b. Duration (the dependent variable), for every de-duplicated case ------
#   start_date            SCALES filing_date (FJC filing date if SCALES has none)
#   end_date              SCALES terminating_date if the case was closed when
#                         SCALES collected it; otherwise the FJC termination
#                         date if the FJC shows it ended by mid-2026
#   end_date_source       "SCALES" or "FJC"
#   duration_days         end_date - start_date, uncapped (NA if no end date)
#   duration_capped_days  THE DV: duration_days, or duration_cap_days (3103)
#                         for overlong cases; NA if it can't be determined
#   is_overlong           TRUE if the case lasted longer than the cap, including
#                         cases still pending in the FJC file at fjc_data_through
#   event_observed        TRUE if the case ENDED in this court within the cap; FALSE
#                         if it is censored - overlong, or transferred out (to another
#                         district or by MDL transfer: it continued elsewhere, so its
#                         duration here is only time until it left). For survival
#                         models: Surv(duration_capped_days, event_observed).
#                         Remands (to state court / a U.S. agency) count as endings.
#   duration_status       ended | longer_than_cap | transferred_out (FJC DISP 0 or 10;
#                         duration = days until the transfer, censored) | and, for cases left out of
#                         the DV: unknown_end (open in SCALES, no FJC record),
#                         pending_short_followup (still pending, but filed after
#                         the cap start, so followed for less than the cap),
#                         no_filing_date, end_before_start (bad dates)
# Computed BEFORE the population and the split, so overlong cases can be dropped
# from the sample (Josh's decision, below); the analysis views reuse it.
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW case_duration AS
  WITH j AS (
    SELECT c.ucid, c.filing_date, c.terminating_date, l.fjc_row, l.fjc_filedate, l.fjc_termdate, l.STATUSCD, l.DISP
    FROM all_cases_dedup c
    LEFT JOIN best_link_unique l USING (ucid)),
  d AS (
    SELECT *,
      coalesce(filing_date, fjc_filedate) AS start_date,
      CASE WHEN terminating_date IS NOT NULL THEN terminating_date
           WHEN fjc_termdate IS NOT NULL AND coalesce(STATUSCD, '') <> 'S' THEN fjc_termdate END AS end_date,
      CASE WHEN terminating_date IS NOT NULL THEN 'SCALES'
           WHEN fjc_termdate IS NOT NULL AND coalesce(STATUSCD, '') <> 'S' THEN 'FJC' END AS end_date_source,
      fjc_row IS NOT NULL AND (STATUSCD = 'S' OR fjc_termdate IS NULL) AS pending_in_fjc
    FROM j),
  e AS (
    SELECT *,
      date_diff('day', start_date, end_date) AS duration_days,
      CASE WHEN start_date IS NULL                                        THEN 'no_filing_date'
           WHEN end_date IS NOT NULL AND end_date < start_date           THEN 'end_before_start'
           WHEN end_date IS NOT NULL AND date_diff('day', start_date, end_date) > %d THEN 'longer_than_cap'
           WHEN end_date IS NOT NULL AND trim(DISP) IN ('0', '10')       THEN 'transferred_out'
           WHEN end_date IS NOT NULL                                      THEN 'ended'
           WHEN pending_in_fjc AND date_diff('day', start_date, DATE '%s') >= %d THEN 'longer_than_cap'
           WHEN pending_in_fjc                                            THEN 'pending_short_followup'
           ELSE 'unknown_end' END AS duration_status
    FROM d)
  SELECT ucid, start_date, end_date, end_date_source, duration_days, duration_status,
    CASE duration_status WHEN 'ended' THEN duration_days
                         WHEN 'transferred_out' THEN duration_days
                         WHEN 'longer_than_cap' THEN %d END AS duration_capped_days,
    duration_status = 'longer_than_cap' AS is_overlong,
    CASE WHEN duration_status IN ('ended', 'transferred_out', 'longer_than_cap')
         THEN duration_status = 'ended' END AS event_observed
  FROM e", duration_cap_days, format(fjc_data_through), duration_cap_days, duration_cap_days))


# ---- 3c. THE BASE SAMPLE: drop the overlong cases ------------------------------
# DECISION (Josh, 24 Oct 2026): cases that lasted longer than the cap - including
# cases still pending at fjc_data_through - are EXCLUDED from the sample, before
# the split. This selects on the outcome: the sample contains only cases that
# ended (or were transferred out) within duration_cap_days, so results describe
# cases resolved within about 8.5 years and duration estimates are somewhat
# shorter than for all cases. See EXPLAINER.md.
# DECISION (Josh, 24 Oct 2026, AFTER the split): cases with NO FJC record (no match
# in best_link_unique - either no FJC match at all, or an FJC record shared with
# another case) are also EXCLUDED. 02-a_data_checks_fjc.R showed they are mostly
# administrative case numbers closed within days (median 3 days, 3 docket entries,
# 'transfer' wording 3x as often), so "no FJC record" partly records the outcome and
# their 'endings' are often not real ones. The split is NOT redrawn: the same rule
# drops these cases from training and holdout alike (02_data_checks.R reports the
# balance). Results describe cases with an FJC record. See CHANGES.md, change 42.
dbExecute(con, "CREATE OR REPLACE TEMP VIEW all_cases AS
  SELECT * FROM all_cases_dedup
  WHERE ucid NOT IN (SELECT ucid FROM case_duration WHERE duration_status = 'longer_than_cap')
    AND ucid IN (SELECT ucid FROM best_link_unique)")

# ---- 4. The chosen population ---------------------------------------------------
if (population == "all") {
  dbExecute(con, "CREATE OR REPLACE TEMP VIEW population_cases AS SELECT * FROM all_cases")

} else if (population == "fee_requests") {
  if (!file.exists(fee_request_file))
    stop("population \"fee_requests\" needs ", fee_request_file,
         "\nRun 99_fee_search.R once with population <- \"all\" first; it creates that file.")
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW population_cases AS
    SELECT * FROM all_cases
    WHERE ucid IN (SELECT ucid FROM read_csv('%s', header = true, columns = {'ucid': 'VARCHAR',
                   'n_fee_requests': 'INTEGER', 'first_fee_request_date': 'VARCHAR'}))", fee_request_file))

} else if (population == "fee_shifting") {
  # fee_shifting_codes.csv: one row per code; lines starting with # are ignored.
  #   code_type = cause   code = "title:section", e.g. 42:1983 (that exact section)
  #                       42:1983+  the section followed only by letters: 1983cv, 1983bv
  #                       42:121*   starts with: 12101, 12112, 12182, ...
  #   code_type = nos     code = 3-digit nature-of-suit code from SCALES, e.g. 440
  codes <- if (file.exists(fee_codes_file))
    read.csv(fee_codes_file, comment.char = "#", colClasses = "character", strip.white = TRUE) else NULL
  if (is.null(codes) || nrow(codes) == 0)
    stop("population \"fee_shifting\" needs codes in ", fee_codes_file,
         "\nAdd at least one row (see the examples in that file).")
  bad <- setdiff(codes$code_type, c("cause", "nos"))
  if (length(bad)) stop("Unknown code_type in fee_shifting_codes.csv: ", paste(bad, collapse = ", "))
  cause_rows <- codes[codes$code_type == "cause", ]
  bad <- cause_rows$code[!grepl("^[0-9]+:[0-9A-Za-z]+[*+]?$", cause_rows$code)]
  if (length(bad)) stop("Cause codes must look like 42:1983, 42:1983+ or 42:121* - check: ", paste(bad, collapse = ", "))
  cause_rows$title   <- as.integer(sub(":.*", "", cause_rows$code))
  cause_rows$section <- tolower(sub("^[0-9]+:0*", "", sub("[*+]$", "", cause_rows$code)))
  cause_rows$match   <- ifelse(grepl("\\*$", cause_rows$code), "prefix",
                        ifelse(grepl("\\+$", cause_rows$code), "letters", "exact"))
  dbWriteTable(con, "fee_shifting_causes", cause_rows[, c("title", "section", "match", "label")],
               temporary = TRUE, overwrite = TRUE)
  dbWriteTable(con, "fee_shifting_nos", codes[codes$code_type == "nos", c("code", "label")],
               temporary = TRUE, overwrite = TRUE)
  dbExecute(con, "CREATE OR REPLACE TEMP VIEW population_cases AS
    SELECT * FROM all_cases c
    WHERE EXISTS (SELECT 1 FROM fee_shifting_causes f
                  WHERE c.cause_title = f.title
                    AND (lower(c.cause_section) = f.section
                         OR (f.match = 'prefix'  AND starts_with(lower(c.cause_section), f.section))
                         OR (f.match = 'letters' AND regexp_matches(lower(c.cause_section), '^' || f.section || '[a-z]*$'))))
       OR NULLIF(regexp_extract(c.nature_suit, '([0-9]{3})', 1), '') IN (SELECT code FROM fee_shifting_nos)")
}

# ---- 5. The holdout split for this population (made once by 03_holdout.R) ----
# Fingerprint check: the split's MD5 checksum is recorded in
# holdout_split_<population>.md5 when the split is made (or, for a split made
# before this check existed, the first time it is loaded). If the file ever
# changes after that, stop rather than quietly using a different holdout.
fingerprint_file <- sub("\\.csv$", ".md5", split_file)
if (file.exists(split_file)) {
  current_md5 <- unname(tools::md5sum(split_file))
  if (!file.exists(fingerprint_file)) {
    writeLines(c(current_md5, paste("recorded", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "for", basename(split_file))),
               fingerprint_file)
    cat("Recorded the holdout split's fingerprint in", basename(fingerprint_file), "\n")
  } else if (!identical(readLines(fingerprint_file, n = 1), current_md5)) {
    stop("The holdout split file has CHANGED since its fingerprint was recorded:\n  ", split_file,
         "\nNothing was loaded. If you did not mean to change it, restore it from your backup.",
         "\nIf you redrew it on purpose, delete ", basename(fingerprint_file),
         " so the new split is fingerprinted, and record why in CHANGES.md.")
  }
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE holdout_split AS
    SELECT * FROM read_csv('%s', header = true,
                           columns = {'ucid': 'VARCHAR', 'is_holdout': 'BOOLEAN'})", split_file))
} else {
  dbExecute(con, "CREATE OR REPLACE TEMP TABLE holdout_split (ucid VARCHAR, is_holdout BOOLEAN)")
}
# Case-level covariates built once by 01_build_features.R, joined when available.
features_file <- file.path(pq, "case_features.parquet")
features_manifest <- file.path(pq, "case_features_inputs.csv")
# What 01_build_features.R reads. Big data files are identified by size and
# modification time; small files by MD5 checksum (so re-copying an unchanged
# file with scp doesn't look like a change).
features_inputs <- function() {
  big   <- file.path(pq, c("cases.parquet", "parties.parquet", "counsel.parquet", "docket_entries.parquet",
                           "fjc_idb_civil.parquet", "scales_fjc_link.parquet"))
  small <- c(file.path(dirname(r_dir), "reference",
                       c("fjc_district_judges.csv", "nchs_urban_rural_2013.csv", "large_firms_bcg_2026.csv")),
             file.path(dirname(r_dir), "fjc_district_crosswalk.csv"), file.path(r_dir, "01_build_features.R"))
  sig <- c(ifelse(file.exists(big), paste(file.size(big), format(as.numeric(file.mtime(big)), nsmall = 0)), "missing"),
           ifelse(file.exists(small), unname(tools::md5sum(small)), "missing"))
  data.frame(file = basename(c(big, small)), signature = sig, stringsAsFactors = FALSE)
}
features_stale <- character(0)
if (file.exists(features_file)) {
  if (!file.exists(features_manifest)) {
    features_stale <- "(no record of the inputs - built before this check existed)"
  } else {
    old <- read.csv(features_manifest, colClasses = "character"); now <- features_inputs()
    both <- merge(now, old, by = "file", all = TRUE, suffixes = c("_now", "_built"))
    features_stale <- both$file[is.na(both$signature_built) | is.na(both$signature_now) |
                                both$signature_now != both$signature_built]
  }
}
if (file.exists(features_file)) {
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW analysis_cases AS
    SELECT p.*, f.* EXCLUDE (ucid), h.is_holdout
    FROM population_cases p
    LEFT JOIN '%s' f USING (ucid)
    LEFT JOIN holdout_split h USING (ucid)", features_file))
} else {
  dbExecute(con, "CREATE OR REPLACE TEMP VIEW analysis_cases AS
    SELECT p.*, h.is_holdout FROM population_cases p LEFT JOIN holdout_split h USING (ucid)")
}

# ---- 6-7. Analysis table: the population + its FJC match + its duration --------
dbExecute(con, "CREATE OR REPLACE TEMP VIEW analysis_fjc_base AS
  SELECT c.*, l.* EXCLUDE (ucid), d.* EXCLUDE (ucid)
  FROM analysis_cases c
  LEFT JOIN best_link_unique l USING (ucid)
  LEFT JOIN case_duration d USING (ucid)")

# ---- 7a. RECODES: rule-based fixes for odd values (Josh, 25 Oct 2026; change 56) ----
# Found by 02-c_data_checks_oddities.R on training cases, but written as general RULES
# so every case - training and holdout - is treated the same. case_features.parquet is
# not rebuilt; the fixes are applied here, in the analysis view.
#   county_area_class     "unmatched county code" + FJC county 75010 (the FJC's code for
#                         the Northern Mariana Islands) -> "US territory"
#   first_defendant_type  "name not recorded" (the first defendant's name has no letters):
#                         name starts with "$"            -> "property (in rem)" (forfeitures)
#                         name is 7-11 / 7-Eleven         -> "business"
#                         name is only digits and hyphens -> "individual" (SCALES-anonymized
#                                                            people and anonymous online sellers)
#   cause_title/section   3:4301 -> 38:4301 (USERRA)    1:102 -> 42:12102 (ADA) - typos in
#                         SCALES's cause field; 73:201 (Pennsylvania's consumer-protection
#                         statute, state law) -> 28:1332 (diversity); 99:9999 (a placeholder
#                         "report cause code") -> no cause. cause_group uses the corrected values
#   nature_suit,          blank in SCALES -> the FJC value (NOS code, labelled with SCALES's own
#   jurisdiction          wording for that code; JURIS 1-5 in words) - change 57
# "Local Question" jurisdiction is NOT recoded: it's real (Guam and Virgin Islands, FJC JURIS 5).
features_cols <- dbListFields(con, "analysis_fjc_base")
if (all(c("county_area_class", "first_defendant_type") %in% features_cols)) {
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE recode_fjc_nmi AS
    SELECT fjc_row FROM '%s/fjc_idb_civil.parquet' WHERE trim(CAST(COUNTY AS VARCHAR)) = '75010'", pq))
  # the first defendant (same definition as 01_build_features.R: role starts with
  # defendant/respondent, else party_type; lowest party_index) of each "name not recorded" case
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE recode_def_names AS
    SELECT DISTINCT ON (p.ucid) p.ucid, trim(coalesce(CAST(p.name AS VARCHAR), '')) AS def_name
    FROM '%s/parties.parquet' p
    WHERE p.ucid IN (SELECT ucid FROM analysis_fjc_base WHERE first_defendant_type = 'name not recorded')
      AND (regexp_matches(lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))), '^(defendant|respondent)')
           OR (NOT regexp_matches(lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))), '^(plaintiff|petitioner)')
               AND lower(coalesce(CAST(p.party_type AS VARCHAR), '')) LIKE 'defendant%%'))
    ORDER BY p.ucid, p.party_index", pq))
  feature_recodes <- ",
    CASE WHEN r.county_area_class = 'unmatched county code' AND r.fjc_row IN (SELECT fjc_row FROM recode_fjc_nmi)
         THEN 'US territory' ELSE r.county_area_class END AS county_area_class,
    CASE WHEN r.first_defendant_type <> 'name not recorded' OR dn.def_name IS NULL THEN r.first_defendant_type
         WHEN regexp_matches(dn.def_name, '^\\$')                         THEN 'property (in rem)'
         WHEN regexp_matches(lower(dn.def_name), '^7[- ]?(11|eleven)\\b')   THEN 'business'
         WHEN regexp_matches(dn.def_name, '^[0-9][0-9 -]*$')               THEN 'individual'
         ELSE r.first_defendant_type END AS first_defendant_type"
  feature_join <- "LEFT JOIN recode_def_names dn ON dn.ucid = r.ucid"
} else {
  feature_recodes <- ""; feature_join <- ""
}
# SCALES's own label for each 3-digit nature-of-suit code (its most common wording)
dbExecute(con, "CREATE OR REPLACE TEMP TABLE recode_nos_labels AS
  SELECT regexp_extract(nature_suit, '^\\s*([0-9]{3})', 1) AS nos_code, mode(trim(nature_suit)) AS nos_label
  FROM civil_cases WHERE regexp_matches(coalesce(nature_suit, ''), '^\\s*[0-9]{3}') GROUP BY 1")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW analysis_fjc_recoded AS
  SELECT r.* REPLACE (
    CASE WHEN r.cause_title = 3  AND r.cause_section = '4301' THEN 38
         WHEN r.cause_title = 1  AND r.cause_section = '102'  THEN 42
         WHEN r.cause_title = 73 AND r.cause_section = '201'  THEN 28
         WHEN r.cause_title = 99 AND r.cause_section = '9999' THEN NULL
         ELSE r.cause_title END AS cause_title,
    CASE WHEN r.cause_title = 1  AND r.cause_section = '102'  THEN '12102'
         WHEN r.cause_title = 73 AND r.cause_section = '201'  THEN '1332'
         WHEN r.cause_title = 99 AND r.cause_section = '9999' THEN NULL
         ELSE r.cause_section END AS cause_section,
    CASE WHEN nullif(trim(r.nature_suit), '') IS NULL AND nl.nos_label IS NOT NULL THEN nl.nos_label
         ELSE r.nature_suit END AS nature_suit,
    CASE WHEN nullif(trim(r.jurisdiction), '') IS NULL THEN
           coalesce(CASE trim(CAST(r.JURIS AS VARCHAR)) WHEN '1' THEN 'U.S. Government Plaintiff'
                      WHEN '2' THEN 'U.S. Government Defendant' WHEN '3' THEN 'Federal Question'
                      WHEN '4' THEN 'Diversity' WHEN '5' THEN 'Local Question' END, r.jurisdiction)
         ELSE r.jurisdiction END AS jurisdiction%s)
  FROM analysis_fjc_base r
  LEFT JOIN recode_nos_labels nl ON nl.nos_code = lpad(trim(CAST(r.NOS AS VARCHAR)), 3, '0') %s", feature_recodes, feature_join))

# ---- 7b. Covariates that depend on the TRAINING data, plus filing month/weekday ----
#   filing_month (1-12), filing_weekday (Monday ... Sunday)   from start_date
#   judge_group   "unassigned" (judge field says Unassigned / Not Assigned ...) and
#                 "(no judge listed)" (blank) are always their own categories;
#                 otherwise the judge (court | name), or "other" if the judge has fewer than
#                 20 TRAINING cases in this population
#   arrival_route, class_action_alleged, in_forma_pauperis, pro_se
#                 labelled versions of FJC ORIGIN, CLASSACT, IFP, PROSE (codes in
#                 words; -8 recoded per the codebook; "no FJC record" when unmatched)
#   cause_group   "title:section" if that pair has at least 100 TRAINING cases,
#                 otherwise "title:other"; "(no cause)" if there's no cause
# Before this population's holdout exists, the thresholds use all of its cases.
threshold_basis <- if (file.exists(split_file)) "is_holdout = FALSE" else "TRUE"
# Wording SCALES uses when no judge has been assigned (a case that ended before
# assignment). NOTE: this partly reflects the outcome - see CHANGES.md, change 28.
# "Executive Committee" (e.g. N.D. Ill.) is the court committee that holds unassigned cases.
unassigned_pattern <- "unassigned|not assigned|no judge assigned|judge not yet assigned|executive committee"
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW analysis_fjc AS
  WITH b AS (SELECT *,
               CASE WHEN nullif(trim(judge), '') IS NULL THEN '(no judge listed)'
                    WHEN regexp_matches(lower(judge), '%s') THEN 'unassigned'
                    ELSE court || ' | ' || trim(judge) END AS judge_key
             FROM analysis_fjc_recoded),
  basis AS (SELECT * FROM b WHERE %s),
  jc AS (SELECT judge_key, count(*) AS n FROM basis GROUP BY 1),
  cc AS (SELECT cause_title, cause_section, count(*) AS n FROM basis
         WHERE cause_title IS NOT NULL GROUP BY 1, 2)
  SELECT b.* EXCLUDE (judge_key),
    CASE WHEN b.fjc_row IS NULL THEN 'no FJC record'
         ELSE CASE trim(b.ORIGIN) WHEN '1' THEN 'original filing' WHEN '2' THEN 'removed from state court'
                WHEN '3' THEN 'remanded from court of appeals' WHEN '4' THEN 'reopened'
                WHEN '5' THEN 'transferred in' WHEN '6' THEN 'MDL transfer in' WHEN '7' THEN 'appeal from magistrate judge'
                WHEN '13' THEN 'MDL originating here' WHEN '8' THEN 'reopened' WHEN '9' THEN 'reopened'
                WHEN '10' THEN 'reopened' WHEN '11' THEN 'reopened' WHEN '12' THEN 'reopened'
                ELSE 'not recorded' END END AS arrival_route,
    CASE WHEN b.fjc_row IS NULL THEN 'no FJC record' WHEN trim(b.CLASSACT) = '1' THEN 'yes' ELSE 'no' END AS class_action_alleged,
    CASE WHEN b.fjc_row IS NULL THEN 'no FJC record' WHEN upper(trim(b.IFP)) = 'FP' THEN 'yes' ELSE 'no' END AS in_forma_pauperis,
    CASE WHEN b.fjc_row IS NULL THEN 'no FJC record'
         ELSE CASE trim(b.PROSE) WHEN '0' THEN 'none' WHEN '1' THEN 'plaintiff' WHEN '2' THEN 'defendant'
                WHEN '3' THEN 'both' ELSE 'not recorded' END END AS pro_se,
    month(b.start_date)   AS filing_month,
    dayname(b.start_date) AS filing_weekday,
    CASE WHEN b.judge_key IN ('unassigned', '(no judge listed)') OR coalesce(jc.n, 0) >= 20 THEN b.judge_key
         ELSE 'other (fewer than 20 training cases)' END AS judge_group,
    CASE WHEN b.cause_title IS NULL THEN '(no cause)'
         WHEN coalesce(cc.n, 0) >= 100 THEN CAST(b.cause_title AS VARCHAR) || ':' || b.cause_section
         ELSE CAST(b.cause_title AS VARCHAR) || ':other' END AS cause_group
  FROM b
  LEFT JOIN jc ON jc.judge_key = b.judge_key
  LEFT JOIN cc ON cc.cause_title = b.cause_title AND cc.cause_section = b.cause_section", unassigned_pattern, threshold_basis))

# ---- 8. Training-only views (empty until 03_holdout.R has been run) ----------
dbExecute(con, "CREATE OR REPLACE TEMP VIEW train_cases AS SELECT * FROM analysis_cases WHERE is_holdout = FALSE")
dbExecute(con, "CREATE OR REPLACE TEMP VIEW train_fjc   AS SELECT * FROM analysis_fjc   WHERE is_holdout = FALSE")

# ---- Report where things stand -----------------------------------------------
status <- dbGetQuery(con, "SELECT (SELECT count(*) FROM all_cases) AS n_base,
                                  count(*) AS n_cases,
                                  count(*) FILTER (WHERE is_holdout = FALSE) AS n_training,
                                  count(*) FILTER (WHERE is_holdout = TRUE)  AS n_holdout,
                                  count(*) FILTER (WHERE is_holdout IS NULL) AS n_unassigned
                           FROM analysis_cases")
fmt <- function(x) format(x, big.mark = ",")
cat(sprintf("Population \"%s\": %s cases (base sample: %s).\n",
            population, fmt(status$n_cases), fmt(status$n_base)))
cat(sprintf("Duration cap: %s days (%s to %s); longer cases are marked is_overlong.\n",
            fmt(duration_cap_days), format(duration_cap_start), format(fjc_data_through)))
if (!file.exists(features_file))
  cat("Covariates file not built yet (case_features.parquet): run 01_build_features.R once.\n")
if (length(features_stale))
  warning("case_features.parquet may be OUT OF DATE - changed since it was built: ",
          paste(features_stale, collapse = ", "), ". Re-run 01_build_features.R.", call. = FALSE)
if (!file.exists(split_file))
  cat("judge_group / cause_group thresholds use all cases until this population's holdout exists.\n")
if (!file.exists(split_file)) {
  cat("No holdout split for this population yet. Run 03_holdout.R before any analysis.\n")
} else {
  cat(sprintf("Holdout split loaded (%s): %s training, %s holdout.\n",
              basename(split_file), fmt(status$n_training), fmt(status$n_holdout)))
  if (status$n_unassigned > 0)
    warning(sprintf(paste0("%s cases in this population are not in its saved holdout split, probably ",
                           "because the population definition changed after the split was made. ",
                           "They are left out of train_cases / train_fjc."), fmt(status$n_unassigned)))
}
