# =============================================================================
# 08-c_group_lasso.R — group lasso of log(1 + duration) (grpreg) (Josh, 1 Nov 2026; change 91). TRAINING CASES ONLY.
# One group per variable and one per interaction; an interaction may enter without its main effects. NOTE: grpreg orthonormalizes each group internally (its algorithm needs it), so the 'dummies not standardized' choice can't be applied here. Penalty lambda.min, inner cross-validation.
# One job = one run and one outer fold, or "full" (fit on all training cases -> coefficients):
#   Rscript ~/scales_setup/r/08-c_group_lasso.R <run 1-4> <fold 1-5|full>
# r/submit_regressions.sh submits every job. Settings and the specification: reg_helpers.R,
# model_spec.csv (from model_spec.xlsx), DATA_DICTIONARY.md sections 1 and 3.
# Output: ~/scales_project/models/reg/group_lasso_run<run>_fold<fold>.rds (and _coefficients.csv for "full");
# scored by 08-z_regression_summary.R once all 5 folds are in.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
source(file.path(r_dir, "reg_helpers.R"))
run_reg_job("group_lasso", commandArgs(trailingOnly = TRUE))
