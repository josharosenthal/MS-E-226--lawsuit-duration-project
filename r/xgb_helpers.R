# =============================================================================
# xgb_helpers.R — shared pieces for 07-c_xgboost.R and 07-d_interactions.R, so both
# read the data, code the categories, choose folds and fit with early stopping the
# same way. Sourced by those scripts (after 00_sample.R and covariate_sets.R), not
# run on its own.
# =============================================================================

# training cases with a duration: categories as factors ("(NA)" for missing), counts with
# NA -> 0, and a fold number (the same folds for every outcome, set and script).
# FOLDS (Josh, 1 Nov 2026; change 84): 02-k_check_fold_stability.R found that DuckDB returns
# these rows in a different order every run, and folds used to be dealt out by row position,
# so every run got a fresh random split. Now:
#   - rows are sorted by ucid, so anything drawn by row position (early-stopping sets, SHAP
#     samples) is the same every run
#   - each CONSOLIDATION GROUP gets its fold from an MD5 hash of its key plus the seed, so a
#     lead case and its members share a fold, as in the holdout split (groups as in
#     03_holdout.R: court + the lead case's number; any other case is its own group).
#     The hash scrambles the key, so folds are effectively random but fixed; a different
#     seed gives a different split. Fold sizes are close to, not exactly, equal.
#   inner_seed (optional): also returns fold_inner, a second fold number from the same groups
#   with another seed - for tuning a penalty inside each outer fold (the 08 regression scripts) -
#   and cons_group, an anonymous code for the consolidation group (an MD5 of its key), for
#   standard errors clustered by group (change 95)
xgb_training_data <- function(sets, n_folds, seed, inner_seed = NULL) {
  cat("Reading training cases...\n")
  lead_sql <- if ("consolidation_role" %in% dbListFields(con, "train_fjc")) "consolidation_role = 'lead'" else "false"
  d <- dbGetQuery(con, sprintf("
    WITH k AS (
      SELECT *,
        regexp_extract(CAST(case_id AS VARCHAR), '([0-9]{2})-[a-z]{2}-', 1) || '-' ||
          ltrim(regexp_extract(CAST(case_id AS VARCHAR), '-[a-z]{2}-([0-9]+)', 1), '0') AS own_key,
        CASE WHEN nullif(trim(CAST(lead_case_id AS VARCHAR)), '') IS NOT NULL
             THEN regexp_extract(CAST(lead_case_id AS VARCHAR), '([0-9]{2})-[a-z]{2}-', 1) || '-' ||
                  ltrim(regexp_extract(CAST(lead_case_id AS VARCHAR), '-[a-z]{2}-([0-9]+)', 1), '0') END AS lead_key
      FROM train_fjc
      WHERE duration_capped_days IS NOT NULL AND event_observed IS NOT NULL)
    SELECT ucid, %s, duration_capped_days, event_observed,
      md5(CASE WHEN lead_key IS NOT NULL AND lead_key <> '-' THEN court || '|' || lead_key
               WHEN coalesce(%s, false) AND own_key <> '-'    THEN court || '|' || own_key
               ELSE ucid END || '#' || '%d') AS fold_hash%s
    FROM k ORDER BY ucid",
    paste(unique(unlist(sets)), collapse = ", "), lead_sql, as.integer(seed),
    if (is.null(inner_seed)) "" else sprintf(",
      md5(CASE WHEN lead_key IS NOT NULL AND lead_key <> '-' THEN court || '|' || lead_key
               WHEN coalesce(%s, false) AND own_key <> '-'    THEN court || '|' || own_key
               ELSE ucid END || '#' || '%d') AS inner_hash,
      md5(CASE WHEN lead_key IS NOT NULL AND lead_key <> '-' THEN court || '|' || lead_key
               WHEN coalesce(%s, false) AND own_key <> '-'    THEN court || '|' || own_key
               ELSE ucid END) AS cons_group", lead_sql, as.integer(inner_seed), lead_sql)))
  for (v in setdiff(unique(unlist(sets)), num_vars)) d[[v]] <- factor(ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]])))
  for (v in intersect(num_vars, names(d))) d[[v]][is.na(d[[v]])] <- 0
  d$fold <- strtoi(substr(d$fold_hash, 1, 7), 16L) %% n_folds + 1L
  d$fold_hash <- NULL
  if (!is.null(inner_seed)) { d$fold_inner <- strtoi(substr(d$inner_hash, 1, 7), 16L) %% n_folds + 1L; d$inner_hash <- NULL }
  cat("Fold sizes:", paste(as.vector(table(d$fold)), collapse = " / "), "\n")
  d
}

# which rows of r/model_spec.csv each regression run uses, for the 08 models (reg_helpers.R) and
# the matched tree sets reg_run1 / reg_run2 / reg_run3 (07-c, 07-f); `col` is the model family's
# column (duration_ols, duration_quantile, short_case):
#   run 1  set = main and "Yes"
#   run 2  also the sensitivity rows, and rows marked "Sensitivity only"
#   run 3  run 2 without n_counsel, and without any interaction that uses it (Josh, 2 Nov 2026;
#          change 99: too much evidence that it leaks)
spec_runs <- 1:3
run3_drop <- "n_counsel"
spec_keep <- function(sp, col, run) {
  if (!(run %in% spec_runs)) stop("Run must be 1, 2 or 3.")
  keep <- if (run == 1) sp$set == "main" & sp[[col]] == "Yes" else sp[[col]] %in% c("Yes", "Sensitivity only")
  if (run == 3) keep <- keep & !vapply(strsplit(sp$term, " x ", fixed = TRUE), function(p) any(trimws(p) %in% run3_drop), TRUE)
  keep
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
# smear = TRUE (log duration only; change 97): also each fold's smearing factor, the mean of
# exp(residual) over that fold's training part, for predictions in days as in the 08 OLS
cv_predict <- function(X, y, obj, fold, params, max_rounds, early_stop, n_threads, seed, label = "", smear = FALSE) {
  pred <- rep(NA_real_, length(y)); iters <- integer(0); smears <- numeric(0)
  for (k in sort(unique(fold))) {
    train_idx <- which(fold != k)
    set.seed(seed + k); stop_idx <- sample(train_idx, round(0.1 * length(train_idx)))
    b <- train_es(X, y, obj, setdiff(train_idx, stop_idx), stop_idx, params, max_rounds, early_stop, n_threads, seed)
    iters <- c(iters, best_iter(b))
    pred[fold == k] <- predict(b, xgboost::xgb.DMatrix(X[fold == k, , drop = FALSE]))
    if (smear) smears <- c(smears, mean(exp(y[train_idx] - predict(b, xgboost::xgb.DMatrix(X[train_idx, , drop = FALSE])))))
    cat(sprintf("  %sfold %d: %d trees\n", label, k, tail(iters, 1)))
  }
  list(pred = pred, iters = iters, smear = if (smear) setNames(smears, sort(unique(fold))) else NULL)
}
