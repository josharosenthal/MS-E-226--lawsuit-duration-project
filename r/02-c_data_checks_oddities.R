# =============================================================================
# 02-c_data_checks_oddities.R — the case header for each training case with an
# odd covariate value, to see what is going on before deciding how to code it.
#
# Flags (a case can have several), from DATA_DICTIONARY.md section 3 (notes; before change 105, "things the counts turned up"):
#   blank_nature_suit         nature of suit blank in SCALES
#   blank_jurisdiction        jurisdiction blank in SCALES
#   local_question            jurisdiction = "Local Question"
#   single_case_cause_title   a U.S. Code title that only one training case cites
#   unmatched_county          county_area_class = "unmatched county code"
#   defendant_name_missing    first_defendant_type = "name not recorded"
#
# For each case: the SCALES header (court, case number, case name, office,
# filing date, status, judge, nature of suit, cause, jurisdiction, jury demand,
# party counts) and, side by side, what the FJC record says (NOS, JURIS, county,
# cause title/section) - often the FJC fills a SCALES gap, or shows a coding error.
#
# TRAINING CASES ONLY. The console shows counts and a compact table without names;
# the full header, including the case name (which names the parties), is saved to
# ~/scales_project/checks/oddities_cases.csv - open it in RStudio or Excel.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)

# Optional columns: use them only if this version of the data has them
have   <- dbListFields(con, "train_fjc")
fjc_cols <- dbGetQuery(con, sprintf("SELECT * FROM '%s/fjc_idb_civil.parquet' LIMIT 0", pq))
opt    <- function(cols, pool, prefix) { cols <- intersect(cols, pool); if (length(cols)) paste0(", ", prefix, cols, collapse = "") else "" }
scales_extra <- opt(c("case_name", "city", "case_status", "judge", "jury_demand", "terminating_date"), have, "t.")
fjc_extra    <- opt(c("COUNTY", "TITL", "SECTION", "NOS", "JURIS", "ORIGIN"), names(fjc_cols), "f.")
fjc_extra    <- gsub("f\\.([A-Z]+)", "f.\\1 AS fjc_\\1", fjc_extra)

flags_sql <- "
    (nullif(trim(t.nature_suit), '') IS NULL)                         AS blank_nature_suit,
    (nullif(trim(t.jurisdiction), '') IS NULL)                        AS blank_jurisdiction,
    coalesce(lower(trim(t.jurisdiction)) = 'local question', false)   AS local_question,
    coalesce(t.cause_title IN (SELECT cause_title FROM train_fjc WHERE cause_title IS NOT NULL
                               GROUP BY 1 HAVING count(*) = 1), false) AS single_case_cause_title,
    coalesce(t.county_area_class = 'unmatched county code', false)    AS unmatched_county,
    coalesce(t.first_defendant_type = 'name not recorded', false)     AS defendant_name_missing"
flag_names <- c("blank_nature_suit", "blank_jurisdiction", "local_question", "single_case_cause_title",
                "unmatched_county", "defendant_name_missing")

odd <- dbGetQuery(con, sprintf("
  WITH flagged AS (
    SELECT t.*, %s FROM train_fjc t)
  SELECT t.ucid, t.court, t.case_id, t.year_dir, t.filing_date %s,
         t.nature_suit, t.cause, t.cause_title, t.cause_section, t.jurisdiction,
         t.n_plaintiffs, t.n_defendants, t.first_defendant_type, t.county_area_class, t.arrival_route
         %s, %s
  FROM flagged t LEFT JOIN '%s/fjc_idb_civil.parquet' f ON f.fjc_row = t.fjc_row
  WHERE %s
  ORDER BY t.court, t.ucid",
  flags_sql, scales_extra, fjc_extra, paste0("t.", flag_names, collapse = ", "), pq,
  paste0("t.", flag_names, collapse = " OR ")))

# First defendant's party row, for the "name not recorded" cases (name, role, SCALES party type)
if (any(odd$defendant_name_missing)) {
  dbWriteTable(con, "odd_defendants", data.frame(ucid = odd$ucid[odd$defendant_name_missing]), temporary = TRUE, overwrite = TRUE)
  pdef <- dbGetQuery(con, sprintf("SELECT DISTINCT ON (p.ucid) p.ucid, p.name AS first_defendant_name,
      p.role AS first_defendant_role %s
    FROM '%s/parties.parquet' p SEMI JOIN odd_defendants USING (ucid)
    WHERE regexp_matches(lower(coalesce(p.role, '')), 'defendant|respondent')
    ORDER BY p.ucid, p.party_index", if ("party_type" %in% names(dbGetQuery(con, sprintf("SELECT * FROM '%s/parties.parquet' LIMIT 0", pq))))
      ", p.party_type AS first_defendant_party_type" else "", pq))
  odd <- merge(odd, pdef, by = "ucid", all.x = TRUE)
}
write.csv(odd, file.path(checks_dir, "oddities_cases.csv"), row.names = FALSE)

# ---- Console: counts, then a compact table per flag (no names) ---------------------
counts <- data.frame(flag = flag_names, n_training_cases = vapply(flag_names, function(f) sum(odd[[f]]), 1L))
cat("\nTraining cases with each odd value (a case can have several):\n"); print(counts, row.names = FALSE)
compact <- intersect(c("ucid", "filing_date", "nature_suit", "cause", "jurisdiction", "fjc_NOS", "fjc_JURIS",
                       "fjc_COUNTY", "fjc_TITL", "fjc_SECTION"), names(odd))
for (f in flag_names) if (sum(odd[[f]])) {
  cat("\n--", f, "(first 15; all in oddities_cases.csv)\n")
  x <- odd[odd[[f]], compact, drop = FALSE]
  x$cause <- substr(x$cause, 1, 45); x$nature_suit <- substr(x$nature_suit, 1, 30)
  print(head(x, 15), row.names = FALSE)
}
cat("\nFull headers (with case names) saved to", file.path(checks_dir, "oddities_cases.csv"), "\n")
