# =============================================================================
# 07-g_decision_tree.R — a single decision tree (CART, the rpart package, which comes with R) on
# the 08 regressions' variables, judged by the same 5 folds as the regressions, XGBoost and the
# forest (Josh, 6 Nov 2026; change 106). TRAINING CASES ONLY; the holdout is untouched.
#   log_duration   regression tree on log(1 + days), cases that ended in court
#   short_60       tree on ended within 60 days (0/1), fitted as a regression tree, so each
#                  leaf predicts the SHARE of short cases (a probability) and splits and pruning
#                  minimize squared error (the Brier score). rpart's "class" method would prune
#                  on misclassification, which is a poor guide for probabilities.
# Sets reg_run1 / reg_run4 by default (any of reg_run1 ... reg_run4): the variables of that run
# in model_spec.csv, as 07-c and 07-f (no logs or interaction terms - a tree finds its own
# interactions); reg_run4 with the post-filing judge labels pooled (recode_run4()).
# Tuning, inside each outer fold (nothing is chosen on the fold being scored):
#   1. grow a large tree on the other 4 folds (cp = cp_min, leaves of at least min_leaf cases)
#   2. rpart's built-in cross-validation, on the INNER folds of xgb_training_data() (seed 227,
#      consolidation groups kept together, as the 08 penalty tuning), gives the error at each
#      complexity cp
#   3. prune at the cp with the smallest inner cross-validated error (as lambda.min in 08-b),
#      and predict the outer fold
#   If the chosen cp is cp_min (the smallest tried), a larger tree might do better: the summary
#   flags it (at_smallest_cp).
# A tree on all the cases, tuned the same way on the outer folds, is saved for interpretation,
# with rpart's variable importance (from the primary splits only; competitor and surrogate
# splits are turned off for speed - no NAs to route, as missing is its own category "(NA)").
# Plus a picture of its top (depth 3): factor splits with more than 3 levels going left, and every
# judge_group split, are shown as "k of n levels", so the picture carries no judge names.
# Smearing factor for days (log_duration): each fold's mean of exp(residual) over its training
# part, as the 08 OLS.
#   Rscript 07-g_decision_tree.R                              both outcomes, runs 1 and 4
#   Rscript 07-g_decision_tree.R log_duration reg_run4        one outcome and set (comma-separated lists)
# Output: ~/scales_project/models/
#   tree_cv/tree_<outcome>_<set>_cv.rds    each case's cross-validated prediction, fold, y,
#                                          smearing factors, model_spec.csv MD5; read by 08-y
#   tree_cv/tree_<outcome>_<set>_full.rds  the all-cases tree (rpart object; holds judge-level values)
#   tree_cv_summary_<outcomes>_<sets>.csv  per fold: chosen cp, leaves; and the cross-validated scores
#   tree_<outcome>_<set>_importance.csv    variable importance of the all-cases tree, largest first
#   ~/scales_project/plots/tree_<outcome>_<set>_top.png   the all-cases tree's first 3 levels
# Batch job: --cpus-per-task=1 --mem=16G --time=04:00:00 (rpart uses one CPU). A fake set of the real
# size (260,000 cases, a 3,000-level judge variable) took about 10 seconds per tuned tree; 24 tuned trees here.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("rpart", quietly = TRUE)) stop("The rpart package isn't available (it normally comes with R).")
model_dir <- file.path(project_dir, "models"); cv_dir <- file.path(model_dir, "tree_cv")
plot_dir <- file.path(project_dir, "plots")
dir.create(cv_dir, showWarnings = FALSE, recursive = TRUE); dir.create(plot_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes   <- c("log_duration", "short_60")
model_sets <- c("reg_run1", "reg_run4")
cp_min     <- 1e-4        # smallest complexity tried (grow this far, then prune back)
min_leaf   <- 20          # fewest cases in a leaf
plot_depth <- 3           # levels shown in the picture
n_folds    <- 5           # as 07-c, 07-f and 08
tree_seed  <- 226         # outer folds, as everywhere
inner_seed <- 227         # inner folds, as the 08 penalty tuning
args <- commandArgs(TRUE)
if (length(args) >= 1) outcomes   <- strsplit(args[1], ",")[[1]]
if (length(args) >= 2) model_sets <- strsplit(args[2], ",")[[1]]

# ---- Variables (as 07-c / 07-f's reg_run sets) and training data ----------------------
source(file.path(r_dir, "covariate_sets.R"))       # num_vars
source(file.path(r_dir, "xgb_helpers.R"))          # spec_keep(), recode_run4(), xgb_training_data(), outcome_data(), auc()
have <- dbListFields(con, "train_fjc")
spec_file <- file.path(r_dir, "model_spec.csv")
spec_vars <- function(set_name, outcome) {
  sp <- read.csv(spec_file, stringsAsFactors = FALSE)
  col <- if (outcome == "log_duration") "duration_ols" else "short_case"
  keep <- spec_keep(sp, col, as.integer(sub("reg_run", "", set_name)))
  v <- sp$term[keep & sp$type != "interaction"]
  miss <- setdiff(v, have); if (length(miss)) stop("Not in train_fjc: ", paste(miss, collapse = ", "))
  v
}
all_vars <- unique(unlist(lapply(model_sets, function(s) lapply(outcomes, function(o) spec_vars(s, o)))))
d_all <- xgb_training_data(list(all_vars), n_folds, tree_seed, inner_seed = inner_seed)

# grow on `rows`, cross-validate on the groups `xgroups` (one per row), prune at the smallest error
tuned_tree <- function(d, y, vars, rows, xgroups) {
  dd <- d[rows, vars, drop = FALSE]; dd$.y <- y[rows]
  fit <- rpart::rpart(.y ~ ., data = dd, method = "anova", model = FALSE, x = FALSE, y = FALSE,
                      control = rpart::rpart.control(cp = cp_min, minbucket = min_leaf, minsplit = 2 * min_leaf,
                                                     xval = xgroups, maxcompete = 0, maxsurrogate = 0))
  ct <- fit$cptable; best <- which.min(ct[, "xerror"])
  list(fit = rpart::prune(fit, cp = ct[best, "CP"]), cp = ct[best, "CP"], leaves = ct[best, "nsplit"] + 1,
       at_smallest = best == nrow(ct))
}

score <- function(outcome, y, p, base) {
  if (outcome == "log_duration") c(r_squared = 1 - sum((y - p)^2) / sum((y - base)^2), rmse_log = sqrt(mean((y - p)^2)),
                                   median_abs_error_days = median(abs(expm1(y) - expm1(p))))
  else c(auc = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / mean((base - y)^2))
}

# text for the split at each internal node (the condition for going LEFT); no judge names
split_text <- function(fit) {
  ff <- fit$frame; internal <- ff$var != "<leaf>"
  index <- cumsum(c(1, ff$ncompete + ff$nsurrogate + internal))
  irow <- index[c(internal, FALSE)]
  xlev <- attr(fit, "xlevels"); out <- character(nrow(ff)); vars <- as.character(ff$var[internal])
  out[internal] <- vapply(seq_along(irow), function(i) {
    v <- vars[i]; s <- fit$splits[irow[i], , drop = FALSE]; ncat <- s[, "ncat"]
    if (abs(ncat) == 1) return(sprintf("%s %s %s", v, if (ncat < 0) "<" else ">=", format(signif(s[, "index"], 3))))
    cs <- fit$csplit[s[, "index"], seq_along(xlev[[v]])]
    left <- xlev[[v]][cs == 1]; present <- sum(cs != 2)
    if (v == "judge_group" || length(left) > 3) sprintf("%s: %d of %d levels", v, length(left), present)
    else paste0(v, ": ", paste(substr(left, 1, 28), collapse = " / "))
  }, "")
  out
}
plot_top <- function(fit, outcome, set_name, n) {
  nodes <- as.integer(rownames(fit$frame))
  toss <- nodes[floor(log2(nodes)) == plot_depth & fit$frame$var != "<leaf>"]   # cut below depth plot_depth
  small <- if (length(toss)) rpart::snip.rpart(fit, toss = toss) else fit
  ff <- small$frame; lab <- split_text(small); leaf <- ff$var == "<leaf>"
  f <- file.path(plot_dir, sprintf("tree_%s_%s_top.png", outcome, set_name))
  png(f, width = 1800, height = 900, res = 110); par(mar = c(1, 1, 4, 1), xpd = NA)
  xy <- plot(small, uniform = TRUE, margin = 0.06, branch = 0.4)
  text(xy$x[!leaf], xy$y[!leaf], lab[!leaf], pos = 3, cex = 0.72, offset = 0.7)
  val <- if (outcome == "log_duration") sprintf("%s days", format(round(expm1(ff$yval)), big.mark = ","))
         else sprintf("%.0f%% short", 100 * ff$yval)
  text(xy$x[leaf], xy$y[leaf], sprintf("%s\nn = %s", val[leaf], trimws(format(ff$n[leaf], big.mark = ","))), pos = 1, cex = 0.68, offset = 0.5)
  title(sprintf("Decision tree, %s, %s: first %d levels of the tuned tree (%s leaves in all)", outcome, set_name, plot_depth,
                format(n, big.mark = ",")), cex.main = 1)
  mtext(sprintf("Left branch = the condition shown. Leaves: %s and cases. Training cases only.",
                if (outcome == "log_duration") "exp(mean log(1 + days)) - 1" else "share ending within 60 days"),
        side = 3, line = 0.3, cex = 0.75, col = "grey30")
  dev.off(); f
}

# ---- One outcome and set ---------------------------------------------------------------
fit_one <- function(outcome, set_name) {
  od <- outcome_data(d_all, outcome); d <- od$d; y <- od$y
  if (set_name == "reg_run4") d <- recode_run4(d)
  vars <- spec_vars(set_name, outcome); reg <- outcome == "log_duration"
  cat(sprintf("\n%s, %s: %s cases, %d variables. %s\n", outcome, set_name, format(nrow(d), big.mark = ","),
              length(vars), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time(); pred <- rep(NA_real_, length(y)); K <- sort(unique(d$fold)); smear <- numeric(0); per_fold <- list()
  for (k in K) {
    tr <- which(d$fold != k); te <- which(d$fold == k)
    tt <- tuned_tree(d, y, vars, tr, d$fold_inner[tr])
    pred[te] <- predict(tt$fit, newdata = d[te, vars, drop = FALSE])
    if (reg) smear <- c(smear, mean(exp(y[tr] - predict(tt$fit, newdata = d[tr, vars, drop = FALSE]))))
    per_fold[[k]] <- data.frame(fold = k, cp = signif(tt$cp, 3), leaves = tt$leaves, at_smallest_cp = tt$at_smallest)
    cat(sprintf("  fold %d: cp %.2g, %d leaves%s  %s\n", k, tt$cp, tt$leaves,
                if (tt$at_smallest) " (smallest cp tried)" else "", format(Sys.time(), "%H:%M:%S")))
    rm(tt); gc(verbose = FALSE)
  }
  full <- tuned_tree(d, y, vars, seq_along(y), d$fold)
  cat(sprintf("  all cases: cp %.2g, %d leaves%s\n", full$cp, full$leaves, if (full$at_smallest) " (smallest cp tried)" else ""))
  imp <- full$fit$variable.importance; imp <- if (is.null(imp)) numeric(0) else sort(imp, decreasing = TRUE)
  write.csv(data.frame(variable = names(imp), importance = signif(imp, 4), share = round(imp / sum(imp), 4), row.names = NULL),
            file.path(model_dir, sprintf("tree_%s_%s_importance.csv", outcome, set_name)), row.names = FALSE)
  saveRDS(full$fit, file.path(cv_dir, sprintf("tree_%s_%s_full.rds", outcome, set_name)))
  pf <- if (full$leaves > 1) plot_top(full$fit, outcome, set_name, full$leaves) else "(no plot: the tree has no splits)"
  saveRDS(list(model = "tree", outcome = outcome, set = set_name, vars = vars,
               pred = data.frame(row = seq_along(y), fold = d$fold, y = y, pred = pred),
               smear = if (reg) setNames(smear, K) else NULL, spec_md5 = unname(tools::md5sum(spec_file))),
          file.path(cv_dir, sprintf("tree_%s_%s_cv.rds", outcome, set_name)))
  base_cv <- vapply(K, function(k) mean(y[d$fold != k]), 1)[match(d$fold, K)]   # each fold's training mean
  cv <- score(outcome, y, pred, base_cv)
  pf_df <- do.call(rbind, per_fold)
  out <- data.frame(outcome = outcome, set = set_name, n_cases = length(y), n_variables = length(vars),
                    metric = names(cv), cross_validated = round(cv, 5),
                    cp_by_fold = paste(pf_df$cp, collapse = " / "), leaves_by_fold = paste(pf_df$leaves, collapse = " / "),
                    any_at_smallest_cp = any(pf_df$at_smallest_cp), full_tree_cp = signif(full$cp, 3), full_tree_leaves = full$leaves,
                    minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), row.names = NULL)
  print(out, row.names = FALSE); cat("  plot:", pf, "\n"); out
}
res <- do.call(rbind, lapply(outcomes, function(o) do.call(rbind, lapply(model_sets, function(s) fit_one(o, s)))))
f <- file.path(model_dir, sprintf("tree_cv_summary_%s_%s.csv", paste(outcomes, collapse = "-"), paste(model_sets, collapse = "-")))
write.csv(res, f, row.names = FALSE)
cat("\nDecision trees, cross-validated on the shared folds (training cases only; the holdout is untouched):\n")
print(res, row.names = FALSE)
cat("any_at_smallest_cp TRUE: the inner folds wanted the biggest tree tried; lower cp_min to check.\n")
cat("Saved", f, "and", cv_dir, "\n")
