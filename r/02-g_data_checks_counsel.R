# =============================================================================
# 02-g_data_checks_counsel.R — where does n_counsel's leakage come from?
# (Josh, 28 Oct 2026)
#
# n_counsel (flatten_scales.py) = every lawyer listing on every party, as SCALES
# collected the docket (usually after the case ended). This splits it up, by side
# (plaintiff / defendant, as in 01_build_features.R) and by how long the case lasted:
#   lawyers at collection   distinct lawyer names on that side (repeat listings of
#                           the same lawyer for several parties count once; pro se
#                           listings are not lawyers)
#   lawyers at filing       of those, the ones named in a docket entry dated within
#                           filing_window_days of the filing date (the complaint or
#                           notice of removal, and its filer). A lawyer matches an
#                           entry when both the first and last word of the name
#                           appear in it. The counsel table has no dates, so docket
#                           text is the only source; counsel_6_match_rate.csv shows
#                           how often lawyers are named in the docket at all.
#   added after filing      at collection minus at filing
#   terminated listings     a counsel field says TERMINATED (SCALES has no separate
#                           field; counsel_1_fields.csv shows where it appears)
#   pro hac vice listings   is_pro_hac_vice, or a field says "pro hac vice"
#   listings for dismissed  lawyers listed for a party with its own terminating date
#   parties                 (e.g. a defendant dismissed early)
#   pro se and lawyer       the plaintiff side has both a pro se listing and a lawyer
# Case-level, from docket text: entries about withdrawal or substitution of counsel.
#
# TRAINING CASES ONLY (it uses durations); the holdout is untouched. Counts only:
# no names are printed or saved.
# Output: ~/scales_project/checks/counsel_*.csv
#   counsel_1_fields.csv          values of designation / bar_status / trial_bar_status,
#                                 and which fields mention "terminat" or "pro hac"
#   counsel_2_by_band.csv         every measure above, by side and duration band
#   counsel_3_withdrawals.csv     docket entries on withdrawal / substitution, by band
#   counsel_4_decomposition.csv   n_counsel split into its parts, by band
#   counsel_5_correlations.csv    rank correlation of each count with duration (ended cases)
#   counsel_6_match_rate.csv      share of lawyers named anywhere in the docket / at filing,
#                                 by side and by court
#   counsel_spotcheck.csv         30 random training cases (ucid and counts) to look up
# Run as a batch job (it reads every training docket entry): --mem=32G, about an hour.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("counsel_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
ex <- function(sql) invisible(dbExecute(con, sql))
step <- function(msg) cat(sprintf("%s  %s\n", format(Sys.time(), "%H:%M:%S"), msg))
# keep DuckDB inside the batch job's memory (it would otherwise size itself to the whole node), spilling to disk
tmp_dir <- file.path(project_dir, "tmp_duckdb"); dir.create(tmp_dir, showWarnings = FALSE)
ex(sprintf("SET memory_limit = '%s'", Sys.getenv("SCALES_DUCKDB_MEMORY", "24GB")))
ex(sprintf("SET temp_directory = '%s'", tmp_dir)); ex("SET preserve_insertion_order = false")

# ---- Settings ----------------------------------------------------------------------
filing_window_days <- 7      # "at filing" = named in a docket entry within this many days of filing
band_breaks <- c(60, 120, 365, 730)
withdraw_regex <- "withdraw[a-z]* (as )?(of )?(counsel|attorney)|motion to withdraw|substitut[a-z]* (of )?(counsel|attorney)|change of (counsel|attorney)"

# ---- Training cases and duration bands ------------------------------------------------------
band_sql <- paste0("CASE WHEN duration_status = 'transferred_out' THEN 'transferred out' ",
  paste(sprintf("WHEN duration_capped_days <= %d THEN '%s'", band_breaks,
                sprintf("%s-%d days", c(0, head(band_breaks, -1) + 1), band_breaks)), collapse = " "),
  sprintf(" ELSE 'over %d days' END", max(band_breaks)))
