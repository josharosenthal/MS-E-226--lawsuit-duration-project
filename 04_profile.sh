#!/usr/bin/env bash
# =============================================================================
# 04_profile.sh — describe the "shape" of every table and save it as CSV:
#   * every column: type, % missing, approx. number of distinct values, min/max
#   * 10,000-row random samples to open in RStudio
#   * coverage: cases by year folder, court, case type, filing year
#   * structure: entries / parties / lawyers per case; junk-case flags
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

P="$PARQUET_DIR"; O="$PROFILE_DIR"
SET="SET memory_limit = '$DUCKDB_MEMORY'; SET threads = $DUCKDB_THREADS; SET temp_directory = '$WORK_DIR/tmp';"
q ()   { "$DUCKDB" -c "$SET $1"; }                         # run a query
val () { "$DUCKDB" -noheader -list -c "$SET $1" | tail -n 1; }   # get a single value
out () { q "COPY ($2) TO '$O/$1.csv' (HEADER);"; echo "   wrote $1.csv"; }

tables=(cases parties counsel docket_entries criminal_counts)

echo "== Column reports and samples"
for t in "${tables[@]}"; do
  echo "-- $t: $(val "SELECT count(*) FROM '$P/$t.parquet'") rows"
  # SUMMARIZE = DuckDB's one-line-per-column overview. Long text is cut to 80 characters.
  out "$t.columns" "SELECT column_name, column_type, null_percentage, approx_unique,
                           left(min, 80) AS min, left(max, 80) AS max
                    FROM (SUMMARIZE SELECT * FROM '$P/$t.parquet')"
  out "$t.sample_${SAMPLE_ROWS}" "SELECT * FROM '$P/$t.parquet'
                    USING SAMPLE reservoir($SAMPLE_ROWS ROWS) REPEATABLE ($SAMPLE_SEED)"
done

echo "== Case coverage"
out cases.by_year_dir_and_type "SELECT year_dir, case_type, count(*) AS n_cases,
       round(100.0 * avg((terminating_date IS NOT NULL)::INT), 1) AS pct_with_terminating_date
  FROM '$P/cases.parquet' GROUP BY ALL ORDER BY 1, 3 DESC"
out cases.by_filing_year "SELECT year(filing_date) AS filing_year, year_dir, count(*) AS n_cases
  FROM '$P/cases.parquet' GROUP BY ALL ORDER BY 1, 2"
out cases.by_court "SELECT court, count(*) AS n_cases,
       count(*) FILTER (WHERE case_type = 'cv') AS n_civil,
       count(*) FILTER (WHERE case_type = 'cr') AS n_criminal,
       round(100.0 * avg(is_mdl::INT), 1) AS pct_mdl
  FROM '$P/cases.parquet' GROUP BY 1 ORDER BY 2 DESC"
out cases.by_source "SELECT source, is_stub, is_private, count(*) AS n_cases
  FROM '$P/cases.parquet' GROUP BY ALL ORDER BY 4 DESC"
out cases.flags "SELECT
    count(*) AS n_cases,
    count(*) FILTER (WHERE is_mdl)                       AS n_mdl,
    count(*) FILTER (WHERE filed_in_error_text IS NOT NULL) AS n_filed_in_error,
    count(*) FILTER (WHERE docket_available = FALSE)     AS n_no_docket_table,
    count(*) FILTER (WHERE n_docket_entries = 0)         AS n_zero_entries,
    count(*) FILTER (WHERE filing_date IS NULL)          AS n_missing_filing_date,
    count(DISTINCT ucid)                                 AS n_distinct_ucid
  FROM '$P/cases.parquet'"
cat "$O/cases.flags.csv"

echo "== Structure per case (quartiles)"
out cases.size_per_case "SELECT case_type,
    quantile_cont(n_docket_entries, [0.1, 0.25, 0.5, 0.75, 0.9, 0.99]) AS docket_entries_p10_p25_p50_p75_p90_p99,
    quantile_cont(n_parties,        [0.1, 0.25, 0.5, 0.75, 0.9, 0.99]) AS parties_quantiles,
    quantile_cont(n_counsel,        [0.1, 0.25, 0.5, 0.75, 0.9, 0.99]) AS counsel_quantiles
  FROM '$P/cases.parquet' GROUP BY 1 ORDER BY 1"
out parties.by_party_type "SELECT party_type, count(*) AS n_parties FROM '$P/parties.parquet' GROUP BY 1 ORDER BY 2 DESC"
out parties.top_roles "SELECT role, count(*) AS n FROM '$P/parties.parquet' GROUP BY 1 ORDER BY 2 DESC LIMIT 50"
out counsel.flags "SELECT count(*) AS n_counsel_rows,
    count(*) FILTER (WHERE is_pro_se) AS n_pro_se, count(*) FILTER (WHERE is_lead_attorney) AS n_lead,
    count(*) FILTER (WHERE is_pro_hac_vice) AS n_pro_hac_vice, count(*) FILTER (WHERE has_see_above) AS n_see_above
  FROM '$P/counsel.parquet'"

echo "== Done. Everything is in $O"
ls "$O"
