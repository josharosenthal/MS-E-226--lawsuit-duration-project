#!/usr/bin/env bash
# =============================================================================
# 02_flatten_cases.sh — turn the 676,809 case JSONs into five Parquet tables
# (cases, parties, counsel, docket_entries, criminal_counts).
#   Part A: flatten_scales.py streams through the .tar.gz (nothing unpacked to disk)
#   Part B: DuckDB converts the flat files to Parquet
# Budget 1-2 hours. Nothing is filtered: every case and every docket line is kept.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

contact_flag=""; [ "$KEEP_CONTACT_INFO" = "yes" ] && contact_flag="--keep-contact-info"

echo "== Part A: flattening the case archive (progress every 20,000 cases)"
"$PYTHON" flatten_scales.py "$CASES_ARCHIVE" "$FLAT_DIR" "$PARQUET_DIR" $contact_flag \
  --expected-cases "$EXPECTED_CASES"

echo "== Part B: converting to Parquet"
"$DUCKDB" -c "SET memory_limit = '$DUCKDB_MEMORY'; SET threads = $DUCKDB_THREADS;
              SET temp_directory = '$WORK_DIR/tmp'; SET preserve_insertion_order = false;
              $(cat "$FLAT_DIR/convert_to_parquet.sql")"

echo "== Files that could not be read: $(( $(wc -l < "$FLAT_DIR/parse_errors.csv") - 1 ))  (details: $FLAT_DIR/parse_errors.csv)"
cp "$FLAT_DIR/keys_report.csv" "$FLAT_DIR/parse_errors.csv" "$PROFILE_DIR/"
ls -lh "$PARQUET_DIR"
echo "   The .jsonl.gz files in $FLAT_DIR can be deleted once you're happy with the Parquet files."
