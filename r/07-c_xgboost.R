# =============================================================================
# 07-c_xgboost.R — gradient-boosted trees (XGBoost), TRAINING CASES ONLY (Josh, 28 Oct 2026).
#
# The same three outcomes as the forests, so the two kinds of model can be compared:
#   log_duration   regression on log(1 + days), cases that ENDED in court (as 07-a)
#   short_60       ended within 60 days?  yes/no  (as 07-b)
#   short_120      ended within 120 days? yes/no  (as 07-b)
# For the yes/no outcomes, a case transferred out after the cutoff counts as "no" and one
# transferred out before it is dropped for that cutoff (as 07-b).
# Covariate sets: main, main_plus_counsel, sensitivity (r/covariate_sets.R).
#
# A forest grows deep trees independently and averages them. Boosting grows many small
# trees one after another, each fitted to what the earlier ones got wrong, so it can pick
# up finer patterns - and can also overfit, which is why the number of trees is chosen by
# early stopping (stop adding trees once a validation set stops improving).
#
# How it's judged: boosting has no out-of-bag error, so 5-FOLD CROSS-VALIDATION within the
# training cases. Each case is predicted by a model fitted on the other four folds (its
# early-stopping set is a further 10% of those folds, so the case's own fold is never used
# for anything but scoring). The HOLDOUT stays unused.
#   log_duration:  cross-validated R-squared and RMSE on log(1 + days); median absolute
#                  error in days (comparable to 07-a's OOB numbers)
#   short_*:       cross-validated AUC, Brier score and Brier skill (comparable to 07-b)
# Variable importance: "gain" (how much each variable's splits improved the fit) from one
# model on all training cases, with the median number of trees from the folds. Categories
# are one-hot coded (one column per category) and their gains are added back up to the
# variable. Like the forests, many-category variables can look more important than they are.
#
# Output: ~/scales_project/models/
#   xgb_summary.csv                        cross-validated performance, each outcome and set
#   xgb_<outcome>_<set>_importance.csv     gain by variable (share of the total), largest first
#   xgb_<outcome>_importance.png           importance plot, sets side by side
#
# Needs the xgboost package. If it's missing, run once in R:  install.packages("xgboost")
# Run as a batch job: --cpus-per-task=8 --mem=32G, a few hours.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("xgboost", quietly = TRUE))
  stop("The xgboost package isn't installed. Run once in R:  install.packages(\"xgboost\")")
model_dir <- file.path(project_dir, "models"); dir.create(model_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes   <- c("log_duration", "short_60", "short_120")
model_sets <- c("main", "main_plus_counsel", "sensitivity")
n_folds    <- 5
params     <- list(eta = 0.05,               # learning rate: smaller = more, gentler trees
                   max_depth = 6,            # depth of each tree
                   min_child_weight = 10,    # smallest leaf (roughly, number of cases)
                   subsample = 0.8,          # share of cases each tree sees
                   colsample_bytree = 0.8,   # share of columns each tree sees
                   tree_method = "hist")
max_rounds <- 3000                           # upper limit on the number of trees
early_stop <- 50                             # stop after this many trees without improvement
xgb_seed   <- 226
n_threads  <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))

# ---- Covariate sets and training data ---------------------------------------------------
source(file.path(r_dir, "covariate_sets.R"))
sets <- make_sets(dbListFields(con, "train_fjc"), model_sets)
source(file.path(r_dir, "xgb_helpers.R"))
d_all <- xgb_training_data(sets, n_folds, xgb_seed)

