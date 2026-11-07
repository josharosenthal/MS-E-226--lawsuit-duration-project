# =============================================================================
# 08-a_ols.R — OLS of log(1 + duration) (Josh, 1 Nov 2026; change 91). TRAINING CASES ONLY.
# Cases that ended in court. Categories against their most common level; logged counts; the duration interactions. Coefficients of the full fit come with standard errors clustered by court; predictions in days use Duan's smearing.
# One job = one run and one outer fold, or "full" (fit on all training cases -> coefficients):
#   Rscript ~/scales_setup/r/08-a_ols.R <run 1-4> <fold 1-5|full>
# r/submit_regressions.sh submits every job. Settings and the specification: reg_helpers.R,
# model_spec.csv (from model_spec.xlsx), DATA_DICTIONARY.md sections 1 and 3.
# Output: ~/scales_project/models/reg/ols_run<run>_fold<fold>.rds (and _coefficients.csv for "full");
# scored by 08-z_regression_summary.R once all 5 folds are in.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
source(file.path(r_dir, "reg_helpers.R"))
run_reg_job("ols", commandArgs(trailingOnly = TRUE))
