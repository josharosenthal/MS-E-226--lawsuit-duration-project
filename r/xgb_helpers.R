# =============================================================================
# xgb_helpers.R — shared pieces for 07-c_xgboost.R and 07-d_interactions.R, so both
# read the data, code the categories, choose folds and fit with early stopping the
# same way. Sourced by those scripts (after 00_sample.R and covariate_sets.R), not
# run on its own.
# =============================================================================

# training cases with a duration: categories as factors ("(NA)" for missing), counts with
# NA -> 0, and a random fold number (the same folds for every outcome and set)
xgb_training_data <- function(sets, n_folds, seed) {
  cat("Reading training cases...\n")
  d <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                                WHERE duration_capped_days IS NOT NULL AND event_observed IS NOT NULL",
                               paste(unique(unlist(sets)), collapse = ", ")))
  for (v in setdiff(unique(unlist(sets)), num_vars)) d[[v]] <- factor(ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]])))
  for (v in intersect(num_vars, names(d))) d[[v]][is.na(d[[v]])] <- 0
  set.seed(seed)
  d$fold <- sample(rep_len(seq_len(n_folds), nrow(d)))
  d
}

# the cases and outcome for one outcome name:
#   log_duration   cases that ended in court, y = log(1 + days)
#   short_<days>   y = ended within <days>; cases transferred out before the cutoff are dropped
outcome_data <- function(d_all, outcome) {
  if (outcome == "log_duration") {
    d <- d_all[d_all$event_observed, ]
    return(list(d = d, y = log1p(d$duration_capped_days), obj = "reg:squarederror", dropped = NA))
  }
  cutoff <- as.integer(sub("short_", "", outcome))
  keep <- d_all$event_observed | d_all$duration_capped_days > cutoff
  d <- d_all[keep, ]
  list(d = d, y = as.numeric(d$duration_capped_days <= cutoff), obj = "binary:logistic", dropped = sum(!keep))
}

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
train_es <- function(X, y, obj, idx_fit, idx_stop, params, max_rounds, early_stop, n_threads, seed) {
  dfit  <- xgboost::xgb.DMatrix(X[idx_fit, , drop = FALSE], label = y[idx_fit])
  dstop <- xgboost::xgb.DMatrix(X[idx_stop, , drop = FALSE], label = y[idx_stop])
  args <- list(params = c(params, list(objective = obj, nthread = n_threads, seed = seed,
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

# cross-validated predictions: each fold is predicted by a model fitted on the other folds,
# with early stopping on a further 10% of those folds (so a fold is only ever used for scoring)
cv_predict <- function(X, y, obj, fold, params, max_rounds, early_stop, n_threads, seed, label = "") {
  pred <- rep(NA_real_, length(y)); iters <- integer(0)
  for (k in sort(unique(fold))) {
    train_idx <- which(fold != k)
    set.seed(seed + k); stop_idx <- sample(train_idx, round(0.1 * length(train_idx)))
    b <- train_es(X, y, obj, setdiff(train_idx, stop_idx), stop_idx, params, max_rounds, early_stop, n_threads, seed)
    iters <- c(iters, best_iter(b))
    pred[fold == k] <- predict(b, xgboost::xgb.DMatrix(X[fold == k, , drop = FALSE]))
    cat(sprintf("  %sfold %d: %d trees\n", label, k, tail(iters, 1)))
  }
  list(pred = pred, iters = iters)
}
