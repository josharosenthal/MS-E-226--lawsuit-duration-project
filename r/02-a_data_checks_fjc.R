# =============================================================================
# 02-a_data_checks_fjc.R — the training cases with NO FJC record: how many, how
# long they last, how SCALES says they ended, and where they come from.
#
# Why: in 05_feature_selection.R, six FJC-derived covariates (class action, in
# forma pauperis, arrival route, ...) were associated with duration almost
# entirely through their shared "no FJC record" category. Before relying on that,
# check whether a missing FJC record is harmless (the SCALES-FJC link fails for
# some courts or case types) or reflects how the case ended (e.g. cases opened in
# error, re-filed or sealed may be missing from the FJC file) - which would make
# it leakage. Cases with no FJC record also get their dates from SCALES alone, so
# part 5 checks how far SCALES and FJC termination dates agree when both exist.
#
# FJC status of a case:
#   linked          one FJC record, matched to this case only
#   shared record   the best FJC match is also the best match for another case,
#                   so 00_sample.R gives neither case FJC data
#   no match        no FJC record matched at all
# ("shared record" and "no match" together are the "no FJC record" category.)
#
# RESULT (24 Oct 2026): they were mostly administrative case numbers closed within
# days, so Josh EXCLUDED them from the sample (00_sample.R, CHANGES.md change 42).
# This script still looks at them: it uses the training cases as they were in the
# split, BEFORE that exclusion, so it documents why they were dropped.
#
# TRAINING CASES ONLY (this compares durations): stops if the split doesn't exist.
# Counts only - no docket text or party details are printed or saved.
# Output: printed summary, plus ~/scales_project/checks/fjc_missing_*.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("fjc_missing_", name, ".csv")), row.names = FALSE)

