# =============================================================================
# 08-y_compare_models.R — the 08 regressions and XGBoost side by side, on the same cases, the
# same folds and the same variables (Josh, 2 Nov 2026; change 97). TRAINING CASES ONLY
# (cross-validated); the holdout is untouched. Quick: reads saved predictions, no data.
#   Rscript ~/scales_setup/r/08-y_compare_models.R
# Reads the 08 fold predictions (models/reg/*_run<r>_fold<k>.rds) and 07-c's cross-validated
# predictions for the matched sets (models/xgb_cv/xgb_<outcome>_reg_run<r>_cv.rds; run
#   Rscript 07-c_xgboost.R log_duration,short_60 reg_run1,reg_run2   first), and 07-f's random
# forests on the same folds (models/forest_cv/rf_<outcome>_reg_run<r>_cv.rds; change 98).
# A model whose file isn't there yet is listed under "Not included" and the rest are compared.
# Runs 1-4 (change 99: run 3 = run 2 without n_counsel; change 100: run 4 = run 3 with the
# post-filing judge labels pooled). Runs 3 and 4 so far have OLS, the quantile median, plain
# logistic, XGBoost and the forest; the others are listed as not included there.
# Comparisons, each run separately:
#   log duration   ols, ridge, group_lasso, quantile_50, xgboost, forest
#   short_60       logistic, logistic_ridge, logistic_lasso, xgboost, forest
# Every model is scored on EVERY metric, including the ones it wasn't fitted for:
#   duration: r_squared, rmse_log (squared error: what OLS, ridge, group lasso and XGBoost
#     minimize), mae_log (absolute error, = 2 x the median model's pinball loss: what
#     quantile_50 minimizes), mean_abs_error_days and median_abs_error_days (exp(pred) - 1),
#     rmse_days (exp(pred) x the fold's smearing factor - 1, a mean; not for quantile_50,
#     which predicts a median and has no smearing factor)
#   short_60: auc, brier_skill, log_loss
# So expect each model to do best on its own loss; a win there isn't overall superiority.
# Baselines as 08-z (change 93): r_squared and brier_skill against each fold's TRAINING mean.
# The baseline is also a row of its own, "baseline" (change 101; Project Part 1, 6(c)): it predicts
# each fold's training mean of log(1 + days) (in days with that fold's smearing factor for
# rmse_days), or the fold's training share of short cases, and is scored and paired like the rest.
# (07-c's own summary uses the mean of all cases, which differs in the 4th decimal.)
# Paired differences: the folds are shared, so for two models the SE of their difference is
# sd(the 5 per-fold differences) / sqrt(5), usually much smaller than either model's own SE.
# Checks: a model is included only with all 5 folds made from the same model_spec.csv as the
# others; every model must have the same cases, outcomes and folds (stops otherwise).
# Output: ~/scales_project/models/reg/compare_scores.csv (model, metric, value, se, per fold)
#         ~/scales_project/models/reg/compare_pairs.csv  (model_a minus model_b, se, folds a ahead)
# =============================================================================

project_dir <- path.expand(Sys.getenv("SCALES_PROJECT", "~/scales_project"))
reg_dir <- file.path(project_dir, "models", "reg")
cv_files <- c(xgboost = file.path(project_dir, "models", "xgb_cv", "xgb_%s_reg_run%d_cv.rds"),
              forest  = file.path(project_dir, "models", "forest_cv", "rf_%s_reg_run%d_cv.rds"))
auc <- function(p, y) { r <- rank(p); n1 <- as.numeric(sum(y)); n0 <- as.numeric(length(y)) - n1
                        if (n1 == 0 || n0 == 0) return(NA_real_); (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0) }
families <- list(log_duration = c("ols", "ridge", "group_lasso", "quantile_50", "xgboost", "forest"),
                 short_60     = c("logistic", "logistic_ridge", "logistic_lasso", "xgboost", "forest"))
lower_better <- c(rmse_log = TRUE, mae_log = TRUE, mean_abs_error_days = TRUE, median_abs_error_days = TRUE,
                  rmse_days = TRUE, log_loss = TRUE, r_squared = FALSE, auc = FALSE, brier_skill = FALSE)

# one model's predictions for every case: row, fold, y, pred, smear (that fold's factor)
load_model <- function(model, outcome, run) {
  if (model %in% names(cv_files)) {
    f <- sprintf(cv_files[[model]], outcome, run)
    if (!file.exists(f)) return(list(why = sprintf("not run yet (%s with reg_run%d)", if (model == "xgboost") "07-c" else "07-f", run)))
    r <- readRDS(f); d <- r$pred[c("row", "fold", "y", "pred")]
    d$smear <- if (is.null(r$smear)) NA else unname(r$smear[as.character(d$fold)])
    return(list(d = d, md5 = r$spec_md5))
  }
  fs <- file.path(reg_dir, sprintf("%s_run%d_fold%d.rds", model, run, 1:5))
  if (!all(file.exists(fs))) return(list(why = sprintf("folds %s missing", paste(which(!file.exists(fs)), collapse = ", "))))
  rs <- lapply(fs, readRDS)
  md5 <- unique(vapply(rs, function(r) if (is.null(r$spec_md5)) "none" else r$spec_md5, ""))
  if (length(md5) > 1) return(list(why = "folds made from different model_spec.csv versions"))
  d <- do.call(rbind, lapply(rs, function(r) cbind(r$pred, smear = if (is.null(r$smear)) NA else r$smear)))
  list(d = d[order(d$row), ], md5 = md5)
}

