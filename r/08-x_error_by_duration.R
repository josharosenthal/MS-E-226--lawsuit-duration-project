# =============================================================================
# 08-x_error_by_duration.R — where the squared error comes from, by how long the case actually
# took (Josh, 6 Nov 2026; change 107: "is the RMSE also higher because of short cases or just
# the long cases?"). TRAINING CASES ONLY (cross-validated predictions); the holdout is untouched.
# Quick: reads saved predictions, no data.
#   Rscript ~/scales_setup/r/08-x_error_by_duration.R
# For log duration, each model's cross-validated predictions (07-c XGBoost; also the 07-f forest
# and 07-g tree if their files are there) and the baseline (each fold's training mean, as 08-y).
# Cases are put in bands of their ACTUAL duration, and for each band:
#   share_of_cases
#   rmse_log, share_of_sq_error_log     on log(1 + days), the scale the models are fitted on
#   rmse_days, share_of_sq_error_days   in days: exp(pred) x the fold's smearing factor - 1, as 08-y
#   mean_error_days                     predicted minus actual (+ = predicted too long)
# A band whose share of the squared error is far above its share of cases is where the RMSE
# comes from. Days and logs can answer differently: in days the long cases dominate, on the log
# scale a quick case predicted at months is a large error.
# Output: ~/scales_project/models/reg/error_by_duration.csv (also printed)
# =============================================================================

project_dir <- path.expand(Sys.getenv("SCALES_PROJECT", "~/scales_project"))
out_dir <- file.path(project_dir, "models", "reg"); dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---- Settings (edit these) --------------------------------------------------------
runs   <- c(1, 4)
bands  <- c(0, 30, 180, 365, 730, Inf)           # actual days: [0,30) [30,180) [180,365) [365,730) [730,+)
files  <- c(xgboost = "xgb_cv/xgb_log_duration_reg_run%d_cv.rds",
            forest  = "forest_cv/rf_log_duration_reg_run%d_cv.rds",
            tree    = "tree_cv/tree_log_duration_reg_run%d_cv.rds")

band_lab <- function(b) { lo <- head(b, -1); hi <- tail(b, -1)
  ifelse(is.infinite(hi), sprintf("%g+ days", lo), sprintf("%g-%g days", lo, hi - 1)) }

one <- function(model, run, d) {
  days <- expm1(d$y); pdays <- exp(d$pred) * d$smear - 1
  band <- cut(days, bands, right = FALSE, labels = band_lab(bands))
  e_log <- (d$y - d$pred)^2; e_day <- (days - pdays)^2
  do.call(rbind, lapply(levels(band), function(b) { i <- band == b
    data.frame(run = run, model = model, actual_duration = b, n_cases = sum(i),
               share_of_cases = round(mean(i), 4),
               rmse_log = round(sqrt(mean(e_log[i])), 3), share_of_sq_error_log = round(sum(e_log[i]) / sum(e_log), 4),
               rmse_days = round(sqrt(mean(e_day[i])), 1), share_of_sq_error_days = round(sum(e_day[i]) / sum(e_day), 4),
               mean_actual_days = round(mean(days[i]), 1), mean_predicted_days = round(mean(pdays[i]), 1),
               mean_error_days = round(mean(pdays[i] - days[i]), 1))
  }))
}

res <- list(); missing <- character(0)
for (run in runs) {
  got <- list()
  for (m in names(files)) {
    f <- file.path(project_dir, "models", sprintf(files[[m]], run))
    if (!file.exists(f)) { missing <- c(missing, sprintf("run %d %s (%s)", run, m, f)); next }
    r <- readRDS(f); d <- r$pred[c("row", "fold", "y", "pred")]
    if (is.null(r$smear)) { missing <- c(missing, sprintf("run %d %s: no smearing factors", run, m)); next }
    d$smear <- unname(r$smear[as.character(d$fold)]); got[[m]] <- d
  }
  if (!length(got)) next
  ref <- got[[1]]; K <- sort(unique(ref$fold))           # baseline: each fold's training mean, as 08-y
  base <- vapply(K, function(k) mean(ref$y[ref$fold != k]), 1)
  sm <- vapply(K, function(k) mean(exp(ref$y[ref$fold != k] - base[k == K])), 1)
  got <- c(list(baseline = data.frame(ref[c("row", "fold", "y")], pred = base[match(ref$fold, K)], smear = sm[match(ref$fold, K)])), got)
  for (m in names(got)) {
    if (nrow(got[[m]]) != nrow(ref) || max(abs(got[[m]]$y - ref$y)) > 1e-9) stop(sprintf("run %d: %s has different cases from %s", run, m, names(got)[2]))
    res[[paste(run, m)]] <- one(m, run, got[[m]])
  }
}
if (!length(res)) stop("No prediction files found:\n", paste(missing, collapse = "\n"))
out <- do.call(rbind, res); rownames(out) <- NULL
f <- file.path(out_dir, "error_by_duration.csv"); write.csv(out, f, row.names = FALSE)

cat("Log duration: where the squared error comes from, by actual duration\n",
    "(cross-validated, training cases only; the holdout is untouched)\n", sep = "")
for (run in unique(out$run)) for (m in unique(out$model[out$run == run])) {
  cat(sprintf("\nrun %d, %s:\n", run, m))
  print(out[out$run == run & out$model == m, -(1:2)], row.names = FALSE)
}
if (length(missing)) cat("\nNot included:\n", paste(" ", missing, collapse = "\n"), "\n")
cat("\nSaved", f, "\n")
