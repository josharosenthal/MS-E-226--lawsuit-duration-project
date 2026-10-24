#!/usr/bin/env bash
# =============================================================================
# 05_import_fjc.sh — add the Federal Judicial Center's Integrated Database (IDB)
# civil file, which records HOW each federal civil case ended (disposition,
# judgment for whom, nature of judgment, procedural progress), and link it to
# the SCALES cases.
#
#   Step 1, on the LOGIN node (needs internet; ~330 MB download):
#       bash 05_import_fjc.sh download
#   Step 2, as a batch job (about 2 GB of text to convert):
#       sbatch --time=01:00:00 --cpus-per-task=4 --mem=16G \
#              --output=fjc_%j.out --wrap="bash 05_import_fjc.sh"
#
# Makes (in PARQUET_DIR):
#   fjc_idb_civil.parquet    every row and column of the FJC file, as text, plus
#                            fjc_row (its row number in the file). A few malformed
#                            lines are repaired first (fix_fjc_text.py; list in
#                            profiles/fjc.repaired_lines.csv). Codebook:
#                            https://www.fjc.gov/research/idb
#   scales_fjc_link.parquet  one row per (SCALES civil case, matching FJC record),
#                            with the FJC outcome fields. fjc_rank = 1 marks the
#                            best match when a case has more than one (see below).
# and link reports fjc.*.csv in PROFILE_DIR.
#
# How cases are matched: SCALES ucid "ilnd;;1:16-cv-04871" = court ilnd, office 1,
# docket 16 + 04871. FJC = DISTRICT 52 (-> ilnd, via fjc_district_crosswalk.csv),
# OFFICE 1, DOCKET 1604871. All three must agree. Leading zeros in the office are
# ignored. A case can have several FJC records (e.g. it was reopened), so they
# are ranked: FJC filing date equal to the SCALES filing date first, then
# terminated before pending, then the latest file year.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

if [ "${1:-}" = "download" ]; then
  echo "== Downloading $FJC_URL"
  curl -fL --retry 3 -o "$FJC_ZIP" "$FJC_URL"
  if unzip -tq "$FJC_ZIP"; then echo "   OK: zip is intact ($(du -h "$FJC_ZIP" | cut -f1))"
  else echo "   STOP: the zip is corrupted or incomplete. Run the download again."; exit 1; fi
  {
    echo
    echo "FJC IDB civil cumulative file, downloaded $(date -u '+%Y-%m-%d %H:%M UTC') from $FJC_URL"
    ls -l "$FJC_ZIP"
    sha256sum "$FJC_ZIP"
  } >> "$RAW_DIR/download_manifest.txt"
  echo "   Added size and checksum to $RAW_DIR/download_manifest.txt"
  exit 0
fi

if [ ! -f "$FJC_ZIP" ]; then
  echo "STOP: $FJC_ZIP not found. Run 'bash 05_import_fjc.sh download' on the login node first."
  exit 1
fi

P="$PARQUET_DIR"; O="$PROFILE_DIR"
SET="SET memory_limit = '$DUCKDB_MEMORY'; SET threads = $DUCKDB_THREADS; SET temp_directory = '$WORK_DIR/tmp';"
txt="$WORK_DIR/tmp/fjc_civil.txt"
member=$(unzip -Z1 "$FJC_ZIP" | grep -i '\.txt$' | head -n 1)

echo "== Part A: unzipping $member and repairing malformed lines (about 2 GB, deleted afterwards)"
# fix_fjc_text.py: rejoins party names that contain a tab, reads non-UTF-8 lines
# as Latin-1, and removes stray carriage returns, so that every row can be read.
mkdir -p "$WORK_DIR/tmp"
unzip -p "$FJC_ZIP" "$member" | "$PYTHON" fix_fjc_text.py "$txt" "$O/fjc.repaired_lines.csv"

echo "== Part B: FJC file to Parquet (every row and column kept, as text)"
"$DUCKDB" -c "$SET
  COPY (SELECT row_number() OVER () AS fjc_row, *
        FROM read_csv('$txt', delim = '\t', header = true, quote = '', escape = '',
                      new_line = '\n', all_varchar = true, store_rejects = true))
    TO '$P/fjc_idb_civil.parquet' (FORMAT parquet, COMPRESSION zstd);
  COPY (SELECT line, error_type, error_message FROM reject_errors)
    TO '$O/fjc.rejected_lines.csv' (HEADER);"
rm -f "$txt"
echo "   FJC rows: $("$DUCKDB" -noheader -list -c "SELECT count(*) FROM '$P/fjc_idb_civil.parquet'" | tail -n 1)"
echo "   lines the reader could not parse: $(( $(wc -l < "$O/fjc.rejected_lines.csv") - 1 ))  (should be 0 after the repair in Part A)"

