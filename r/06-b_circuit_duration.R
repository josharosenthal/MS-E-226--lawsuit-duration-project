# =============================================================================
# 06-b_circuit_duration.R — duration by circuit. TRAINING CASES ONLY (Josh, 5 Nov 2026;
# change 104). Cases that ended in court, as the log-duration models.
# Per circuit: cases, mean, median and geometric mean days (the geometric mean is
# exp(mean log(1 + days)) - 1, the scale the models predict on), standard deviation, and the
# share ending within 60 days among all its cases with a duration (transfers out before day 60
# left out, as the short-case models). The mean is pulled up by the long cases; the median and
# geometric mean are less so. Not adjusted for case mix or court.
#   source("~/scales_setup/r/06-b_circuit_duration.R")     (or Rscript; quick)
# Output: ~/scales_project/plots/circuit_duration.csv (also printed)
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
plot_dir <- file.path(project_dir, "plots"); dir.create(plot_dir, showWarnings = FALSE)

tab <- dbGetQuery(con, "
  SELECT circuit,
    count(*) FILTER (WHERE event_observed)                                        AS n_ended,
    round(avg(duration_capped_days) FILTER (WHERE event_observed), 1)             AS mean_days,
    median(duration_capped_days) FILTER (WHERE event_observed)                    AS median_days,
    round(exp(avg(ln(1 + duration_capped_days)) FILTER (WHERE event_observed)) - 1, 1) AS geometric_mean_days,
    round(stddev(duration_capped_days) FILTER (WHERE event_observed), 1)          AS sd_days,
    round(avg(CASE WHEN duration_capped_days <= 60 THEN 1.0 ELSE 0.0 END)
          FILTER (WHERE event_observed OR duration_capped_days > 60), 4)          AS share_within_60_days
  FROM train_fjc
  WHERE duration_capped_days IS NOT NULL
  GROUP BY circuit
  ORDER BY try_cast(circuit AS INTEGER) NULLS LAST, circuit")
tab$circuit <- ifelse(tab$circuit == "0", "D.C. (0)", tab$circuit)
all <- dbGetQuery(con, "SELECT round(avg(duration_capped_days), 1) AS mean_days, median(duration_capped_days) AS median_days
                        FROM train_fjc WHERE event_observed AND duration_capped_days IS NOT NULL")
f <- file.path(plot_dir, "circuit_duration.csv")
write.csv(tab, f, row.names = FALSE)
cat("Duration by circuit, training cases that ended in court (the holdout is untouched):\n")
print(tab, row.names = FALSE)
cat(sprintf("All circuits: mean %s days, median %s days. Saved %s\n", all$mean_days, all$median_days, f))
