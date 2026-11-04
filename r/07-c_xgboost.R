# =============================================================================
# 07-c_xgboost.R — gradient-boosted trees (XGBoost), TRAINING CASES ONLY (Josh, 28 Oct 2026).
#
# The same three outcomes as the forests, so the two kinds of model can be compared:
#   log_duration   regression on log(1 + days), cases that ENDED in court (as 07-a)
#   short_60       ended within 60 days?  yes/no  (as 07-b)
#   short_120      ended within 120 days? yes/no  (as 07-b)
# For the yes/no outcomes, a case transferred out after the cutoff counts as "no" and one
# transferred out before it is dropped for that cutoff (as 07-b).
# Covariate sets: main, main_plus_counsel, sensitivity (r/covariate_sets.R), and two sets
# matched to the 08 regressions (change 97): reg_run1 and reg_run2 use exactly the variables of
# the 08 models' run 1 and run 2 in r/model_spec.csv (for log_duration the duration models'
# list, for short_* the short-case list). No logs or interaction terms: trees don't need them.
# reg_run3 (change 99): run 3, which is run 2 without n_counsel (spec_keep() in xgb_helpers.R).
# reg_run4 (change 100): run 3's variables with the post-filing judge labels pooled (recode_run4()).
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
# SHAP (change 99), from the same model, for a random sample of n_shap of these cases: each
# case's prediction split exactly into a part for each variable (log(1 + days) for log
# duration, log-odds for short_*), one-hot columns added back up to the variable. Saved per
# case (with the variables' values and the case's circuit), and summarized:
#   shap_summary    mean |SHAP| by variable and its share (less tilted toward many-category
#                   variables than gain), and for each category how much of its SHAP spread is
#                   WITHIN its own levels: the same court gets different contributions in
#                   different cases only through interactions with the other variables
#   shap_location   when court is in the set: court's SHAP, judge_group's, and the two added
#                   (the "where and before whom" effect), each split into between circuits,
#                   between courts in a circuit, between judges in a court, and within a judge
#                   (interactions with the other variables); shares of the total sum of squares.
#                   Circuit isn't a model variable (courts nest in it); it's only used to group.
#   shap_by_court   mean SHAP of court, judge_group and the two added, by circuit and court
#                   (judge-level values stay in the .rds)
#
# Choosing outcomes and sets (change 97): with no arguments, the settings below. Otherwise
#   Rscript 07-c_xgboost.R <outcomes> <sets>      comma-separated, e.g.
#   Rscript 07-c_xgboost.R log_duration reg_run1
# and the summary and plot names get a suffix (xgb_summary_log_duration_reg_run1.csv), so jobs
# run side by side don't overwrite each other or the full run's files.
#
# Output: ~/scales_project/models/
#   xgb_summary.csv                        cross-validated performance, each outcome and set
#   xgb_cv/xgb_<outcome>_<set>_cv.rds      each case's cross-validated prediction, with its fold,
#                                          y, each fold's smearing factor (log_duration) and the
#                                          model_spec.csv MD5; read by 08-y_compare_models.R
#   xgb_<outcome>_<set>_importance.csv     gain by variable (share of the total), largest first
#   xgb_<outcome>_importance.png           importance plot, sets side by side
#   xgb_shap/xgb_<outcome>_<set>_shap.rds  SHAP per sampled case (change 99): row (as in the _cv
#                                          file), y, the model's prediction (log-odds for short_*),
#                                          the baseline, SHAP by variable, the variables' values
#                                          and circuit; also the column-level SHAP check
#   xgb_shap/xgb_<outcome>_<set>_full.json the all-cases model itself (xgboost::xgb.load), with
#                                          its column names in the .rds
#   xgb_<outcome>_<set>_shap_summary.csv, _shap_location.csv, _shap_by_court.csv   (above)
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
n_shap     <- 20000                          # cases sampled for SHAP (0 = none); about 0.4 GB per 1,000 columns
n_threads  <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))
args <- commandArgs(TRUE)
if (length(args) >= 1) outcomes   <- strsplit(args[1], ",")[[1]]
if (length(args) >= 2) model_sets <- strsplit(args[2], ",")[[1]]
suffix <- if (length(args)) paste0("_", paste(outcomes, collapse = "-"), "_", paste(model_sets, collapse = "-")) else ""

