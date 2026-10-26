# =============================================================================
# 02-d_data_checks_prose.R — do the two sources agree on who has no lawyer?
#
# Two independent measures of self-representation:
#   SCALES (counsel table, at collection)   built by 01_build_features.R
#     plaintiff_firm_cases = "pro se / no counsel": the first plaintiff's lead
#                            counsel is marked pro se, or no counsel is listed
#     defendant_firm_rank  = "no counsel listed":   the same, for the first defendant
#   FJC (PROSE, recorded at termination)    built in 00_sample.R
#     pro_se = plaintiff / defendant / both / none
#
# For each side this cross-tabulates the two and reports agreement: how often
# each source's "no lawyer" is confirmed by the other, and Cohen's kappa
# (agreement beyond chance: 0 = chance, 1 = perfect).
#
# What to expect: the plaintiff side should agree well. The DEFENDANT side may not:
# a defendant that never appears (default, or dismissed before answering) has no
# counsel in SCALES but is usually not recorded as pro se by the FJC. That gap is
# what makes "no counsel listed" leaky (EXPLAINER section 7B).
#
# TRAINING CASES ONLY (as for all analysis since the split); counts only, no
# outcomes. Output: printed tables, plus ~/scales_project/checks/prose_*.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("prose_", name, ".csv")), row.names = FALSE)

d <- dbGetQuery(con, "SELECT court, nature_suit, pro_se, plaintiff_firm_cases, defendant_firm_rank FROM train_fjc")
cat(sprintf("%s training cases.\n", format(nrow(d), big.mark = ",")))

# Collapse each source to: no lawyer / has a lawyer / not comparable
d$scales_plf <- with(d, ifelse(is.na(plaintiff_firm_cases) | plaintiff_firm_cases == "no plaintiff listed", NA,
                        ifelse(plaintiff_firm_cases == "pro se / no counsel", "no lawyer (SCALES)",
                        ifelse(plaintiff_firm_cases == "no firm listed", "lawyer, no firm listed", "lawyer with firm"))))
d$scales_def <- with(d, ifelse(is.na(defendant_firm_rank) | defendant_firm_rank == "no defendant listed", NA,
                        ifelse(defendant_firm_rank == "no counsel listed", "no lawyer (SCALES)", "lawyer listed")))
fjc_known <- d$pro_se %in% c("none", "plaintiff", "defendant", "both")
d$fjc_plf <- ifelse(!fjc_known, NA, ifelse(d$pro_se %in% c("plaintiff", "both"), "pro se (FJC)", "not pro se (FJC)"))
d$fjc_def <- ifelse(!fjc_known, NA, ifelse(d$pro_se %in% c("defendant", "both"), "pro se (FJC)", "not pro se (FJC)"))

crosstab <- function(a, b) {
  t <- table(a, b, useNA = "ifany"); x <- as.data.frame.matrix(t)
  cbind(SCALES = ifelse(is.na(rownames(x)), "(not comparable)", rownames(x)), x, total = rowSums(x), row.names = NULL)
}
agreement <- function(scales_nolaw, fjc_prose, side) {
  ok <- !is.na(scales_nolaw) & !is.na(fjc_prose); s <- scales_nolaw[ok]; f <- fjc_prose[ok]
  po <- mean(s == f)                                          # observed agreement
  pe <- mean(s) * mean(f) + (1 - mean(s)) * (1 - mean(f))      # agreement expected by chance
  data.frame(side = side, n_compared = sum(ok),
             n_scales_no_lawyer = sum(s), n_fjc_pro_se = sum(f), n_both = sum(s & f),
             pct_scales_no_lawyer_that_fjc_calls_pro_se = round(100 * sum(s & f) / max(1, sum(s)), 1),
             pct_fjc_pro_se_that_scales_shows_no_lawyer = round(100 * sum(s & f) / max(1, sum(f)), 1),
             pct_agree = round(100 * po, 1), cohen_kappa = round((po - pe) / (1 - pe), 3))
}

# ---- 1. Plaintiff side ------------------------------------------------------------
t_plf <- crosstab(d$scales_plf, d$fjc_plf)
save_csv(t_plf, "1_plaintiff_crosstab")
cat("\n1. PLAINTIFF: SCALES first plaintiff's counsel vs FJC PROSE (plaintiff or both)\n"); print(t_plf, row.names = FALSE)

# ---- 2. Defendant side ------------------------------------------------------------
t_def <- crosstab(d$scales_def, d$fjc_def)
save_csv(t_def, "2_defendant_crosstab")
cat("\n2. DEFENDANT: SCALES first defendant's counsel vs FJC PROSE (defendant or both)\n"); print(t_def, row.names = FALSE)

# ---- 3. Agreement -------------------------------------------------------------------
agree <- rbind(
  agreement(ifelse(is.na(d$scales_plf), NA, d$scales_plf == "no lawyer (SCALES)"), ifelse(is.na(d$fjc_plf), NA, d$fjc_plf == "pro se (FJC)"), "plaintiff"),
  agreement(ifelse(is.na(d$scales_def), NA, d$scales_def == "no lawyer (SCALES)"), ifelse(is.na(d$fjc_def), NA, d$fjc_def == "pro se (FJC)"), "defendant"))
save_csv(agree, "3_agreement")
cat("\n3. Agreement (cases where both sources are comparable)\n"); print(t(agree), quote = FALSE)

# ---- 4. Where they disagree ---------------------------------------------------------
dis <- function(mask, label) {
  if (!any(mask, na.rm = TRUE)) return(NULL)
  x <- d[mask %in% TRUE, ]
  top <- function(v, by) { t <- table(v); t <- t[order(-t)]
    head(data.frame(disagreement = label, by = by, value = names(t), n_cases = as.integer(t)), 10) }
  rbind(top(x$nature_suit, "nature_suit"), top(x$court, "court"))
}
dis_tab <- rbind(
  dis(d$scales_plf == "no lawyer (SCALES)" & d$fjc_plf == "not pro se (FJC)", "plaintiff: no lawyer in SCALES, not pro se in FJC"),
  dis(d$scales_plf %in% c("lawyer with firm", "lawyer, no firm listed") & d$fjc_plf == "pro se (FJC)", "plaintiff: lawyer in SCALES, pro se in FJC"),
  dis(d$scales_def == "no lawyer (SCALES)" & d$fjc_def == "not pro se (FJC)", "defendant: no lawyer in SCALES, not pro se in FJC"),
  dis(d$scales_def == "lawyer listed" & d$fjc_def == "pro se (FJC)", "defendant: lawyer in SCALES, pro se in FJC"))
if (!is.null(dis_tab)) {
  save_csv(dis_tab, "4_disagreements")
  cat("\n4. Largest natures of suit and courts among the disagreements (full list in prose_4_disagreements.csv)\n")
  for (lab in unique(dis_tab$disagreement)) {
    cat("\n  ", lab, "\n", sep = ""); x <- dis_tab[dis_tab$disagreement == lab & dis_tab$by == "nature_suit", c("value", "n_cases")]
    print(head(x, 5), row.names = FALSE)
  }
}
cat("\nTables saved in", checks_dir, "(prose_*.csv)\n")