invisible(dbExecute(con, "CREATE OR REPLACE TEMP VIEW fjc_status AS
  SELECT t.*,
    CASE WHEN t.fjc_row IS NOT NULL THEN 'linked'
         WHEN t.ucid IN (SELECT ucid FROM best_link) THEN 'shared record'
         ELSE 'no match' END AS fjc_status
  FROM (SELECT c.*, l.fjc_row, l.fjc_termdate, d.* EXCLUDE (ucid)
        FROM all_cases_dedup c
        JOIN holdout_split h USING (ucid)              -- the cases in the split, before the no-FJC exclusion
        LEFT JOIN best_link_unique l USING (ucid)
        LEFT JOIN case_duration d USING (ucid)
        WHERE NOT h.is_holdout) t"))

# ---- 1. How many --------------------------------------------------------------
counts <- dbGetQuery(con, "SELECT fjc_status, count(*) AS n_cases,
    round(100 * count(*) / sum(count(*)) OVER (), 2) AS pct,
    count(duration_capped_days) AS n_with_duration
  FROM fjc_status GROUP BY 1 ORDER BY 2 DESC")
save_csv(counts, "counts")
cat("\n1. Training cases by FJC status\n"); print(counts, row.names = FALSE)

# ---- 2. How long they last --------------------------------------------------------
durations <- dbGetQuery(con, "SELECT fjc_status, count(*) AS n_ended,
    min(duration_capped_days) AS min_days,
    quantile_cont(duration_capped_days, 0.10) AS p10, quantile_cont(duration_capped_days, 0.25) AS p25,
    median(duration_capped_days) AS median, quantile_cont(duration_capped_days, 0.75) AS p75,
    quantile_cont(duration_capped_days, 0.90) AS p90, max(duration_capped_days) AS max_days,
    round(100 * avg((duration_capped_days = 0)::INT), 1)   AS pct_0_days,
    round(100 * avg((duration_capped_days <= 30)::INT), 1)  AS pct_30d_or_less,
    round(100 * avg((duration_capped_days <= 90)::INT), 1)  AS pct_90d_or_less,
    round(100 * avg((duration_capped_days > 1095)::INT), 1) AS pct_over_3yrs
  FROM fjc_status WHERE event_observed GROUP BY 1 ORDER BY 1")
save_csv(durations, "durations")
cat("\n2. Duration (days) of cases that ended in court, by FJC status\n"); print(durations, row.names = FALSE)

# ---- 3. How SCALES says they ended ---------------------------------------------------
status <- dbGetQuery(con, "SELECT fjc_status, case_status, duration_status, end_date_source, count(*) AS n
  FROM fjc_status GROUP BY ALL ORDER BY 1, 5 DESC")
save_csv(status, "status")
cat("\n3a. SCALES case status, duration status and end-date source\n"); print(status, row.names = FALSE)

entries <- dbGetQuery(con, "SELECT fjc_status,
    round(100 * avg((coalesce(n_docket_entries, 0) = 0)::INT), 1) AS pct_no_entries,
    round(100 * avg((coalesce(n_docket_entries, 0) <= 5)::INT), 1) AS pct_5_or_fewer,
    median(n_docket_entries) AS median_entries
  FROM fjc_status GROUP BY 1 ORDER BY 1")
save_csv(entries, "docket_size")
cat("\n3b. Docket size\n"); print(entries, row.names = FALSE)

# Docket wording: share of cases with at least one entry matching each phrase.
# Every no-FJC case, against an equal-sized random sample of linked cases (fixed order
# by hash, so the same sample each run). Searched in DuckDB; no text is kept.
phrases <- c(opened_in_error = "opened in error|filed in error|opened incorrectly|wrong case number|incorrect case number",
             duplicate_or_refiled = "duplicate|re-?filed",
             transfer = "transferr",
             remand = "remand",
             consolidated = "consolidat",
             voluntary_dismissal = "voluntar",
             sealed = "sealed|under seal")
n_missing <- sum(counts$n_cases[counts$fjc_status != "linked"])
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE fjc_docket_sample AS
  SELECT ucid, 'no FJC record' AS grp
  FROM fjc_status WHERE fjc_status <> 'linked'
  UNION ALL
  SELECT ucid, 'linked (random sample)' FROM
    (SELECT ucid FROM fjc_status WHERE fjc_status = 'linked' ORDER BY hash(ucid || '226') LIMIT %d)", n_missing)))
phrase_cols <- paste(sprintf("bool_or(regexp_matches(lower(e.docket_text), '%s')) AS %s", phrases, names(phrases)), collapse = ",\n    ")
wording <- dbGetQuery(con, sprintf("WITH per_case AS (
    SELECT s.ucid, s.grp, %s
    FROM fjc_docket_sample s LEFT JOIN '%s/docket_entries.parquet' e USING (ucid)
    GROUP BY 1, 2)
  SELECT grp, count(*) AS n_cases, %s FROM per_case GROUP BY 1 ORDER BY 1",
  phrase_cols, pq,
  paste(sprintf("round(100 * avg(coalesce(%s, false)::INT), 1) AS pct_%s", names(phrases), names(phrases)), collapse = ", ")))
save_csv(wording, "docket_wording")
cat("\n3c. % of cases with any docket entry mentioning ... (no-FJC cases vs a same-size sample of linked cases)\n")
print(wording, row.names = FALSE)

# ---- 4. Where they come from ---------------------------------------------------------
share_by <- function(col, min_cases = 200) dbGetQuery(con, sprintf("SELECT %s, count(*) AS n_cases,
    sum((fjc_status <> 'linked')::INT) AS n_no_fjc,
    round(100 * avg((fjc_status <> 'linked')::INT), 2) AS pct_no_fjc
  FROM fjc_status GROUP BY 1 HAVING count(*) >= %d ORDER BY pct_no_fjc DESC", col, min_cases))
by_year  <- share_by("year_dir", 0)
by_court <- share_by("court")
by_nos   <- share_by("nature_suit")
save_csv(by_year, "by_year"); save_csv(by_court, "by_court"); save_csv(by_nos, "by_nature_suit")
cat("\n4a. % with no FJC record, by year\n"); print(by_year, row.names = FALSE)
cat("\n4b. Courts with the highest % (courts with >= 200 training cases; full list in the CSV)\n"); print(head(by_court, 15), row.names = FALSE)
cat("\n4c. Natures of suit with the highest % (>= 200 training cases)\n"); print(head(by_nos, 15), row.names = FALSE)
top_courts <- dbGetQuery(con, "SELECT court, count(*) AS n_no_fjc,
    round(100 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_all_no_fjc
  FROM fjc_status WHERE fjc_status <> 'linked' GROUP BY 1 ORDER BY 2 DESC LIMIT 10")
cat("\n4d. Courts holding the most no-FJC cases\n"); print(top_courts, row.names = FALSE)

# ---- 5. Are SCALES and FJC end dates comparable? -----------------------------------
# For linked cases closed in SCALES, compare the SCALES termination date with the FJC
# one. No-FJC cases rely on the SCALES date alone, so a big typical gap would mean
# their durations are measured differently.
dates <- dbGetQuery(con, "SELECT count(*) AS n_both_dates,
    round(100 * avg((terminating_date = fjc_termdate)::INT), 1) AS pct_same_day,
    round(100 * avg((abs(date_diff('day', fjc_termdate, terminating_date)) <= 7)::INT), 1) AS pct_within_7d,
    round(100 * avg((abs(date_diff('day', fjc_termdate, terminating_date)) > 30)::INT), 1) AS pct_over_30d_apart,
    median(date_diff('day', fjc_termdate, terminating_date)) AS median_scales_minus_fjc
  FROM fjc_status WHERE fjc_status = 'linked' AND terminating_date IS NOT NULL AND fjc_termdate IS NOT NULL")
save_csv(dates, "end_date_agreement")
cat("\n5. Linked cases with both end dates: SCALES vs FJC termination date\n"); print(dates, row.names = FALSE)

cat("\nHow to read this: if no-FJC cases are mostly very short, carry 'opened in error' or\n",
    "'duplicate' wording far more often than linked cases, or have few docket entries, the\n",
    "missing FJC record partly reflects how the case ended (leakage). If they're spread like\n",
    "linked cases and concentrated in a few courts, it's more likely a linking gap.\n",
    "Tables saved in ", checks_dir, " (fjc_missing_*.csv)\n", sep = "")
