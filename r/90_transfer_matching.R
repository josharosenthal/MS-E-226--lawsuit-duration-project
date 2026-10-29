# =============================================================================
# 90_transfer_matching.R — can the cases TRANSFERRED OUT (FJC DISP 0; censored in the
# duration variable) be matched to the case they became in the receiving district?
# If so, the full time to resolution could be followed across courts.
#
# Origin cases: TRAINING cases with duration_status = 'transferred_out'.
# Receiving cases: any civil case in cases.parquet (any filing year), EXCEPT holdout
# cases - they stay untouched, so every count here is a LOWER BOUND on what could be
# matched. A case filed in the receiving court after 2017 is only findable if SCALES
# collected that year (the coverage table below shows which years cases.parquet holds).
#
# Three ways to find the receiving case:
#   1. receiving docket   an early entry (first 10) of a case in ANOTHER court mentions a
#                         transfer and the origin's case number (year + number, e.g.
#                         "1:16-cv-00023" -> 16-23), and that case was filed within
#                         -30 / +365 days of the origin's transfer date
#   2. origin docket      an origin docket entry mentioning a transfer gives another case
#                         number, and a case in another court with that number was filed
#                         in the same window
#   3. FJC only           how many FJC records that arrived by transfer (ORIGIN 5), with the
#                         same nature-of-suit code, were filed 0-60 days after the origin's
#                         transfer date - 1 candidate is a plausible match, more is ambiguous
#                         (needs ORIGIN, NOS, FILEDATE in fjc_idb_civil.parquet)
# A docket-text match also requires the case number to be found in only one receiving
# court; origins with several candidates are counted as ambiguous.
#
# Counts only (no names). Output: ~/scales_project/checks/transfers_*.csv, including
# transfers_spotcheck.csv (case IDs of up to 50 matched pairs, to look up by hand).
# Run as a batch job: it reads the docket entries of every case filed from 2016 on.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("transfers_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
fmt <- function(x) format(x, big.mark = ",")

window_before <- 30      # days before the origin's transfer date a receiving case may be filed
window_after  <- 365     # days after
n_entries     <- 10      # early docket entries searched in receiving cases
# a federal civil case number: optional office "1:", 2-digit year, "cv"/"civ", number
case_no_pat <- "(?i)(?:\\b[0-9]{1,2}:)?\\b([0-9]{2})[ -]?(?:cv|civ|c)[ -]?0*([0-9]{1,6})\\b"
key_of <- function(col) sprintf("regexp_extract(%s, '([0-9]{2})-[a-z]{2,3}-', 1) || '-' || ltrim(regexp_extract(%s, '-[a-z]{2,3}-([0-9]+)', 1), '0')", col, col)

# ---- Origin cases and the receiving pool --------------------------------------------
split <- read.csv(split_file)
dbWriteTable(con, "holdout_ids", split[split$is_holdout %in% TRUE, "ucid", drop = FALSE], temporary = TRUE, overwrite = TRUE)
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE origin AS
  SELECT ucid, court, lower(case_id) AS case_id, %s AS case_key, start_date, end_date, NOS,
         regexp_extract(nature_suit, '^\\s*([0-9]{3})', 1) AS nos_code
  FROM train_fjc WHERE duration_status = 'transferred_out'", key_of("lower(case_id)"))))
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE pool AS
  SELECT ucid, court, year_dir, lower(case_id) AS case_id, %s AS case_key, filing_date, terminating_date
  FROM '%s/cases.parquet'
  WHERE case_type = 'cv' AND ucid NOT IN (SELECT ucid FROM holdout_ids)", key_of("lower(case_id)"), pq)))
n_origin <- q("SELECT count(*) AS n FROM origin")$n
cat(sprintf("\nTransferred-out TRAINING cases: %s.\n", fmt(n_origin)))
cov <- q("SELECT year_dir, count(*) AS n_civil_cases FROM pool GROUP BY 1 ORDER BY 1")
save_csv(cov, "1_pool_years")
cat("Civil cases in cases.parquet available as receiving cases (holdout left out), by filing year:\n"); print(cov, row.names = FALSE)

