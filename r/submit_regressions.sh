#!/bin/bash
# =============================================================================
# submit_regressions.sh — submit the 08 regression jobs, one Slurm job per model, run and fold
# (Josh, 1 Nov 2026; change 91). Each job gets the partition's longest time limit (2 days).
# Run it from the FarmShare shell (works from tcsh, since it's run with bash):
#   bash ~/scales_setup/r/submit_regressions.sh                 every model, both runs, folds 1-5 + full
#   bash ~/scales_setup/r/submit_regressions.sh ols ridge       only these models
#   env RUNS="1" FOLDS="1 2" bash ~/scales_setup/r/submit_regressions.sh ols   a subset (env: works from tcsh)
#   env RUNS="3" bash ~/scales_setup/r/submit_regressions.sh ols logistic       run 3 (run 2 without n_counsel; change 99)
# Models: ols ridge group_lasso quantile_50 quantile_90 logistic logistic_ridge logistic_lasso
# Logs: ~/reg_logs/<model>_run<r>_fold<f>_<job id>.out   (the folder is made first: a missing
# log folder makes Slurm fail jobs with exit code 0:53)
# After the fold jobs finish:  module load r && Rscript ~/scales_setup/r/08-z_regression_summary.R
# =============================================================================
models=("$@")
[ ${#models[@]} -eq 0 ] && models=(ols ridge group_lasso quantile_50 quantile_90 logistic logistic_ridge logistic_lasso)
RUNS=${RUNS:-"1 2"}; FOLDS=${FOLDS:-"1 2 3 4 5 full"}
mkdir -p "$HOME/reg_logs"
declare -A script=( [ols]=08-a_ols.R [ridge]=08-b_ridge.R [group_lasso]=08-c_group_lasso.R
  [quantile_50]=08-d1_quantile_50.R [quantile_90]=08-d2_quantile_90.R [logistic]=08-e_logistic.R
  [logistic_ridge]=08-f_logistic_ridge.R [logistic_lasso]=08-g_logistic_lasso.R )
# 8 CPUs: ridge, lasso and group lasso run their 5 inner cross-validation folds in parallel
# (change 93); OLS, quantile and plain logistic use one CPU (and the BLAS, if it's threaded).
# memory (GB): run 2 adds judge_group (about 1,450 more columns); group lasso needs a dense copy.
# Group lasso raised after the pilot (run 1 ran out of 48 GB with 5 inner folds at once): 128 / 176 GB,
# with 2 inner folds at a time (REG_GL_WORKERS in reg_helpers.R; change 96). 176 GB fits the
# 191 GB nodes. Run 3 (run 2 less one count column) gets run 2's memory.
declare -A mem1=( [ols]=16 [ridge]=32 [group_lasso]=128 [quantile_50]=32 [quantile_90]=32 [logistic]=24 [logistic_ridge]=32 [logistic_lasso]=32 )
declare -A mem2=( [ols]=32 [ridge]=48 [group_lasso]=176 [quantile_50]=64 [quantile_90]=64 [logistic]=48 [logistic_ridge]=48 [logistic_lasso]=48 )
n=0
for m in "${models[@]}"; do
  s=${script[$m]}; [ -z "$s" ] && { echo "Unknown model: $m"; exit 1; }
  for r in $RUNS; do
    mem=${mem1[$m]}; [ "$r" != "1" ] && mem=${mem2[$m]}
    for f in $FOLDS; do
      sbatch --exclude=barley-03,barley-04 --job-name="${m}_r${r}_${f}" --time=2-00:00:00 --cpus-per-task=8 --mem=${mem}G \
        --output="$HOME/reg_logs/${m}_run${r}_fold${f}_%j.out" \
        --wrap="bash -l -c 'module load r && Rscript ~/scales_setup/r/$s $r $f'"
      n=$((n + 1))
    done
  done
done
echo "Submitted $n jobs. Check:  squeue -u $USER   and   grep -l Error ~/reg_logs/*.out"
