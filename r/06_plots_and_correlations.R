# =============================================================================
# 06_plots_and_correlations.R — a first look at the dependent variable and the
# covariates, as plots: TRAINING CASES ONLY.
#
# Plots (PNG files in ~/scales_project/plots/):
#   00_duration_histogram_all.png general histogram: every training case with a duration,
#                                 ended vs transferred out (censored), 30-day bins, yearly lines
#   01_duration_histograms.png    duration in days and log(1 + days), cases that ended in court
#   02_survival_overall.png       Kaplan-Meier curve: share of cases still open by day,
#                                 with transferred-out cases treated as censored
#   03_survival_by_<var>.png      Kaplan-Meier curves for a few key categorical covariates
#   04_box_<var>.png              log(1 + duration) by category (the 15 largest categories),
#                                 cases that ended in court, for each main-model categorical
#   05_counts_<var>.png           median log duration by value of each count covariate
#   06_association_heatmap.png    covariate-by-covariate association (|Spearman|, Cramer's V,
#                                 eta), from 05_feature_selection.R's fs_association_square.csv
#   07_dv_association.png         each covariate's association with duration (rank-based),
#                                 all cases vs recorded-only, from fs_dv_association.csv
#
# Plots 06 and 07 reuse 05_feature_selection.R's tables, so run 05 first (it saves them in
# ~/scales_project/feature_selection/). The covariate lists come from r/covariate_sets.R:
# "main" covariates, plus the "sensitivity" ones (leaky: judge variables, the original
# defense firm variable, pro_se, n_counsel) shown separately. Base R graphics plus the survival package (installed
# with R), so no extra packages are needed.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
plot_dir <- file.path(project_dir, "plots"); dir.create(plot_dir, showWarnings = FALSE)
fs_dir   <- file.path(project_dir, "feature_selection")
png_open <- function(name, w = 1100, h = 750) {
  png(file.path(plot_dir, name), width = w, height = h, res = 110)
}

# ---- Covariates (r/covariate_sets.R, shared with the 07 scripts) ----------------------
source(file.path(r_dir, "covariate_sets.R"))
main_counts <- intersect(main_vars, num_vars)
main_cats   <- setdiff(main_vars, num_vars)
sens_cats   <- setdiff(sens_extra, c(num_vars, "judge_group"))  # judge_group: too many levels to plot
survival_by <- c("jurisdiction", "arrival_route", "plaintiff_firm_cases", "class_action_alleged")

have <- dbListFields(con, "train_fjc")
keep <- function(v) intersect(v, have)
main_counts <- keep(main_counts); main_cats <- keep(main_cats); sens_cats <- keep(sens_cats); survival_by <- keep(survival_by)

cat("Reading training cases...\n")
d <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                              WHERE duration_capped_days IS NOT NULL",
                             paste(c(main_counts, main_cats, sens_cats), collapse = ", ")))
for (v in c(main_cats, sens_cats)) d[[v]] <- ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]]))
ended <- d[d$event_observed %in% TRUE, ]
ended$log_dur <- log1p(ended$duration_capped_days)
cat(sprintf("%s training cases with a duration; %s ended in court.\n",
            format(nrow(d), big.mark = ","), format(nrow(ended), big.mark = ",")))

# ---- 00. General histogram: every training case with a duration --------------------------
# Ended cases and transferred-out (censored) cases stacked, in 30-day bins up to the cap,
# with yearly gridlines and the overall median and quartiles printed underneath.
breaks <- seq(0, max(d$duration_capped_days, 30) + 30, by = 30)
h_end  <- hist(d$duration_capped_days[d$event_observed %in% TRUE],  breaks = breaks, plot = FALSE)$counts
h_cens <- hist(d$duration_capped_days[!(d$event_observed %in% TRUE)], breaks = breaks, plot = FALSE)$counts
q <- quantile(d$duration_capped_days, c(0.25, 0.5, 0.75))
png_open("00_duration_histogram_all.png", 1400, 650)
par(mar = c(6, 5, 3, 1))
barplot(rbind(h_end, h_cens), space = 0, border = NA, col = c("grey45", "orange"),
        xlab = "", ylab = "number of training cases",
        main = sprintf("Case duration, all %s training cases with a duration (30-day bins)", format(nrow(d), big.mark = ",")))
years <- seq(0, max(breaks), by = 365); axis(1, at = years / 30, labels = paste0(years / 365, " yr"))
abline(v = years / 30, col = "grey85", lty = 3)
legend("topright", c("ended in court", "transferred out (censored)"), fill = c("grey45", "orange"), border = NA, bty = "n")
mtext(sprintf("days since filing   |   25th percentile %s days, median %s, 75th percentile %s; cap %s days",
              q[1], q[2], q[3], format(duration_cap_days, big.mark = ",")), side = 1, line = 4)
dev.off()

# ---- 01. Duration histograms -------------------------------------------------------
png_open("01_duration_histograms.png", 1300, 600); par(mfrow = c(1, 2))
hist(ended$duration_capped_days, breaks = 100, col = "grey75", border = "white",
     main = "Duration (days), cases that ended in court", xlab = "days")
abline(v = median(ended$duration_capped_days), col = "firebrick", lwd = 2)
hist(ended$log_dur, breaks = 80, col = "grey75", border = "white",
     main = "log(1 + duration)", xlab = "log(1 + days)")
abline(v = median(ended$log_dur), col = "firebrick", lwd = 2)
dev.off()