# ---- 1. Receiving docket names the origin case -------------------------------------------
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE recv_mentions AS
  WITH e AS (
    SELECT d.ucid, CAST(d.docket_text AS VARCHAR) AS txt FROM '%s/docket_entries.parquet' d
    WHERE d.entry_index <= %d AND d.ucid IN (SELECT ucid FROM pool WHERE filing_date >= DATE '2016-01-01')
      AND regexp_matches(lower(CAST(d.docket_text AS VARCHAR)), 'transfer')),
  m AS (SELECT ucid, unnest(regexp_extract_all(txt, '%s', 1)) AS yr,
                     unnest(regexp_extract_all(txt, '%s', 2)) AS num FROM e)
  SELECT DISTINCT ucid, yr || '-' || ltrim(num, '0') AS mentioned_key FROM m", pq, n_entries, case_no_pat, case_no_pat)))
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE match1 AS
  SELECT o.ucid AS origin_ucid, p.ucid AS recv_ucid, p.court AS recv_court
  FROM origin o JOIN recv_mentions r ON r.mentioned_key = o.case_key
  JOIN pool p ON p.ucid = r.ucid
  WHERE p.court <> o.court
    AND p.filing_date BETWEEN o.end_date - INTERVAL %d DAY AND o.end_date + INTERVAL %d DAY",
  window_before, window_after)))

# ---- 2. Origin docket names the receiving case -------------------------------------------
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE origin_mentions AS
  WITH e AS (
    SELECT d.ucid, CAST(d.docket_text AS VARCHAR) AS txt FROM '%s/docket_entries.parquet' d
    WHERE d.ucid IN (SELECT ucid FROM origin) AND regexp_matches(lower(CAST(d.docket_text AS VARCHAR)), 'transfer')),
  m AS (SELECT ucid, unnest(regexp_extract_all(txt, '%s', 1)) AS yr,
                     unnest(regexp_extract_all(txt, '%s', 2)) AS num FROM e)
  SELECT DISTINCT ucid, yr || '-' || ltrim(num, '0') AS mentioned_key FROM m", pq, case_no_pat, case_no_pat)))
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE match2 AS
  SELECT o.ucid AS origin_ucid, p.ucid AS recv_ucid, p.court AS recv_court
  FROM origin o JOIN origin_mentions m ON m.ucid = o.ucid AND m.mentioned_key <> o.case_key
  JOIN pool p ON p.case_key = m.mentioned_key
  WHERE p.court <> o.court
    AND p.filing_date BETWEEN o.end_date - INTERVAL %d DAY AND o.end_date + INTERVAL %d DAY",
  window_before, window_after)))

