# =============================================================================
# 07-b_short_case_forest.R — classification ("logistic") random forests for whether a
# case is SHORT, TRAINING CASES ONLY (Josh, 28 Oct 2026).
#
# Two yes/no outcomes, one forest each (short_cutoffs below):
#   ended within 60 days?     ended within 120 days?
# ranger probability forests (probability = TRUE): each tree votes, and the forest gives
# the probability that a case is short. Every tree's splits are chosen to separate short
# cases from the rest, so this targets the quick end directly (unlike 07-a, whose splits
# are chosen for the mean of log duration).
#
# Which cases (all training cases with a duration):
#   ended in court            short = duration <= cutoff
#   transferred out (censored) at day t:
#     t >  cutoff  -> known NOT short (it was still open at the cutoff): kept, short = no
#     t <= cutoff  -> unknown (it left before the cutoff): DROPPED for that cutoff
#   (remands count as endings, as everywhere else - see 02-f_data_checks_endings.R)
#
# Same covariate sets as 07-a (r/covariate_sets.R): main, main_plus_counsel, sensitivity. Judged OUT-OF-BAG:
#   oob_auc           chance a random short case gets a higher probability than a random
#                     other case (0.5 = coin flip, 1 = perfect)
#   oob_brier         mean squared error of the probabilities (lower is better)
#   brier_skill       1 - brier / brier of predicting the overall share for everyone
#                     (0 = no better than ignoring the covariates)
# Variable importance: permutation importance (rise in OOB Brier score when a variable is
# shuffled). Many-category variables (court, cause_group, judge_group) can look more
# important than they are. The HOLDOUT stays unused.
#
# Output: ~/scales_project/models/
#   short_summary.csv                       OOB performance for each cutoff and set
#   short_<cutoff>d_<set>_importance.csv    permutation importance, largest first
#   short_<cutoff>d_importance.png          importance plot, sets side by side
#   short_<cutoff>d_by_band.csv             (120 only) AUC of 0-60 vs over 120, 61-120 vs over 120,
#                                           and 0-60 vs 61-120; the first two average to the overall AUC
#
# Needs the ranger package (as 07-a). Run as a batch job with --cpus-per-task=8 --mem=32G.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
if (!requireNamespace("ranger", quietly = TRUE))
  stop("The ranger package isn't installed. Run once in R:  install.packages(\"ranger\")")
model_dir <- file.path(project_dir, "models"); dir.create(model_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
short_cutoffs <- c(60, 120)        # days: one yes/no outcome (and forest) for each
model_sets    <- c("main", "main_plus_counsel", "sensitivity")
num_trees     <- 500
min_node      <- 10                # smallest number of cases in a leaf (probability forests)
rf_seed       <- 226
n_threads     <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))

# ---- Covariate sets (r/covariate_sets.R, same as 07-a) ----------------------------
source(file.path(r_dir, "covariate_sets.R"))
sets <- make_sets(dbListFields(con, "train_fjc"), model_sets)

# ---- Training data ------------------------------------------------------------------
cat("Reading training cases...\n")
d_all <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                                  WHERE duration_capped_days IS NOT NULL AND event_observed IS NOT NULL",
                                 paste(unique(unlist(sets)), collapse = ", ")))
for (v in setdiff(unique(unlist(sets)), num_vars)) d_all[[v]] <- factor(ifelse(is.na(d_all[[v]]), "(NA)", as.character(d_all[[v]])))
for (v in intersect(num_vars, names(d_all))) d_all[[v]][is.na(d_all[[v]])] <- 0

