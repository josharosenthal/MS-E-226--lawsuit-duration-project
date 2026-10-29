# =============================================================================
# 07-a_random_forest.R — random forests for case duration, TRAINING CASES ONLY.
#
# Fits a random forest (ranger package) for each covariate set:
#   main         covariates known at, or close to, filing (DATA_DICTIONARY.md "main")
#   main_plus_counsel  main + n_counsel. n_counsel is out of main (too leaky; change 70), so
#                the gap shows what it would add
#   sensitivity  main + the leaky ones kept out of the main model (EXPLAINER 7B)
# The sets are defined in r/covariate_sets.R, shared with 06, 07-b and 07-c.
# The gain from main to sensitivity is an UPPER BOUND on what those variables add,
# since part of it is leakage.
#
# Two kinds of forest (rf_outcome below):
#   "log_duration"  regression on log(1 + days), cases that ENDED in court only.
#                   Simple and fast, but it leaves out cases transferred out (censored).
#   "survival"      random survival forest on (days, ended), so transferred-out cases
#                   count as censored, like the Kaplan-Meier curves. Slower and more
#                   memory-hungry: try rf_sample_n = 50000 first.
#
# How it's judged: OUT-OF-BAG (OOB) error. Each tree is grown on a bootstrap sample of the
# training cases, so the cases it didn't see act as a built-in validation set - no data
# beyond training is touched. The HOLDOUT stays unused until the final evaluation.
#   log_duration: OOB R-squared and RMSE on log(1 + days); median absolute error in days
#   survival:     OOB C-index (0.5 = coin flip, 1 = perfect ordering of who ends first)
# Variable importance: permutation importance (how much OOB error rises when a variable's
# values are shuffled). Many-category variables (court, cause_group, judge_group) can look
# more important than they are, so read importance alongside the 05/06 outputs.
#
# Output: ~/scales_project/models/
#   rf_<outcome>_summary.csv           OOB performance for each covariate set
#   rf_<outcome>_<set>_importance.csv  permutation importance, largest first
#   rf_<outcome>_importance.png        importance plot, main and sensitivity side by side
#   rf_<outcome>_<set>.rds             the fitted forest (only if save_models = TRUE; large)
#
# Needs the ranger package. If it's missing, run once in R:  install.packages("ranger")
# Run it as a batch job for the full training set (see EXPLAINER, section 5), e.g. with
# --cpus-per-task=8 --mem=32G; ranger uses all the CPUs Slurm gives it.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("ranger", quietly = TRUE))
  stop("The ranger package isn't installed. Run once in R:  install.packages(\"ranger\")")
model_dir <- file.path(project_dir, "models"); dir.create(model_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
rf_outcome   <- "log_duration"     # "log_duration" or "survival"
model_sets   <- c("main", "main_plus_counsel", "sensitivity")
num_trees    <- 500
rf_sample_n  <- NA                 # NA = all training cases; e.g. 50000 for a quick run
min_node     <- 5                  # smallest number of cases in a leaf
save_models  <- FALSE              # TRUE saves each fitted forest as .rds (can be several GB)
rf_seed      <- 226
n_threads    <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))

# ---- Covariate sets (r/covariate_sets.R) -------------------------------------------
source(file.path(r_dir, "covariate_sets.R"))
sets <- make_sets(dbListFields(con, "train_fjc"), model_sets)

# ---- Training data ------------------------------------------------------------------
cat("Reading training cases...\n")
where <- if (rf_outcome == "log_duration") "event_observed" else "event_observed IS NOT NULL"
d <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                              WHERE duration_capped_days IS NOT NULL AND %s",
                             paste(unique(unlist(sets)), collapse = ", "), where))
if (!is.na(rf_sample_n) && rf_sample_n < nrow(d)) { set.seed(rf_seed); d <- d[sample.int(nrow(d), rf_sample_n), ] }
for (v in setdiff(unique(unlist(sets)), num_vars)) d[[v]] <- factor(ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]])))
for (v in intersect(num_vars, names(d))) d[[v]][is.na(d[[v]])] <- 0
d$y_log <- log1p(d$duration_capped_days)
d$ended <- d$event_observed %in% TRUE
cat(sprintf("%s training cases (%s), %s threads, %s trees.\n", format(nrow(d), big.mark = ","),
            if (rf_outcome == "log_duration") "ended in court" else sprintf("%.1f%% ended in court, rest censored", 100 * mean(d$ended)),
            n_threads, num_trees))

