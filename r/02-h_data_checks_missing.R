# =============================================================================
# 02-h_data_checks_missing.R — spot check of two "missing" categories still undecided
# (Josh, 29 Oct 2026):
#   no plaintiff   first_plaintiff_type = "no plaintiff listed": no party on the case has a
#                  plaintiff/petitioner role or party type (01_build_features.R)
#   jury (NA)      jury_demand is blank in SCALES's case header
# For each, compared with all other training cases:
#   counts by court, nature of suit, year, arrival route, jurisdiction (with each group's
#   share vs everyone's), pro se and IFP rates, number of parties, and how the case
#   ended (median days, share ended within 60 days, share transferred out)
#   no plaintiff:  the party ROLES those cases do have (e.g. movant, claimant, debtor)
#   jury (NA):     the FJC's own jury-demand field (JURY), if the FJC file has it
#   both:          what kind of entry the docket starts with (complaint, notice of
#                  removal, petition, ...), classified by keyword - no docket text is saved
# TRAINING CASES ONLY (it uses durations); the holdout is untouched. No names are
# printed or saved; the spot-check file has case IDs to look up by hand.
# Output: ~/scales_project/checks/missing_*.csv
#   missing_1_summary.csv        each group vs the rest
#   missing_2_<by>.csv           by court / nature_suit / year_dir / arrival_route / jurisdiction
#   missing_3_plaintiff_roles.csv party roles on "no plaintiff listed" cases
#   missing_4_jury_fjc.csv       SCALES jury_demand vs FJC JURY
#   missing_5_first_entry.csv    type of the first docket entry, by group
#   missing_spotcheck.csv        25 random training cases from each group (IDs and facts)
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("missing_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
ex <- function(sql) invisible(dbExecute(con, sql))

fjc_cols <- names(q(sprintf("SELECT * FROM '%s/fjc_idb_civil.parquet' LIMIT 0", pq)))
jury_sql <- if ("JURY" %in% fjc_cols) "coalesce(nullif(trim(CAST(f.JURY AS VARCHAR)), ''), '(blank)')" else "'(no JURY field)'"

# ---- Training cases, flagged -----------------------------------------------------------
ex(sprintf("CREATE OR REPLACE TEMP TABLE h_cases AS
  SELECT t.ucid, t.court, t.nature_suit, t.year_dir, t.arrival_route, t.jurisdiction, t.pro_se, t.in_forma_pauperis,
         t.n_parties, t.n_plaintiffs, t.n_defendants, t.duration_capped_days, t.duration_status, t.start_date,
         coalesce(t.jury_demand, '(NA)') AS jury_demand,
         t.first_plaintiff_type = 'no plaintiff listed' AS no_plaintiff,
         t.jury_demand IS NULL AS jury_na,
         %s AS fjc_jury
  FROM train_fjc t LEFT JOIN '%s/fjc_idb_civil.parquet' f ON f.fjc_row = t.fjc_row", jury_sql, pq))
groups <- c(no_plaintiff = "no plaintiff listed", jury_na = "jury_demand (NA)")
n_all <- q("SELECT count(*) AS n FROM h_cases")$n
cat(sprintf("%s training cases: %s with no plaintiff listed, %s with jury_demand (NA), %s with both.\n",
            format(n_all, big.mark = ","), format(q("SELECT count(*) AS n FROM h_cases WHERE no_plaintiff")$n, big.mark = ","),
            format(q("SELECT count(*) AS n FROM h_cases WHERE jury_na")$n, big.mark = ","),
            format(q("SELECT count(*) AS n FROM h_cases WHERE no_plaintiff AND jury_na")$n, big.mark = ",")))

# ---- 1. Each group vs the rest ---------------------------------------------------------------
summ <- function(where, label) q(sprintf("SELECT '%s' AS grp, count(*) AS n_cases,
    round(100 * avg(CAST(pro_se IN ('plaintiff', 'both') AS INTEGER)), 1) AS pct_plaintiff_pro_se_fjc,
    round(100 * avg(CAST(in_forma_pauperis = 'yes' AS INTEGER)), 1) AS pct_ifp,
    round(100 * avg(CAST(arrival_route = 'removed from state court' AS INTEGER)), 1) AS pct_removed,
    round(avg(n_parties), 2) AS mean_parties, round(avg(n_defendants), 2) AS mean_defendants,
    median(duration_capped_days) AS median_days,
    round(100 * avg(CAST(duration_capped_days <= 60 AS INTEGER)), 1) AS pct_within_60_days,
    round(100 * avg(CAST(duration_status = 'transferred_out' AS INTEGER)), 1) AS pct_transferred_out
  FROM h_cases WHERE %s", label, where))
s1 <- rbind(summ("no_plaintiff", "no plaintiff listed"), summ("NOT no_plaintiff", "plaintiff listed (the rest)"),
            summ("jury_na", "jury_demand (NA)"), summ("NOT jury_na", "jury_demand recorded (the rest)"))
save_csv(s1, "1_summary")
cat("\nEach group vs the rest:\n"); print(s1, row.names = FALSE)

# ---- 2. Where they come from -----------------------------------------------------------------
for (by in c("court", "nature_suit", "year_dir", "arrival_route", "jurisdiction")) {
  t2 <- do.call(rbind, lapply(names(groups), function(g) {
    x <- q(sprintf("SELECT '%s' AS grp, CAST(%s AS VARCHAR) AS value, count(*) FILTER (WHERE %s) AS n_in_group,
                           count(*) AS n_all_training
                    FROM h_cases GROUP BY 2 HAVING count(*) FILTER (WHERE %s) > 0 ORDER BY 3 DESC LIMIT 15",
                   groups[[g]], by, g, g))
    n_g <- q(sprintf("SELECT count(*) AS n FROM h_cases WHERE %s", g))$n
    x$pct_of_group <- round(100 * x$n_in_group / n_g, 1)
    x$pct_of_all_training <- round(100 * x$n_all_training / n_all, 1)
    x$rate_in_value_pct <- round(100 * x$n_in_group / x$n_all_training, 2)   # share of this value's cases in the group
    x
  }))
  save_csv(t2, paste0("2_", by))
  if (by %in% c("court", "nature_suit")) {
    cat(sprintf("\nLargest %s values in each group (pct_of_group vs pct_of_all_training):\n", by))
    print(do.call(rbind, lapply(split(t2, t2$grp), head, 8)), row.names = FALSE)
  }
}

# ---- 3. No plaintiff listed: what roles do those cases have? ----------------------------------
roles <- q(sprintf("SELECT coalesce(nullif(lower(trim(CAST(p.role AS VARCHAR))), ''), '(blank role)') AS role,
    coalesce(nullif(lower(trim(CAST(p.party_type AS VARCHAR))), ''), '(blank)') AS party_type,
    count(*) AS n_parties, count(DISTINCT p.ucid) AS n_cases
  FROM '%s/parties.parquet' p WHERE p.ucid IN (SELECT ucid FROM h_cases WHERE no_plaintiff)
  GROUP BY 1, 2 ORDER BY 4 DESC LIMIT 30", pq))
no_parties <- q(sprintf("SELECT count(*) AS n FROM h_cases WHERE no_plaintiff
  AND ucid NOT IN (SELECT ucid FROM '%s/parties.parquet')", pq))$n
roles <- rbind(roles, data.frame(role = "(case has no parties at all)", party_type = NA, n_parties = 0, n_cases = no_parties))
save_csv(roles, "3_plaintiff_roles")
cat("\nParty roles on 'no plaintiff listed' cases (most common):\n"); print(head(roles, 15), row.names = FALSE)
cat(sprintf("Cases with no parties at all: %s\n", format(no_parties, big.mark = ",")))

# ---- 4. Jury demand: SCALES vs the FJC ---------------------------------------------------------
jt <- q("SELECT jury_demand AS scales_jury_demand, fjc_jury, count(*) AS n FROM h_cases GROUP BY ALL ORDER BY 1, 3 DESC")
save_csv(jt, "4_jury_fjc")
cat("\nSCALES jury_demand vs FJC JURY (P plaintiff, D defendant, B both, N none, -8 missing):\n")
print(jt[jt$scales_jury_demand == "(NA)", ], row.names = FALSE)

# ---- 5. What the docket starts with ------------------------------------------------------------
entry_type <- "CASE WHEN t IS NULL THEN '(no docket entries)'
  WHEN regexp_matches(t, 'notice of removal|petition for removal') THEN 'notice of removal'
  WHEN regexp_matches(t, 'transfer') THEN 'transfer in'
  WHEN regexp_matches(t, 'miscellaneous|misc\\.? case') THEN 'miscellaneous case'
  WHEN regexp_matches(t, 'petition|application') THEN 'petition or application'
  WHEN regexp_matches(t, 'complaint') THEN 'complaint'
  WHEN regexp_matches(t, 'motion') THEN 'motion'
  WHEN regexp_matches(t, 'subpoena|registration of (foreign )?judgment|judgment') THEN 'subpoena or judgment registration'
  ELSE 'other' END"
ex(sprintf("CREATE OR REPLACE TEMP TABLE h_first AS
  SELECT c.ucid, %s AS first_entry
  FROM h_cases c LEFT JOIN (
    SELECT DISTINCT ON (ucid) ucid, lower(left(CAST(docket_text AS VARCHAR), 200)) AS t
    FROM '%s/docket_entries.parquet' WHERE ucid IN (SELECT ucid FROM h_cases WHERE no_plaintiff OR jury_na)
    ORDER BY ucid, entry_index) d USING (ucid)
  WHERE c.no_plaintiff OR c.jury_na", entry_type, pq))
fe <- q("SELECT CASE WHEN c.no_plaintiff AND c.jury_na THEN 'both' WHEN c.no_plaintiff THEN 'no plaintiff listed'
                     ELSE 'jury_demand (NA)' END AS grp, f.first_entry, count(*) AS n
         FROM h_first f JOIN h_cases c USING (ucid) GROUP BY ALL ORDER BY 1, 3 DESC")
save_csv(fe, "5_first_entry")
cat("\nWhat the docket starts with:\n"); print(fe, row.names = FALSE)

# ---- Spot check: 25 random cases from each group -------------------------------------------------
set.seed(226)
spot <- q(sprintf("SELECT c.ucid, CASE WHEN c.no_plaintiff AND c.jury_na THEN 'both' WHEN c.no_plaintiff THEN 'no plaintiff listed'
           ELSE 'jury_demand (NA)' END AS grp, c.court, c.nature_suit, c.arrival_route, c.start_date AS filed,
         c.duration_capped_days AS days, c.n_parties, c.jury_demand, c.fjc_jury, f.first_entry,
         (SELECT string_agg(DISTINCT coalesce(nullif(lower(trim(CAST(p.role AS VARCHAR))), ''), '(blank)'), '; ')
            FROM '%s/parties.parquet' p WHERE p.ucid = c.ucid) AS party_roles
  FROM h_cases c JOIN h_first f USING (ucid)", pq))
spot <- do.call(rbind, lapply(split(spot, spot$grp), function(x) x[sample(nrow(x), min(25, nrow(x))), ]))
spot <- spot[order(spot$grp, spot$court, spot$ucid), ]
save_csv(spot, "spotcheck")
cat(sprintf("\nSpot check: %d cases saved (case IDs, no names) to look up by hand.\n", nrow(spot)))
cat("Tables saved in", checks_dir, "(missing_*.csv)\n")