# ---- Covariate sets and training data ---------------------------------------------------
source(file.path(r_dir, "covariate_sets.R"))
have <- dbListFields(con, "train_fjc")
source(file.path(r_dir, "xgb_helpers.R"))          # spec_keep(), xgb_training_data(), cv_predict()
reg_sets <- paste0("reg_run", spec_runs)
sets <- make_sets(have, setdiff(model_sets, reg_sets))
# the 08 regressions' variables: the non-interaction terms of model_spec.csv, as in
# reg_helpers.R's spec_terms() (spec_keep(): run 1 set main and Yes; run 2 also sensitivity and
# "Sensitivity only"; run 3 run 2 without n_counsel); the duration list for log_duration, the
# short-case list for short_*
spec_file <- file.path(r_dir, "model_spec.csv")
spec_vars <- function(set_name, outcome) {
  sp <- read.csv(spec_file, stringsAsFactors = FALSE)
  col <- if (outcome == "log_duration") "duration_ols" else "short_case"
  keep <- spec_keep(sp, col, as.integer(sub("reg_run", "", set_name)))
  v <- sp$term[keep & sp$type != "interaction"]
  miss <- setdiff(v, have); if (length(miss)) stop("Not in train_fjc: ", paste(miss, collapse = ", "))
  v
}
for (s in intersect(model_sets, reg_sets))   # read every variable either list needs
  sets[[s]] <- unique(unlist(lapply(outcomes, function(o) spec_vars(s, o))))
set_vars <- function(set_name, outcome) if (set_name %in% reg_sets) spec_vars(set_name, outcome) else sets[[set_name]]
# circuit is read only to group the SHAP values (not a model variable)
d_all <- xgb_training_data(c(sets, list(intersect("circuit", have))), n_folds, xgb_seed)
cv_dir <- file.path(model_dir, "xgb_cv"); dir.create(cv_dir, showWarnings = FALSE)
shap_dir <- file.path(model_dir, "xgb_shap"); dir.create(shap_dir, showWarnings = FALSE)

# ---- SHAP for one model (change 99) -------------------------------------------------------
# sum of squares of x split by nested groups: between g1, between g2 within g1, ..., and what's
# left within the last group; shares of the total
nested_ss <- function(x, groups) {
  tot <- sum((x - mean(x))^2); out <- numeric(0); prev <- mean(x)
  key <- rep("", length(x))
  for (g in names(groups)) {
    key <- paste(key, groups[[g]], sep = "|"); m <- ave(x, key)
    out[g] <- sum((m - prev)^2); prev <- m
  }
  out["within"] <- sum((x - prev)^2)
  out / max(tot, 1e-12)
}
shap_one <- function(full, X, col_var, d, y, vars, outcome, set_name) {
  set.seed(xgb_seed); idx <- sort(sample(nrow(X), min(n_shap, nrow(X))))
  vs <- unique(col_var)
  M <- Matrix::sparseMatrix(i = seq_along(col_var), j = match(col_var, vs), x = 1, dims = c(length(col_var), length(vs)))
  S <- matrix(0, length(idx), length(vs), dimnames = list(NULL, vs)); bias <- margin <- numeric(length(idx))
  for (ch in split(seq_along(idx), ceiling(seq_along(idx) / 2000))) {   # chunks keep the dense output small
    dx <- xgboost::xgb.DMatrix(X[idx[ch], , drop = FALSE])
    sh <- predict(full, dx, predcontrib = TRUE)
    is_x <- colnames(sh) %in% colnames(X)
    if (sum(!is_x) != 1 || !identical(colnames(sh)[is_x], colnames(X))) stop("Unexpected SHAP columns from xgboost.")
    bias[ch] <- sh[, !is_x]; S[ch, ] <- as.matrix(sh[, is_x, drop = FALSE] %*% M)
    margin[ch] <- predict(full, dx, outputmargin = TRUE)
  }
  check <- max(abs(rowSums(S) + bias - margin))               # SHAP adds up to the prediction
  cat(sprintf("  SHAP: %s cases, largest gap between SHAP sum and prediction %.2g\n", format(length(idx), big.mark = ","), check))
  vals <- d[idx, unique(c(vars, intersect(c("circuit", "court", "judge_group"), names(d)))), drop = FALSE]
  saveRDS(list(outcome = outcome, set = set_name, row = idx, y = y[idx], margin = margin, bias = bias, shap = S,
               values = vals, columns = colnames(X), sum_check = check, spec_md5 = unname(tools::md5sum(spec_file))),
          file.path(shap_dir, sprintf("xgb_%s_%s_shap.rds", outcome, set_name)))
  ma <- colMeans(abs(S))
  within <- vapply(vs, function(v) if (is.factor(vals[[v]])) { x <- S[, v]; sum((x - ave(x, vals[[v]]))^2) / max(sum((x - mean(x))^2), 1e-12) } else NA_real_, 1)
  summ <- data.frame(variable = vs, mean_abs_shap = signif(ma, 4), share = signif(ma / sum(ma), 4), sd_shap = signif(apply(S, 2, sd), 4),
                     share_within_levels = round(within, 4), n_categories = vapply(vs, function(v) if (is.factor(vals[[v]])) nlevels(droplevels(vals[[v]])) else NA_integer_, 1L),
                     row.names = NULL)
  summ <- summ[order(-summ$mean_abs_shap), ]
  write.csv(summ, file.path(model_dir, sprintf("xgb_%s_%s_shap_summary.csv", outcome, set_name)), row.names = FALSE)
  if ("court" %in% vs) {
    ct <- as.character(vals$court)
    ci <- if ("circuit" %in% names(vals)) as.character(vals$circuit) else rep("(no circuit)", length(ct))
    jg <- if ("judge_group" %in% vs) as.character(vals$judge_group) else rep("", length(ct))
    parts <- list(court = S[, "court"])
    if ("judge_group" %in% vs) parts <- c(parts, list(judge_group = S[, "judge_group"], court_plus_judge = S[, "court"] + S[, "judge_group"]))
    loc <- do.call(rbind, lapply(names(parts), function(p) {           # judges within courts: court + judge as the key
      sh <- nested_ss(parts[[p]], list(circuit = ci, court = ct, judge = jg))
      data.frame(outcome = outcome, set = set_name, shap_of = p, n_cases = length(ct), mean_abs_shap = signif(mean(abs(parts[[p]])), 4),
                 sd_shap = signif(sd(parts[[p]]), 4), share_between_circuits = round(sh[["circuit"]], 4),
                 share_courts_within_circuit = round(sh[["court"]], 4),
                 share_judges_within_court = if ("judge_group" %in% vs) round(sh[["judge"]], 4) else NA,
                 share_within_judge_or_court = round(sh[["within"]], 4), row.names = NULL)
    }))
    write.csv(loc, file.path(model_dir, sprintf("xgb_%s_%s_shap_location.csv", outcome, set_name)), row.names = FALSE)
    by <- aggregate(data.frame(n_sampled = 1, court_shap = parts$court,
                               judge_shap = if ("judge_group" %in% vs) parts$judge_group else NA,
                               court_plus_judge = if ("judge_group" %in% vs) parts$court_plus_judge else parts$court),
                    list(circuit = ci, court = ct), function(z) if (all(is.na(z))) NA else mean(z))
    by$n_sampled <- as.vector(table(paste(ci, ct))[paste(by$circuit, by$court)])
    by[c("court_shap", "judge_shap", "court_plus_judge")] <- lapply(by[c("court_shap", "judge_shap", "court_plus_judge")], signif, 4)
    write.csv(by[order(by$circuit, by$court), ], file.path(model_dir, sprintf("xgb_%s_%s_shap_by_court.csv", outcome, set_name)), row.names = FALSE)
    print(loc[c("shap_of", "share_between_circuits", "share_courts_within_circuit", "share_judges_within_court", "share_within_judge_or_court")], row.names = FALSE)
  }
}

