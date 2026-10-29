# =============================================================================
# 02-e_data_checks_nocause.R — the training cases with NO CAUSE of action
# (cause_group = "(no cause)": the SCALES cause field is blank, or was the 99:9999
# placeholder recoded in 00_sample.R). What else do we know about them?
#
# For "no cause" cases, compared with all training cases:
#   1. jurisdiction   - is there one, and which
#   2. nature of suit - is there one, and the 15 most common
#   3. court          - the courts with the most no-cause cases, and each court's share
#   4. pro se         - FJC PROSE and the SCALES plaintiff representation category
#   5. FJC cause      - does the FJC record have a cause title/section (TITL/SECTION)?
#                       If it usually does, the FJC could fill the SCALES gap.
#   6. also: duration (median, share ending within 30 days), docket size, arrival route,
#      filing year, first plaintiff/defendant type, in forma pauperis, class action, and the
#      SCALES data-quality flags is_stub / docket_available where present - to tell
#      "ordinary case with a missing field" from "odd record" (as the no-FJC cases were)
#
# TRAINING CASES ONLY (it looks at duration, which is allowed on training data); counts only, no names.
# Output: printed tables, plus ~/scales_project/checks/nocause_*.csv
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("nocause_", name, ".csv")), row.names = FALSE)

fjc_cols <- names(dbGetQuery(con, sprintf("SELECT * FROM '%s/fjc_idb_civil.parquet' LIMIT 0", pq)))
have <- dbListFields(con, "train_fjc")
flag_cols <- paste0(vapply(c("is_stub", "docket_available", "n_docket_entries"), function(v)
  if (v %in% have) sprintf(", t.%s", v) else sprintf(", NULL AS %s", v), ""), collapse = "")