# ---- 02-03. Kaplan-Meier curves (censoring transferred-out cases) ----------------------
if (requireNamespace("survival", quietly = TRUE)) {
  S <- survival::Surv(d$duration_capped_days, d$event_observed %in% TRUE)
  png_open("02_survival_overall.png")
  plot(survival::survfit(S ~ 1), conf.int = FALSE, xlab = "days since filing", ylab = "share of cases still open",
       main = "Kaplan-Meier: share of training cases still open", lwd = 2)
  abline(h = 0.5, lty = 3, col = "grey50")
  dev.off()
  for (v in survival_by) {
    g <- d[[v]]; top <- names(sort(table(g), decreasing = TRUE))[seq_len(min(6, length(unique(g))))]
    ok <- g %in% top
    fit <- survival::survfit(S[ok] ~ factor(g[ok], levels = top))
    png_open(sprintf("03_survival_by_%s.png", v))
    cols <- seq_along(top)
    plot(fit, col = cols, lwd = 2, xlab = "days since filing", ylab = "share of cases still open",
         main = sprintf("Kaplan-Meier by %s (largest categories)", v))
    legend("topright", legend = top, col = cols, lwd = 2, cex = 0.8, bty = "n")
    dev.off()
  }
} else cat("survival package not available - skipping Kaplan-Meier plots.\n")

# ---- 04. log duration by category ---------------------------------------------------
box_by <- function(v, tag) {
  g <- ended[[v]]; tab <- sort(table(g), decreasing = TRUE)
  top <- names(tab)[seq_len(min(15, length(tab)))]; ok <- g %in% top
  f <- factor(g[ok], levels = rev(top))
  png_open(sprintf("04_box_%s.png", v), 1100, 120 + 45 * length(top))
  par(mar = c(4, 22, 3, 5))
  boxplot(ended$log_dur[ok] ~ f, horizontal = TRUE, las = 1, outline = FALSE, col = "grey85",
          xlab = "log(1 + days)", ylab = "", cex.axis = 0.75,
          main = sprintf("%s%s: log duration by category (n shown, largest 15)", v, tag))
  axis(4, at = seq_along(levels(f)), labels = format(as.integer(tab[levels(f)]), big.mark = ","),
       las = 1, tick = FALSE, cex.axis = 0.65)
  dev.off()
}
for (v in main_cats) box_by(v, "")
for (v in sens_cats) box_by(v, " [SENSITIVITY - leaky]")

# ---- 05. Count covariates: median log duration by value --------------------------------
for (v in main_counts) {
  x <- pmin(ended[[v]], 50)                                   # 50+ pooled so the tail is readable
  med <- tapply(ended$log_dur, x, median); n <- tapply(ended$log_dur, x, length)
  png_open(sprintf("05_counts_%s.png", v))
  plot(as.numeric(names(med)), med, type = "b", pch = 19, cex = pmin(2.5, 0.4 + log10(n) / 2),
       xlab = sprintf("%s (50 = 50 or more; point size ~ number of cases)", v), ylab = "median log(1 + days)",
       main = sprintf("Median log duration by %s (cases that ended in court)", v))
  dev.off()
}

# ---- 06-07. Association plots, from 05_feature_selection.R's tables -------------------
sq_file <- file.path(fs_dir, "fs_association_square.csv")
if (file.exists(sq_file)) {
  m <- as.matrix(read.csv(sq_file, row.names = 1, check.names = FALSE))
  m[is.na(m)] <- 0
  png_open("06_association_heatmap.png", 1300, 1250)
  par(mar = c(12, 12, 3, 2))
  k <- nrow(m)
  image(1:k, 1:k, m[, k:1], col = hcl.colors(20, "YlOrRd", rev = TRUE), zlim = c(0, 1),
        axes = FALSE, xlab = "", ylab = "", main = "Covariate associations (0 = none, 1 = identical)")
  axis(1, 1:k, rownames(m), las = 2, cex.axis = 0.7); axis(2, 1:k, rev(colnames(m)), las = 1, cex.axis = 0.7)
  for (i in 1:k) for (j in 1:k) if (i != j && m[i, k - j + 1] >= 0.7) text(i, j, sprintf("%.2f", m[i, k - j + 1]), cex = 0.5)
  dev.off()
} else cat("No fs_association_square.csv - run 05_feature_selection.R first for the heatmap.\n")

dv_file <- file.path(fs_dir, "fs_dv_association.csv")
if (file.exists(dv_file) && any(!is.na(read.csv(dv_file)$rank_all))) {
  dv <- read.csv(dv_file); dv <- dv[!is.na(dv$rank_all), ]; dv <- dv[order(dv$rank_all), ]
  png_open("07_dv_association.png", 1100, 950)
  par(mar = c(4, 14, 3, 1))
  bp <- barplot(rbind(dv$rank_all, dv$rank_recorded), beside = TRUE, horiz = TRUE, names.arg = dv$variable,
                las = 1, cex.names = 0.7, col = c("grey45", "steelblue"), xlim = c(0, max(dv$rank_all, na.rm = TRUE) * 1.1),
                xlab = "association with duration (rank-based: eta or |Spearman|)",
                main = "Each covariate vs duration, training cases that ended in court")
  legend("bottomright", c("all cases", "recorded cases only"), fill = c("grey45", "steelblue"), bty = "n")
  leaky <- dv$leak == "leaky"
  text(0, colMeans(bp)[leaky], "  leaky", adj = 0, cex = 0.55, col = "firebrick")
  dev.off()
}

cat("\nPlots saved in", plot_dir, ":\n"); print(list.files(plot_dir))
