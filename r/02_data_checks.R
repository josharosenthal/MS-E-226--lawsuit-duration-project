# =============================================================================
# 02_data_checks.R — every data check in one place. Run it before making the
# holdout split (03_holdout.R), and again whenever the data or covariates change.
#
# PART 1  SUMMARY - PASS / FLAG / INFO / OPEN lines, printed as it runs:
#         sample size; duplicates; covariates built, current and well matched;
#         duration coverage; related cases (MDL, consolidated); removed and
#         transferred cases (FJC ORIGIN) vs is_multi / is_mdl; cases that ended
#         by transfer or remand (counts only); decisions still open; software
#         versions. Saved as checks/presplit_report.txt and checks/presplit_*.csv.
# PART 2  DETAILED TABLES (R objects; duplicate reports always saved as CSV):
#         duplicates; FJC match rate; FJC and SCALES missing values;
#         SCALES-vs-FJC consistency; jurisdiction mapping; nature-of-suit
#         disagreements; class-action codes; duration coverage; FJC date check.
# PART 3  OPEN CASES, across ALL cases in cases.parquet (not just the sample):
#         how many weren't terminated when SCALES collected them, and what the
#         FJC file says happened to them later. Saved as checks/open_*.csv.
#
# Structure only: nothing here compares outcomes across groups of cases, so it
# is safe to run before the split. Uses the population set before sourcing
# (default "all", the current project). Most of the R objects (dup_report,
# fjc_missing, consistency, open_summary, ...) can be printed afterwards.
# Merged on 24 Oct 2026 from the former 01_data_checks.R, 05_open_cases.R and
# 07_presplit_checks.R.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)

# #############################################################################
# PART 1  SUMMARY
# #############################################################################
q <- function(sql) dbGetQuery(con, sql)
fmt <- function(x) format(x, big.mark = ",")
pct <- function(a, b) if (b == 0) "0%" else sprintf("%.1f%%", 100 * a / b)
report <- character(0)
say <- function(status, msg) { line <- sprintf("[%-5s] %s", status, msg); cat(line, "\n"); report <<- c(report, line) }
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("presplit_", name, ".csv")), row.names = FALSE)
has_features <- file.exists(features_file)
cat("\n================ PRE-SPLIT CHECKS: population \"", population, "\" ================\n", sep = "")