# ---- Fit one outcome and set: cross-validated predictions, then importance --------------
fit_one <- function(outcome, set_name) {
  od <- outcome_data(d_all, outcome); d <- od$d; y <- od$y; obj <- od$obj; dropped <- od$dropped
  vars <- sets[[set_name]]
  dm <- design(d, vars); X <- dm$X
  cat(sprintf("\n%s, %s set: %s cases, %d covariates (%d columns). %s\n", outcome, set_name,
              format(nrow(d), big.mark = ","), length(vars), ncol(X), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time()
  cv <- cv_predict(X, y, obj, d$fold, params, max_rounds, early_stop, n_threads, xgb_seed)
  pred <- cv$pred; iters <- cv$iters
  perf <- data.frame(outcome = outcome, set = set_name, n_cases = nrow(d), n_dropped_transferred = dropped,
                     n_covariates = length(vars), n_columns = ncol(X), median_trees = median(iters))
  if (outcome == "log_duration") {
    perf$cv_r_squared <- round(1 - sum((y - pred)^2) / sum((y - mean(y))^2), 4)
    perf$cv_rmse_log  <- round(sqrt(mean((y - pred)^2)), 4)
    perf$cv_median_abs_error_days <- round(median(abs(expm1(pred) - d$duration_capped_days)), 1)
  } else {
    brier <- mean((pred - y)^2); null <- mean(y) * (1 - mean(y))
    perf$pct_short <- round(100 * mean(y), 2)
    perf$cv_auc <- round(auc(pred, y == 1), 4); perf$cv_brier <- round(brier, 5)
    perf$brier_skill <- round(1 - brier / null, 4)
  }
  # importance: one model on all of these training cases, with the median number of trees
  args <- list(params = c(params, list(objective = obj, nthread = n_threads, seed = xgb_seed)),
               data = xgboost::xgb.DMatrix(X, label = y), nrounds = max(1L, as.integer(median(iters))), verbose = 0)
  full <- do.call(xgboost::xgb.train, args)
  g <- xgboost::xgb.importance(model = full)
  col_var <- setNames(dm$vars, colnames(X))
  gain <- if (is.null(g) || !nrow(g)) numeric(0) else c(tapply(g$Gain, col_var[g$Feature], sum))
  gain <- sort(c(gain, setNames(rep(0, length(setdiff(vars, names(gain)))), setdiff(vars, names(gain)))), decreasing = TRUE)
  imp_tab <- data.frame(variable = names(gain), gain_share = signif(gain / max(sum(gain), 1e-12), 4),   # all 0 if no tree split
                        n_categories = vapply(names(gain), function(v) if (is.factor(d[[v]])) nlevels(d[[v]]) else NA_integer_, 1L),
                        in_main = names(gain) %in% main_vars, row.names = NULL)
  write.csv(imp_tab, file.path(model_dir, sprintf("xgb_%s_%s_importance.csv", outcome, set_name)), row.names = FALSE)
  perf$minutes <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
  print(perf, row.names = FALSE)
  list(perf = perf, imp = imp_tab)
}
res <- list()
for (o in outcomes) for (s in names(sets)) res[[paste(o, s, sep = "|")]] <- fit_one(o, s)
perfs <- lapply(res, `[[`, "perf")
cols <- unique(unlist(lapply(perfs, names)))
summary_tab <- do.call(rbind, lapply(perfs, function(p) { p[setdiff(cols, names(p))] <- NA; p[cols] })); rownames(summary_tab) <- NULL
write.csv(summary_tab, file.path(model_dir, "xgb_summary.csv"), row.names = FALSE)

# ---- Importance plots, one per outcome --------------------------------------------------------
for (o in outcomes) {
  png(file.path(model_dir, sprintf("xgb_%s_importance.png", o)), width = 650 * length(sets), height = 900, res = 110)
  par(mfrow = c(1, length(sets)), mar = c(4, 13, 3, 1))
  for (s in names(sets)) {
    x <- head(res[[paste(o, s, sep = "|")]]$imp, 25); x <- x[rev(seq_len(nrow(x))), ]
    barplot(x$gain_share, horiz = TRUE, names.arg = x$variable, las = 1, cex.names = 0.7,
            col = ifelse(x$in_main, "grey45", "firebrick"), xlab = "share of total gain", main = sprintf("%s: %s", s, o))
  }
  legend("bottomright", c("main covariate", "not in main (leaky)"), fill = c("grey45", "firebrick"), bty = "n", cex = 0.8)
  dev.off()
}

# ---- Headline ------------------------------------------------------------------------------
cat("\nCross-validated performance (training cases only; the holdout is untouched):\n"); print(summary_tab, row.names = FALSE)
for (o in outcomes) {
  m <- if (o == "log_duration") "cv_r_squared" else "cv_auc"
  v <- function(s) summary_tab[summary_tab$outcome == o & summary_tab$set == s, m]
  if (all(c("main", "main_plus_counsel") %in% names(sets)))
    cat(sprintf("%s - main_plus_counsel minus main (%s): %+.4f\n", o, m, v("main_plus_counsel") - v("main")))
  if (all(c("main", "sensitivity") %in% names(sets)))
    cat(sprintf("%s - sensitivity minus main (%s): %+.4f (an UPPER BOUND on what the leaky variables add)\n", o, m, v("sensitivity") - v("main")))
}
for (o in outcomes) if (paste(o, "main", sep = "|") %in% names(res)) {
  cat(sprintf("\nTop 10 variables, main model, %s:\n", o)); print(head(res[[paste(o, "main", sep = "|")]]$imp, 10), row.names = FALSE)
}
cat("\nAll outputs saved in", model_dir, "\n")