# ---- Fit one outcome and set: cross-validated predictions, then importance --------------
fit_one <- function(outcome, set_name) {
  od <- outcome_data(d_all, outcome); d <- od$d; y <- od$y; obj <- od$obj; dropped <- od$dropped
  if (set_name == "reg_run4") d <- recode_run4(d)
  vars <- set_vars(set_name, outcome)
  dm <- design(d, vars); X <- dm$X
  cat(sprintf("\n%s, %s set: %s cases, %d covariates (%d columns). %s\n", outcome, set_name,
              format(nrow(d), big.mark = ","), length(vars), ncol(X), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time()
  cv <- cv_predict(X, y, obj, d$fold, params, max_rounds, early_stop, n_threads, xgb_seed, smear = outcome == "log_duration")
  pred <- cv$pred; iters <- cv$iters
  # each case's cross-validated prediction (change 97). row = the case's position among this
  # outcome's training cases, sorted by ucid as in the 08 jobs, so 08-y_compare_models.R can line
  # them up (it checks that the folds and outcomes agree)
  saveRDS(list(model = "xgboost", outcome = outcome, set = set_name, vars = vars, median_trees = median(iters),
               pred = data.frame(row = seq_along(y), fold = d$fold, y = y, pred = pred), smear = cv$smear,
               spec_md5 = if (set_name %in% reg_sets) unname(tools::md5sum(spec_file)) else NA),
          file.path(cv_dir, sprintf("xgb_%s_%s_cv.rds", outcome, set_name)))
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
  if (n_shap > 0) {
    xgboost::xgb.save(full, file.path(shap_dir, sprintf("xgb_%s_%s_full.json", outcome, set_name)))
    shap_one(full, X, unname(col_var), d, y, vars, outcome, set_name)
  }
  perf$minutes <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
  print(perf, row.names = FALSE)
  list(perf = perf, imp = imp_tab)
}
res <- list()
for (o in outcomes) for (s in names(sets)) res[[paste(o, s, sep = "|")]] <- fit_one(o, s)
perfs <- lapply(res, `[[`, "perf")
cols <- unique(unlist(lapply(perfs, names)))
summary_tab <- do.call(rbind, lapply(perfs, function(p) { p[setdiff(cols, names(p))] <- NA; p[cols] })); rownames(summary_tab) <- NULL
write.csv(summary_tab, file.path(model_dir, paste0("xgb_summary", suffix, ".csv")), row.names = FALSE)

# ---- Importance plots, one per outcome --------------------------------------------------------
for (o in outcomes) {
  png(file.path(model_dir, sprintf("xgb_%s_importance%s.png", o, suffix)), width = 650 * length(sets), height = 900, res = 110)
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