# ---- 1. Sample size and make-up ------------------------------------------------
cat("\n-- 1. Sample\n")
s1 <- q("SELECT count(*) AS n, count(*) FILTER (WHERE case_closed) AS closed,
                count(*) FILTER (WHERE NOT case_closed) AS open_at_collection,
                count(*) FILTER (WHERE year_dir = '16') AS y2016, count(*) FILTER (WHERE year_dir = '17') AS y2017
         FROM analysis_cases")
say("INFO", sprintf("%s cases: %s closed and %s open when SCALES collected them; %s from 2016, %s from 2017.",
                    fmt(s1$n), fmt(s1$closed), fmt(s1$open_at_collection), fmt(s1$y2016), fmt(s1$y2017)))
save_csv(s1, "sample")

# ---- 2. Duplicates -----------------------------------------------------------
cat("\n-- 2. Duplicates\n")
d2 <- q("SELECT (SELECT count(*) FROM analysis_cases_raw) - (SELECT count(*) FROM all_cases_dedup) AS removed,
                (SELECT count(*) - count(DISTINCT ucid) FROM all_cases_dedup) AS left_over,
                (SELECT count(*) FROM (SELECT fjc_row FROM best_link GROUP BY 1 HAVING count(*) > 1)) AS shared_fjc_records")
say(if (d2$left_over == 0) "PASS" else "FLAG",
    sprintf("%s duplicate rows removed; %s left in the sample; %s FJC records matched more than one case.",
            fmt(d2$removed), fmt(d2$left_over), fmt(d2$shared_fjc_records)))

# ---- 3. Covariates -------------------------------------------------------------
cat("\n-- 3. Covariates\n")
if (!has_features) {
  say("FLAG", "case_features.parquet not built: run 01_build_features.R, then re-run this script.")
} else {
  say(if (length(features_stale)) "FLAG" else "PASS",
      if (length(features_stale)) paste("Covariates may be OUT OF DATE (changed since built):", paste(features_stale, collapse = ", "))
      else "Covariates are built and up to date with their inputs.")
  feat_cols <- c("case_number_parity", "consolidation_role", "circuit", "diversity_residence", "county_area_class",
                 "judge_type", "first_plaintiff_type", "first_defendant_type",
                 "plaintiff_firm_cases", "defendant_firm_rank")
  # Missing values now carry labels (CHANGES.md 33), so count those labels as missing.
  missing_labels <- "('no FJC record', 'not recorded', 'county not recorded', 'unmatched county code', 'no judge listed',
                      'filing date missing', 'no plaintiff listed', 'no defendant listed', 'name not recorded')"
  miss <- do.call(rbind, lapply(feat_cols, function(cl) q(sprintf(
    "SELECT '%s' AS feature, round(100.0 * avg((%s IS NULL OR CAST(%s AS VARCHAR) IN %s)::INT), 1) AS pct_missing,
            round(100.0 * avg((CAST(%s AS VARCHAR) = 'no FJC record')::INT), 1) AS pct_no_fjc_record
     FROM analysis_cases", cl, cl, cl, missing_labels, cl))))
  save_csv(miss, "covariate_missing")
  hi <- miss[miss$pct_missing > 10, ]
  say(if (nrow(hi)) "FLAG" else "PASS",
      if (nrow(hi)) paste0("Covariates missing for over 10% of cases: ", paste0(hi$feature, " (", hi$pct_missing, "%)", collapse = ", "),
                           ". Missing values are labelled (e.g. 'no FJC record'); check whether that's enough.")
      else sprintf("No covariate is missing for more than 10%% of cases (largest: %s, %s%%). Missing values are labelled, not blank.",
                   miss$feature[which.max(miss$pct_missing)], max(miss$pct_missing)))
  j <- q("SELECT count(*) FILTER (WHERE judge_type IN ('senior', 'active')) AS matched,
                 count(*) FILTER (WHERE judge_type = 'appointed after filing') AS after_filing,
                 count(*) FILTER (WHERE judge_type = 'magistrate') AS magistrate,
                 count(*) FILTER (WHERE judge_type = 'territorial court') AS territorial,
                 count(*) FILTER (WHERE judge_type = 'unassigned') AS unassigned,
                 count(*) FILTER (WHERE judge_type = 'not matched') AS not_matched,
                 count(*) FILTER (WHERE judge_type IS NOT NULL AND judge_type <> 'unassigned') AS with_judge,
                 count(*) FILTER (WHERE judge_visiting) AS visiting
          FROM analysis_cases")
  say(if (j$not_matched > 0.10 * j$with_judge) "FLAG" else "PASS",
      sprintf("Judges (cases with an assigned judge): %s matched to the FJC directory (%s visiting from another court), %s appointed after filing, %s magistrate, %s territorial court, %s not matched. See features_report_judges_not_matched.csv.",
              pct(j$matched, j$with_judge), fmt(j$visiting), fmt(j$after_filing), fmt(j$magistrate), fmt(j$territorial), fmt(j$not_matched)))
  say("INFO", sprintf("Judge 'unassigned': %s cases; 'appointed after filing': %s. Both mostly reflect what happened later in the case (ended before assignment; reassigned to a newer judge), so they partly leak duration.",
                      fmt(j$unassigned), fmt(j$after_filing)))
  cty <- q("SELECT count(*) FILTER (WHERE county_area_class = 'unmatched county code') AS unmatched,
                   count(*) FILTER (WHERE county_area_class IS NOT NULL) AS with_county FROM analysis_cases")
  say(if (cty$unmatched > 0.05 * cty$with_county) "FLAG" else "PASS",
      sprintf("County codes not found in the NCHS (FIPS) list: %s of cases with a county code. If high, the FJC codes may not be FIPS.",
              pct(cty$unmatched, cty$with_county)))
  big <- q("SELECT count(*) FILTER (WHERE defendant_firm_rank LIKE 'rank%' OR defendant_firm_rank LIKE 'large-firm%') AS big,
                   count(*) FILTER (WHERE defendant_firm_rank NOT IN ('no counsel listed')) AS with_counsel FROM analysis_cases")
  say("INFO", sprintf("Defendant's lead attorney matched to a large firm in %s of cases with defendant counsel. Spot-check features_report_defendant_big_firm_matches.csv.",
                      pct(big$big, big$with_counsel)))
}

# ---- 4. Dependent variable coverage ------------------------------------------------
cat("\n-- 4. Duration (dependent variable)\n")
dv <- q("SELECT duration_status, count(*) AS n FROM analysis_fjc GROUP BY 1 ORDER BY 2 DESC")
save_csv(dv, "duration_status")
has_value <- c("ended", "longer_than_cap", "transferred_out")
n_dv <- sum(dv$n[dv$duration_status %in% has_value]); n_all <- sum(dv$n)
no_dv <- dv[!dv$duration_status %in% has_value, ]
say(if (n_all - n_dv > 0.05 * n_all) "FLAG" else "PASS",
    sprintf("Duration available for %s of cases (%s). Without a value: %s.", pct(n_dv, n_all), fmt(n_dv),
            if (nrow(no_dv)) paste0(no_dv$duration_status, " ", fmt(no_dv$n), collapse = ", ") else "none"))
cens <- q("SELECT count(*) FILTER (WHERE event_observed) AS ended_here,
                  count(*) FILTER (WHERE duration_status = 'longer_than_cap') AS overlong,
                  count(*) FILTER (WHERE duration_status = 'transferred_out') AS transferred
           FROM analysis_fjc")
say("INFO", sprintf("Of cases with a duration: %s ended in this court (event_observed); censored: %s overlong, %s transferred out (duration = time until transfer).",
                    fmt(cens$ended_here), fmt(cens$overlong), fmt(cens$transferred)))
fd <- q(sprintf("SELECT max(fjc_termdate) AS latest, count(*) FILTER (WHERE fjc_termdate > DATE '%s') AS later
                 FROM '%s/scales_fjc_link.parquet'", format(fjc_data_through), pq))
say(if (fd$later == 0) "PASS" else "FLAG",
    sprintf("Latest FJC termination date %s; %s later than the cap date setting (%s).", format(fd$latest), fmt(fd$later), format(fjc_data_through)))

# ---- 5. Related cases ------------------------------------------------------------
cat("\n-- 5. Related cases (MDL members excluded; split drawn by consolidation group)\n")
excl <- q("SELECT count(*) AS non_habeas, count(*) FILTER (WHERE is_mdl_any) AS mdl,
                  count(*) FILTER (WHERE scales_mdl AND fjc_mdl) AS both,
                  count(*) FILTER (WHERE scales_mdl AND NOT fjc_mdl) AS scales_only,
                  count(*) FILTER (WHERE fjc_mdl AND NOT scales_mdl) AS fjc_only
           FROM mdl_flagged")
say("INFO", sprintf("MDL member cases EXCLUDED from the sample: %s of %s non-habeas civil cases (%s). Flagged by SCALES and FJC %s, SCALES only %s, FJC only %s - the FJC 'MDL originating here' code only began July 2016, so neither source is complete alone.",
                    fmt(excl$mdl), fmt(excl$non_habeas), pct(excl$mdl, excl$non_habeas), fmt(excl$both), fmt(excl$scales_only), fmt(excl$fjc_only)))
top_mdl <- q("SELECT n.mdl_code, count(*) AS n_cases FROM non_habeas_cases n WHERE n.is_mdl GROUP BY 1 ORDER BY 2 DESC LIMIT 10")
save_csv(top_mdl, "top_mdls_excluded")
xo <- q("SELECT count(*) FILTER (WHERE mdl_transfer_out AND NOT is_mdl_any) AS mdl_transfer_out FROM mdl_flagged")
say("INFO", sprintf("Cases that ENDED by MDL transfer out (FJC DISP 10) also EXCLUDED: %s more (sent to an MDL court, so not a real ending here).",
                    fmt(xo$mdl_transfer_out)))
ov <- q("SELECT count(*) AS n FROM case_duration WHERE duration_status = 'longer_than_cap'")$n
say("INFO", sprintf("OVERLONG cases EXCLUDED from the sample: %s (lasted, or were still pending, beyond the %s-day cap). This selects on the outcome: results describe cases resolved within about 8.5 years.",
                    fmt(ov), fmt(duration_cap_days)))
nofjc <- q("SELECT count(*) AS n FROM all_cases_dedup
             WHERE ucid NOT IN (SELECT ucid FROM case_duration WHERE duration_status = 'longer_than_cap')
               AND ucid NOT IN (SELECT ucid FROM best_link_unique)")$n
say("INFO", sprintf("Cases with NO FJC record EXCLUDED from the sample: %s (mostly administrative case numbers closed within days - see 02-a_data_checks_fjc.R; Josh, 24 Oct 2026, after the split). Results describe cases with an FJC record.",
                    fmt(nofjc)))
if (file.exists(split_file)) {
  # The split was made before this exclusion. Check the same rule removed cases from
  # both sides in proportion (counts only - no outcomes).
  # (only cases still in the sample before this rule - cases removed by other rules,
  # e.g. habeas nature of suit, have no FJC link either and must not be counted here)
  bal <- q("WITH s AS (SELECT h.ucid, h.is_holdout, h.ucid IN (SELECT ucid FROM best_link_unique) AS has_fjc,
                              h.ucid IN (SELECT ucid FROM all_cases_dedup) AS still_in
                       FROM holdout_split h)
            SELECT is_holdout, count(*) AS in_split, count(*) FILTER (WHERE still_in AND NOT has_fjc) AS dropped_no_fjc
            FROM s GROUP BY 1 ORDER BY 1")
  bal$pct_dropped <- round(100 * bal$dropped_no_fjc / bal$in_split, 2)
  save_csv(bal, "no_fjc_split_balance")
  by_year <- q("SELECT year_dir, round(100 * avg(is_holdout::INT), 2) AS pct_holdout, count(*) AS n
                FROM analysis_cases GROUP BY 1 ORDER BY 1")
  tr <- bal[!bal$is_holdout, ]; ho <- bal[bal$is_holdout, ]
  share_now <- q("SELECT avg(is_holdout::INT) AS s FROM analysis_cases")$s
  diff_pts <- abs(tr$pct_dropped - ho$pct_dropped)
  say(if (diff_pts < 0.3 && abs(share_now - 0.2) < 0.005) "PASS" else "FLAG",
      sprintf("No-FJC exclusion vs the split: dropped %s of %s training cases (%s%%) and %s of %s holdout cases (%s%%). Holdout share now %.2f%% (by year: %s).",
              fmt(tr$dropped_no_fjc), fmt(tr$in_split), tr$pct_dropped, fmt(ho$dropped_no_fjc), fmt(ho$in_split), ho$pct_dropped,
              100 * share_now, paste0("20", by_year$year_dir, " ", by_year$pct_holdout, "%", collapse = ", ")))
  # Nature-of-suit exclusions (habeas / prisoner codes the cause rules miss), changes 50, 54, 55.
  # Balance test: a two-proportion z-test of the share removed from training vs holdout.
  # |z| > 3 is FLAGged - a random split rarely gives that by chance (the grouped split makes
  # chance differences slightly larger than the test assumes). Counts only, no outcomes.
  ztest <- function(k_tr, n_tr, k_ho, n_ho) {
    p <- (k_tr + k_ho) / (n_tr + n_ho)
    if (p == 0 || p == 1) return(0)
    (k_tr / n_tr - k_ho / n_ho) / sqrt(p * (1 - p) * (1 / n_tr + 1 / n_ho))
  }
  # (a) codes already APPLIED (exclude_nos_codes): every split case passed the cause rules,
  #     so a split case no longer in non_habeas_cases was removed by these codes
  hab <- q("SELECT h.is_holdout, regexp_extract(c.nature_suit, '^\\s*([0-9]{3})', 1) AS nos_code, count(*) AS n
            FROM holdout_split h JOIN civil_cases c USING (ucid)
            WHERE h.ucid NOT IN (SELECT ucid FROM non_habeas_cases)
            GROUP BY ALL ORDER BY 2, 1")
  save_csv(hab, "nos_applied_split_balance")
  hab_tr <- sum(hab$n[!hab$is_holdout]); hab_ho <- sum(hab$n[hab$is_holdout])
  z <- ztest(hab_tr, tr$in_split, hab_ho, ho$in_split)
  say(if (abs(z) <= 3) "PASS" else "FLAG",
      sprintf("Nature-of-suit exclusion APPLIED (%s): removed %s training (%.2f%%) and %s holdout cases (%.2f%%); z = %.2f.",
              if (length(exclude_nos_codes)) paste(exclude_nos_codes, collapse = ", ") else "none",
              fmt(hab_tr), 100 * hab_tr / tr$in_split, fmt(hab_ho), 100 * hab_ho / ho$in_split, z))
  # (b) CANDIDATE codes not yet applied: what excluding each would remove from the current
  #     sample, by side, before deciding. Also the habeas group, the prisoner group and all.
  pending <- setdiff(candidate_nos_codes, exclude_nos_codes)
  if (length(pending)) {
    cnt <- q(sprintf("SELECT is_holdout, regexp_extract(nature_suit, '^\\s*([0-9]{3})', 1) AS nos_code, count(*) AS n
                      FROM analysis_cases WHERE regexp_extract(nature_suit, '^\\s*([0-9]{3})', 1) IN (%s)
                      GROUP BY ALL", paste0("'", pending, "'", collapse = ", ")))
    tot <- q("SELECT is_holdout, count(*) AS n FROM analysis_cases GROUP BY 1")
    n_tr <- tot$n[!tot$is_holdout]; n_ho <- tot$n[tot$is_holdout]
    groups <- c(setNames(as.list(pending), pending),
                list("habeas codes (463, 510, 530, 535)"         = intersect(pending, c("463", "510", "530", "535")),
                     "prisoner codes (540, 550, 555, 560)"        = intersect(pending, c("540", "550", "555", "560")),
                     "ALL candidates"                              = pending))
    cand <- do.call(rbind, lapply(names(groups), function(g) {
      k_tr <- sum(cnt$n[!cnt$is_holdout & cnt$nos_code %in% groups[[g]]])
      k_ho <- sum(cnt$n[cnt$is_holdout & cnt$nos_code %in% groups[[g]]])
      data.frame(codes = g, training_removed = k_tr, pct_training = round(100 * k_tr / n_tr, 3),
                 holdout_removed = k_ho, pct_holdout = round(100 * k_ho / n_ho, 3),
                 z = round(ztest(k_tr, n_tr, k_ho, n_ho), 2))
    }))
    cand$balanced <- ifelse(abs(cand$z) <= 3, "yes", "NO - check")
    save_csv(cand, "nos_candidate_balance")
    all_row <- cand[cand$codes == "ALL candidates", ]
    say(if (all(abs(cand$z) <= 3)) "INFO" else "FLAG",
        sprintf("Nature-of-suit CANDIDATE exclusions (not applied): all %s codes together would remove %s training (%.2f%%) and %s holdout cases (%.2f%%), z = %.2f; %s of %s code groups balanced (|z| <= 3). Table: presplit_nos_candidate_balance.csv.",
                length(pending), fmt(all_row$training_removed), all_row$pct_training, fmt(all_row$holdout_removed),
                all_row$pct_holdout, all_row$z, sum(abs(cand$z) <= 3), nrow(cand)))
    print(cand, row.names = FALSE)
  }
}
# Cases dropped for missing data (00_sample.R section 5b; change 76): jury demand blank, and
# no plaintiff found in the party table, case name or FJC. Same rule on both sides of the split.
if (file.exists(split_file) && "population_drops" %in% dbListTables(con)) {
  pd <- q("SELECT d.reason, a.is_holdout, count(*) AS n FROM population_drops d JOIN analysis_cases_all a USING (ucid)
           WHERE a.is_holdout IS NOT NULL GROUP BY ALL")
  if (nrow(pd)) {
    all_n <- q("SELECT is_holdout, count(*) AS n FROM analysis_cases_all WHERE is_holdout IS NOT NULL GROUP BY 1")
    n_tr0 <- all_n$n[!all_n$is_holdout]; n_ho0 <- all_n$n[all_n$is_holdout]
    pdt <- do.call(rbind, lapply(c(unique(pd$reason), "ALL"), function(r) {
      x <- if (r == "ALL") pd else pd[pd$reason == r, ]
      k_tr <- sum(x$n[!x$is_holdout]); k_ho <- sum(x$n[x$is_holdout])
      data.frame(reason = r, training_removed = k_tr, pct_training = round(100 * k_tr / n_tr0, 3),
                 holdout_removed = k_ho, pct_holdout = round(100 * k_ho / n_ho0, 3),
                 z = round(ztest(k_tr, n_tr0, k_ho, n_ho0), 2))
    }))
    pdt$balanced <- ifelse(abs(pdt$z) <= 3, "yes", "NO - check")
    save_csv(pdt, "missing_data_drops_balance")
    a <- pdt[pdt$reason == "ALL", ]
    say(if (all(abs(pdt$z) <= 3)) "PASS" else "FLAG",
        sprintf("Dropped for missing data (jury demand blank; no plaintiff found): %s training (%.2f%%) and %s holdout cases (%.2f%%), z = %.2f. Table: presplit_missing_data_drops_balance.csv.",
                fmt(a$training_removed), a$pct_training, fmt(a$holdout_removed), a$pct_holdout, a$z))
    print(pdt, row.names = FALSE)
  }
}
left_mdl <- q("SELECT count(*) AS n FROM analysis_cases WHERE coalesce(is_mdl, false)")$n
say(if (left_mdl == 0) "PASS" else "FLAG", sprintf("MDL cases left in the sample: %s (should be 0).", fmt(left_mdl)))
rel <- q("SELECT count(*) AS n, count(*) FILTER (WHERE is_multi) AS multi,
                 count(*) FILTER (WHERE nullif(trim(CAST(lead_case_id AS VARCHAR)), '') IS NOT NULL) AS with_lead
          FROM analysis_cases")
if (has_features) {
  cons <- q("SELECT consolidation_role, count(*) AS n FROM analysis_cases GROUP BY 1 ORDER BY 2 DESC")
  save_csv(cons, "consolidation_roles")
  say("INFO", sprintf("Consolidated cases in the sample: %s (%s). 03_holdout.R keeps each lead case and its members on the same side of the split.",
                      paste0(cons$consolidation_role, " ", fmt(cons$n), collapse = ", "), pct(sum(cons$n[cons$consolidation_role != "not consolidated"]), sum(cons$n))))
}
overlap <- q("SELECT coalesce(is_multi, false) AS is_multi,
                     nullif(trim(CAST(lead_case_id AS VARCHAR)), '') IS NOT NULL AS has_lead_case, count(*) AS n
              FROM analysis_cases GROUP BY ALL ORDER BY n DESC")
save_csv(overlap, "related_case_overlap")
say("INFO", sprintf("is_multi: %s cases (%s); with a lead case listed: %s. (is_multi flags any docket referring to another case number - removal/transfer origins, lead cases - so it is NOT used as a covariate; see CHANGES.md 31.)",
                    fmt(rel$multi), pct(rel$multi, rel$n), fmt(rel$with_lead)))

# ---- 6. Removed and transferred cases -------------------------------------------
cat("\n-- 6. Removed and transferred cases\n")
origin_sql <- "CASE trim(ORIGIN) WHEN '1' THEN '1 original filing' WHEN '2' THEN '2 removed from state court'
      WHEN '3' THEN '3 remanded from court of appeals' WHEN '4' THEN '4 reinstated/reopened'
      WHEN '5' THEN '5 transferred from another district' WHEN '6' THEN '6 MDL transfer in'
      WHEN '7' THEN '7 appeal from magistrate judge' WHEN '13' THEN '13 MDL originating here'
      WHEN '8' THEN '8-12 later reopen' WHEN '9' THEN '8-12 later reopen' WHEN '10' THEN '8-12 later reopen'
      WHEN '11' THEN '8-12 later reopen' WHEN '12' THEN '8-12 later reopen'
      ELSE coalesce('other/missing: ' || trim(ORIGIN), 'no FJC record') END"
by_origin <- q(sprintf("SELECT %s AS how_case_arrived, count(*) AS n_cases,
                               count(*) FILTER (WHERE is_multi) AS is_multi,
                               count(*) FILTER (WHERE is_mdl) AS is_mdl,
                               count(*) FILTER (WHERE nullif(trim(CAST(lead_case_id AS VARCHAR)), '') IS NOT NULL) AS has_lead_case,
                               count(*) FILTER (WHERE coalesce(trim(CAST(other_courts_json AS VARCHAR)), '') NOT IN ('', '[]')) AS lists_other_courts
                        FROM analysis_fjc GROUP BY 1 ORDER BY 2 DESC", origin_sql))
save_csv(by_origin, "origin_vs_multi")
print(by_origin, row.names = FALSE)
o <- function(lbl) { x <- by_origin[by_origin$how_case_arrived == lbl, ]; if (nrow(x)) x else data.frame(n_cases = 0, is_multi = 0, is_mdl = 0) }
rem <- o("2 removed from state court"); tin <- o("5 transferred from another district"); mdl_in <- o("6 MDL transfer in")
say("INFO", sprintf("Removed from state court: %s cases, %s of them flagged is_multi. Transferred in: %s (%s is_multi). MDL transfer in: %s (%s is_multi).",
                    fmt(rem$n_cases), pct(rem$is_multi, rem$n_cases), fmt(tin$n_cases), pct(tin$is_multi, tin$n_cases),
                    fmt(mdl_in$n_cases), pct(mdl_in$is_multi, mdl_in$n_cases)))
multi_rows <- by_origin[by_origin$is_multi > 0, ]
say("INFO", sprintf("Of the %s is_multi cases, by how they arrived: %s.", fmt(sum(by_origin$is_multi)),
                    paste0(multi_rows$how_case_arrived, " ", pct(multi_rows$is_multi, sum(by_origin$is_multi)), collapse = "; ")))
# Ended by transfer or remand: an OUTCOME (DISP), so overall counts only - not compared with any covariate.
ended_away <- q("SELECT CASE trim(DISP) WHEN '0' THEN 'transferred to another district' WHEN '1' THEN 'remanded to state court'
                                        WHEN '10' THEN 'MDL transfer out' WHEN '11' THEN 'remanded to U.S. agency' END AS ended_by,
                        count(*) AS n_cases
                 FROM analysis_fjc WHERE trim(DISP) IN ('0', '1', '10', '11') GROUP BY 1 ORDER BY 2 DESC")
save_csv(ended_away, "ended_by_transfer_or_remand")
say("INFO", sprintf("Cases that ENDED by transfer or remand: %s - %s. Transfers out (DISP 0, 10) are censored in the duration variable; remands count as endings.",
                    fmt(sum(ended_away$n_cases)), if (nrow(ended_away)) paste0(ended_away$ended_by, " ", fmt(ended_away$n_cases), collapse = ", ") else "none"))

# ---- 7. Decisions still open -----------------------------------------------------
cat("\n-- 7. Decisions to settle before the split\n")
pend <- q(sprintf("SELECT count(*) AS n FROM analysis_fjc WHERE duration_status = 'pending_short_followup'"))$n
say(if (pend > 0) "FLAG" else "PASS", sprintf("Cap start date %s (cap %s days, Josh's choice). Cases with pending_short_followup (followed less than the cap): %s.",
                    format(duration_cap_start), fmt(duration_cap_days), fmt(pend)))
say("INFO", "Split design (Josh, 24 Oct 2026): MDL members excluded from the sample; 03_holdout.R draws 20% of consolidation groups.")
say("INFO", "Cases without a duration value (unknown_end, end_before_start, no_filing_date, pending_short_followup) are LEFT OUT of the duration analysis (Josh, 24 Oct 2026).")
if (file.exists(split_file)) say("INFO", paste("A holdout split already exists for this population:", basename(split_file)))

# ---- 8. Software versions ----------------------------------------------------------
cat("\n-- 8. Software versions\n")
duck_v <- q("SELECT version() AS v")$v
info <- c(paste("Recorded", format(Sys.time(), "%Y-%m-%d %H:%M %Z")), R.version.string,
          paste("duckdb R package", as.character(packageVersion("duckdb")), "- DuckDB engine", duck_v),
          capture.output(sessionInfo()))
writeLines(info, file.path(checks_dir, "presplit_session_info.txt"))
say("INFO", sprintf("%s; duckdb package %s. Full details saved to presplit_session_info.txt.", R.version.string, as.character(packageVersion("duckdb"))))

writeLines(report, file.path(checks_dir, "presplit_report.txt"))
cat("\nSaved presplit_report.txt and presplit_*.csv in", checks_dir, "\n")
cat("FLAG and OPEN lines need a decision or a look before running 03_holdout.R.\n")
cat("Building the detailed tables (Parts 2 and 3)...\n")

# #############################################################################
# PART 2  DETAILED TABLES
# #############################################################################
# =============================================================================
# 0. DUPLICATES: what 00_sample.R found and removed
# =============================================================================
dup_report <- dbGetQuery(con, "
  SELECT
    (SELECT count(*) FROM analysis_cases_raw)                         AS rows_before,
    (SELECT count(DISTINCT ucid) FROM analysis_cases_raw)             AS distinct_ucids,
    (SELECT count(*) - count(DISTINCT ucid) FROM analysis_cases_raw)  AS extra_rows_with_same_ucid,
    (SELECT count(*) FROM (SELECT case_number_key FROM analysis_cases_keyed
                           GROUP BY 1 HAVING count(DISTINCT ucid) > 1)) AS case_numbers_with_several_ucids,
    (SELECT count(*) FROM analysis_cases_raw) - (SELECT count(*) FROM all_cases_dedup) AS rows_removed,
    (SELECT count(*) FROM all_cases_dedup)                            AS rows_after,
    (SELECT count(*) FROM (SELECT fjc_row FROM best_link GROUP BY 1 HAVING count(*) > 1))
                                                                      AS fjc_records_matching_several_cases,
    (SELECT count(*) FROM best_link
      WHERE fjc_row IN (SELECT fjc_row FROM best_link GROUP BY 1 HAVING count(*) > 1))
                                                                      AS cases_whose_fjc_data_was_blanked,
    (SELECT count(*) - count(DISTINCT ucid) FROM all_cases_dedup)     AS duplicate_rows_left_in_final_table")
dup_report
# duplicate_rows_left_in_final_table should be 0.

# The duplicate groups themselves (first 20), to see what kind of duplicates they are.
dup_examples <- dbGetQuery(con, "
  SELECT case_number_key, ucid, archive_path, n_docket_entries, filing_date, download_timestamp
  FROM analysis_cases_keyed
  WHERE case_number_key IN (SELECT case_number_key FROM analysis_cases_keyed GROUP BY 1 HAVING count(*) > 1)
  ORDER BY case_number_key, ucid LIMIT 20")
dup_examples

# Every duplicate group (not just the first 20), with which row was kept.
dup_all <- dbGetQuery(con, "
  SELECT k.case_number_key, k.ucid, k.archive_path, k.n_docket_entries, k.filing_date,
         k.download_timestamp, (k.ucid, k.archive_path) IN (SELECT (ucid, archive_path) FROM all_cases_dedup) AS kept
  FROM analysis_cases_keyed k
  WHERE k.case_number_key IN (SELECT case_number_key FROM analysis_cases_keyed GROUP BY 1 HAVING count(*) > 1)
  ORDER BY k.case_number_key, kept DESC, k.ucid")

# FJC records that were the best match for more than one case (their FJC data was blanked).
dup_fjc <- dbGetQuery(con, "
  SELECT fjc_row, ucid FROM best_link
  WHERE fjc_row IN (SELECT fjc_row FROM best_link GROUP BY 1 HAVING count(*) > 1)
  ORDER BY fjc_row, ucid")

write.csv(dup_report, file.path(checks_dir, "duplicates_summary.csv"),          row.names = FALSE)
write.csv(dup_all,    file.path(checks_dir, "duplicates_all_groups.csv"),       row.names = FALSE)
write.csv(dup_fjc,    file.path(checks_dir, "duplicates_shared_fjc_records.csv"), row.names = FALSE)
cat(sprintf("Saved duplicate reports to %s (%d duplicate rows, %d shared FJC records)\n",
            checks_dir, nrow(dup_all), length(unique(dup_fjc$fjc_row))))

# =============================================================================
# A. HOW MANY CASES HAVE AN FJC RECORD AT ALL
# =============================================================================
match_rate <- dbGetQuery(con, "
  SELECT count(*) AS n_cases,
         count(fjc_row) AS matched,
         count(*) - count(fjc_row) AS not_matched,
         round(100.0 * count(fjc_row) / count(*), 1) AS pct_matched,
         count(*) FILTER (WHERE n_fjc_matches > 1) AS matched_more_than_once
  FROM analysis_fjc")
match_rate

# =============================================================================
# B. MISSING VALUES IN THE FJC FIELDS (matched cases only)
# The FJC codes missing values as -8 rather than leaving them blank, and some
# fields only apply to some cases (codebook rules):
#   JUDGMENT, NOJ   only when the case ended in a judgment (DISP 4-9, 15-17)
#   TRCLACT         only when CLASSACT = 1 (a class action was alleged)
#   (An empty field counts as "not applicable" in those cases. If the field
#   HAS a value anyway, it counts as present - see the class-action table in D.)
#   fjc_termdate    blank is expected for pending cases (STATUSCD = 'S')
#   IFP             -8 means "not in forma pauperis" - a real value, not missing
#   JUDGMENT        0 also means missing
#   AMTREC          the FJC advises against using it even when filled in
# =============================================================================
fjc_missing <- dbGetQuery(con, "
  WITH wide AS (
    SELECT ucid, DISP AS disp_code, CLASSACT AS classact_code, STATUSCD AS status_code,
           COLUMNS(c -> c IN ('ORIGIN','JURIS','NOS','CLASSACT','TRCLACT','PROCPROG','DISP',
                              'NOJ','AMTREC','JUDGMENT','PROSE','IFP','STATUSCD'))::VARCHAR,
           fjc_filedate::VARCHAR AS fjc_filedate,
           fjc_termdate::VARCHAR AS fjc_termdate
    FROM analysis_fjc WHERE fjc_row IS NOT NULL),
  long AS (
    SELECT * FROM wide
    UNPIVOT INCLUDE NULLS (val FOR field IN (COLUMNS(* EXCLUDE (ucid, disp_code, classact_code, status_code))))),
  s AS (
    SELECT field, CASE
      WHEN field IN ('NOJ', 'JUDGMENT')
           AND coalesce(disp_code, '') NOT IN ('4','5','6','7','8','9','15','16','17')
           AND (val IS NULL OR trim(val) IN ('', '-8', '0'))                THEN 'not_applicable'
      WHEN field = 'TRCLACT' AND coalesce(classact_code, '') <> '1'
           AND (val IS NULL OR trim(val) IN ('', '-8'))                     THEN 'not_applicable'
      WHEN field = 'fjc_termdate' AND status_code = 'S' AND val IS NULL     THEN 'not_applicable'
      WHEN val IS NULL OR trim(val) = ''                                    THEN 'blank'
      WHEN field = 'IFP'                                                    THEN 'present'
      WHEN val = '-8' OR (field = 'JUDGMENT' AND val = '0')                 THEN 'coded_missing'
      ELSE 'present' END AS status
    FROM long)
  SELECT field, count(*) AS n_matched,
         round(100.0 * count(*) FILTER (WHERE status = 'present')        / count(*), 1) AS pct_present,
         round(100.0 * count(*) FILTER (WHERE status = 'coded_missing')  / count(*), 1) AS pct_coded_missing,
         round(100.0 * count(*) FILTER (WHERE status = 'blank')          / count(*), 1) AS pct_blank,
         round(100.0 * count(*) FILTER (WHERE status = 'not_applicable') / count(*), 1) AS pct_not_applicable
  FROM s GROUP BY field ORDER BY pct_present")
fjc_missing

# =============================================================================
# C. MISSING VALUES IN THE SCALES FIELDS (every column of the sample)
# Missing = NULL, blank text, or an empty list ("[]").
# =============================================================================
scales_missing <- dbGetQuery(con, "
  WITH wide AS (SELECT ucid, COLUMNS(* EXCLUDE (ucid))::VARCHAR FROM analysis_cases),
  long AS (SELECT * FROM wide UNPIVOT INCLUDE NULLS (val FOR field IN (COLUMNS(* EXCLUDE (ucid)))))
  SELECT field,
         round(100.0 * avg((val IS NULL OR trim(val) IN ('', '[]'))::INT), 1) AS pct_missing
  FROM long GROUP BY field ORDER BY pct_missing DESC")
scales_missing

# =============================================================================
# D. CONSISTENCY: DO SCALES AND THE FJC AGREE WHERE BOTH HAVE THE FIELD?
# (matched cases only)
#   nature of suit   3-digit code in SCALES nature_suit vs FJC NOS
#   jurisdiction     SCALES text mapped to FJC codes: 1 US gov't plaintiff,
#                    2 US gov't defendant, 3 federal question, 4 diversity, 5 local
#   filing date      SCALES filing_date vs FJC FILEDATE
#   termination date SCALES terminating_date vs FJC TERMDATE. These can differ
#                    for real reasons: SCALES is a snapshot from 2020-21, the
#                    FJC file runs to 2026, and reopened cases get new dates.
# For dates, pct_within_7_days allows for clerical lags.
# =============================================================================
consistency <- dbGetQuery(con, "
  WITH a AS (
    SELECT
      NULLIF(regexp_extract(nature_suit, '([0-9]{3})', 1), '') AS s_nos,
      CASE WHEN trim(NOS) IN ('', '-8') THEN NULL ELSE trim(NOS) END AS f_nos,
      CASE WHEN jurisdiction ILIKE '%plaintiff%'        THEN '1'
           WHEN jurisdiction ILIKE '%defendant%'        THEN '2'
           WHEN jurisdiction ILIKE '%federal question%' THEN '3'
           WHEN jurisdiction ILIKE '%diversity%'        THEN '4'
           WHEN jurisdiction ILIKE '%local%'            THEN '5' END AS s_juris,
      CASE WHEN trim(JURIS) IN ('1','2','3','4','5') THEN trim(JURIS) END AS f_juris,
      filing_date AS s_file, fjc_filedate AS f_file,
      terminating_date AS s_term, fjc_termdate AS f_term
    FROM analysis_fjc WHERE fjc_row IS NOT NULL)
  SELECT 'nature of suit' AS check_item,
         count(*) FILTER (WHERE s_nos IS NOT NULL AND f_nos IS NOT NULL) AS n_both_present,
         round(100.0 * count(*) FILTER (WHERE s_nos = f_nos)
               / nullif(count(*) FILTER (WHERE s_nos IS NOT NULL AND f_nos IS NOT NULL), 0), 1) AS pct_agree,
         NULL::DOUBLE AS pct_within_7_days,
         count(*) FILTER (WHERE s_nos IS NOT NULL AND f_nos IS NULL) AS n_scales_only,
         count(*) FILTER (WHERE s_nos IS NULL AND f_nos IS NOT NULL) AS n_fjc_only,
         count(*) FILTER (WHERE s_nos IS NULL AND f_nos IS NULL)     AS n_neither
  FROM a
  UNION ALL
  SELECT 'jurisdiction',
         count(*) FILTER (WHERE s_juris IS NOT NULL AND f_juris IS NOT NULL),
         round(100.0 * count(*) FILTER (WHERE s_juris = f_juris)
               / nullif(count(*) FILTER (WHERE s_juris IS NOT NULL AND f_juris IS NOT NULL), 0), 1),
         NULL,
         count(*) FILTER (WHERE s_juris IS NOT NULL AND f_juris IS NULL),
         count(*) FILTER (WHERE s_juris IS NULL AND f_juris IS NOT NULL),
         count(*) FILTER (WHERE s_juris IS NULL AND f_juris IS NULL)
  FROM a
  UNION ALL
  SELECT 'filing date',
         count(*) FILTER (WHERE s_file IS NOT NULL AND f_file IS NOT NULL),
         round(100.0 * count(*) FILTER (WHERE s_file = f_file)
               / nullif(count(*) FILTER (WHERE s_file IS NOT NULL AND f_file IS NOT NULL), 0), 1),
         round(100.0 * count(*) FILTER (WHERE abs(date_diff('day', s_file, f_file)) <= 7)
               / nullif(count(*) FILTER (WHERE s_file IS NOT NULL AND f_file IS NOT NULL), 0), 1),
         count(*) FILTER (WHERE s_file IS NOT NULL AND f_file IS NULL),
         count(*) FILTER (WHERE s_file IS NULL AND f_file IS NOT NULL),
         count(*) FILTER (WHERE s_file IS NULL AND f_file IS NULL)
  FROM a
  UNION ALL
  SELECT 'termination date',
         count(*) FILTER (WHERE s_term IS NOT NULL AND f_term IS NOT NULL),
         round(100.0 * count(*) FILTER (WHERE s_term = f_term)
               / nullif(count(*) FILTER (WHERE s_term IS NOT NULL AND f_term IS NOT NULL), 0), 1),
         round(100.0 * count(*) FILTER (WHERE abs(date_diff('day', s_term, f_term)) <= 7)
               / nullif(count(*) FILTER (WHERE s_term IS NOT NULL AND f_term IS NOT NULL), 0), 1),
         count(*) FILTER (WHERE s_term IS NOT NULL AND f_term IS NULL),
         count(*) FILTER (WHERE s_term IS NULL AND f_term IS NOT NULL),
         count(*) FILTER (WHERE s_term IS NULL AND f_term IS NULL)
  FROM a")
consistency

# Check the jurisdiction mapping: every SCALES jurisdiction text and the code it
# was mapped to. Rows with mapped_code = NA weren't mapped; if a common one
# appears, the CASE lines in D need another pattern.
juris_mapping <- dbGetQuery(con, "
  SELECT jurisdiction,
         CASE WHEN jurisdiction ILIKE '%plaintiff%'        THEN '1'
              WHEN jurisdiction ILIKE '%defendant%'        THEN '2'
              WHEN jurisdiction ILIKE '%federal question%' THEN '3'
              WHEN jurisdiction ILIKE '%diversity%'        THEN '4'
              WHEN jurisdiction ILIKE '%local%'            THEN '5' END AS mapped_code,
         count(*) AS n_cases
  FROM analysis_cases GROUP BY 1, 2 ORDER BY 3 DESC")
juris_mapping

# Class-action fields: every combination of CLASSACT (class action alleged at
# filing: 1 = yes, -8 = missing / not alleged) and TRCLACT (certification at
# termination: 2 = denied, 3 = granted, -8 = missing), matched cases only.
# The codebook says TRCLACT should only be filled in when CLASSACT = 1, so
# combinations like CLASSACT -8 with TRCLACT 2 or 3 are inconsistencies, and
# any code other than those listed is undocumented.
class_action_codes <- dbGetQuery(con, "
  SELECT coalesce(nullif(trim(CLASSACT), ''), '(blank)') AS CLASSACT,
         coalesce(nullif(trim(TRCLACT), ''), '(blank)')  AS TRCLACT,
         CASE WHEN trim(CLASSACT) = '1' AND trim(TRCLACT) = '3' THEN 'alleged; certification granted'
              WHEN trim(CLASSACT) = '1' AND trim(TRCLACT) = '2' THEN 'alleged; certification denied'
              WHEN trim(CLASSACT) = '1'                          THEN 'alleged; no certification ruling recorded'
              WHEN trim(TRCLACT) IN ('2', '3')                   THEN 'INCONSISTENT: ruling recorded but no allegation'
              WHEN coalesce(trim(TRCLACT), '') IN ('', '-8')     THEN 'not a class action (or not recorded)'
              ELSE 'UNDOCUMENTED TRCLACT code' END AS reading,
         count(*) AS n_cases
  FROM analysis_fjc WHERE fjc_row IS NOT NULL
  GROUP BY ALL ORDER BY n_cases DESC")
class_action_codes

# Where nature of suit disagrees, which code pairs are most common?
# (Often near-identical categories, e.g. 440 vs 442, or a code change.)
nos_disagreements <- dbGetQuery(con, "
  SELECT NULLIF(regexp_extract(nature_suit, '([0-9]{3})', 1), '') AS scales_nos,
         trim(NOS) AS fjc_nos, count(*) AS n_cases
  FROM analysis_fjc
  WHERE fjc_row IS NOT NULL AND trim(NOS) NOT IN ('', '-8')
    AND NULLIF(regexp_extract(nature_suit, '([0-9]{3})', 1), '') <> trim(NOS)
  GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 15")
nos_disagreements

# =============================================================================
# E. DURATION: how many cases the dependent variable can be computed for
# Counts by duration_status and where the end date came from - coverage only,
# no duration statistics (those belong to the analysis, on training cases).
# =============================================================================
duration_coverage <- dbGetQuery(con, "
  SELECT duration_status, coalesce(end_date_source, '-') AS end_date_source, count(*) AS n_cases,
         round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM analysis_fjc GROUP BY ALL ORDER BY n_cases DESC")
duration_coverage

# Check the FJC coverage date used for the cap: no FJC termination date in the
# link table should be later than fjc_data_through.
fjc_dates_check <- dbGetQuery(con, sprintf("
  SELECT max(fjc_termdate) AS latest_fjc_termination_date,
         DATE '%s' AS fjc_data_through_setting,
         count(*) FILTER (WHERE fjc_termdate > DATE '%s') AS n_later_than_setting
  FROM '%s/scales_fjc_link.parquet'", format(fjc_data_through), format(fjc_data_through), pq))
fjc_dates_check

# ---- Optional: save the other tables to the same folder (they stay on FarmShare) ----
# (The duplicate reports are always saved; see section 0.) The file names
# include the population, so results for different populations don't overwrite each other.
# out <- function(x, name) write.csv(x, file.path(checks_dir, paste0(name, "_", population, ".csv")), row.names = FALSE)
# out(match_rate, "match_rate"); out(fjc_missing, "fjc_missing"); out(scales_missing, "scales_missing")
# out(consistency, "consistency"); out(class_action_codes, "class_action_codes")
# out(duration_coverage, "duration_coverage")

# #############################################################################
# PART 3  OPEN CASES (all cases in cases.parquet)
# #############################################################################
# Every case, with a simple year group and both termination signals.
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW status_all AS
  SELECT ucid, case_type,
         CASE WHEN year_dir IN ('16', '17') THEN '20' || year_dir ELSE 'other years' END AS year_group,
         coalesce(lower(trim(case_status)), '') = 'closed' AS status_closed,
         terminating_date IS NOT NULL AS has_termination_date
  FROM '%s/cases.parquet'", pq))

# ---- 1. Closed vs not closed, by case type and year ------------------------------
open_summary <- dbGetQuery(con, "
  SELECT case_type, year_group,
         count(*) AS n_cases,
         count(*) FILTER (WHERE status_closed) AS closed,
         count(*) FILTER (WHERE NOT status_closed) AS not_closed,
         round(100.0 * count(*) FILTER (WHERE NOT status_closed) / count(*), 1) AS pct_not_closed,
         count(*) FILTER (WHERE status_closed AND NOT has_termination_date) AS closed_but_no_termination_date,
         count(*) FILTER (WHERE NOT status_closed AND has_termination_date) AS not_closed_but_has_termination_date
  FROM status_all
  GROUP BY ROLLUP (case_type, year_group)
  ORDER BY case_type NULLS LAST, year_group NULLS LAST")
open_summary$case_type[is.na(open_summary$case_type)]   <- "ALL"
open_summary$year_group[is.na(open_summary$year_group)] <- "all years"
open_summary

# ---- 2. Every case_status value ---------------------------------------------------
status_values <- dbGetQuery(con, sprintf("
  SELECT coalesce(nullif(trim(case_status), ''), '(blank)') AS case_status, count(*) AS n_cases
  FROM '%s/cases.parquet' GROUP BY 1 ORDER BY 2 DESC", pq))
status_values

# ---- 3. Open civil 2016-17 cases: what the FJC file says happened later -----------
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW open_civil AS
  SELECT s.ucid, l.fjc_row, l.STATUSCD, l.fjc_termdate
  FROM status_all s
  LEFT JOIN (SELECT * FROM '%s/scales_fjc_link.parquet' WHERE fjc_rank = 1) l USING (ucid)
  WHERE s.case_type = 'cv' AND s.year_group IN ('2016', '2017') AND NOT s.status_closed", pq))

open_civil_fjc <- dbGetQuery(con, "
  SELECT CASE WHEN fjc_row IS NULL                                  THEN 'no FJC record'
              WHEN STATUSCD = 'S' OR fjc_termdate IS NULL           THEN 'still pending in the FJC file (mid-2026)'
              ELSE 'terminated later, per the FJC file' END AS fjc_says,
         count(*) AS n_cases,
         round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM open_civil GROUP BY 1 ORDER BY 2 DESC")
open_civil_fjc

open_civil_closed_by_year <- dbGetQuery(con, "
  SELECT year(fjc_termdate) AS year_terminated_per_fjc, count(*) AS n_cases
  FROM open_civil
  WHERE fjc_row IS NOT NULL AND coalesce(STATUSCD, '') <> 'S' AND fjc_termdate IS NOT NULL
  GROUP BY 1 ORDER BY 1")
open_civil_closed_by_year

# ---- Save -------------------------------------------------------------------------
write.csv(open_summary,              file.path(checks_dir, "open_cases_summary.csv"),        row.names = FALSE)
write.csv(status_values,             file.path(checks_dir, "open_cases_status_values.csv"),  row.names = FALSE)
write.csv(open_civil_fjc,            file.path(checks_dir, "open_civil_cases_fjc.csv"),      row.names = FALSE)
write.csv(open_civil_closed_by_year, file.path(checks_dir, "open_civil_cases_closed_by_year.csv"), row.names = FALSE)
cat("Saved four tables to", checks_dir, "(open_cases_*.csv, open_civil_cases_*.csv)\n")

cat("\nDone. Summary: checks/presplit_report.txt. Detailed tables are R objects - e.g. print(dup_report),\n",
    "fjc_missing, scales_missing, consistency, class_action_codes, duration_coverage, open_summary, open_civil_fjc.\n")
