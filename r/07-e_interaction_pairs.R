# =============================================================================
# 07-e_interaction_pairs.R — WHICH pairs of covariates interact, what the interactions
# look like, and do they help a regression? TRAINING CASES ONLY (Josh, 31 Oct 2026).
# Steps 2-4 of the interaction plan, for log duration and ended within 60 days (short_120 is
# left out by default); step 1 (do interactions matter at all?) is 07-d_interactions.R, whose
# depth check found most of the gain comes from two-way pairs.
#
# STEP 2 — which pairs. One XGBoost model per outcome with trees of depth 2 (so every tree is
#   one variable or one pair), main set, fitted on the training cases. For a sample of cases,
#   XGBoost splits each prediction exactly into a part for each variable ("main effect") and
#   a part for each pair ("SHAP interaction values"). A pair's strength is the average size of
#   its part, in the model's units: log(1 + days) for log duration, log-odds for the
#   ended-within-60-day outcome. Categories' one-hot columns are added up to their
#   variable first. rank_half_a / rank_half_b are the ranks in two random halves of the
#   sample: if they're close, the ranking is stable.
# STEP 3 — what the top pairs look like. For each top pair, a grid of the two variables'
#   levels (the most common categories, the rest as "other"; counts in up to 5 bins):
#     mean_shap_interaction     the model's interaction part in that cell (other variables held
#                               in the model, so this is the pair's own joint effect)
#     mean_outcome              raw average outcome in the cell (all training cases)
#     departure_from_additive   raw cell average minus what the two variables would give if
#                               they simply added up (no model, no other variables)
#   small_cell = TRUE: fewer than min_cell cases - don't read much into it.
# STEP 4 — do they help a regression? 5-fold cross-validated OLS (same folds as 07-c / 07-d)
#   on the main set with no interactions, then adding each top pair on its own, then all top
#   pairs together. Each pair's term crosses the two variables (categories lumped as in step 3;
#   counts as centred log(1 + count)). For the ended-within outcomes the OLS is a linear
#   probability model scored by AUC (ranking) and Brier skill (accuracy of the predicted
#   probabilities; AUC can miss a pair that changes how likely, but not the order) - a quick
#   check, not the final model. The pairs were
#   chosen from these same training cases, so the gains are slightly optimistic; the holdout
#   is untouched. XGBoost rows from step 1 are shown for comparison if that file exists.
#
# Output: ~/scales_project/models/, one set per outcome, written as soon as that outcome is done
# (<outcome> = log_duration or short_60; short_120 if named):
#   interactions_2_pairs_<outcome>.csv              every pair, ranked
#   interactions_2_summary_<outcome>.csv            total main-effect vs pair strength
#   interactions_2_top_pairs_<outcome>.png          the strongest pairs
#   interactions_3_shapes_<outcome>.csv             the level-by-level grid for each top pair
#   interactions_3_heatmaps_<outcome>.png           heat maps of mean_shap_interaction for the top pairs
#                                         (red = the pair pushes the prediction up: longer for
#                                         log duration, MORE likely to end within the cutoff for
#                                         short_60; blue = down; grey = under 10
#                                         sampled cases; each panel has its own colour scale)
#   interactions_4_regression_check_<outcome>.csv   cross-validated OLS with and without the pairs
#
# Run time is mostly step 2, and grows with trees x sampled cases x columns. On the real data
# (31 Oct 2026, 8 CPUs, about 500 columns, 5,000 cases): log_duration about 1 h 40 min
# (4,680 trees), short_60 about 3 h 40 min (8,128 trees). One job per outcome is quickest:
#   sbatch ... --wrap="... Rscript ~/scales_setup/r/07-e_interaction_pairs.R short_60"
# Needs the xgboost package (as 07-c). Batch job: --cpus-per-task=8 --mem=32G, up to 6 hours per outcome.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("xgboost", quietly = TRUE))
  stop("The xgboost package isn't installed. Run once in R:  install.packages(\"xgboost\")")
