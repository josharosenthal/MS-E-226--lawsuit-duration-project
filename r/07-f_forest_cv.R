# =============================================================================
# 07-f_forest_cv.R — the random forests of 07-a / 07-b on the 08 regressions' variables, judged
# by the same 5 folds as XGBoost and the regressions (Josh, 2 Nov 2026; change 98). TRAINING
# CASES ONLY; the holdout is untouched.
#
# Why not out-of-bag (OOB) error, as 07-a / 07-b use: OOB doesn't keep a consolidation group
# together (a case's lead or member cases can be in the trees that predict it), and it can't be
# paired fold by fold with the other models. So each forest is fitted 5 times, each time on 4
# folds, and predicts the 5th - exactly as 07-c and the 08 jobs. A forest on all the cases also
# gives the OOB score on the same cases, so the gap shows how much OOB flatters the forest here.
#   log_duration   regression forest on log(1 + days), cases that ended in court (as 07-a:
#                  500 trees, smallest leaf 5)
#   short_60       probability forest for ended within 60 days (as 07-b: 500 trees, leaf 10)
# Sets reg_run1 / reg_run2: the variables of the 08 models' run 1 / run 2 in model_spec.csv, as
# in 07-c (no logs or interaction terms). Cases and folds from xgb_training_data().
# reg_run3 (change 99): run 3, run 2 without n_counsel (spec_keep() in xgb_helpers.R).
# reg_run4 (change 100): run 3's variables with the post-filing judge labels pooled (recode_run4()).
# Smearing factor for days (log_duration): each fold's mean of exp(residual) over its training
# part, using that forest's OOB predictions (a forest's in-sample residuals are far too small).
# Permutation importance (change 99) from the all-cases forest, as 07-a / 07-b: how much the
# out-of-bag error (squared error; Brier score for short_60) rises when a variable is shuffled.
# Out-of-bag, so a case's related cases can be in its trees; fine for ranking variables. Forest
# SHAP isn't computed (ranger has none; it would need the treeshap package). Forests not saved.
#   Rscript 07-f_forest_cv.R                              both outcomes, both sets
#   Rscript 07-f_forest_cv.R log_duration reg_run2        one outcome and set (comma-separated lists)
# Output: ~/scales_project/models/
#   forest_cv/rf_<outcome>_<set>_cv.rds    each case's cross-validated prediction (and its OOB
#                                          prediction from the all-cases forest), fold, y,
#                                          smearing factors, model_spec.csv MD5; read by 08-y
#   forest_cv_summary_<outcomes>_<sets>.csv  cross-validated vs OOB scores
#   rf_<outcome>_<set>_importance.csv      permutation importance, largest first (change 99)
# Batch job: --cpus-per-task=8 --mem=48G; about 6 forests per outcome and set, a few minutes each.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("ranger", quietly = TRUE))
  stop("The ranger package isn't installed. Run once in R:  install.packages(\"ranger\")")
model_dir <- file.path(project_dir, "models"); cv_dir <- file.path(model_dir, "forest_cv")
dir.create(cv_dir, showWarnings = FALSE, recursive = TRUE)

# ---- Settings (edit these) --------------------------------------------------------
outcomes   <- c("log_duration", "short_60")
model_sets <- c("reg_run1", "reg_run2")
num_trees  <- 500
min_node   <- c(log_duration = 5, short_60 = 10)   # as 07-a and 07-b
n_folds    <- 5                                    # as 07-c and 08
rf_seed    <- 226
n_threads  <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))
args <- commandArgs(TRUE)
if (length(args) >= 1) outcomes   <- strsplit(args[1], ",")[[1]]
if (length(args) >= 2) model_sets <- strsplit(args[2], ",")[[1]]

# ---- Variables (as 07-c's reg_run sets) and training data ------------------------------
source(file.path(r_dir, "covariate_sets.R"))       # num_vars
source(file.path(r_dir, "xgb_helpers.R"))          # spec_keep(), xgb_training_data(), outcome_data(), auc()
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
d_all <- xgb_training_data(list(all_vars), n_folds, rf_seed)

score <- function(outcome, y, p, base) {
  if (outcome == "log_duration") c(r_squared = 1 - sum((y - p)^2) / sum((y - base)^2), rmse_log = sqrt(mean((y - p)^2)),
                                   median_abs_error_days = median(abs(expm1(y) - expm1(p))))
  else c(auc = auc(p, y == 1), brier_skill = 1 - mean((p - y)^2) / mean((base - y)^2))
}

