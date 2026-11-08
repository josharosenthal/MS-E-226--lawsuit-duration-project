# =============================================================================
# 09-a_holdout_xgboost.R — Project Part 2: the final XGBoost models (run 4 variables) applied to
# the HOLDOUT (test) cases (Josh, 8 Nov 2026; change 108). THIS SCRIPT READS THE HOLDOUT.
# Run it only once the models are chosen; every run is logged (below).
#   Rscript ~/scales_setup/r/09-a_holdout_xgboost.R use_holdout
#   Rscript ~/scales_setup/r/09-a_holdout_xgboost.R use_holdout log_duration     (one outcome)
# Without the word use_holdout it stops before reading anything.
#
# The pipeline, every step fitted on the TRAINING cases only and applied unchanged here:
#   1. 00_sample.R (as for every script): the same population, exclusions and missing-data
#      drops; judge_group (judges with fewer than 20 TRAINING cases -> "other"), cause_group
#      (title:section pairs with fewer than 100 TRAINING cases -> "title:other") and the cause fill
#      (most common cause among TRAINING cases with the same nature of suit and section) are
#      computed from training cases and applied to every case, so the holdout's labels never
#      depend on the holdout.
#   2. xgb_training_data() (xgb_helpers.R), the same function 07-c used: missing category ->
#      "(NA)", missing count -> 0; then outcome_data() (log duration: cases that ended in court;
#      short_60: cases transferred out before day 60 dropped) and recode_run4().
#   3. One-hot columns exactly as in training: one column per TRAINING category, in the trained
#      model's column order. A holdout category the training cases never had gets zeros in all
#      of that variable's columns (it is counted and reported).
#   4. The saved model: models/xgb_shap/xgb_<outcome>_reg_run4_full.json, fitted by 07-c on all
#      training cases with the median number of trees from the 5 folds. Not refitted here.
#   Check before scoring: the training cases are rebuilt through steps 2-3 and the loaded model's
#   predictions for 07-c's SHAP sample are compared with the predictions 07-c saved; the script
#   stops if they differ, or if the column names differ from the model's.
# Days (log duration): exp(prediction) x smearing factor - 1, the factor being the mean of the
#   5 cross-validation folds' factors saved by 07-c (each from out-of-fold-trained models, so not
#   flattered by the model's fit to its own training cases).
# Scores, as 08-y (log duration: r_squared, rmse_log, mae_log, mean and median absolute error in
#   days, rmse_days; short_60: auc, brier_skill, log_loss). The baseline is the TRAINING mean of
#   log(1 + days) or the training share of short cases - fixed before the holdout is seen; R-squared
#   and Brier skill are relative to it. Next to each, the cross-validated (training) score from
#   07-c's saved predictions, so the two estimates of test error can be compared.
#   95% intervals: bootstrap over consolidation groups (lead and member cases resampled together),
#   n_boot resamples, percentile intervals.
# Holdout log: each run adds a line to models/holdout/holdout_use_log.csv (time, outcome, model
#   file MD5, cases), so the number of times the holdout was scored is on record.
# Output: ~/scales_project/models/holdout/
#   holdout_scores.csv                       holdout and cross-validated scores, with intervals
#   xgb_<outcome>_reg_run4_holdout_pred.rds  each holdout case's ucid, y and prediction
#   holdout_use_log.csv
# Login node or a small job: --cpus-per-task=4 --mem=16G, minutes.
# =============================================================================

if (!("use_holdout" %in% commandArgs(TRUE)))
  stop("This script scores the HOLDOUT. Run it with the word use_holdout:\n",
       "  Rscript ~/scales_setup/r/09-a_holdout_xgboost.R use_holdout")
r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" - run 03_holdout.R first.")
if (!requireNamespace("xgboost", quietly = TRUE)) stop("The xgboost package isn't installed.")
model_dir <- file.path(project_dir, "models"); out_dir <- file.path(model_dir, "holdout")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes  <- c("log_duration", "short_60")
set_name  <- "reg_run4"          # the run 4 variables (the trained model must be for this set)
n_folds   <- 5; xgb_seed <- 226  # as 07-c (only so the shared reader runs the same way)
n_boot    <- 1000                # bootstrap resamples for the intervals (0 = none)
boot_seed <- 2026
n_threads <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "4"))
a <- setdiff(commandArgs(TRUE), "use_holdout"); if (length(a)) outcomes <- strsplit(a[1], ",")[[1]]

