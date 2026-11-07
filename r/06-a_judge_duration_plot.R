# =============================================================================
# 06-a_judge_duration_plot.R — duration by judge, for the judges with the most cases.
# TRAINING CASES ONLY (Josh, 5 Nov 2026; change 103). Cases that ended in court.
#
# Two panels, one row per judge, ordered by median duration:
#   left    days to ending (log scale), box and whiskers per judge
#   right   the same cases relative to their COURT: log(1 + days) minus the court's median
#           log(1 + days) (all of that court's training cases), shown as a ratio (x0.5, x1, x2).
#           Judges are nested in courts, so the left panel mixes court and judge; the right
#           one shows how a judge differs from the rest of the same court.
# Neither panel adjusts for case mix (nature of suit, parties, ...): a judge who gets more
# quick case types looks faster. The model's judge effects (07-c SHAP, judge_group) do adjust.
# Box: middle line = median, box = middle half of the cases (25th to 75th percentile),
# whiskers = the furthest case within 1.5 box-lengths, dots beyond them not drawn (too many).
# Labels: "court J1 (n)" by default; the judge's usual type is marked (M) magistrate,
# (S) senior. Set show_names <- TRUE to label by judge name instead.
# Left out: judge_group's pooled levels ("other (fewer than 20 training cases)",
# "unassigned", "(no judge listed)").
#   source("~/scales_setup/r/06-a_judge_duration_plot.R")     (or Rscript; quick)
# Output: ~/scales_project/plots/judge_duration_top<N>.png and .csv (per judge: court, cases,
#         median and quartiles in days, court median, ratio to the court median)
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
plot_dir <- file.path(project_dir, "plots"); dir.create(plot_dir, showWarnings = FALSE)

# ---- Settings (edit these) --------------------------------------------------------
n_judges   <- 25          # judges with the most training cases (that ended in court)
show_names <- FALSE       # TRUE: label rows by judge name; FALSE: court + J1, J2, ...

cat("Reading training cases...\n")
d <- dbGetQuery(con, "SELECT court, judge_group, judge_type, duration_capped_days FROM train_fjc
                      WHERE event_observed AND duration_capped_days IS NOT NULL")
d$log_dur <- log1p(d$duration_capped_days)
d$court_median <- ave(d$log_dur, d$court, FUN = median)          # every case of the court
pooled <- c("other (fewer than 20 training cases)", "unassigned", "(no judge listed)")
j <- d[!is.na(d$judge_group) & !(d$judge_group %in% pooled), ]
top <- head(names(sort(table(j$judge_group), decreasing = TRUE)), n_judges)
j <- j[j$judge_group %in% top, ]

# one row per judge
tab <- do.call(rbind, lapply(top, function(g) {
  x <- j[j$judge_group == g, ]; q <- quantile(x$duration_capped_days, c(0.25, 0.5, 0.75))
  tp <- names(which.max(table(x$judge_type)))
  data.frame(judge_group = g, court = x$court[1], usual_type = tp, n_cases = nrow(x),
             q1_days = unname(q[1]), median_days = unname(q[2]), q3_days = unname(q[3]),
             court_median_days = round(expm1(x$court_median[1]), 1),
             ratio_to_court = round(exp(median(x$log_dur - x$court_median)), 3))
}))
tab <- tab[order(tab$median_days), ]
mark <- ifelse(tab$usual_type == "magistrate", " (M)", ifelse(tab$usual_type == "senior", " (S)", ""))
tab$label <- if (show_names) {
  sprintf("%s%s (%s)", tab$judge_group, mark, format(tab$n_cases, big.mark = ","))
} else {
  sprintf("%s J%d%s (%s)", tab$court, ave(seq_len(nrow(tab)), tab$court, FUN = seq_along), mark,
          format(tab$n_cases, big.mark = ","))
}
j$row <- factor(j$judge_group, levels = tab$judge_group)

# ---- Plot ----------------------------------------------------------------------------
courts <- unique(tab$court)
col_court <- setNames(hcl.colors(max(length(courts), 2), "Dark 3")[seq_along(courts)], courts)
f <- file.path(plot_dir, sprintf("judge_duration_top%d.png", n_judges))
png(f, width = 1500, height = 320 + 32 * nrow(tab), res = 110)
layout(matrix(1:2, 1), widths = c(1.35, 1))
par(mar = c(5, 15, 4, 1), oma = c(2, 0, 0, 0))
day_ticks <- c(7, 30, 90, 180, 365, 730, 1460, 3103)
boxplot(log_dur ~ row, data = j, horizontal = TRUE, las = 1, outline = FALSE, names = tab$label,
        col = adjustcolor(col_court[tab$court], 0.45), border = col_court[tab$court], xaxt = "n",
        cex.axis = 0.75, xlab = "days to ending (log scale)", ylab = "",
        main = sprintf("Duration by judge (%d judges with the most cases)", nrow(tab)), cex.main = 1)
axis(1, at = log1p(day_ticks), labels = day_ticks, cex.axis = 0.8)
abline(v = median(d$log_dur), lty = 2, col = "grey40")
mtext(sprintf("dashed line: median of all cases, %s days", round(median(d$duration_capped_days))),
      side = 3, line = 0.3, cex = 0.7, col = "grey30")
rel <- j$log_dur - j$court_median
ratio_ticks <- c(0.1, 0.25, 0.5, 1, 2, 4, 10)
par(mar = c(5, 1, 4, 1))
boxplot(rel ~ j$row, horizontal = TRUE, las = 1, outline = FALSE, names = rep("", nrow(tab)),
        col = adjustcolor(col_court[tab$court], 0.45), border = col_court[tab$court], xaxt = "n",
        xlab = "relative to the court's median (ratio, log scale)", ylab = "",
        main = "Relative to the judge's own court", cex.main = 1)
axis(1, at = log(ratio_ticks), labels = paste0("x", ratio_ticks), cex.axis = 0.8)
mtext("dashed line: the court's median", side = 3, line = 0.3, cex = 0.7, col = "grey30")
abline(v = 0, lty = 2, col = "grey40")
mtext(sprintf("Training cases that ended in court; boxes = middle half of each judge's cases, line = median; colour = court. Not adjusted for case mix.%s",
              if (show_names) "" else " (M) magistrate, (S) senior."), side = 1, outer = TRUE, cex = 0.75)
dev.off()

out <- tab[c(if (show_names) "judge_group", "label", "court", "usual_type", "n_cases", "q1_days", "median_days",
             "q3_days", "court_median_days", "ratio_to_court")]
write.csv(out, sub("\\.png$", ".csv", f), row.names = FALSE)
cat(sprintf("%d judges, %s cases (of %s training cases that ended in court). Saved %s and the .csv\n",
            nrow(tab), format(nrow(j), big.mark = ","), format(nrow(d), big.mark = ","), f))