model_dir <- file.path(project_dir, "models"); dir.create(model_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes    <- c("log_duration", "short_60")   # short_120 left out (Josh, 31 Oct 2026); any of the
                                                # three can be named after the script instead:
                                                #   Rscript 07-e_interaction_pairs.R short_60
model_set   <- "main"
pair_depth  <- 2                  # depth-2 trees: each tree is one variable or one pair
params      <- list(eta = 0.05, min_child_weight = 10, subsample = 0.8, colsample_bytree = 0.8,
                    tree_method = "hist")     # as 07-c / 07-d
max_rounds  <- 15000              # 07-d's depth-2 models reached 6,000 trees, so a higher cap
early_stop  <- 50
xgb_seed    <- 226
n_threads   <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))
n_shap      <- 5000               # cases sampled for the SHAP interaction values
shap_batch  <- 250                # cases per batch (memory: about 1 MB per case)
n_top_pairs <- 6                  # pairs carried into steps 3 and 4
lump_levels <- 8                  # most common categories kept in steps 3-4; the rest are "other"
n_bins      <- 5                  # bins for counts in step 3
min_cell    <- 30                 # step 3 cells with fewer training cases are flagged small_cell
n_folds     <- 5
log_counts  <- TRUE               # step 4: counts enter the OLS as log(1 + count)

args <- commandArgs(trailingOnly = TRUE)
if (length(args)) {
  bad <- setdiff(args, c("log_duration", "short_60", "short_120"))
  if (length(bad)) stop("Unknown outcome(s): ", paste(bad, collapse = ", "), ". Use log_duration, short_60 or short_120.")
  outcomes <- args
}

source(file.path(r_dir, "covariate_sets.R"))
sets <- make_sets(dbListFields(con, "train_fjc"), model_set)
source(file.path(r_dir, "xgb_helpers.R"))
d_all <- xgb_training_data(sets, n_folds, xgb_seed)      # same folds as 07-c and 07-d
vars_all <- sets[[1]]

# score per fold and overall, as in 07-d: R-squared (log duration) or AUC (yes/no)
score <- function(y, p, binary) if (binary) auc(p, y == 1) else 1 - sum((y - p)^2) / sum((y - mean(y))^2)

# category -> the most common lump_levels categories (most common first), the rest "other"
lump <- function(x, k = lump_levels) {
  tab <- sort(table(as.character(x)), decreasing = TRUE)
  keep <- names(tab)[seq_len(min(k, length(tab)))]
  factor(ifelse(as.character(x) %in% keep, as.character(x), "other"), levels = c(keep, if (length(tab) > k) "other"))
}
# count -> up to n_bins bins with about equal numbers of cases
bin <- function(x, k = n_bins) {
  br <- unique(quantile(x, seq(0, 1, length.out = k + 1), names = FALSE))
  if (length(br) < 2) return(factor(rep(format(x[1]), length(x))))
  cut(x, br, include.lowest = TRUE, dig.lab = 6)
}
cell_var <- function(d, v) if (v %in% num_vars) bin(d[[v]]) else lump(d[[v]])

pair_rows <- list(); summary_rows <- list(); shape_rows <- list(); reg_rows <- list(); top <- list()

# ---- Outputs for one outcome, written as soon as it's done (so a timeout keeps what's finished) ----
short <- function(s, k = 22) ifelse(nchar(s) > k, paste0(substr(s, 1, k - 1), "~"), s)
save_outcome <- function(o) {
  out <- function(name, ext = "csv") file.path(model_dir, sprintf("interactions_%s_%s.%s", name, o, ext))
  write.csv(pair_rows[[o]], out("2_pairs"), row.names = FALSE)
  write.csv(summary_rows[[o]], out("2_summary"), row.names = FALSE)
  x3 <- do.call(rbind, Filter(function(z) z$outcome[1] == o, shape_rows))
  write.csv(x3, out("3_shapes"), row.names = FALSE)
  write.csv(reg_rows[[o]], out("4_regression_check"), row.names = FALSE)
  png(out("2_top_pairs", "png"), width = 700, height = 900, res = 110)
  par(mar = c(4, 17, 3, 1))
  x <- head(pair_rows[[o]], 15); x <- x[rev(seq_len(nrow(x))), ]
  barplot(x$share_of_all_pairs, horiz = TRUE, xlim = c(0, max(x$share_of_all_pairs, 0.01)), names.arg = paste(x$var1, "x", x$var2), las = 1, cex.names = 0.6,
          main = o, xlab = "share of all pair strength")
  dev.off()
  if (is.null(x3) || !nrow(x3)) return(invisible())
  png(out("3_heatmaps", "png"), width = 1500, height = 1000, res = 100)
  par(mfrow = c(2, 3), mar = c(9, 11, 3, 1))
  for (r in sort(unique(x3$pair_rank))) {
    z <- x3[x3$pair_rank == r, ]; z$mean_shap_interaction[z$n_shap_cases < 10] <- NA   # grey: under 10 sampled cases
    lim <- max(abs(z$mean_shap_interaction), 1e-9, na.rm = TRUE)                         # each panel its own scale
    r1 <- unique(z$level1); r2 <- unique(z$level2)
    m <- matrix(NA, length(r1), length(r2)); m[cbind(match(z$level1, r1), match(z$level2, r2))] <- z$mean_shap_interaction
    image(seq_along(r1), seq_along(r2), m, col = hcl.colors(21, "Blue-Red 3"), zlim = c(-lim, lim),
          axes = FALSE, xlab = "", ylab = "", main = sprintf("%d. %s x %s\n(colour scale -%.3f to +%.3f)", r, z$var1[1], z$var2[1], lim, lim), cex.main = 0.85)
    if (anyNA(m)) image(seq_along(r1), seq_along(r2), ifelse(is.na(m), 1, NA), col = "grey85", add = TRUE)
    text(row(m), col(m), ifelse(is.na(m), "", formatC(m, format = "f", digits = 3)), cex = 0.7,
         col = ifelse(!is.na(m) & abs(m) > 0.6 * lim, "white", "black"))
    axis(1, seq_along(r1), short(r1), las = 2, cex.axis = 0.65); axis(2, seq_along(r2), short(r2), las = 1, cex.axis = 0.65)
    box()
  }
  dev.off()
  cat(sprintf("  %s: outputs saved (interactions_*_%s.*) %s\n", o, o, format(Sys.time(), "%H:%M:%S")))
}