echo "== Part C: linking SCALES civil cases to FJC records"
"$DUCKDB" -c "$SET
  CREATE TEMP TABLE xw AS SELECT * FROM read_csv('fjc_district_crosswalk.csv', all_varchar = true);

  CREATE TEMP TABLE s AS
    SELECT ucid, court, year_dir, filing_date,
           coalesce(nullif(ltrim(upper(regexp_extract(ucid, ';;([0-9A-Za-z]+):', 1)), '0'), ''), '0') AS k_office,
           regexp_extract(ucid, ':([0-9]{2})-cv-', 1)
             || lpad(regexp_extract(ucid, '-cv-([0-9]+)', 1), 5, '0') AS k_docket
    FROM '$P/cases.parquet' WHERE case_type = 'cv';

  CREATE TEMP TABLE link AS
    WITH f AS (
      SELECT x.scales_court AS k_court,
             coalesce(nullif(ltrim(upper(trim(fj.OFFICE)), '0'), ''), '0') AS k_office,
             lpad(trim(fj.DOCKET), 7, '0') AS k_docket,
             try_strptime(fj.FILEDATE, '%m/%d/%Y')::DATE AS fjc_filedate,
             try_strptime(fj.TERMDATE, '%m/%d/%Y')::DATE AS fjc_termdate,
             fj.*
      FROM '$P/fjc_idb_civil.parquet' fj
      JOIN xw x ON x.fjc_district = lpad(upper(trim(fj.DISTRICT)), 2, '0'))
    SELECT s.ucid, f.fjc_row,
           count(*) OVER (PARTITION BY s.ucid) AS n_fjc_matches,
           row_number() OVER (PARTITION BY s.ucid
             ORDER BY coalesce(f.fjc_filedate = s.filing_date, false) DESC,
                      (f.fjc_termdate IS NOT NULL) DESC, f.TAPEYEAR DESC, f.fjc_row DESC) AS fjc_rank,
           coalesce(f.fjc_filedate = s.filing_date, false) AS filedate_agrees,
           f.ORIGIN, f.fjc_filedate, f.fjc_termdate, f.JURIS, f.NOS, f.CLASSACT, f.TRCLACT,
           f.PROCPROG, f.DISP, f.NOJ, f.AMTREC, f.JUDGMENT, f.PROSE, f.IFP, f.STATUSCD, f.TAPEYEAR
    FROM s JOIN f ON f.k_court = s.court AND f.k_office = s.k_office AND f.k_docket = s.k_docket;

  COPY (SELECT * FROM link ORDER BY ucid, fjc_rank)
    TO '$P/scales_fjc_link.parquet' (FORMAT parquet, COMPRESSION zstd);

  CREATE TEMP TABLE best AS SELECT * FROM link WHERE fjc_rank = 1;
  COPY (SELECT count(*) AS scales_civil_cases,
               count(b.ucid) AS matched,
               round(100.0 * count(b.ucid) / count(*), 1) AS pct_matched,
               count(*) FILTER (WHERE b.filedate_agrees) AS matched_and_filing_date_agrees,
               count(*) FILTER (WHERE b.n_fjc_matches > 1) AS matched_more_than_once
        FROM s LEFT JOIN best b USING (ucid))
    TO '$O/fjc.link_summary.csv' (HEADER);
  COPY (SELECT s.court, count(*) AS scales_civil_cases, count(b.ucid) AS matched,
               round(100.0 * count(b.ucid) / count(*), 1) AS pct_matched,
               count(*) FILTER (WHERE b.filedate_agrees) AS filing_date_agrees
        FROM s LEFT JOIN best b USING (ucid) GROUP BY 1 ORDER BY pct_matched, 2 DESC)
    TO '$O/fjc.link_by_court.csv' (HEADER);
  COPY (SELECT s.year_dir, count(*) AS scales_civil_cases, count(b.ucid) AS matched,
               round(100.0 * count(b.ucid) / count(*), 1) AS pct_matched
        FROM s LEFT JOIN best b USING (ucid) GROUP BY 1 ORDER BY 1)
    TO '$O/fjc.link_by_year.csv' (HEADER);
  COPY (SELECT DISTINCT court FROM s WHERE court NOT IN (SELECT scales_court FROM xw) ORDER BY 1)
    TO '$O/fjc.scales_courts_not_in_crosswalk.csv' (HEADER);"

echo "== Link summary"
cat "$O/fjc.link_summary.csv"
echo "   SCALES courts missing from the crosswalk (should be none):"
tail -n +2 "$O/fjc.scales_courts_not_in_crosswalk.csv" | sed 's/^/      /'
ls -lh "$P/fjc_idb_civil.parquet" "$P/scales_fjc_link.parquet"