source(file.path(r_dir, "covariate_sets.R"))       # num_vars
source(file.path(r_dir, "xgb_helpers.R"))          # spec_keep(), recode_run4(), xgb_training_data(), outcome_data(), auc()
spec_file <- file.path(r_dir, "model_spec.csv")
have <- dbListFields(con, "train_fjc")
spec_vars <- function(outcome) {                   # as 07-c's reg_run sets
  sp <- read.csv(spec_file, stringsAsFactors = FALSE)
  keep <- spec_keep(sp, if (outcome == "log_duration") "duration_ols" else "short_case", as.integer(sub("reg_run", "", set_name)))
  v <- sp$term[keep & sp$type != "interaction"]
  miss <- setdiff(v, have); if (length(miss)) stop("Not in the data: ", paste(miss, collapse = ", "))
  v
}
all_vars <- unique(unlist(lapply(outcomes, spec_vars)))

# ---- Read training and holdout cases through the same code ------------------------------
dbExecute(con, "CREATE OR REPLACE TEMP VIEW holdout_fjc AS SELECT * FROM analysis_fjc WHERE is_holdout = TRUE")
d_train_all <- xgb_training_data(list(all_vars), n_folds, xgb_seed)
d_hold_all  <- xgb_training_data(list(all_vars), n_folds, xgb_seed, inner_seed = xgb_seed + 1, from = "holdout_fjc")
if (!nrow(d_hold_all)) stop("No holdout cases found (analysis_fjc with is_holdout = TRUE) - stopping.")
if (length(intersect(d_train_all$ucid, d_hold_all$ucid))) stop("Some cases are in both training and holdout - stopping.")

# one-hot columns for the TRAINING categories, named as sparse.model.matrix names them (variable
# then level); unseen holdout categories -> all zeros for that variable
onehot <- function(d, vars, levs) {
  blocks <- lapply(vars, function(v) {
    if (is.null(levs[[v]])) { x <- as.numeric(d[[v]]); return(Matrix::Matrix(matrix(x, ncol = 1, dimnames = list(NULL, v)), sparse = TRUE)) }
    j <- match(as.character(d[[v]]), levs[[v]]); ok <- !is.na(j)
    Matrix::sparseMatrix(i = which(ok), j = j[ok], x = 1, dims = c(nrow(d), length(levs[[v]])),
                         dimnames = list(NULL, paste0(v, levs[[v]])))
  })
  do.call(cbind, blocks)
}

score <- function(outcome, y, p, base, smear = NA) {
  if (outcome == "log_duration") {
    days <- expm1(y)
    c(r_squared = 1 - sum((y - p)^2) / sum((y - base)^2), rmse_log = sqrt(mean((y - p)^2)), mae_log = mean(abs(y - p)),
      mean_abs_error_days = mean(abs(days - expm1(p))), median_abs_error_days = median(abs(days - expm1(p))),
      rmse_days = sqrt(mean((days - (exp(p) * smear - 1))^2)))
  } else {
    pc <- pmin(pmax(p, 1e-15), 1 - 1e-15)
    c(auc = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / mean((base - y)^2),
      log_loss = -mean(y * log(pc) + (1 - y) * log(1 - pc)))
  }
}