fjc_titl <- if (all(c("TITL", "SECTION") %in% fjc_cols)) "nullif(trim(CAST(f.TITL AS VARCHAR)), '') AS fjc_titl, nullif(trim(CAST(f.SECTION AS VARCHAR)), '') AS fjc_section" else "NULL AS fjc_titl, NULL AS fjc_section"
invisible(dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW nocause_base AS
  SELECT t.court, t.jurisdiction, t.nature_suit, t.pro_se, t.plaintiff_firm_cases,
         t.arrival_route, t.year_dir, t.first_plaintiff_type, t.first_defendant_type,
         t.in_forma_pauperis, t.class_action_alleged, t.duration_capped_days, t.event_observed %s,
         t.cause_group = '(no cause)' AS no_cause, %s
  FROM train_fjc t LEFT JOIN '%s/fjc_idb_civil.parquet' f ON f.fjc_row = t.fjc_row", flag_cols, fjc_titl, pq)))
q <- function(sql) dbGetQuery(con, sql)
pct <- function(a, b) round(100 * a / b, 1)

tot <- q("SELECT count(*) AS n_training, count(*) FILTER (WHERE no_cause) AS n_no_cause FROM nocause_base")
cat(sprintf("\nTraining cases: %s; with no cause: %s (%.2f%%).\n", format(tot$n_training, big.mark = ","),
            format(tot$n_no_cause, big.mark = ","), 100 * tot$n_no_cause / tot$n_training))
if ("cause_from_fjc" %in% have) {
  filled <- q("SELECT cause_group, count(*) AS n FROM train_fjc WHERE cause_from_fjc GROUP BY 1 ORDER BY 2 DESC")
  save_csv(filled, "0_filled_from_fjc")
  cat(sprintf("Causes FILLED from the FJC section (00_sample.R, change 65): %s training cases; most common:\n",
              format(sum(filled$n), big.mark = ",")))
  print(head(filled, 10), row.names = FALSE)
}

# ---- Summary: how much else is recorded ---------------------------------------------
summ <- q("SELECT CASE WHEN no_cause THEN 'no cause' ELSE 'has a cause' END AS grp, count(*) AS n_cases,
    round(100 * avg((nullif(trim(jurisdiction), '') IS NOT NULL)::INT), 1)         AS pct_has_jurisdiction,
    round(100 * avg((nullif(trim(nature_suit), '') IS NOT NULL)::INT), 1)          AS pct_has_nature_suit,
    round(100 * avg((pro_se IN ('plaintiff', 'both'))::INT), 1)                   AS pct_pro_se_plaintiff_fjc,
    round(100 * avg((plaintiff_firm_cases = 'pro se / no counsel')::INT), 1)      AS pct_pro_se_plaintiff_scales,
    round(100 * avg((fjc_titl IS NOT NULL AND fjc_titl NOT IN ('-8', '0'))::INT), 1) AS pct_fjc_has_cause_title,
    median(duration_capped_days) FILTER (WHERE event_observed)                    AS median_days_ended,
    round(100 * avg((duration_capped_days <= 30)::INT), 1)                        AS pct_30_days_or_less,
    round(100 * avg((NOT coalesce(event_observed, false))::INT), 1)               AS pct_transferred_out,
    median(n_docket_entries)                                                      AS median_docket_entries,
    round(100 * avg(coalesce(CAST(is_stub AS BOOLEAN), false)::INT), 1)           AS pct_is_stub,
    round(100 * avg((NOT coalesce(CAST(docket_available AS BOOLEAN), true))::INT), 1) AS pct_no_docket,
    round(100 * avg((in_forma_pauperis = 'yes')::INT), 1)                         AS pct_ifp,
    round(100 * avg((class_action_alleged = 'yes')::INT), 1)                      AS pct_class_action
  FROM nocause_base GROUP BY 1 ORDER BY 1 DESC")
save_csv(summ, "1_summary")
cat("\nSummary: no-cause cases vs cases with a cause\n"); print(t(summ), quote = FALSE)

# ---- 1. Jurisdiction ---------------------------------------------------------------------
dist <- function(col, label, top = 15) {
  x <- q(sprintf("SELECT coalesce(nullif(trim(CAST(%s AS VARCHAR)), ''), '(blank)') AS value,
                   count(*) FILTER (WHERE no_cause) AS n_no_cause, count(*) AS n_all
                 FROM nocause_base GROUP BY 1 ORDER BY 2 DESC, 3 DESC", col))
  x$pct_of_no_cause <- pct(x$n_no_cause, sum(x$n_no_cause)); x$pct_of_all <- pct(x$n_all, sum(x$n_all))
  x$pct_no_cause_within <- pct(x$n_no_cause, x$n_all)
  save_csv(x, label)
  head(x[x$n_no_cause > 0, ], top)
}
cat("\n1. Jurisdiction (pct_no_cause_within = share of that category's cases with no cause)\n"); print(dist("jurisdiction", "2_jurisdiction"), row.names = FALSE)
cat("\n2. Nature of suit (15 most common among no-cause cases)\n");   print(dist("nature_suit", "3_nature_suit"), row.names = FALSE)
cat("\n3. Court (15 with the most no-cause cases)\n");                print(dist("court", "4_court"), row.names = FALSE)
cat("\n4a. Pro se (FJC PROSE)\n");                                    print(dist("pro_se", "5_pro_se_fjc"), row.names = FALSE)
cat("\n4b. Plaintiff representation (SCALES plaintiff_firm_cases)\n"); print(dist("plaintiff_firm_cases", "6_plaintiff_rep"), row.names = FALSE)
cat("\n6a. Arrival route\n");            print(dist("arrival_route", "8_arrival_route"), row.names = FALSE)
cat("\n6b. Filing year\n");              print(dist("year_dir", "9_year"), row.names = FALSE)
cat("\n6c. First plaintiff type\n");     print(dist("first_plaintiff_type", "10_plaintiff_type"), row.names = FALSE)
cat("\n6d. First defendant type\n");     print(dist("first_defendant_type", "11_defendant_type"), row.names = FALSE)

# ---- 5. FJC cause title for the no-cause cases -------------------------------------------
fjc <- q("SELECT coalesce(fjc_titl, '(blank)') AS fjc_title, count(*) AS n_no_cause
          FROM nocause_base WHERE no_cause GROUP BY 1 ORDER BY 2 DESC LIMIT 15")
save_csv(fjc, "7_fjc_cause_title")
cat("\n5. FJC cause title (TITL) for the no-cause cases (15 most common; -8 = missing in the FJC codebook)\n"); print(fjc, row.names = FALSE)
cat("\nTables saved in", checks_dir, "(nocause_*.csv)\n")
