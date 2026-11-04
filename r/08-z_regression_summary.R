# =============================================================================
# 08-z_regression_summary.R — score the 08 regression models from their saved fold
# predictions (Josh, 1 Nov 2026; change 91). TRAINING CASES ONLY (cross-validated); the
# holdout is untouched. Run after the fold jobs have finished; a model and run is scored only
# when all 5 of its folds are in, and the missing ones are listed. Quick: no data are read.
#   Rscript ~/scales_setup/r/08-z_regression_summary.R
# Metrics (each over all cases, plus its standard error across the 5 folds). Every baseline is
# the fold's TRAINING part (change 93): its mean log duration, its plain quantile, its share of
# short cases, so no score uses the outcomes of the cases it predicts to set its yardstick.
#   duration models (ols, ridge, group_lasso), log(1 + duration):
#     r_squared (against the training mean), rmse_log; in days, with the prediction that suits
#     each loss: mean_abs_error_days and median_abs_error_days use exp(pred) - 1 (a median-type
#     prediction; absolute error is smallest at the median), rmse_days uses exp(pred) x
#     smearing - 1 (a mean; squared error is smallest at the mean)
#   quantile models: pinball_loss (the loss quantile regression minimizes; log scale),
#     pseudo_r1 = 1 - pinball loss / that of the fold's plain training quantile, coverage =
#     share of cases at or below the prediction (target 0.50 / 0.90); crossing = share of
#     cases whose predicted 90th percentile is below their predicted median
#   short-case models (ended within 60 days): auc, brier_skill (against the training share),
#     log_loss; calibration by decile of the predicted probability in reg_calibration.csv
# Checks (change 93), printed as FLAG lines and kept in reg_summary.csv:
#   - a model and run is scored only if all 5 folds were made from the same model_spec.csv
#     (its MD5 is saved by each job); otherwise it is listed as not scored
#   - plain logistic: folds_converged (out of 5)
#   - ridge / lasso / group lasso: folds_lambda_at_boundary, folds whose lambda.min was the
#     smallest or largest penalty tried
# Output: ~/scales_project/models/reg/reg_summary.csv, reg_per_fold.csv, reg_calibration.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
project_dir <- path.expand(Sys.getenv("SCALES_PROJECT", "~/scales_project"))
reg_dir <- file.path(project_dir, "models", "reg")
auc <- function(p, y) { r <- rank(p); n1 <- as.numeric(sum(y)); n0 <- as.numeric(length(y)) - n1
                        if (n1 == 0 || n0 == 0) return(NA_real_); (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0) }

files <- list.files(reg_dir, pattern = "_run[1-4]_fold[1-5]\\.rds$", full.names = TRUE)
if (!length(files)) stop("No fold results in ", reg_dir, " yet.")
res <- lapply(files, readRDS)
key <- vapply(res, function(r) paste(r$model, r$run), "")

# d: one row per case, with y, pred and that case's fold values smear, nullq (training
# quantile) and base (training mean / share)
score <- function(model, d, tau = NULL) {
  y <- d$y; p <- d$pred
  if (model %in% c("ols", "ridge", "group_lasso")) {
    days <- expm1(y)
    c(r_squared = 1 - sum((y - p)^2) / sum((y - d$base)^2), rmse_log = sqrt(mean((y - p)^2)),
      mean_abs_error_days = mean(abs(days - expm1(p))), median_abs_error_days = median(abs(days - expm1(p))),
      rmse_days = sqrt(mean((days - (exp(p) * d$smear - 1))^2)))
  } else if (grepl("^quantile_", model)) {
    rho <- function(u) u * (tau - (u < 0))
    c(pinball_loss = mean(rho(y - p)), pseudo_r1 = 1 - sum(rho(y - p)) / sum(rho(y - d$nullq)), coverage = mean(y <= p))
  } else {
    pc <- pmin(pmax(p, 1e-15), 1 - 1e-15)
    c(auc = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / mean((d$base - y)^2),
      log_loss = -mean(y * log(pc) + (1 - y) * log(1 - pc)))
  }
}
fold_frame <- function(r) cbind(r$pred, smear = if (is.null(r$smear)) NA else r$smear,
                                nullq = if (is.null(r$null_quantile)) NA else r$null_quantile, base = r$base_rate)