score <- function(outcome, y, p, smear, base) {
  if (outcome == "log_duration") {
    days <- expm1(y)
    c(r_squared = 1 - sum((y - p)^2) / sum((y - base)^2), rmse_log = sqrt(mean((y - p)^2)), mae_log = mean(abs(y - p)),
      mean_abs_error_days = mean(abs(days - expm1(p))), median_abs_error_days = median(abs(days - expm1(p))),
      rmse_days = if (all(is.na(smear))) NA else sqrt(mean((days - (exp(p) * smear - 1))^2)))
  } else {
    pc <- pmin(pmax(p, 1e-15), 1 - 1e-15)
    c(auc = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / mean((base - y)^2),
      log_loss = -mean(y * log(pc) + (1 - y) * log(1 - pc)))
  }
}

scores <- list(); pairs <- list(); notes <- character(0)
for (outcome in names(families)) for (run in 1:4) {
  ms <- lapply(setNames(families[[outcome]], families[[outcome]]), load_model, outcome = outcome, run = run)
  for (m in names(ms)) if (!is.null(ms[[m]]$why)) notes <- c(notes, sprintf("%s run %d, %s: %s", outcome, run, m, ms[[m]]$why))
  ms <- ms[vapply(ms, function(x) is.null(x$why), TRUE)]
  if (length(ms) < 2) next
  md5s <- unique(na.omit(vapply(ms, function(x) as.character(x$md5), "")))
  if (length(md5s) > 1) stop(sprintf("%s run %d: models made from different model_spec.csv versions (%s) - rerun the older ones",
                                     outcome, run, paste(sprintf("%s %s", names(ms), substr(vapply(ms, function(x) as.character(x$md5), ""), 1, 8)), collapse = ", ")))
  ref <- ms[[1]]$d
  for (m in names(ms)[-1]) {                           # same cases, outcomes and folds in every model
    d <- ms[[m]]$d
    if (nrow(d) != nrow(ref) || !all(d$row == ref$row) || !all(d$fold == ref$fold) || max(abs(d$y - ref$y)) > 1e-9)
      stop(sprintf("%s run %d: %s doesn't have the same cases, folds and outcomes as %s", outcome, run, m, names(ms)[1]))
  }
  y <- ref$y; fold <- ref$fold; K <- sort(unique(fold))
  base <- vapply(K, function(k) mean(y[fold != k]), 1)            # each fold's training mean / share
  sm <- vapply(K, function(k) mean(exp(y[fold != k] - base[k == K])), 1)
  ms <- c(list(baseline = list(d = data.frame(row = ref$row, fold = fold, y = y, pred = base[match(fold, K)],
                                              smear = if (outcome == "log_duration") sm[match(fold, K)] else NA))), ms)
  per <- lapply(ms, function(x) sapply(K, function(k) { i <- fold == k
           score(outcome, y[i], x$d$pred[i], x$d$smear[i], base[k == K]) }))   # metrics x folds
  over <- lapply(ms, function(x) score(outcome, y, x$d$pred, x$d$smear, base[match(fold, K)]))
  for (m in names(ms)) scores[[paste(outcome, run, m)]] <- data.frame(outcome = outcome, run = run, model = m,
    metric = names(over[[m]]), value = round(over[[m]], 5),
    se_across_folds = round(apply(per[[m]], 1, sd) / sqrt(length(K)), 5),
    setNames(as.data.frame(round(per[[m]], 5)), paste0("fold_", K)), row.names = NULL)
  for (a in names(ms)) for (b in names(ms)) if (match(a, names(ms)) < match(b, names(ms))) {
    dif <- per[[a]] - per[[b]]
    pairs[[paste(outcome, run, a, b)]] <- data.frame(outcome = outcome, run = run, model_a = a, model_b = b,
      metric = names(over[[a]]), a_minus_b = round(over[[a]] - over[[b]], 5),
      se_difference = round(apply(dif, 1, sd) / sqrt(length(K)), 5),
      folds_a_better = vapply(rownames(dif), function(r) if (any(is.na(dif[r, ]))) NA_integer_
                              else as.integer(sum(if (lower_better[[r]]) dif[r, ] < 0 else dif[r, ] > 0)), 1L), row.names = NULL)
  }
}
if (!length(scores)) stop("Nothing to compare yet.\n", paste(notes, collapse = "\n"))
sc <- do.call(rbind, scores); pr <- do.call(rbind, pairs)
write.csv(sc, file.path(reg_dir, "compare_scores.csv"), row.names = FALSE)
write.csv(pr, file.path(reg_dir, "compare_pairs.csv"), row.names = FALSE)

cat("Cross-validated scores, same cases, folds and variables (training cases only; the holdout is untouched):\n")
for (o in unique(sc$outcome)) for (r in unique(sc$run[sc$outcome == o])) {
  x <- sc[sc$outcome == o & sc$run == r, ]
  w <- reshape(x[c("model", "metric", "value")], idvar = "model", timevar = "metric", direction = "wide")
  names(w) <- sub("^value\\.", "", names(w))
  cat(sprintf("\n%s, run %d:\n", o, r)); print(w, row.names = FALSE)
}
cat("\nPaired differences (model_a minus model_b; SE from the 5 per-fold differences):\n")
key <- c(log_duration = "r_squared|mae_log|median_abs_error_days", short_60 = "auc|log_loss")
for (o in unique(pr$outcome)) print(pr[pr$outcome == o & grepl(paste0("^(", key[[o]], ")$"), pr$metric), ], row.names = FALSE)
if (length(notes)) cat("\nNot included:\n", paste(" ", notes, collapse = "\n"), "\n")
cat("\nAll pairs and metrics saved in", reg_dir, "(compare_scores.csv, compare_pairs.csv)\n")
