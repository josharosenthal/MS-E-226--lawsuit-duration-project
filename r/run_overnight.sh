#!/bin/bash -l
# =============================================================================
# run_overnight.sh — re-run feature selection, plots and all three model scripts,
# one after another, as a single batch job (Josh, 28 Oct 2026; change 70).
#   05_feature_selection  ->  06_plots_and_correlations  ->  07-a_random_forest
#   ->  07-b_short_case_forest  ->  07-c_xgboost
# If one script fails, the log says so and the next one still runs.
# Submit from the FarmShare shell (not in R):   sbatch ~/scales_setup/r/run_overnight.sh
# To run only some scripts, name them after it (without .R), e.g.
#   sbatch ~/scales_setup/r/run_overnight.sh 07-a_random_forest 07-b_short_case_forest 07-d_interactions
# Log: ~/overnight_<job id>.out
# =============================================================================
#SBATCH --job-name=overnight
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=overnight_%j.out

module load r
scripts=("$@")
[ ${#scripts[@]} -eq 0 ] && scripts=(05_feature_selection 06_plots_and_correlations 07-a_random_forest 07-b_short_case_forest 07-c_xgboost)
for s in "${scripts[@]}"; do
  echo "===== $s   started $(date)"
  Rscript ~/scales_setup/r/$s.R || echo "!!!!! $s FAILED (exit code $?) - going on to the next script"
done
echo "===== all done $(date)"
