# =============================================================================
# 05_feature_selection.R — how the chosen covariates relate to each other and to
# duration, on TRAINING cases only, to help decide which to keep.
#
# Why not just cor()? cor() measures LINEAR association between NUMERIC
# variables. Most covariates here are categorical (court, judge group, nature of
# suit, ...), and their codes are arbitrary, so cor() on them is meaningless.
# This script uses the measure that fits each pair (all run from 0 to 1, so
# they can sit in one table):
#   numeric x numeric       |Spearman| - rank-based, so skewed counts and
#                           outliers (cases with hundreds of parties) don't dominate
#   categorical x categorical  Cramer's V, bias-corrected (Bergsma 2013) - fair
#                           for variables with many levels
#   numeric x categorical   correlation ratio (eta) - share of the numeric
#                           variable's spread explained by the categories
# Each pair uses only cases where BOTH variables are recorded. Missing-value
# labels ("no FJC record", ...) are left out of the pair: otherwise two unrelated
# FJC variables share that label in the same cases, and Cramer's V reads it as
# association (a perfectly shared level forces V to at least 0.707, however rare).
#
# Output (~/scales_project/feature_selection/):
#   fs_covariates.csv       each covariate: type, leakage tier, number of levels,
#                           smallest level's count
#   fs_levels.csv           training cases in each category: all categories of covariates
#                           with up to 15, otherwise the 10 rarest and 5 most common
#   fs_spearman_numeric.csv Spearman matrix for the numeric covariates
#   fs_association_matrix.csv  every pair, with the measures above and the
#                           number of cases with both recorded (n_both)
#   fs_high_pairs.csv       pairs at or above `assoc_threshold` (redundant pairs)
#   fs_dv_association.csv   each covariate vs duration, cases that ENDED in
#                           court (event_observed = TRUE), four ways:
#                             rank_all       on the RANK of duration (needs no choice of
#                                            scale: eta on ranks = sqrt of the
#                                            Kruskal-Wallis epsilon-squared; |Spearman|
#                                            for the counts)
#                             log_all        eta with log(1 + duration)
#                             rank_recorded, log_recorded  the same, on cases where the
#                                            covariate is recorded (missing labels left
#                                            out). A big drop from _all to _recorded
#                                            means the "missing" category is doing the work.
#                           Censored cases
#                           (transferred out) are left out here - use survival
#                           models for the real analysis. Many-level variables
#                           look more predictive than they are, so read this
#                           with the number of levels in mind.
#
# TRAINING CASES ONLY: stops if this population's holdout split doesn't exist.
# Edit the covariate list below to add or drop variables (see covariates.xlsx
# and EXPLAINER.md section 7 for the leakage tiers).
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
if (!exists("population")) population <- "all"
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
out_dir <- file.path(project_dir, "feature_selection"); dir.create(out_dir, showWarnings = FALSE)
assoc_threshold <- 0.7        # pairs at or above this are listed as possibly redundant

# ---- 1. The covariates (Josh's choices in covariates.xlsx, as built) ----------
#   type: numeric or categorical (yes/no variables count as categorical)
#   leak: "filing" known at filing; "partly" recorded later (EXPLAINER 7C);
#         "leaky" kept knowingly despite leakage (EXPLAINER 7B)
covariates <- read.csv(text = "
variable,type,leak
n_parties,numeric,partly
n_counsel,numeric,leaky
n_plaintiffs,numeric,partly
n_defendants,numeric,partly
year_dir,categorical,filing
filing_month,categorical,filing
filing_weekday,categorical,filing
case_number_parity,categorical,filing
court,categorical,filing
circuit,categorical,filing
city,categorical,filing
judge_group,categorical,leaky
senior_judge_at_filing,categorical,leaky
nature_suit,categorical,filing
cause_title,categorical,filing
cause_group,categorical,filing
jurisdiction,categorical,filing
jury_demand,categorical,partly
arrival_route,categorical,filing
class_action_alleged,categorical,filing
in_forma_pauperis,categorical,partly
pro_se,categorical,partly
diversity_residence,categorical,filing
county_area_class,categorical,filing
first_plaintiff_type,categorical,partly
first_defendant_type,categorical,partly
plaintiff_firm_cases,categorical,partly
defendant_firm_rank,categorical,leaky
defendant_firm_appeared,categorical,partly
defendant_pro_se,categorical,partly
plaintiff_org_attorney,categorical,partly
any_referral,categorical,leaky
has_related_case,categorical,partly
is_consolidated,categorical,leaky
consolidation_role,categorical,leaky
tro_pi_motion_60d,categorical,partly
amicus,categorical,leaky
", strip.white = TRUE)
available <- dbListFields(con, "train_fjc")
missing_cols <- setdiff(covariates$variable, available)
if (length(missing_cols)) {
  warning("Not in train_fjc (skipped): ", paste(missing_cols, collapse = ", "),
          ". Has 01_build_features.R been run?", call. = FALSE)
  covariates <- covariates[covariates$variable %in% available, ]
}

# ---- 2. Training data ---------------------------------------------------------
cat("Reading training cases...\n")
d <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                              WHERE duration_capped_days IS NOT NULL",
                             paste(covariates$variable, collapse = ", ")))
