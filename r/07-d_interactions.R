# =============================================================================
# 07-d_interactions.R — do interactions between covariates matter? TRAINING CASES ONLY
# (Josh, 29 Oct 2026).
#
# STEP 1 (this version): the depth check. XGBoost is refitted with trees of different depths:
#   depth 1   each tree splits once, so the model is ADDITIVE: every variable has its own
#             effect, whatever the others are - like a regression with no interaction terms
#             (but each variable's effect can be any shape)
#   depth 2   each tree splits twice, so pairs of variables can interact (two-way)
#   depth 6   as in 07-c: combinations of up to six variables
# The gaps say how much the interactions are worth:
#   depth 2 minus depth 1   value of two-way interactions
#   depth 6 minus depth 2   value of higher-order interactions on top of that
# Each gap is measured in each of the 5 folds (same folds for every depth), so it comes with
# a fold-to-fold standard error; gap / se above about 2-3 means it's consistent across folds,
# not noise. Small gaps mean an additive OLS / lasso / quantile regression loses little, and
# steps 2-4 (which pairs; what they look like; do they help the regression) aren't needed.
# Steps 2-4 are in 07-e_interaction_pairs.R.
#
# Same outcomes and settings as 07-c (log duration; ended within 60 / 120 days), main set by
# default, so depth 6 here reproduces 07-c's main model. Depth-1 models need many more
# trees, hence the higher cap; hit_cap = TRUE in the output means the cap was reached and
# that model may be slightly under-fitted.
#
# Output: ~/scales_project/models/
#   interactions_1_depth_check.csv     cross-validated performance by outcome and depth
#   interactions_1_depth_gaps.csv      the gaps, with fold-to-fold standard errors
#
# Needs the xgboost package (as 07-c). Batch job: --cpus-per-task=8 --mem=32G, a few hours.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("xgboost", quietly = TRUE))
  stop("The xgboost package isn't installed. Run once in R:  install.packages(\"xgboost\")")
model_dir <- file.path(project_dir, "models"); dir.create(model_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes   <- c("log_duration", "short_60", "short_120")
model_sets <- "main"                         # add "sensitivity" to check it too
depths     <- c(1, 2, 6)
n_folds    <- 5
params     <- list(eta = 0.05, min_child_weight = 10, subsample = 0.8, colsample_bytree = 0.8,
                   tree_method = "hist")     # as 07-c; max_depth is set from `depths`
max_rounds <- c(`1` = 10000, `2` = 6000, `6` = 3000)   # tree cap by depth (shallow trees need more)
early_stop <- 50
xgb_seed   <- 226
n_threads  <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))

source(file.path(r_dir, "covariate_sets.R"))
sets <- make_sets(dbListFields(con, "train_fjc"), model_sets)
source(file.path(r_dir, "xgb_helpers.R"))
d_all <- xgb_training_data(sets, n_folds, xgb_seed)      # same folds as 07-c

# score per fold and overall: R-squared (log duration) or AUC (yes/no), plus Brier skill for yes/no
score <- function(y, p, obj) {
  if (obj == "binary:logistic") c(main = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / (mean(y) * (1 - mean(y))))
  else c(main = 1 - sum((y - p)^2) / sum((y - mean(y))^2), brier_skill = NA)
}

# ---- Step 1: the depth check -----------------------------------------------------------
rows <- list(); fold_scores <- list()
for (o in outcomes) for (s in names(sets)) {
  od <- outcome_data(d_all, o); dm <- design(od$d, sets[[s]])
  cat(sprintf("\n%s, %s set: %s cases, %d columns. %s\n", o, s, format(nrow(od$d), big.mark = ","), ncol(dm$X), format(Sys.time(), "%H:%M:%S")))
  for (dep in depths) {
    t0 <- Sys.time(); cap <- if (as.character(dep) %in% names(max_rounds)) max_rounds[[as.character(dep)]] else 3000
    cv <- cv_predict(dm$X, od$y, od$obj, od$d$fold, c(params, list(max_depth = dep)), cap, early_stop,
                     n_threads, xgb_seed, label = sprintf("depth %d, ", dep))
    sc <- score(od$y, cv$pred, od$obj)
    per_fold <- vapply(sort(unique(od$d$fold)), function(k) { i <- od$d$fold == k; score(od$y[i], cv$pred[i], od$obj)[["main"]] }, 1)
    fold_scores[[paste(o, s, dep)]] <- per_fold
    rows[[length(rows) + 1]] <- data.frame(outcome = o, set = s, depth = dep, n_cases = nrow(od$d),
      metric = if (od$obj == "binary:logistic") "cv_auc" else "cv_r_squared", value = round(sc[["main"]], 4),
      brier_skill = round(sc[["brier_skill"]], 4), median_trees = median(cv$iters), hit_cap = any(cv$iters >= cap),
      minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1))
    print(tail(rows, 1)[[1]], row.names = FALSE)
  }
}
depth_tab <- do.call(rbind, rows)
write.csv(depth_tab, file.path(model_dir, "interactions_1_depth_check.csv"), row.names = FALSE)

# gaps between depths, paired fold by fold
gap <- function(o, s, hi, lo, label) {
  a <- fold_scores[[paste(o, s, hi)]]; b <- fold_scores[[paste(o, s, lo)]]
  if (is.null(a) || is.null(b)) return(NULL)
  dlt <- a - b; se <- sd(dlt) / sqrt(length(dlt))
  data.frame(outcome = o, set = s, comparison = label, metric = if (grepl("short", o)) "cv_auc" else "cv_r_squared",
             gap = round(mean(dlt), 4), se_across_folds = round(se, 4), gap_over_se = round(mean(dlt) / se, 1),
             folds_positive = sprintf("%d of %d", sum(dlt > 0), length(dlt)))
}
gaps <- do.call(rbind, lapply(outcomes, function(o) do.call(rbind, lapply(names(sets), function(s) rbind(
  gap(o, s, 2, 1, "depth 2 minus depth 1 (two-way interactions)"),
  gap(o, s, 6, 2, "depth 6 minus depth 2 (higher-order, on top)"),
  gap(o, s, 6, 1, "depth 6 minus depth 1 (all interactions)"))))))
write.csv(gaps, file.path(model_dir, "interactions_1_depth_gaps.csv"), row.names = FALSE)

cat("\nCross-validated performance by tree depth (training cases only; the holdout is untouched):\n")
print(depth_tab, row.names = FALSE)
cat("\nWhat the interactions are worth (mean gap over the folds, its standard error, and how many folds it was positive in):\n")
print(gaps, row.names = FALSE)
cat("\nAll outputs saved in", model_dir, "\n")