# ---- One outcome ----------------------------------------------------------------------------
run_one <- function(outcome) {
  vars <- spec_vars(outcome)
  mf <- file.path(model_dir, "xgb_shap", sprintf("xgb_%s_%s_full.json", outcome, set_name))
  sf <- file.path(model_dir, "xgb_shap", sprintf("xgb_%s_%s_shap.rds", outcome, set_name))
  cf <- file.path(model_dir, "xgb_cv",   sprintf("xgb_%s_%s_cv.rds", outcome, set_name))
  for (f in c(mf, sf, cf)) if (!file.exists(f)) stop("Missing ", f, " - run 07-c_xgboost.R ", outcome, " ", set_name, " first.")
  shp <- readRDS(sf); cvr <- readRDS(cf)
  if (!is.null(shp$spec_md5) && shp$spec_md5 != unname(tools::md5sum(spec_file)))
    stop("model_spec.csv has changed since the model was trained - the variables may not match.")
  booster <- xgboost::xgb.load(mf)

  # training cases, coded as 07-c coded them
  od <- outcome_data(d_train_all, outcome); dtr <- recode_run4(od$d, quiet = TRUE); ytr <- od$y
  dm <- design(dtr, vars)                                  # 07-c's own coding, for the check
  if (!identical(colnames(dm$X), shp$columns)) stop("Training columns differ from the saved model's columns.")
  vars_used <- unique(dm$vars)                             # one-category variables are dropped, as in 07-c
  levs <- lapply(setNames(vars_used, vars_used), function(v) if (is.factor(dtr[[v]])) levels(droplevels(dtr[[v]])) else NULL)
  Xtr <- onehot(dtr, vars_used, levs)
  if (!identical(colnames(Xtr), shp$columns)) stop("Rebuilt training columns differ from the model's.")
  if (max(abs(Xtr - dm$X)) > 0) stop("Rebuilt training matrix differs from 07-c's coding.")
  chk <- max(abs(predict(booster, xgboost::xgb.DMatrix(Xtr[shp$row, , drop = FALSE]), outputmargin = TRUE) - shp$margin))
  cat(sprintf("\n%s: model reloaded; largest gap from 07-c's saved predictions on %s training cases %.2g\n",
              outcome, format(length(shp$row), big.mark = ","), chk))
  if (chk > 1e-4) stop("The loaded model doesn't reproduce 07-c's predictions - stopping.")

  # holdout cases through the same steps
  oh <- outcome_data(d_hold_all, outcome); dho <- recode_run4(oh$d, quiet = TRUE); yho <- oh$y
  unseen <- vapply(names(levs), function(v) if (is.null(levs[[v]])) 0L else sum(!(as.character(dho[[v]]) %in% levs[[v]])), 1L)
  if (any(unseen > 0)) cat("  Holdout cases with a category the training cases never had (coded as zeros):",
                           paste(sprintf("%s %d", names(unseen)[unseen > 0], unseen[unseen > 0]), collapse = "; "), "\n")
  Xho <- onehot(dho, vars_used, levs)
  p <- predict(booster, xgboost::xgb.DMatrix(Xho))
  smear <- if (outcome == "log_duration") mean(cvr$smear) else NA
  base <- mean(ytr)                                        # training mean / share, fixed in advance
  cat(sprintf("  %s holdout cases (%s dropped: transferred out before the cutoff)\n",
              format(length(yho), big.mark = ","), if (is.na(oh$dropped)) "none" else format(oh$dropped, big.mark = ",")))

  hold <- score(outcome, yho, p, base, smear)
  hold_base <- score(outcome, yho, rep(base, length(yho)), base, if (outcome == "log_duration") mean(exp(ytr - base)) else NA)
  cvp <- cvr$pred; Kf <- sort(unique(cvp$fold))            # cross-validated, as 08-y (each fold's training mean)
  bcv <- vapply(Kf, function(k) mean(cvp$y[cvp$fold != k]), 1)[match(cvp$fold, Kf)]
  cv <- score(outcome, cvp$y, cvp$pred, bcv, if (outcome == "log_duration") unname(cvr$smear[as.character(cvp$fold)]) else NA)

  lo <- hi <- setNames(rep(NA_real_, length(hold)), names(hold))
  if (n_boot > 0) {                                        # resample consolidation groups
    set.seed(boot_seed); g <- split(seq_along(yho), dho$cons_group)
    bs <- replicate(n_boot, { i <- unlist(g[sample(length(g), replace = TRUE)], use.names = FALSE)
                              score(outcome, yho[i], p[i], base, smear) })
    lo <- apply(bs, 1, quantile, 0.025, na.rm = TRUE); hi <- apply(bs, 1, quantile, 0.975, na.rm = TRUE)
  }
  saveRDS(list(outcome = outcome, set = set_name, model_file = mf, model_md5 = unname(tools::md5sum(mf)), smear = smear,
               training_baseline = base, pred = data.frame(ucid = dho$ucid, y = yho, pred = p)),
          file.path(out_dir, sprintf("xgb_%s_%s_holdout_pred.rds", outcome, set_name)))
  logf <- file.path(out_dir, "holdout_use_log.csv")
  write.table(data.frame(time = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), outcome = outcome, set = set_name,
                         model_md5 = unname(tools::md5sum(mf)), n_holdout = length(yho)),
              logf, sep = ",", row.names = FALSE, col.names = !file.exists(logf), append = file.exists(logf))
  data.frame(outcome = outcome, set = set_name, model = "xgboost", metric = names(hold),
             holdout = round(hold, 5), holdout_ci_low = round(lo, 5), holdout_ci_high = round(hi, 5),
             cross_validated = round(cv[names(hold)], 5), holdout_baseline = round(hold_base[names(hold)], 5),
             n_holdout = length(yho), n_training = length(ytr), row.names = NULL)
}

res <- do.call(rbind, lapply(outcomes, run_one))
f <- file.path(out_dir, "holdout_scores.csv"); write.csv(res, f, row.names = FALSE)
cat("\nFinal XGBoost models (", set_name, ") on the HOLDOUT, with the cross-validated estimate from training:\n", sep = "")
print(res[c("outcome", "metric", "holdout", "holdout_ci_low", "holdout_ci_high", "cross_validated", "holdout_baseline")], row.names = FALSE)
cat("holdout_baseline: the training mean (or share) predicted for every holdout case.\n")
cat("95% intervals: bootstrap over consolidation groups,", n_boot, "resamples.\n")
cat("Saved", f, "and the per-case predictions in", out_dir, "\n")