cat(sprintf("%s training cases with a duration value.\n", format(nrow(d), big.mark = ",")))
num_vars <- covariates$variable[covariates$type == "numeric"]
cat_vars <- covariates$variable[covariates$type == "categorical"]
for (v in cat_vars) d[[v]] <- factor(ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]])))
# labels that mean "not recorded" (from 01_build_features.R and 00_sample.R) - real categories
# such as "unassigned", "no counsel listed" or "pro se / no counsel" are NOT in this list
missing_labels <- c("(NA)", "no FJC record", "not recorded", "county not recorded", "no judge listed",
                    "filing date missing", "no plaintiff listed", "no defendant listed", "name not recorded")
recorded <- setNames(lapply(covariates$variable, function(v)
  if (v %in% num_vars) !is.na(d[[v]]) else !(as.character(d[[v]]) %in% missing_labels)), covariates$variable)

# ---- Association measures -------------------------------------------------------
cramers_v <- function(x, y) {                     # bias-corrected (Bergsma 2013)
  tab <- table(x, y); tab <- tab[rowSums(tab) > 0, colSums(tab) > 0, drop = FALSE]
  n <- sum(tab); r <- nrow(tab); k <- ncol(tab)
  if (r < 2 || k < 2) return(NA_real_)
  expected <- outer(rowSums(tab), colSums(tab)) / n
  chi2 <- sum((tab - expected)^2 / expected)
  phi2 <- max(0, chi2 / n - (k - 1) * (r - 1) / (n - 1))
  rc <- r - (r - 1)^2 / (n - 1); kc <- k - (k - 1)^2 / (n - 1)
  denom <- min(kc - 1, rc - 1); if (denom <= 0) return(NA_real_)
  sqrt(phi2 / denom)
}
eta <- function(num, f) {                         # correlation ratio
  ok <- !is.na(num); num <- num[ok]; f <- droplevels(f[ok])
  if (length(unique(num)) < 2 || nlevels(f) < 2) return(NA_real_)
  m <- mean(num); g <- tapply(num, f, mean); ng <- tapply(num, f, length)
  sqrt(sum(ng * (g - m)^2, na.rm = TRUE) / sum((num - m)^2))
}
assoc <- function(a, b) {                         # on cases with both recorded
  ta <- covariates$type[covariates$variable == a]; tb <- covariates$type[covariates$variable == b]
  ok <- recorded[[a]] & recorded[[b]]; x <- d[[a]][ok]; y <- d[[b]][ok]
  if (is.factor(x)) x <- droplevels(x); if (is.factor(y)) y <- droplevels(y)
  n_both <- sum(ok)
  if (ta == "numeric" && tb == "numeric")
    return(c(measure = "|Spearman|", value = abs(suppressWarnings(cor(x, y, method = "spearman"))), n_both = n_both))
  if (ta == "categorical" && tb == "categorical") return(c(measure = "Cramer's V", value = cramers_v(x, y), n_both = n_both))
  if (ta == "numeric") return(c(measure = "eta", value = eta(x, y), n_both = n_both))
  c(measure = "eta", value = eta(y, x), n_both = n_both)
}

# ---- 3. Covariate summary: levels and smallest level ----------------------------
covariates$n_levels <- vapply(covariates$variable, function(v) if (v %in% cat_vars) nlevels(d[[v]]) else NA_integer_, 1L)
covariates$smallest_level_n <- vapply(covariates$variable, function(v) if (v %in% cat_vars) as.integer(min(table(d[[v]]))) else NA_integer_, 1L)
covariates$pct_missing_or_NA <- vapply(covariates$variable, function(v)
  round(100 * mean(!recorded[[v]]), 1), 1)
covariates$note <- ifelse(vapply(covariates$variable, function(v) length(unique(d[[v]])) < 2, TRUE),
                          "CONSTANT in training data - carries no information", "")
write.csv(covariates, file.path(out_dir, "fs_covariates.csv"), row.names = FALSE)

