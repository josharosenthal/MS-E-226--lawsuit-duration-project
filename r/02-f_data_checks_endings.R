# =============================================================================
# 02-f_data_checks_endings.R — cases that LEFT this court without being resolved here:
# are they balanced between training and holdout, in case we decide to drop them?
#
# Ending types (FJC DISP):
#   0  transferred to another district   (now censored in the duration variable)
#   1  remanded to state court           (now counted as an ending)
#   11 remanded to a U.S. agency         (now counted as an ending)
#   15 award of arbitrator               (now counted as an ending)
#   16 stayed pending bankruptcy         (now counted as an ending)
#   18 statistical closing - closed administratively, often while stayed (e.g. pending
#      arbitration or another case); can be reopened (now counted as an ending)
# Balance: for each type, and groups of them, the share of training vs holdout cases with
# it, with the two-proportion z-test used in 02_data_checks.R (|z| > 3 is FLAGged).
# This uses an outcome (how the case ended) in the holdout, so COUNTS ONLY - no durations,
# nothing compared with covariates.
#
# Training cases only: how often the docket mentions sending the case to arbitration
# (compel / stay / refer ... arbitration), by DISP - arbitration often ends as a stay plus
# statistical closing (18) or a dismissal, not as DISP 15.
# Output: ~/scales_project/checks/endings_*.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("endings_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
ztest <- function(k_tr, n_tr, k_ho, n_ho) {          # as in 02_data_checks.R
  p <- (k_tr + k_ho) / (n_tr + n_ho)
  if (p == 0 || p == 1) return(0)
  (k_tr / n_tr - k_ho / n_ho) / sqrt(p * (1 - p) * (1 / n_tr + 1 / n_ho))
}

types <- c("0" = "transferred to another district", "1" = "remanded to state court",
           "11" = "remanded to U.S. agency", "15" = "award of arbitrator",
           "16" = "stayed pending bankruptcy", "18" = "statistical closing")
groups <- c(setNames(as.list(names(types)), paste0(names(types), " ", types)),
            list("remands (1, 11)"                         = c("1", "11"),
                 "left for another forum (0, 1, 11)"       = c("0", "1", "11"),
                 "left or set aside (0, 1, 11, 15, 16, 18)" = names(types)))

cnt <- q("SELECT is_holdout, trim(CAST(DISP AS VARCHAR)) AS disp, count(*) AS n FROM analysis_fjc
          WHERE is_holdout IS NOT NULL GROUP BY ALL")
n_tr <- sum(cnt$n[!cnt$is_holdout]); n_ho <- sum(cnt$n[cnt$is_holdout])
bal <- do.call(rbind, lapply(names(groups), function(g) {
  k_tr <- sum(cnt$n[!cnt$is_holdout & cnt$disp %in% groups[[g]]])
  k_ho <- sum(cnt$n[cnt$is_holdout & cnt$disp %in% groups[[g]]])
  data.frame(ending = g, training = k_tr, pct_training = round(100 * k_tr / n_tr, 3),
             holdout = k_ho, pct_holdout = round(100 * k_ho / n_ho, 3),
             z = round(ztest(k_tr, n_tr, k_ho, n_ho), 2))
}))
bal$balanced <- ifelse(abs(bal$z) <= 3, "yes", "NO - check")
save_csv(bal, "1_split_balance")
cat(sprintf("\nSample: %s training, %s holdout cases.\n", format(n_tr, big.mark = ","), format(n_ho, big.mark = ",")))
cat("Endings by type, training vs holdout (|z| > 3 would be unusual for a random split):\n")
print(bal, row.names = FALSE)
cat(sprintf("\n%s: %d of %d rows balanced.\n", if (all(abs(bal$z) <= 3)) "PASS" else "FLAG",
            sum(abs(bal$z) <= 3), nrow(bal)))

# ---- Training only: docket mentions of arbitration, by how the case ended -------------------
arb <- q(sprintf("WITH a AS (
    SELECT DISTINCT d.ucid FROM '%s/docket_entries.parquet' d
    WHERE d.ucid IN (SELECT ucid FROM train_fjc)
      AND regexp_matches(lower(CAST(d.docket_text AS VARCHAR)),
            '(compel|stay|stayed|refer|referred|submit|pending)[a-z ,]{0,40}arbitrat|arbitrat[a-z ,]{0,20}(compelled|granted)'))
  SELECT coalesce(trim(CAST(t.DISP AS VARCHAR)), '(no FJC DISP)') AS disp, count(*) AS n_training,
         count(a.ucid) AS n_docket_mentions_arbitration
  FROM train_fjc t LEFT JOIN a ON a.ucid = t.ucid GROUP BY 1 ORDER BY 3 DESC", pq))
arb$pct_mention <- round(100 * arb$n_docket_mentions_arbitration / arb$n_training, 2)
save_csv(arb, "2_arbitration_by_disp")
cat(sprintf("\nTraining cases whose docket mentions sending the case to arbitration: %s. By FJC DISP:\n",
            format(sum(arb$n_docket_mentions_arbitration), big.mark = ",")))
print(head(arb[arb$n_docket_mentions_arbitration > 0, ], 12), row.names = FALSE)
cat("\nTables saved in", checks_dir, "(endings_*.csv)\n")