for (o in outcomes) {
  od <- outcome_data(d_all, o); binary <- od$obj == "binary:logistic"
  dm <- design(od$d, vars_all); n <- nrow(od$d)
  cat(sprintf("\n===== %s: %s cases, %d columns. %s\n", o, format(n, big.mark = ","), ncol(dm$X), format(Sys.time(), "%H:%M:%S")))

  # ---- Step 2: which pairs ---------------------------------------------------------------
  set.seed(xgb_seed); stop_idx <- sample(n, round(0.1 * n))
  b <- train_es(dm$X, od$y, od$obj, setdiff(seq_len(n), stop_idx), stop_idx,
                c(params, list(max_depth = pair_depth)), max_rounds, early_stop, n_threads, xgb_seed)
  trees <- best_iter(b)
  cat(sprintf("  depth-%d model: %d trees%s\n", pair_depth, trees, if (trees >= max_rounds) " (reached the cap)" else ""))

  vv <- unique(dm$vars); V <- length(vv); p <- ncol(dm$X)
  G <- matrix(0, p, V); G[cbind(seq_len(p), match(dm$vars, vv))] <- 1    # one-hot column -> its variable
  set.seed(xgb_seed + 1); sh <- sample(n, min(n_shap, n))
  A <- array(0, c(length(sh), V, V))                                       # per case: variable x variable
  for (st in seq(1, length(sh), by = shap_batch)) {
    ii <- st:min(st + shap_batch - 1, length(sh)); m <- length(ii)
    a <- predict(b, xgboost::xgb.DMatrix(dm$X[sh[ii], , drop = FALSE]), predinteraction = TRUE)[, 1:p, 1:p, drop = FALSE]
    B <- array(matrix(a, m * p, p) %*% G, c(m, p, V))                      # add up columns (second index)
    C <- array(t(G) %*% matrix(aperm(B, c(2, 1, 3)), p, m * V), c(V, m, V)) # ... and rows (first index)
    A[ii, , ] <- aperm(C, c(2, 1, 3))
    cat(sprintf("  SHAP interactions: %d of %d cases %s\n", max(ii), length(sh), format(Sys.time(), "%H:%M:%S")))
  }
  main_abs <- setNames(vapply(seq_len(V), function(u) mean(abs(A[, u, u])), 1), vv)
  half <- sample(rep_len(1:2, length(sh)))
  pr <- t(combn(V, 2))
  pv <- function(u, w, rows = TRUE) mean(abs(A[rows, u, w] + A[rows, w, u]))
  pt <- data.frame(outcome = o, var1 = vv[pr[, 1]], var2 = vv[pr[, 2]],
                   strength = apply(pr, 1, function(r) pv(r[1], r[2])),
                   s_a = apply(pr, 1, function(r) pv(r[1], r[2], half == 1)),
                   s_b = apply(pr, 1, function(r) pv(r[1], r[2], half == 2)))
  pt <- pt[order(-pt$strength), ]
  pt$rank <- seq_len(nrow(pt)); pt$rank_half_a <- rank(-pt$s_a, ties.method = "min"); pt$rank_half_b <- rank(-pt$s_b, ties.method = "min")
  pt$share_of_all_pairs <- if (sum(pt$strength) > 0) round(pt$strength / sum(pt$strength), 4) else 0
  pt$main_effect_var1 <- round(main_abs[pt$var1], 4); pt$main_effect_var2 <- round(main_abs[pt$var2], 4)
  pt$strength <- round(pt$strength, 4)
  pt <- pt[c("outcome", "rank", "var1", "var2", "strength", "share_of_all_pairs", "rank_half_a", "rank_half_b",
             "main_effect_var1", "main_effect_var2")]
  pair_rows[[o]] <- pt
  summary_rows[[o]] <- data.frame(outcome = o, n_cases = n, n_shap_cases = length(sh), trees = trees,
    hit_cap = trees >= max_rounds, units = if (binary) "log-odds" else "log(1 + days)",
    total_main_effects = round(sum(main_abs), 4), total_pairs = round(sum(pt$strength), 4),
    pair_share = round(sum(pt$strength) / (sum(pt$strength) + sum(main_abs)), 4))
  cat("  Strongest pairs:\n"); print(head(pt[, -1], 10), row.names = FALSE)
  top[[o]] <- head(pt, n_top_pairs)

  # ---- Step 3: what the top pairs look like ----------------------------------------------
  for (r in seq_len(nrow(top[[o]]))) {
    v1 <- top[[o]]$var1[r]; v2 <- top[[o]]$var2[r]
    l1 <- cell_var(od$d, v1); l2 <- cell_var(od$d, v2)
    f <- c("l1", "l2")[c(nlevels(l1), nlevels(l2)) >= 2]                    # a one-level grid side has no effect
    add_fit <- lm.fit(model.matrix(reformulate(if (length(f)) f else "1"), data.frame(l1, l2)), od$y)$fitted.values
    cell <- interaction(l1, l2, drop = TRUE, sep = "\r")
    raw <- data.frame(cell = levels(cell), n_cases = as.vector(table(cell)),
                      mean_outcome = as.vector(tapply(od$y, cell, mean)),
                      departure_from_additive = as.vector(tapply(od$y - add_fit, cell, mean)))
    u1 <- match(v1, vv); u2 <- match(v2, vv)
    sc <- interaction(l1[sh], l2[sh], drop = TRUE, sep = "\r")
    shp <- data.frame(cell = levels(sc), n_shap_cases = as.vector(table(sc)),
                      mean_shap_interaction = as.vector(tapply(A[, u1, u2] + A[, u2, u1], sc, mean)))
    x <- merge(raw, shp, by = "cell", all.x = TRUE)
    x$n_shap_cases[is.na(x$n_shap_cases)] <- 0L
    parts <- do.call(rbind, strsplit(x$cell, "\r", fixed = TRUE))
    shape_rows[[length(shape_rows) + 1]] <- data.frame(outcome = o, pair_rank = r, var1 = v1, level1 = parts[, 1],
      var2 = v2, level2 = parts[, 2], n_cases = x$n_cases, mean_outcome = round(x$mean_outcome, 4),
      departure_from_additive = round(x$departure_from_additive, 4), n_shap_cases = x$n_shap_cases,
      mean_shap_interaction = round(x$mean_shap_interaction, 4), small_cell = x$n_cases < min_cell)
  }

  # ---- Step 4: do they help a regression? ------------------------------------------------
  df <- od$d[vars_all]
  for (v in intersect(vars_all, num_vars)) if (log_counts) df[[v]] <- log1p(df[[v]])
  df[] <- lapply(df, function(x) if (is.factor(x)) droplevels(x) else x)
  df <- df[vapply(df, function(x) !is.factor(x) || nlevels(x) >= 2, TRUE)]
  X0 <- model.matrix(~ ., df)
  term_var <- function(v) if (v %in% num_vars) { x <- if (log_counts) log1p(od$d[[v]]) else od$d[[v]]; x - mean(x) } else lump(od$d[[v]])
  pair_cols <- function(v1, v2) {
    a <- term_var(v1); b <- term_var(v2)
    if ((is.factor(a) && nlevels(a) < 2) || (is.factor(b) && nlevels(b) < 2)) return(matrix(0, length(y), 0))
    mm <- model.matrix(~ a * b, data.frame(a = a, b = b))
    mm <- mm[, grepl(":", colnames(mm), fixed = TRUE), drop = FALSE]
    mm[, colSums(mm != 0) > 0, drop = FALSE]
  }
  y <- od$y; fold <- od$d$fold; ks <- sort(unique(fold))
  XX <- crossprod(X0); Xy <- crossprod(X0, y)
  te <- lapply(ks, function(k) which(fold == k))
  XXk <- lapply(te, function(i) XX - crossprod(X0[i, , drop = FALSE]))     # training part of each fold
  Xyk <- lapply(te, function(i) Xy - crossprod(X0[i, , drop = FALSE], y[i]))
  solve_ls <- function(M, r) { cf <- qr.coef(qr(M, tol = 1e-7), r); cf[is.na(cf)] <- 0; cf }
  ols_cv <- function(Z = NULL) {
    pred <- numeric(length(y))
    if (!is.null(Z) && ncol(Z) == 0) Z <- NULL
    if (!is.null(Z)) { XZ <- crossprod(X0, Z); ZZ <- crossprod(Z); Zy <- crossprod(Z, y) }
    for (j in seq_along(ks)) {
      i <- te[[j]]
      if (is.null(Z)) cf <- solve_ls(XXk[[j]], Xyk[[j]]) else {
        xz <- XZ - crossprod(X0[i, , drop = FALSE], Z[i, , drop = FALSE]); zz <- ZZ - crossprod(Z[i, , drop = FALSE])
        cf <- solve_ls(rbind(cbind(XXk[[j]], xz), cbind(t(xz), zz)), rbind(Xyk[[j]], Zy - crossprod(Z[i, , drop = FALSE], y[i])))
      }
      pred[i] <- if (is.null(Z)) X0[i, , drop = FALSE] %*% cf else cbind(X0[i, , drop = FALSE], Z[i, , drop = FALSE]) %*% cf
    }
    pc <- pmin(pmax(pred, 0), 1)                                          # linear-probability predictions kept in 0-1
    list(all = score(y, pred, binary), per_fold = vapply(te, function(i) score(y[i], pred[i], binary), 1),
         brier_skill = if (binary) 1 - mean((pc - y)^2) / (mean(y) * (1 - mean(y))) else NA)
  }
  metric <- if (binary) "cv_auc" else "cv_r_squared"
  base <- ols_cv()
  reg_row <- function(label, added, res) {
    dlt <- res$per_fold - base$per_fold; se <- sd(dlt, na.rm = TRUE) / sqrt(sum(!is.na(dlt)))   # NA if a fold can't be scored
    data.frame(outcome = o, model = label, columns_added = added, metric = metric, value = round(res$all, 4),
               brier_skill = round(res$brier_skill, 4), gap_vs_additive = round(mean(dlt, na.rm = TRUE), 4), se_across_folds = round(se, 4),
               gap_over_se = if (is.finite(se) && se > 0) round(mean(dlt, na.rm = TRUE) / se, 1) else NA,
               folds_positive = sprintf("%d of %d", sum(dlt > 0, na.rm = TRUE), sum(!is.na(dlt))))
  }
  rows <- list(reg_row("OLS, main effects only (additive)", 0L, base))
  Zs <- lapply(seq_len(nrow(top[[o]])), function(r) pair_cols(top[[o]]$var1[r], top[[o]]$var2[r]))
  for (r in seq_along(Zs)) {
    rows[[length(rows) + 1]] <- reg_row(sprintf("OLS + %s x %s", top[[o]]$var1[r], top[[o]]$var2[r]), ncol(Zs[[r]]), ols_cv(Zs[[r]]))
    cat(sprintf("  regression check: pair %d of %d %s\n", r, length(Zs), format(Sys.time(), "%H:%M:%S")))
  }
  Zall <- do.call(cbind, Zs)
  rows[[length(rows) + 1]] <- reg_row(sprintf("OLS + all %d pairs", length(Zs)), ncol(Zall), ols_cv(Zall))
  step1 <- file.path(model_dir, "interactions_1_depth_check.csv")
  if (file.exists(step1)) {
    s1 <- read.csv(step1); s1 <- s1[s1$outcome == o & s1$set == model_set, ]
    for (k in seq_len(nrow(s1))) rows[[length(rows) + 1]] <- data.frame(outcome = o,
      model = sprintf("for comparison: XGBoost depth %d (07-d)", s1$depth[k]), columns_added = NA, metric = metric,
      value = s1$value[k], brier_skill = s1$brier_skill[k], gap_vs_additive = NA, se_across_folds = NA, gap_over_se = NA, folds_positive = NA)
  }
  reg_rows[[o]] <- do.call(rbind, rows)
  print(reg_rows[[o]][, -1], row.names = FALSE)
  save_outcome(o)
  rm(A, X0, XX, XXk, Zs, Zall); invisible(gc())
}

cat("\nAll outputs saved in", model_dir, "\n")
