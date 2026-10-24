#!/usr/bin/env bash
# =============================================================================
# run_all.sh — runs steps 00, 01, 02 and 04 in order and saves a log of everything.
# (There is no step 03: it converted the event log, which is no longer used.)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh
mkdir -p "$LOG_DIR"
log="$LOG_DIR/run_$(date +%Y%m%d_%H%M%S).log"
echo "Logging to $log"
{
  echo "Started: $(date)"
  echo "Settings:"; grep -E '^[A-Z_]+=' ./config.sh
  for step in 00_setup.sh 01_check_files.sh 02_flatten_cases.sh 04_profile.sh; do
    echo; echo "################ $step  ($(date +%H:%M)) ################"
    bash "./$step"
  done
  echo; echo "Finished: $(date)"
} 2>&1 | tee "$log"
