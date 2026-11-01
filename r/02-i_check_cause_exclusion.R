# =============================================================================
# 02-i_check_cause_exclusion.R — would cutting a cause of action from the population
# keep training and holdout balanced? (Josh, 30 Oct 2026)
#
# Candidate: 33:2701 (Oil Pollution Act). Josh: the E.D. La. "no plaintiff listed" cases
# (02-h_data_checks_missing.R) look like Deepwater Horizon proceedings, not representative.
# For the candidate, and for other ways of drawing the same group (to see whether the cause
# code captures it), the number and share of training vs holdout cases it would remove, with
# the two-proportion z-test used in 02_data_checks.R (|z| > 3 FLAGged).
# Uses only covariates (cause, court, parties), never outcomes, so holdout counts are fine.
# Training only: the courts and natures of suit of the candidate cases.
# Output: ~/scales_project/checks/cause_exclusion_*.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("cause_exclusion_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
ztest <- function(k_tr, n_tr, k_ho, n_ho) {          # as in 02_data_checks.R
  p <- (k_tr + k_ho) / (n_tr + n_ho)
  if (p == 0 || p == 1) return(0)
  (k_tr / n_tr - k_ho / n_ho) / sqrt(p * (1 - p) * (1 / n_tr + 1 / n_ho))
}

# ---- Settings ------------------------------------------------------------------------
cand_title <- 33; cand_section <- "2701"
cand <- sprintf("(cause_title = %d AND cause_section = '%s')", cand_title, cand_section)
label <- sprintf("%d:%s", cand_title, cand_section)
groups <- c(
  setNames(cand, sprintf("cause %s (the candidate)", label)),
  setNames(sprintf("%s AND court = 'laed'", cand), sprintf("cause %s, E.D. La.", label)),
  setNames(sprintf("%s AND court <> 'laed'", cand), sprintf("cause %s, other courts", label)),
  "E.D. La., no plaintiff listed"                    = "court = 'laed' AND first_plaintiff_type = 'no plaintiff listed'",
  "E.D. La., no plaintiff listed, other causes"      = sprintf("court = 'laed' AND first_plaintiff_type = 'no plaintiff listed' AND NOT coalesce(%s, false)", cand),
  "jury_demand (NA)"                                 = "jury_demand IS NULL")

# ---- Balance -----------------------------------------------------------------------------
tot <- q("SELECT is_holdout, count(*) AS n FROM analysis_fjc WHERE is_holdout IS NOT NULL GROUP BY 1")
n_tr <- tot$n[!tot$is_holdout]; n_ho <- tot$n[tot$is_holdout]
bal <- do.call(rbind, lapply(names(groups), function(g) {
  x <- q(sprintf("SELECT count(*) FILTER (WHERE NOT is_holdout) AS k_tr, count(*) FILTER (WHERE is_holdout) AS k_ho
                  FROM analysis_fjc WHERE is_holdout IS NOT NULL AND coalesce(%s, false)", groups[[g]]))
  data.frame(group = g, training_removed = x$k_tr, pct_training = round(100 * x$k_tr / n_tr, 3),
             holdout_removed = x$k_ho, pct_holdout = round(100 * x$k_ho / n_ho, 3),
             z = round(ztest(x$k_tr, n_tr, x$k_ho, n_ho), 2))
}))
bal$balanced <- ifelse(abs(bal$z) <= 3, "yes", "NO - check")
save_csv(bal, "1_balance")
cat(sprintf("\nSample: %s training, %s holdout cases.\n", format(n_tr, big.mark = ","), format(n_ho, big.mark = ",")))
cat("What each cut would remove, training vs holdout (|z| > 3 would be unusual for a random split):\n")
print(bal, row.names = FALSE)
main_row <- bal[1, ]
cat(sprintf("\n%s: cutting cause %s removes %s training (%.2f%%) and %s holdout cases (%.2f%%), z = %.2f.\n",
            if (abs(main_row$z) <= 3) "PASS" else "FLAG", label, format(main_row$training_removed, big.mark = ","),
            main_row$pct_training, format(main_row$holdout_removed, big.mark = ","), main_row$pct_holdout, main_row$z))

# ---- Training only: where the candidate cases are -------------------------------------------
where_tab <- q(sprintf("SELECT court, nature_suit, first_plaintiff_type = 'no plaintiff listed' AS no_plaintiff_listed,
    count(*) AS n_training FROM train_fjc WHERE coalesce(%s, false) GROUP BY ALL ORDER BY 4 DESC LIMIT 25", cand))
save_csv(where_tab, "2_where_training")
cat(sprintf("\nTraining cases with cause %s, by court and nature of suit (largest 25):\n", label))
print(where_tab, row.names = FALSE)
cat("\nTables saved in", checks_dir, "(cause_exclusion_*.csv)\n")
