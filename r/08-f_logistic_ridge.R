# =============================================================================
# 08-f_logistic_ridge.R — ridge logistic regression: ended within 60 days? (glmnet, alpha = 0) (Josh, 1 Nov 2026; change 91). TRAINING CASES ONLY.
# Every level and cell its own column; logged counts scaled to SD 0.5; lambda.min by inner cross-validation (deviance).
# One job = one run and one outer fold, or "full" (fit on all training cases -> coefficients):
#   Rscript ~/scales_setup/r/08-f_logistic_ridge.R <run 1-4> <fold 1-5|full>
# r/submit_regressions.sh submits every job. Settings and the specification: reg_helpers.R,
# model_spec.csv (from model_spec.xlsx), DATA_DICTIONARY.md section 5.
# Output: ~/scales_project/models/reg/logistic_ridge_run<run>_fold<fold>.rds (and _coefficients.csv for "full");
# scored by 08-z_regression_summary.R once all 5 folds are in.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
source(file.path(r_dir, "reg_helpers.R"))
run_reg_job("logistic_ridge", commandArgs(trailingOnly = TRUE))