auc <- function(p, y) {                       # Mann-Whitney form of the area under the ROC curve
  r <- rank(p); n1 <- as.numeric(sum(y)); n0 <- as.numeric(length(y)) - n1   # numeric: n1 * n0 overflows R's integers on the full data
  if (n1 == 0 || n0 == 0) return(NA_real_)
  (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

# ---- Fit one forest per cutoff and covariate set ---------------------------------------------
fit_one <- function(cutoff, set_name) {
  keep <- d_all$event_observed | d_all$duration_capped_days > cutoff   # drop cases transferred out before the cutoff
  d <- d_all[keep, ]
  y <- d$duration_capped_days <= cutoff                                 # TRUE only for cases that ENDED by the cutoff
  vars <- sets[[set_name]]
  cat(sprintf("\nWithin %d days: %s cases (%s transferred out before the cutoff dropped), %.1f%% short. Fitting the %s forest (%d covariates)... %s\n",
              cutoff, format(nrow(d), big.mark = ","), format(sum(!keep), big.mark = ","), 100 * mean(y),
              set_name, length(vars), format(Sys.time(), "%H:%M:%S")))
  t0 <- Sys.time()
  fit <- ranger::ranger(x = d[vars], y = factor(y, levels = c(FALSE, TRUE), labels = c("no", "short")),
                        probability = TRUE, num.trees = num_trees, min.node.size = min_node,
                        importance = "permutation", respect.unordered.factors = "order",
                        num.threads = n_threads, seed = rf_seed, write.forest = FALSE, verbose = FALSE)
  p <- fit$predictions[, "short"]
  ok <- !is.na(p)                                                       # (a case in every tree's sample has no OOB prediction)
  brier <- mean((p[ok] - y[ok])^2); null <- mean(y) * (1 - mean(y))
  perf <- data.frame(cutoff_days = cutoff, set = set_name, n_cases = nrow(d), n_dropped_transferred = sum(!keep),
                     pct_short = round(100 * mean(y), 2), n_covariates = length(vars),
                     oob_auc = round(auc(p[ok], y[ok]), 4), oob_brier = round(brier, 5),
                     brier_skill = round(1 - brier / null, 4),
                     minutes = round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1))
  imp <- sort(fit$variable.importance, decreasing = TRUE)
  imp_tab <- data.frame(variable = names(imp), permutation_importance = signif(imp, 4),
                        n_categories = vapply(names(imp), function(v) if (is.factor(d[[v]])) nlevels(d[[v]]) else NA_integer_, 1L),
                        in_main = names(imp) %in% main_vars, row.names = NULL)
  write.csv(imp_tab, file.path(model_dir, sprintf("short_%dd_%s_importance.csv", cutoff, set_name)), row.names = FALSE)
  print(perf, row.names = FALSE)
  list(perf = perf, imp = imp_tab, bands = band_auc(cutoff, set_name, d$duration_capped_days[ok], p[ok], y[ok]))
}

# ---- AUC by duration band (Josh, 28 Oct 2026) -------------------------------------------------
# For a cutoff with smaller cutoffs below it (120 with 60), the short cases split into bands
# (0-60 days, 61-120 days). The overall AUC is exactly the weighted average of each band vs the
# not-short cases, weighted by the band's share of the short cases. Also: each band vs the next
# band up (the shorter band counts as "short" there). Counts only, no case identifiers.
band_auc <- function(cutoff, set_name, dur, p, y) {
  lower <- sort(short_cutoffs[short_cutoffs < cutoff])
  if (!length(lower)) return(NULL)
  labels <- sprintf("%d-%d days", c(0, lower + 1), c(lower, cutoff))
  over <- sprintf("over %d days", cutoff)
  band <- ifelse(y, as.character(cut(dur, c(-Inf, lower, cutoff), labels = labels)), over)
  pair <- function(a, b, w) {
    s <- band %in% c(a, b)
    data.frame(cutoff_days = cutoff, set = set_name, comparison = paste(a, "vs", b),
               n_first = sum(band == a), n_second = sum(band == b), weight_in_overall_auc = w,
               oob_auc = round(auc(p[s], band[s] == a), 4))
  }
  rbind(do.call(rbind, lapply(labels, function(a) pair(a, over, round(sum(band == a) / sum(y), 4)))),
        do.call(rbind, lapply(seq_along(labels)[-1], function(i) pair(labels[i - 1], labels[i], NA))))
}
res <- list()
for (cutoff in short_cutoffs) for (s in names(sets)) res[[sprintf("%dd_%s", cutoff, s)]] <- fit_one(cutoff, s)
summary_tab <- do.call(rbind, lapply(res, `[[`, "perf")); rownames(summary_tab) <- NULL
write.csv(summary_tab, file.path(model_dir, "short_summary.csv"), row.names = FALSE)
band_tab <- do.call(rbind, lapply(res, `[[`, "bands"))
if (!is.null(band_tab)) {
  rownames(band_tab) <- NULL
  for (cutoff in unique(band_tab$cutoff_days))
    write.csv(band_tab[band_tab$cutoff_days == cutoff, ], file.path(model_dir, sprintf("short_%dd_by_band.csv", cutoff)), row.names = FALSE)
}

# ---- Importance plots, one per cutoff -------------------------------------------------------------
for (cutoff in short_cutoffs) {
  png(file.path(model_dir, sprintf("short_%dd_importance.png", cutoff)), width = 650 * length(sets), height = 900, res = 110)
  par(mfrow = c(1, length(sets)), mar = c(4, 13, 3, 1))
  for (s in names(sets)) {
    x <- head(res[[sprintf("%dd_%s", cutoff, s)]]$imp, 25); x <- x[rev(seq_len(nrow(x))), ]
    barplot(x$permutation_importance, horiz = TRUE, names.arg = x$variable, las = 1, cex.names = 0.7,
            col = ifelse(x$in_main, "grey45", "firebrick"), xlab = "permutation importance (rise in OOB Brier score)",
            main = sprintf("%s: ended within %d days?", s, cutoff))
  }
  legend("bottomright", c("main covariate", "sensitivity only (leaky)"), fill = c("grey45", "firebrick"), bty = "n", cex = 0.8)
  dev.off()
}

# ---- Headline ------------------------------------------------------------------------------
cat("\nOut-of-bag performance (training cases only; the holdout is untouched):\n"); print(summary_tab, row.names = FALSE)
for (cutoff in short_cutoffs) {
  a <- function(s) summary_tab$oob_auc[summary_tab$cutoff_days == cutoff & summary_tab$set == s]
  if (all(c("main", "main_plus_counsel") %in% names(sets)))
    cat(sprintf("Within %d days - main_plus_counsel minus main (OOB AUC): %+.4f\n", cutoff, a("main_plus_counsel") - a("main")))
  if (all(c("main", "sensitivity") %in% names(sets)))
    cat(sprintf("Within %d days - sensitivity minus main (OOB AUC): %+.4f\n", cutoff, a("sensitivity") - a("main")))
  b <- if (!is.null(band_tab)) band_tab[band_tab$cutoff_days == cutoff, ] else NULL
  if (!is.null(b) && nrow(b) && all(c("main", "main_plus_counsel") %in% names(sets))) {
    cat(sprintf("Within %d days - AUC by band, and each band's share of the main_plus_counsel minus main gap:\n", cutoff))
    bm <- b[b$set == "main", ]; bn <- b[b$set == "main_plus_counsel", ]
    bm$auc_plus_counsel <- bn$oob_auc[match(bm$comparison, bn$comparison)]
    bm$weighted_gap <- round(bm$weight_in_overall_auc * (bm$auc_plus_counsel - bm$oob_auc), 4)
    print(bm[c("comparison", "n_first", "n_second", "weight_in_overall_auc", "oob_auc", "auc_plus_counsel", "weighted_gap")], row.names = FALSE)
  }
  key <- sprintf("%dd_main", cutoff)
  if (key %in% names(res)) { cat(sprintf("\nTop 10 variables, main forest, ended within %d days?\n", cutoff)); print(head(res[[key]]$imp, 10), row.names = FALSE) }
}
cat("\nAll outputs saved in", model_dir, "\n")