band_levels <- c(sprintf("%s-%d days", c(0, head(band_breaks, -1) + 1), band_breaks), sprintf("over %d days", max(band_breaks)), "transferred out")
step("training cases")
ex(sprintf("CREATE OR REPLACE TEMP TABLE g_cases AS
  SELECT ucid, court, start_date, duration_capped_days, event_observed, %s AS n_counsel, %s AS band
  FROM train_fjc WHERE duration_capped_days IS NOT NULL",
  if ("n_counsel" %in% dbListFields(con, "train_fjc")) "n_counsel" else "CAST(NULL AS INTEGER)", band_sql))

# ---- Counsel listings, with side and flags ---------------------------------------------------
step("counsel listings")
cols <- function(t) q(sprintf("DESCRIBE SELECT * FROM '%s/%s.parquet'", pq, t))$column_name
kcols <- cols("counsel"); pcols <- cols("parties")
col_or_null <- function(x, have, type = "VARCHAR") if (x %in% have) sprintf("k.%s", x) else sprintf("CAST(NULL AS %s)", type)
text_fields <- c("designation", "bar_status", "trial_bar_status", "office_name", "name")
txt <- sapply(text_fields, function(f) sprintf("lower(coalesce(CAST(%s AS VARCHAR), ''))", col_or_null(f, kcols)))
party_term <- if ("terminating_date" %in% pcols) "p.terminating_date IS NOT NULL" else "false"
ex(sprintf("CREATE OR REPLACE TEMP TABLE g_listings AS
  WITH k AS (SELECT * FROM '%s/counsel.parquet' WHERE ucid IN (SELECT ucid FROM g_cases)),
  p AS (SELECT ucid, party_index, %s AS party_terminated,
          CASE WHEN regexp_matches(lower(trim(coalesce(CAST(role AS VARCHAR), ''))), '^(plaintiff|petitioner)') THEN 'P'
               WHEN regexp_matches(lower(trim(coalesce(CAST(role AS VARCHAR), ''))), '^(defendant|respondent)') THEN 'D'
               WHEN lower(coalesce(CAST(party_type AS VARCHAR), '')) LIKE 'plaintiff%%' THEN 'P'
               WHEN lower(coalesce(CAST(party_type AS VARCHAR), '')) LIKE 'defendant%%' THEN 'D' END AS side
        FROM '%s/parties.parquet' p WHERE ucid IN (SELECT ucid FROM g_cases)),
  n AS (SELECT k.ucid, k.party_index, coalesce(p.side, 'other') AS side, coalesce(p.party_terminated, false) AS party_terminated,
          coalesce(%s, false) AS is_pro_se, coalesce(%s, false) AS is_phv_flag,
          %s AS t_designation, %s AS t_bar_status, %s AS t_trial_bar_status, %s AS t_office, %s AS t_name,
          trim(regexp_replace(regexp_replace(lower(strip_accents(coalesce(CAST(k.name AS VARCHAR), ''))), '[^a-z]+', ' ', 'g'),
               '(^| )(jr|sr|ii|iii|iv|esq|esquire|mr|ms|mrs|dr)( |$)', ' ', 'g')) AS name_n
        FROM k LEFT JOIN p ON p.ucid = k.ucid AND p.party_index = k.party_index)
  SELECT *, regexp_replace(name_n, ' +', ' ', 'g') AS name_key,
         split_part(name_n, ' ', 1) AS first_w, list_extract(string_split(regexp_replace(name_n, ' +', ' ', 'g'), ' '), -1) AS last_w,
         regexp_matches(t_designation || ' ' || t_bar_status || ' ' || t_trial_bar_status || ' ' || t_office || ' ' || t_name, 'terminat') AS is_terminated,
         is_phv_flag OR regexp_matches(t_designation || ' ' || t_bar_status || ' ' || t_trial_bar_status, 'pro hac') AS is_phv,
         NOT is_pro_se AND name_n <> '' AS is_lawyer
  FROM n", pq, party_term, pq, col_or_null("is_pro_se", kcols, "BOOLEAN"), col_or_null("is_pro_hac_vice", kcols, "BOOLEAN"),
  txt[["designation"]], txt[["bar_status"]], txt[["trial_bar_status"]], txt[["office_name"]], txt[["name"]]))