summary_rows <- list(); fold_rows <- list(); calib <- list(); missing <- character(0); preds <- list(); flags <- character(0)
for (k in unique(key)) {
  rs <- res[key == k]; folds <- vapply(rs, function(r) as.integer(r$fold), 1L)
  model <- rs[[1]]$model; run <- rs[[1]]$run
  if (!identical(sort(folds), 1:5)) { missing <- c(missing, sprintf("%s run %d: folds %s missing", model, run,
                                  paste(setdiff(1:5, folds), collapse = ", "))); next }
  md5 <- vapply(rs, function(r) if (is.null(r$spec_md5)) "(none: made before change 93)" else r$spec_md5, "")
  if (length(unique(md5)) > 1 || grepl("^\\(none", md5[1])) {
    missing <- c(missing, sprintf("%s run %d: folds made from different model_spec.csv versions or before change 93 (%s) - rerun all its folds",
                                  model, run, paste(sprintf("fold %d %s", folds, substr(md5, 1, 8)), collapse = ", "))); next }
  # each fold's cases are scored with that fold's smearing factor, training quantile and training mean
  rs <- rs[order(folds)]; folds <- sort(folds)
  per <- do.call(rbind, lapply(rs, function(r) score(model, fold_frame(r), r$tau)))
  all_pred <- do.call(rbind, lapply(rs, fold_frame))
  preds[[k]] <- all_pred
  overall <- score(model, all_pred, rs[[1]]$tau)
  se <- apply(per, 2, sd) / sqrt(nrow(per))
  summary_rows[[k]] <- data.frame(model = model, run = run, n_cases = nrow(all_pred),
    n_columns = rs[[1]]$n_columns, lambda_mean = if (is.null(rs[[1]]$lambda)) NA else mean(vapply(rs, function(r) r$lambda, 1)),
    metric = names(overall), value = round(unname(overall), 5), se_across_folds = round(unname(se[names(overall)]), 5))
  chk <- NULL                                         # convergence / penalty-boundary checks
  if (model == "logistic") {
    nc <- sum(vapply(rs, function(r) isTRUE(r$converged), TRUE))
    chk <- c(folds_converged = nc); if (nc < 5) flags <- c(flags, sprintf("FLAG  %s run %d: %d of 5 folds converged", model, run, nc))
  } else if (!is.null(rs[[1]]$lambda)) {
    b <- vapply(rs, function(r) if (is.null(r$lambda_boundary)) NA_character_ else r$lambda_boundary, "")
    nb <- sum(b %in% c("smallest", "largest"))
    chk <- c(folds_lambda_at_boundary = nb)
    if (nb > 0) flags <- c(flags, sprintf("FLAG  %s run %d: lambda.min at the end of the path in %d fold(s) (%s)", model, run, nb,
                                          paste(sprintf("fold %d %s", folds, b)[b %in% c("smallest", "largest")], collapse = ", ")))
  }
  if (length(chk)) summary_rows[[paste(k, "checks")]] <- data.frame(model = model, run = run, n_cases = nrow(all_pred),
    n_columns = rs[[1]]$n_columns, lambda_mean = NA, metric = names(chk), value = unname(chk), se_across_folds = NA)
  fold_rows[[k]] <- data.frame(model = model, run = run, fold = rep(folds, ncol(per)),
                               metric = rep(colnames(per), each = nrow(per)), value = round(as.vector(per), 5))
  if (!(model %in% c("ols", "ridge", "group_lasso")) && !grepl("^quantile_", model)) {
    b <- cut(all_pred$pred, unique(quantile(all_pred$pred, seq(0, 1, 0.1))), include.lowest = TRUE)
    calib[[k]] <- data.frame(model = model, run = run, decile = seq_len(nlevels(b)), n = as.vector(table(b)),
                             mean_predicted = round(as.vector(tapply(all_pred$pred, b, mean)), 4),
                             share_short = round(as.vector(tapply(all_pred$y, b, mean)), 4))
  }
}
# quantile crossing: predicted 90th percentile below the predicted median
for (run in 1:4) {
  a <- preds[[paste("quantile_50", run)]]; b <- preds[[paste("quantile_90", run)]]
  if (!is.null(a) && !is.null(b)) {
    m <- merge(a[c("row", "pred")], b[c("row", "pred")], by = "row", suffixes = c("_50", "_90"))
    summary_rows[[paste("crossing", run)]] <- data.frame(model = "quantile_50 vs quantile_90", run = run, n_cases = nrow(m),
      n_columns = NA, lambda_mean = NA, metric = "crossing", value = round(mean(m$pred_90 < m$pred_50), 5), se_across_folds = NA)
  }
}
sm <- do.call(rbind, summary_rows)
if (is.null(sm)) stop("No model has all 5 folds yet.\n", paste(missing, collapse = "\n"))
write.csv(sm, file.path(reg_dir, "reg_summary.csv"), row.names = FALSE)
write.csv(do.call(rbind, fold_rows), file.path(reg_dir, "reg_per_fold.csv"), row.names = FALSE)
if (length(calib)) write.csv(do.call(rbind, calib), file.path(reg_dir, "reg_calibration.csv"), row.names = FALSE)

cat("Cross-validated scores (training cases only; the holdout is untouched):\n")
print(sm, row.names = FALSE)
if (length(flags)) cat("\n", paste(flags, collapse = "\n"), "\n", sep = "") else cat("\nPASS  every plain logistic fold converged; no penalty at the end of its path\n")
if (length(missing)) cat("\nNot scored yet:\n", paste(" ", missing, collapse = "\n"), "\n")
cat("\nSaved in", reg_dir, "\n")