# ---- Fit one forest per covariate set ---------------------------------------------------
fit_one <- function(set_name) {
  vars <- sets[[set_name]]
  cat(sprintf("\nFitting the %s forest (%d covariates)... %s\n", set_name, length(vars), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time()
  args <- list(num.trees = num_trees, min.node.size = min_node, importance = "permutation",
               respect.unordered.factors = "order", num.threads = n_threads, seed = rf_seed,
               write.forest = save_models, verbose = FALSE)
  if (rf_outcome == "log_duration") {
    fit <- do.call(ranger::ranger, c(list(x = d[vars], y = d$y_log), args))
    pred_days <- expm1(fit$predictions)
    perf <- data.frame(set = set_name, n_cases = nrow(d), n_covariates = length(vars),
                       oob_r_squared = round(fit$r.squared, 4), oob_rmse_log = round(sqrt(fit$prediction.error), 4),
                       oob_median_abs_error_days = round(median(abs(pred_days - d$duration_capped_days)), 1),
                       minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1))
  } else {
    fit <- do.call(ranger::ranger, c(list(x = d[vars], y = survival::Surv(d$duration_capped_days, d$ended),
                                          splitrule = "logrank"), args))
    perf <- data.frame(set = set_name, n_cases = nrow(d), n_covariates = length(vars),
                       pct_censored = round(100 * mean(!d$ended), 1),
                       oob_c_index = round(1 - fit$prediction.error, 4),
                       minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1))
  }
  imp <- sort(fit$variable.importance, decreasing = TRUE)
  imp_tab <- data.frame(variable = names(imp), permutation_importance = signif(imp, 4),
                        n_categories = vapply(names(imp), function(v) if (is.factor(d[[v]])) nlevels(d[[v]]) else NA_integer_, 1L),
                        in_main = names(imp) %in% main_vars, row.names = NULL)
  write.csv(imp_tab, file.path(model_dir, sprintf("rf_%s_%s_importance.csv", rf_outcome, set_name)), row.names = FALSE)
  if (save_models) saveRDS(fit, file.path(model_dir, sprintf("rf_%s_%s.rds", rf_outcome, set_name)))
  print(perf, row.names = FALSE)
  list(perf = perf, imp = imp_tab)
}
res <- lapply(names(sets), fit_one); names(res) <- names(sets)
summary_tab <- do.call(rbind, lapply(res, `[[`, "perf"))
write.csv(summary_tab, file.path(model_dir, sprintf("rf_%s_summary.csv", rf_outcome)), row.names = FALSE)

# ---- Importance plot ------------------------------------------------------------------
png(file.path(model_dir, sprintf("rf_%s_importance.png", rf_outcome)), width = 650 * length(res), height = 900, res = 110)
par(mfrow = c(1, length(res)), mar = c(4, 13, 3, 1))
for (s in names(res)) {
  x <- head(res[[s]]$imp, 25); x <- x[rev(seq_len(nrow(x))), ]
  barplot(x$permutation_importance, horiz = TRUE, names.arg = x$variable, las = 1, cex.names = 0.7,
          col = ifelse(x$in_main, "grey45", "firebrick"), xlab = "permutation importance (rise in OOB error)",
          main = sprintf("%s forest (%s)", s, rf_outcome))
}
legend("bottomright", c("main covariate", "sensitivity only (leaky)"), fill = c("grey45", "firebrick"), bty = "n", cex = 0.8)
dev.off()

# ---- Headline ------------------------------------------------------------------------------
cat("\nOut-of-bag performance (training cases only; the holdout is untouched):\n"); print(summary_tab, row.names = FALSE)
if (all(c("main", "sensitivity") %in% names(res))) {
  m <- if (rf_outcome == "log_duration") "oob_r_squared" else "oob_c_index"
  cat(sprintf("\nSensitivity minus main (%s): %+.4f. If positive, that's an UPPER BOUND on what the leaky variables add (part of it is leakage).\n",
              m, summary_tab[summary_tab$set == "sensitivity", m] - summary_tab[summary_tab$set == "main", m]))
}
if (all(c("main", "main_plus_counsel") %in% names(res))) {
  m <- if (rf_outcome == "log_duration") "oob_r_squared" else "oob_c_index"
  cat(sprintf("main_plus_counsel minus main (%s): %+.4f - what n_counsel would add (part of it leakage).\n",
              m, summary_tab[summary_tab$set == "main_plus_counsel", m] - summary_tab[summary_tab$set == "main", m]))
}
for (s in intersect(c("main", "main_plus_counsel"), names(res))) { cat(sprintf("\nTop 10 variables in the %s forest:\n", s)); print(head(res[[s]]$imp, 10), row.names = FALSE) }
cat("\nAll outputs saved in", model_dir, "\n")