# ---- 1. Which fields carry TERMINATED / pro hac vice, and their common values ---------------------
step("1. counsel fields")
n_list <- q("SELECT count(*) AS n FROM g_listings")$n
flag_tab <- do.call(rbind, lapply(c("t_designation", "t_bar_status", "t_trial_bar_status", "t_office", "t_name"), function(f)
  q(sprintf("SELECT '%s' AS field, count(*) FILTER (WHERE %s <> '') AS n_filled,
                    count(*) FILTER (WHERE regexp_matches(%s, 'terminat')) AS n_mention_terminated,
                    count(*) FILTER (WHERE regexp_matches(%s, 'pro hac')) AS n_mention_pro_hac_vice FROM g_listings",
            sub("^t_", "", f), f, f, f))))
flag_tab <- rbind(flag_tab, data.frame(field = "is_pro_hac_vice (true)", n_filled = NA,
  n_mention_terminated = NA, n_mention_pro_hac_vice = q("SELECT count(*) AS n FROM g_listings WHERE is_phv_flag")$n))
flag_tab$pct_of_listings_terminated <- round(100 * flag_tab$n_mention_terminated / n_list, 2)
# common values (dates and numbers replaced by #, so values group); names and offices are never listed
vals <- do.call(rbind, lapply(c("t_designation", "t_bar_status", "t_trial_bar_status"), function(f)
  q(sprintf("SELECT '%s' AS field, left(regexp_replace(%s, '[0-9]+', '#', 'g'), 60) AS value, count(*) AS n_listings
             FROM g_listings WHERE %s <> '' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 15", sub("^t_", "", f), f, f))))
out1 <- data.frame(part = "flags", field = flag_tab$field, value = NA, n_listings = flag_tab$n_filled,
                   n_mention_terminated = flag_tab$n_mention_terminated, n_mention_pro_hac_vice = flag_tab$n_mention_pro_hac_vice)
if (nrow(vals)) out1 <- rbind(out1, data.frame(part = "common values", vals, n_mention_terminated = NA, n_mention_pro_hac_vice = NA))
save_csv(out1, "1_fields")
cat(sprintf("\n%s counsel listings on training cases. Fields mentioning TERMINATED / pro hac vice:\n", format(n_list, big.mark = ",")))
print(flag_tab, row.names = FALSE)
cat("\nMost common values (digits shown as #):\n"); print(vals, row.names = FALSE)

# ---- Distinct lawyers per case and side, and whether each is named at filing ------------------
step("docket text (training cases)")
ex(sprintf("CREATE OR REPLACE TEMP TABLE g_docket AS
  SELECT d.ucid, CAST(d.date_filed AS DATE) AS date_filed, CAST(d.date_filed AS DATE) <= c.start_date + %d AS in_window,
         ' ' || regexp_replace(lower(strip_accents(coalesce(CAST(d.docket_text AS VARCHAR), ''))), '[^a-z]+', ' ', 'g') || ' ' AS t,
         regexp_matches(lower(coalesce(CAST(d.docket_text AS VARCHAR), '')), '%s') AS is_withdraw
  FROM '%s/docket_entries.parquet' d JOIN g_cases c USING (ucid)", filing_window_days, withdraw_regex, pq))
step("lawyers, and docket mentions")
ex("CREATE OR REPLACE TEMP TABLE g_lawyers AS
  SELECT ucid, side, name_key, any_value(first_w) AS first_w, any_value(last_w) AS last_w,
         count(*) AS n_listings, bool_or(is_terminated) AS any_terminated, bool_or(is_phv) AS any_phv
  FROM g_listings WHERE is_lawyer GROUP BY ALL")
ex("CREATE OR REPLACE TEMP TABLE g_mentions AS
  SELECT l.ucid, l.side, l.name_key, bool_or(d.in_window) AS at_filing, count(*) AS n_entries
  FROM g_lawyers l JOIN g_docket d ON d.ucid = l.ucid
  WHERE l.first_w <> l.last_w AND length(l.last_w) >= 2
    AND contains(d.t, ' ' || l.last_w || ' ') AND contains(d.t, ' ' || l.first_w || ' ')
  GROUP BY ALL")
ex("CREATE OR REPLACE TEMP TABLE g_lawyers2 AS
  SELECT l.*, m.ucid IS NOT NULL AS ever_named, coalesce(m.at_filing, false) AS at_filing,
         l.first_w <> l.last_w AND length(l.last_w) >= 2 AS matchable
  FROM g_lawyers l LEFT JOIN g_mentions m USING (ucid, side, name_key)")

# ---- Per case and side ---------------------------------------------------------------------
step("per case and side")
ex("CREATE OR REPLACE TEMP TABLE g_side AS
  WITH s AS (SELECT * FROM (VALUES ('P'), ('D')) v(side)),
  li AS (SELECT ucid, side, count(*) AS listings, count(*) FILTER (WHERE is_pro_se) AS pro_se_listings,
                count(*) FILTER (WHERE is_lawyer AND is_terminated) AS terminated_listings,
                count(*) FILTER (WHERE is_lawyer AND is_phv) AS phv_listings,
                count(*) FILTER (WHERE is_lawyer AND party_terminated) AS dismissed_party_listings
         FROM g_listings GROUP BY ALL),
  la AS (SELECT ucid, side, count(*) AS lawyers_collection, count(*) FILTER (WHERE at_filing) AS lawyers_filing
         FROM g_lawyers2 GROUP BY ALL)
  SELECT c.ucid, c.band, s.side, coalesce(li.listings, 0) AS listings, coalesce(li.pro_se_listings, 0) AS pro_se_listings,
         coalesce(la.lawyers_collection, 0) AS lawyers_collection, coalesce(la.lawyers_filing, 0) AS lawyers_filing,
         coalesce(li.terminated_listings, 0) AS terminated_listings, coalesce(li.phv_listings, 0) AS phv_listings,
         coalesce(li.dismissed_party_listings, 0) AS dismissed_party_listings
  FROM g_cases c CROSS JOIN s LEFT JOIN li USING (ucid, side) LEFT JOIN la USING (ucid, side)")

# ---- 2. Every measure by side and duration band --------------------------------------------------
step("2. by band")
by_band <- q("SELECT band, side, count(*) AS n_cases,
    round(avg(listings), 2) AS mean_listings,
    round(avg(lawyers_collection), 2) AS mean_lawyers_collection,
    round(avg(lawyers_filing), 2) AS mean_lawyers_filing,
    round(avg(lawyers_collection - lawyers_filing), 2) AS mean_added_after_filing,
    round(100 * avg(CAST(lawyers_collection = 0 AS INTEGER)), 1) AS pct_no_lawyer_collection,
    round(100 * avg(CAST(lawyers_filing = 0 AS INTEGER)), 1) AS pct_no_lawyer_filing,
    round(avg(terminated_listings), 3) AS mean_terminated_listings,
    round(100 * avg(CAST(terminated_listings > 0 AS INTEGER)), 1) AS pct_any_terminated,
    round(avg(phv_listings), 3) AS mean_phv_listings,
    round(100 * avg(CAST(phv_listings > 0 AS INTEGER)), 1) AS pct_any_phv,
    round(avg(dismissed_party_listings), 3) AS mean_listings_dismissed_parties,
    round(100 * avg(CAST(pro_se_listings > 0 AS INTEGER)), 1) AS pct_any_pro_se,
    round(100 * avg(CAST(pro_se_listings > 0 AND lawyers_collection > 0 AS INTEGER)), 2) AS pct_pro_se_and_lawyer
  FROM g_side GROUP BY ALL")
by_band$band <- factor(by_band$band, band_levels)
by_band <- by_band[order(by_band$side != "P", by_band$band), ]
save_csv(by_band, "2_by_band")
for (s in c("P", "D")) {
  cat(sprintf("\n%s side, by how long the case lasted:\n", c(P = "PLAINTIFF", D = "DEFENDANT")[[s]]))
  print(by_band[by_band$side == s, setdiff(names(by_band), "side")], row.names = FALSE)
}

# ---- 3. Docket entries on withdrawal / substitution of counsel ---------------------------------------
step("3. withdrawals")
wd <- q("SELECT c.band, count(*) AS n_cases, round(avg(coalesce(w.n, 0)), 3) AS mean_withdraw_entries,
           round(100 * avg(CAST(coalesce(w.n, 0) > 0 AS INTEGER)), 1) AS pct_any_withdraw_entry
         FROM g_cases c LEFT JOIN (SELECT ucid, count(*) AS n FROM g_docket WHERE is_withdraw GROUP BY 1) w USING (ucid)
         GROUP BY 1")
wd$band <- factor(wd$band, band_levels); wd <- wd[order(wd$band), ]
save_csv(wd, "3_withdrawals")
cat("\nDocket entries about withdrawal or substitution of counsel (whole case, both sides):\n"); print(wd, row.names = FALSE)

# ---- 4. n_counsel split into its parts ------------------------------------------------------------
# n_counsel = pro se listings + repeat listings of the same lawyer + lawyers named at filing
#             + lawyers added after filing + listings on parties that are neither side ("other")
step("4. decomposition")
dec <- q("WITH per AS (
    SELECT ucid, sum(CASE WHEN side IN ('P', 'D') THEN 0 ELSE 1 END) AS other_listings, count(*) AS all_listings
    FROM g_listings GROUP BY 1),
  sd AS (SELECT ucid, any_value(band) AS band, sum(pro_se_listings) AS pro_se, sum(listings - pro_se_listings - lawyers_collection) AS repeats,
                sum(lawyers_filing) AS at_filing, sum(lawyers_collection - lawyers_filing) AS added_later,
                sum(terminated_listings) AS terminated, sum(phv_listings) AS phv
         FROM g_side GROUP BY 1)
  SELECT sd.band, count(*) AS n_cases, round(avg(c.n_counsel), 2) AS mean_n_counsel,
    round(avg(coalesce(per.all_listings, 0)), 2) AS mean_listings_here,
    round(avg(sd.pro_se), 2) AS pro_se_listings, round(avg(sd.repeats), 2) AS repeat_listings,
    round(avg(coalesce(per.other_listings, 0)), 2) AS other_party_listings,
    round(avg(sd.at_filing), 2) AS lawyers_at_filing, round(avg(sd.added_later), 2) AS lawyers_added_later,
    round(avg(sd.terminated), 3) AS of_listings_terminated, round(avg(sd.phv), 3) AS of_listings_pro_hac_vice,
    round(100 * avg(CASE WHEN c.n_counsel IS NOT NULL THEN CAST(c.n_counsel <> coalesce(per.all_listings, 0) AS INTEGER) END), 2) AS pct_cases_count_mismatch
  FROM sd JOIN g_cases c USING (ucid) LEFT JOIN per USING (ucid) GROUP BY 1")
dec$band <- factor(dec$band, band_levels); dec <- dec[order(dec$band), ]
save_csv(dec, "4_decomposition")
cat("\nn_counsel split into its parts (means per case; both sides):\n"); print(dec, row.names = FALSE)
cat("(pct_cases_count_mismatch: cases where n_counsel differs from the listings counted here - should be about 0)\n")

# ---- 5. Rank correlation with duration (cases that ended in court) -------------------------------------
step("5. correlations")
w <- q("SELECT c.ucid, c.duration_capped_days AS days, c.n_counsel,
    sum(lawyers_collection) FILTER (WHERE side = 'P') AS p_collection, sum(lawyers_filing) FILTER (WHERE side = 'P') AS p_filing,
    sum(lawyers_collection) FILTER (WHERE side = 'D') AS d_collection, sum(lawyers_filing) FILTER (WHERE side = 'D') AS d_filing,
    sum(terminated_listings) AS terminated, sum(phv_listings) AS phv, sum(dismissed_party_listings) AS dismissed_party,
    sum(listings - pro_se_listings - lawyers_collection) AS repeats
  FROM g_side s JOIN g_cases c USING (ucid) WHERE c.event_observed GROUP BY ALL")
w$p_added <- w$p_collection - w$p_filing; w$d_added <- w$d_collection - w$d_filing
measures <- c(n_counsel = "n_counsel (current variable)", p_collection = "plaintiff lawyers at collection",
              p_filing = "plaintiff lawyers at filing", p_added = "plaintiff lawyers added after filing",
              d_collection = "defendant lawyers at collection", d_filing = "defendant lawyers at filing",
              d_added = "defendant lawyers added after filing", repeats = "repeat listings of the same lawyer",
              terminated = "terminated listings", phv = "pro hac vice listings", dismissed_party = "listings for dismissed parties")
cors <- data.frame(measure = unname(measures), variable = names(measures),
                   spearman_with_days = sapply(names(measures), function(m) if (sum(!is.na(w[[m]])) < 3) NA else round(suppressWarnings(cor(w[[m]], w$days, method = "spearman", use = "complete.obs")), 3)),
                   pct_cases_nonzero = sapply(names(measures), function(m) round(100 * mean(w[[m]] > 0, na.rm = TRUE), 1)), row.names = NULL)
save_csv(cors, "5_correlations")
cat(sprintf("\nRank (Spearman) correlation with days to ending, %s training cases that ended in court:\n", format(nrow(w), big.mark = ",")))
print(cors, row.names = FALSE)

# ---- 6. How often are lawyers named in the docket at all? -------------------------------------------
step("6. match rate")
mr_side <- q("SELECT side, count(*) AS n_lawyers, round(100 * avg(CAST(matchable AS INTEGER)), 1) AS pct_two_word_name,
    round(100 * avg(CAST(ever_named AS INTEGER)), 1) AS pct_named_in_docket,
    round(100 * avg(CAST(at_filing AS INTEGER)), 1) AS pct_named_at_filing
  FROM g_lawyers2 WHERE side IN ('P', 'D') GROUP BY 1 ORDER BY 1 DESC")
mr_court <- q("SELECT c.court, count(*) AS n_lawyers, round(100 * avg(CAST(l.ever_named AS INTEGER)), 1) AS pct_named_in_docket,
    round(100 * avg(CAST(l.at_filing AND l.side = 'P' AS INTEGER)) / nullif(avg(CAST(l.side = 'P' AS INTEGER)), 0), 1) AS pct_plaintiff_lawyers_at_filing
  FROM g_lawyers2 l JOIN g_cases c USING (ucid) WHERE l.side IN ('P', 'D') GROUP BY 1 ORDER BY 3")
save_csv(rbind(cbind(level = "side", group = mr_side$side, mr_side[c("n_lawyers", "pct_named_in_docket", "pct_named_at_filing")]),
               cbind(level = "court", group = mr_court$court, n_lawyers = mr_court$n_lawyers, pct_named_in_docket = mr_court$pct_named_in_docket,
                     pct_named_at_filing = mr_court$pct_plaintiff_lawyers_at_filing)), "6_match_rate")
cat("\nHow often each lawyer is named in the case's docket text (the basis for 'at filing'):\n"); print(mr_side, row.names = FALSE)
cat("\nCourts with the LOWEST share named (at filing = plaintiff lawyers only):\n"); print(head(mr_court, 10), row.names = FALSE)

# ---- Spot check: 30 random training cases (ucid and counts, no names) ---------------------------------
set.seed(226)
spot <- q("SELECT ucid, band,
    sum(listings) FILTER (WHERE side = 'P') AS p_listings, sum(lawyers_filing) FILTER (WHERE side = 'P') AS p_filing,
    sum(lawyers_collection) FILTER (WHERE side = 'P') AS p_collection,
    sum(listings) FILTER (WHERE side = 'D') AS d_listings, sum(lawyers_filing) FILTER (WHERE side = 'D') AS d_filing,
    sum(lawyers_collection) FILTER (WHERE side = 'D') AS d_collection,
    sum(terminated_listings) AS terminated, sum(phv_listings) AS phv
  FROM g_side GROUP BY ALL")
spot <- spot[sample(nrow(spot), min(30, nrow(spot))), ]
spot$band <- factor(spot$band, band_levels); spot <- spot[order(spot$band, spot$ucid), ]
save_csv(spot, "spotcheck")
unlink(tmp_dir, recursive = TRUE)
cat("\nTables saved in", checks_dir, "(counsel_*.csv)\n")
