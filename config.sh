#!/usr/bin/env bash
# =============================================================================
# config.sh — THE ONLY FILE YOU SHOULD NEED TO EDIT
# Every other script reads its settings from here. Lines starting with # are notes.
# =============================================================================

# ---- Where things live on FarmShare ------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$HOME/scales_project}"
RAW_DIR="${RAW_DIR:-$PROJECT_DIR/raw}"            # put the two downloaded files here
FLAT_DIR="${FLAT_DIR:-$PROJECT_DIR/flat}"         # temporary flattened files (.jsonl.gz)
PARQUET_DIR="${PARQUET_DIR:-$PROJECT_DIR/parquet}" # finished tables, ready to query
PROFILE_DIR="${PROFILE_DIR:-$PROJECT_DIR/profiles}" # "shape" reports + small samples
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"

# ---- The two files you downloaded from the SCALES file server ------------------
# Put the exact file names here (they should be inside RAW_DIR).
CASES_ARCHIVE="${CASES_ARCHIVE:-$RAW_DIR/cross_sectional.tar.gz}"
EXPECTED_CASES=676809   # SCALES's stated case count; step 02 warns if it reads a different number

# ---- FJC Integrated Database, civil cases (step 05) ------------------------------
# Cumulative file: cases terminated since 1988 plus cases pending (as of the file's date).
FJC_URL="https://www.fjc.gov/sites/default/files/idb/textfiles/cv88on.zip"
FJC_ZIP="${FJC_ZIP:-$RAW_DIR/cv88on.zip}"

# ---- Privacy -------------------------------------------------------------------
# The case files include parties' and lawyers' addresses, phone numbers and
# emails. I have not yet decided whether these pieces of information--particularly city, state, and email domain--could be useful, so I'm keeping them in.
KEEP_CONTACT_INFO="yes"      # "yes" to keep them

# ---- Small random samples for looking at in RStudio ----------------------------
SAMPLE_ROWS=10000
SAMPLE_SEED=226

# ---- Tools ------------------------------------------------------------------------
PYTHON="${PYTHON:-python3}"
DUCKDB="${DUCKDB:-$HOME/bin/duckdb}"
DUCKDB_MEMORY="8GB"     # keep below the memory you request from FarmShare
DUCKDB_THREADS=4
