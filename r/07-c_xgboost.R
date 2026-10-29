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
cat("Reading training cases...\n")
d_all <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                                  WHERE duration_capped_days IS NOT NULL AND event_observed IS NOT NULL",
                                 paste(unique(unlist(sets)), collapse = ", ")))
for (v in setdiff(unique(unlist(sets)), num_vars)) d_all[[v]] <- factor(ifelse(is.na(d_all[[v]]), "(NA)", as.character(d_all[[v]])))
for (v in intersect(num_vars, names(d_all))) d_all[[v]][is.na(d_all[[v]])] <- 0
set.seed(xgb_seed)
d_all$fold <- sample(rep_len(seq_len(n_folds), nrow(d_all)))     # the same folds for every outcome and set

auc <- function(p, y) {                       # Mann-Whitney form of the area under the ROC curve
  r <- rank(p); n1 <- as.numeric(sum(y)); n0 <- as.numeric(length(y)) - n1
  if (n1 == 0 || n0 == 0) return(NA_real_)
  (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
# one-hot design matrix (every category gets a column); `vars` maps each column back to its variable
design <- function(d, vars) {
  d[vars] <- lapply(d[vars], function(x) if (is.factor(x)) droplevels(x) else x)
  vars <- vars[vapply(vars, function(v) !is.factor(d[[v]]) || nlevels(d[[v]]) >= 2, TRUE)]   # a one-category variable can't split
  f <- vars[vapply(d[vars], is.factor, TRUE)]
  X <- Matrix::sparse.model.matrix(reformulate(vars, intercept = FALSE), d,
                                   contrasts.arg = lapply(setNames(f, f), function(v) contrasts(d[[v]], contrasts = FALSE)))
  list(X = X, vars = vars[attr(X, "assign")])
}
# xgb.train's validation-set argument was renamed from watchlist to evals in xgboost 2
evals_arg <- if ("evals" %in% names(formals(xgboost::xgb.train))) "evals" else "watchlist"
train_es <- function(X, y, obj, idx_fit, idx_stop) {
  dfit  <- xgboost::xgb.DMatrix(X[idx_fit, , drop = FALSE], label = y[idx_fit])
  dstop <- xgboost::xgb.DMatrix(X[idx_stop, , drop = FALSE], label = y[idx_stop])
  args <- list(params = c(params, list(objective = obj, nthread = n_threads, seed = xgb_seed,
                                       eval_metric = if (obj == "binary:logistic") "logloss" else "rmse")),
               data = dfit, nrounds = max_rounds, early_stopping_rounds = early_stop, verbose = 0)
  args[[evals_arg]] <- list(stop = dstop)
  do.call(xgboost::xgb.train, args)
}
best_iter <- function(b) {
  it <- xgboost::xgb.attr(b, "best_iteration")
  if (is.null(it)) it <- b$best_iteration
  as.integer(it) + if (evals_arg == "evals") 1L else 0L          # 0-based in xgboost 2+, 1-based before
}

# ---- Fit one outcome and set: cross-validated predictions, then importance --------------
fit_one <- function(outcome, set_name) {
  if (outcome == "log_duration") {
    d <- d_all[d_all$event_observed, ]; y <- log1p(d$duration_capped_days); obj <- "reg:squarederror"; dropped <- NA
  } else {
    cutoff <- as.integer(sub("short_", "", outcome))
    keep <- d_all$event_observed | d_all$duration_capped_days > cutoff    # drop cases transferred out before the cutoff
    d <- d_all[keep, ]; y <- as.numeric(d$duration_capped_days <= cutoff); obj <- "binary:logistic"; dropped <- sum(!keep)
  }
  vars <- sets[[set_name]]
  dm <- design(d, vars); X <- dm$X
  cat(sprintf("\n%s, %s set: %s cases, %d covariates (%d columns). %s\n", outcome, set_name,
              format(nrow(d), big.mark = ","), length(vars), ncol(X), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time(); pred <- rep(NA_real_, nrow(d)); iters <- integer(0)
  for (k in seq_len(n_folds)) {
    train_idx <- which(d$fold != k)
    set.seed(xgb_seed + k); stop_idx <- sample(train_idx, round(0.1 * length(train_idx)))
    b <- train_es(X, y, obj, setdiff(train_idx, stop_idx), stop_idx)
    iters <- c(iters, best_iter(b))
    pred[d$fold == k] <- predict(b, xgboost::xgb.DMatrix(X[d$fold == k, , drop = FALSE]))
    cat(sprintf("  fold %d: %d trees\n", k, tail(iters, 1)))
  }
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