# Count of training cases in each category (for DATA_DICTIONARY.md): every category of
# covariates with up to 15 categories; for larger ones, the 10 rarest and 5 most common.
levels_tab <- do.call(rbind, lapply(cat_vars, function(v) {
  tab <- sort(table(d[[v]]), decreasing = TRUE)
  x <- data.frame(variable = v, value = names(tab), n_training = as.integer(tab),
                  pct = round(100 * as.integer(tab) / nrow(d), 2), stringsAsFactors = FALSE)
  if (nrow(x) <= 15) return(cbind(x, shown = "all categories"))
  rbind(cbind(head(x, 5), shown = "5 most common"), cbind(tail(x, 10), shown = "10 rarest"))
}))
write.csv(levels_tab, file.path(out_dir, "fs_levels.csv"), row.names = FALSE)

# ---- 4. Spearman matrix for the numeric covariates --------------------------------
if (length(num_vars) >= 2) {
  sp <- round(suppressWarnings(cor(d[num_vars], method = "spearman", use = "pairwise.complete.obs")), 3)
  write.csv(sp, file.path(out_dir, "fs_spearman_numeric.csv"))
}

# ---- 5. Every pair: association matrix and redundant pairs -------------------------
cat("Computing associations for every pair of covariates...\n")
vars <- covariates$variable
pairs <- t(combn(vars, 2))
res <- do.call(rbind, lapply(seq_len(nrow(pairs)), function(i) {
  a <- assoc(pairs[i, 1], pairs[i, 2])
  data.frame(var1 = pairs[i, 1], var2 = pairs[i, 2], measure = a[["measure"]], value = round(as.numeric(a[["value"]]), 3),
             n_both = as.integer(a[["n_both"]]))
}))
res <- res[order(-res$value), ]
write.csv(res, file.path(out_dir, "fs_association_matrix.csv"), row.names = FALSE)
high <- res[!is.na(res$value) & res$value >= assoc_threshold, ]
write.csv(high, file.path(out_dir, "fs_high_pairs.csv"), row.names = FALSE)
# also as a square matrix, for viewing
m <- matrix(NA_real_, length(vars), length(vars), dimnames = list(vars, vars)); diag(m) <- 1
for (i in seq_len(nrow(res))) m[res$var1[i], res$var2[i]] <- m[res$var2[i], res$var1[i]] <- res$value[i]
write.csv(m, file.path(out_dir, "fs_association_square.csv"))

# ---- 6. Each covariate vs duration (training cases that ended in court) ------------
# Missing labels stay in here as their own category: duration is never labelled, so the
# shared-label problem above can't arise, and "no FJC record" may itself relate to duration.
ended <- d$event_observed %in% TRUE
e <- d[ended, ]
y_log  <- log1p(e$duration_capped_days)
dv_measure <- function(v, keep) {               # keep = which ended cases to use
  x <- e[[v]][keep]
  if (v %in% num_vars) {                        # counts: Spearman is rank-based either way
    s <- round(abs(suppressWarnings(cor(x, e$duration_capped_days[keep], method = "spearman", use = "pairwise.complete.obs"))), 3)
    return(c(rank = s, log = s))
  }
  c(rank = round(eta(rank(e$duration_capped_days[keep]), x), 3), log = round(eta(y_log[keep], x), 3))
}
dv <- do.call(rbind, lapply(vars, function(v) {
  all_cases <- dv_measure(v, rep(TRUE, nrow(e))); rec <- recorded[[v]][ended]
  rec_cases <- dv_measure(v, rec)
  data.frame(variable = v,
             measure = if (v %in% num_vars) "|Spearman|" else "eta",
             rank_all = all_cases[["rank"]], rank_recorded = rec_cases[["rank"]],
             log_all = all_cases[["log"]], log_recorded = rec_cases[["log"]],
             n_ended = nrow(e), n_ended_recorded = sum(rec))
}))
dv <- merge(dv, covariates[, c("variable", "type", "leak", "n_levels")], by = "variable")
dv <- dv[order(-dv$rank_all), ]
write.csv(dv, file.path(out_dir, "fs_dv_association.csv"), row.names = FALSE)

# ---- Show the headlines -----------------------------------------------------------
cat(sprintf("\nPairs with association >= %.2f (possibly redundant - consider keeping one):\n", assoc_threshold))
if (nrow(high)) print(high, row.names = FALSE) else cat("  none\n")
cat("\nAssociation with duration (training cases that ended in court; strongest first by rank_all):\n")
cat("  _recorded = missing labels left out; a big drop from _all means the missing category drives it\n")
print(head(dv[, c("variable", "rank_all", "rank_recorded", "log_all", "log_recorded", "n_levels", "leak")], 25), row.names = FALSE)
constant <- covariates$variable[covariates$note != ""]
if (length(constant)) cat("\nConstant in training data (carry no information):", paste(constant, collapse = ", "), "\n")
cat("\nleak = 'leaky' marks covariates kept knowingly despite leakage (EXPLAINER section 7B).\n")
cat("Many-level variables (n_levels) look more predictive than they are.\n")
cat("All tables saved in", out_dir, "\n")