# ---- One outcome and set ---------------------------------------------------------------
fit_one <- function(outcome, set_name) {
  od <- outcome_data(d_all, outcome); d <- od$d; y <- od$y
  if (set_name == "reg_run4") d <- recode_run4(d)
  vars <- spec_vars(set_name, outcome); reg <- outcome == "log_duration"
  forest <- function(rows, write, importance = "none") {
    ranger::ranger(x = d[rows, vars, drop = FALSE],
                   y = if (reg) y[rows] else factor(y[rows], levels = c(0, 1), labels = c("no", "short")),
                   probability = !reg, num.trees = num_trees, min.node.size = min_node[[outcome]],
                   respect.unordered.factors = "order", num.threads = n_threads, seed = rf_seed,
                   write.forest = write, importance = importance, verbose = FALSE)
  }
  oob <- function(fit) if (reg) fit$predictions else fit$predictions[, "short"]
  cat(sprintf("\n%s, %s: %s cases, %d variables. %s\n", outcome, set_name, format(nrow(d), big.mark = ","),
              length(vars), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time(); pred <- rep(NA_real_, length(y)); K <- sort(unique(d$fold)); smear <- numeric(0)
  for (k in K) {
    tr <- which(d$fold != k); te <- which(d$fold == k)
    fit <- forest(tr, TRUE)
    p <- predict(fit, data = d[te, vars, drop = FALSE], num.threads = n_threads)$predictions
    pred[te] <- if (reg) p else p[, "short"]
    if (reg) { o <- oob(fit); ok <- !is.na(o); smear <- c(smear, mean(exp(y[tr][ok] - o[ok]))) }
    rm(fit); gc(verbose = FALSE)
    cat(sprintf("  fold %d done %s\n", k, format(Sys.time(), "%H:%M:%S")))
  }
  full <- forest(seq_along(y), FALSE, "permutation"); oob_pred <- oob(full)
  imp <- sort(full$variable.importance, decreasing = TRUE); rm(full); gc(verbose = FALSE)
  write.csv(data.frame(variable = names(imp), permutation_importance = signif(imp, 4),
                       n_categories = vapply(names(imp), function(v) if (is.factor(d[[v]])) nlevels(droplevels(d[[v]])) else NA_integer_, 1L),
                       row.names = NULL),
            file.path(model_dir, sprintf("rf_%s_%s_importance.csv", outcome, set_name)), row.names = FALSE)
  saveRDS(list(model = "forest", outcome = outcome, set = set_name, vars = vars,
               pred = data.frame(row = seq_along(y), fold = d$fold, y = y, pred = pred, oob_pred = oob_pred),
               smear = if (reg) setNames(smear, K) else NULL, spec_md5 = unname(tools::md5sum(spec_file))),
          file.path(cv_dir, sprintf("rf_%s_%s_cv.rds", outcome, set_name)))
  base_cv <- vapply(K, function(k) mean(y[d$fold != k]), 1)[match(d$fold, K)]   # each fold's training mean
  ok <- !is.na(oob_pred)
  cv <- score(outcome, y, pred, base_cv); ob <- score(outcome, y[ok], oob_pred[ok], mean(y))
  out <- data.frame(outcome = outcome, set = set_name, n_cases = length(y), n_variables = length(vars),
                    metric = names(cv), cross_validated = round(cv, 5), out_of_bag = round(ob, 5),
                    oob_minus_cv = round(ob - cv, 5),
                    minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), row.names = NULL)
  print(out, row.names = FALSE); out
}
res <- do.call(rbind, lapply(outcomes, function(o) do.call(rbind, lapply(model_sets, function(s) fit_one(o, s)))))
f <- file.path(model_dir, sprintf("forest_cv_summary_%s_%s.csv", paste(outcomes, collapse = "-"), paste(model_sets, collapse = "-")))
write.csv(res, f, row.names = FALSE)
cat("\nForests, cross-validated on the shared folds vs out-of-bag (training cases only; the holdout is untouched):\n")
print(res, row.names = FALSE)
cat("oob_minus_cv > 0 (R-squared, AUC, Brier skill) means OOB makes the forest look better than the folds do.\n")
cat("Saved", f, "and", cv_dir, "\n")
