#!/usr/bin/env bash
# =============================================================================
# 00_setup.sh — make folders, check tools, install DuckDB if needed, check space.
# Safe to run more than once.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

echo "== Making folders under $PROJECT_DIR"
mkdir -p "$RAW_DIR" "$FLAT_DIR" "$PARQUET_DIR" "$PROFILE_DIR" "$WORK_DIR/tmp" "$LOG_DIR" "$HOME/bin"

echo "== Checking tools"
for tool in curl unzip gzip tar sha256sum "$PYTHON"; do
  if command -v "$tool" >/dev/null 2>&1; then echo "   ok: $tool"
  else echo "   MISSING: $tool  (try 'module avail' or ask FarmShare support)"; exit 1; fi
done
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 8), "need Python 3.8+"; print("   Python", sys.version.split()[0])'

echo "== DuckDB"
if [ -x "$DUCKDB" ]; then
  echo "   already installed: $("$DUCKDB" --version)"
else
  curl -fL --retry 3 -o "$WORK_DIR/tmp/duckdb.zip" \
    "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip"
  unzip -o "$WORK_DIR/tmp/duckdb.zip" -d "$HOME/bin" && chmod +x "$HOME/bin/duckdb"
  echo "   installed: $("$DUCKDB" --version)"
fi

echo "== Disk space and file-count space (inodes) in $PROJECT_DIR"
df -h "$PROJECT_DIR"
df -i "$PROJECT_DIR" || true
echo "   Need roughly: 2.4 GB for the case archive (+0.3 GB for the FJC file, step 05) + ~10-20 GB working space."
echo "   The 676,809 case files are NEVER unpacked one-by-one, so file-count limits don't matter."

echo "== Is the downloaded case archive in place?"
if [ -f "$CASES_ARCHIVE" ]; then echo "   found: $CASES_ARCHIVE ($(du -h "$CASES_ARCHIVE" | cut -f1))"
else echo "   NOT FOUND: $CASES_ARCHIVE   -> upload it, then fix the name in config.sh"; fi