# ---- Combine: unique vs ambiguous ------------------------------------------------------------
invisible(dbExecute(con, "CREATE OR REPLACE TEMP TABLE matches AS
  WITH a AS (SELECT origin_ucid, recv_ucid, recv_court, 'receiving docket' AS method FROM match1
             UNION ALL SELECT origin_ucid, recv_ucid, recv_court, 'origin docket' FROM match2)
  SELECT origin_ucid, recv_ucid, any_value(recv_court) AS recv_court, string_agg(DISTINCT method, ' + ') AS methods
  FROM a GROUP BY 1, 2"))
invisible(dbExecute(con, "CREATE OR REPLACE TEMP TABLE match_best AS
  SELECT m.*, count(*) OVER (PARTITION BY origin_ucid) AS n_candidates FROM matches m"))
summ <- q(sprintf("SELECT
    %d AS n_transferred_out_training,
    (SELECT count(DISTINCT origin_ucid) FROM match1) AS matched_by_receiving_docket,
    (SELECT count(DISTINCT origin_ucid) FROM match2) AS matched_by_origin_docket,
    count(DISTINCT origin_ucid) AS matched_any,
    count(DISTINCT origin_ucid) FILTER (WHERE n_candidates = 1) AS matched_unique,
    count(DISTINCT origin_ucid) FILTER (WHERE n_candidates > 1) AS matched_ambiguous,
    count(DISTINCT origin_ucid) FILTER (WHERE n_candidates = 1 AND methods LIKE '%%+%%') AS matched_by_both
  FROM match_best", n_origin))
summ$pct_matched_unique <- round(100 * summ$matched_unique / pmax(summ$n_transferred_out_training, 1), 1)

# where the uniquely matched receiving cases are, and whether they've ended
recv <- q("SELECT
    CASE WHEN p.year_dir IN ('16', '17') THEN 'filed 2016-17' ELSE 'filed ' || coalesce(p.year_dir, '?') END AS receiving_filed,
    CASE WHEN t.ucid IS NOT NULL THEN 'in the training sample'
         ELSE 'in cases.parquet, outside the sample' END AS receiving_case,
    count(*) AS n, count(*) FILTER (WHERE p.terminating_date IS NOT NULL) AS n_ended_in_scales
  FROM match_best b JOIN pool p ON p.ucid = b.recv_ucid
  LEFT JOIN (SELECT ucid FROM train_fjc) t ON t.ucid = b.recv_ucid
  WHERE b.n_candidates = 1 GROUP BY 1, 2 ORDER BY 1, 2")
save_csv(summ, "2_summary"); save_csv(recv, "3_receiving_cases")
cat("\nMatches (receiving cases in the holdout are never looked at, so these are lower bounds):\n"); print(t(summ), quote = FALSE)
cat("\nUniquely matched receiving cases:\n"); print(recv, row.names = FALSE)
by_court <- q("SELECT o.court AS origin_court, count(*) AS n_transferred_out,
    count(b.origin_ucid) AS n_matched_unique FROM origin o
  LEFT JOIN (SELECT DISTINCT origin_ucid FROM match_best WHERE n_candidates = 1) b ON b.origin_ucid = o.ucid
  GROUP BY 1 ORDER BY 2 DESC")
by_court$pct_matched <- round(100 * by_court$n_matched_unique / by_court$n_transferred_out, 1)
save_csv(by_court, "4_by_origin_court")
cat("\nBy origin court (15 with the most transfers out):\n"); print(head(by_court, 15), row.names = FALSE)
save_csv(q("SELECT origin_ucid, recv_ucid, recv_court, methods FROM match_best WHERE n_candidates = 1
            ORDER BY hash(origin_ucid) LIMIT 50"), "spotcheck")

# ---- 3. FJC only: transferred-in records filed soon after, same nature of suit ----------------
fjc_cols <- names(q(sprintf("SELECT * FROM '%s/fjc_idb_civil.parquet' LIMIT 0", pq)))
if (all(c("ORIGIN", "NOS", "FILEDATE") %in% fjc_cols)) {
  fjc <- q(sprintf("WITH tin AS (
      SELECT f.fjc_row, lpad(trim(CAST(f.NOS AS VARCHAR)), 3, '0') AS nos_code, coalesce(TRY_CAST(f.FILEDATE AS DATE),
               TRY_CAST(try_strptime(CAST(f.FILEDATE AS VARCHAR), '%%m/%%d/%%Y') AS DATE)) AS fdate
      FROM '%s/fjc_idb_civil.parquet' f
      WHERE trim(CAST(f.ORIGIN AS VARCHAR)) = '5'
        AND f.fjc_row NOT IN (SELECT l.fjc_row FROM best_link l JOIN holdout_ids h USING (ucid))),
    c AS (SELECT o.ucid, count(t.fjc_row) AS n_candidates FROM origin o
          LEFT JOIN tin t ON t.nos_code = o.nos_code AND t.fdate BETWEEN o.end_date AND o.end_date + INTERVAL 60 DAY
          GROUP BY 1)
    SELECT CASE WHEN n_candidates = 0 THEN '0 candidates' WHEN n_candidates = 1 THEN '1 candidate'
                WHEN n_candidates <= 5 THEN '2-5' WHEN n_candidates <= 20 THEN '6-20' ELSE 'more than 20' END AS fjc_candidates,
           count(*) AS n_origin_cases FROM c GROUP BY 1 ORDER BY min(n_candidates)", pq))
  save_csv(fjc, "5_fjc_candidates")
  cat("\n3. FJC only: transferred-in FJC records, same nature of suit, filed 0-60 days after each transfer out:\n")
  print(fjc, row.names = FALSE)
} else cat("\n3. FJC only: skipped (fjc_idb_civil.parquet has no ORIGIN / NOS / FILEDATE columns).\n")
cat("\nTables saved in", checks_dir, "(transfers_*.csv)\n")
