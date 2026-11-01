# =============================================================================
# 02-j_data_checks_plaintiff_fill.R — can the "no plaintiff listed" cases get a plaintiff
# from other fields? (Josh, 30 Oct 2026). A DIAGNOSTIC: nothing in the sample changes.
#
# Step 0  leave out the jury_demand (NA) cases - almost all the Deepwater Horizon batch in
#         E.D. La. (02-h, 02-i), which Josh means to drop
# Step 1  fill the first plaintiff from the FJC's own plaintiff name (PLT)
# Step 2  if still empty, from SCALES's case name: the part before " v. " / " vs. "
#         (captions starting "In re" / "In the matter of" have no plaintiff and are counted)
# Each filled name gets an entity type with the SAME rules as first_plaintiff_type
# (entity_sql, read from 01_build_features.R so the two can't drift apart).
# How far to trust each source: on cases that DO have a SCALES plaintiff, how often the
# FJC name and the case name give the same entity type as SCALES's first plaintiff.
# Still missing after both steps: their party roles that aren't mapped to a side, and
# their natures of suit.
# TRAINING CASES ONLY; no names are printed or saved (only counts and entity types).
# Output: ~/scales_project/checks/plaintiff_fill_*.csv
#   plaintiff_fill_1_steps.csv          how many cases each step fills, and how many are left
#   plaintiff_fill_2_types.csv          entity types of the filled plaintiffs, by source
#   plaintiff_fill_3_agreement.csv      FJC name / case name vs SCALES first plaintiff (type)
#   plaintiff_fill_4_unmapped_roles.csv party roles on the cases still missing (unmapped ones first)
#   plaintiff_fill_5_nature_suit.csv    natures of suit of the cases still missing
#   plaintiff_fill_6_in_re.csv          "In re" captions: all training cases, by group and nature of suit
#   plaintiff_fill_spotcheck.csv        up to 40 still-missing case IDs (court, NOS, roles)
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("plaintiff_fill_", name, ".csv")), row.names = FALSE)
q <- function(sql) dbGetQuery(con, sql)
ex <- function(sql) invisible(dbExecute(con, sql))

# ---- The entity rules, exactly as in 01_build_features.R ----------------------------------
src01 <- readLines(file.path(r_dir, "01_build_features.R"))
i0 <- grep('^entity_sql <- "CASE', src01); i1 <- grep("ELSE 'individual' END\"", src01)
if (length(i0) != 1 || length(i1) != 1 || i1 < i0) stop("Couldn't find entity_sql in 01_build_features.R")
eval(parse(text = src01[i0:i1]))                       # defines entity_sql, which reads a column `n`
norm <- function(x) sprintf("trim(regexp_replace(lower(strip_accents(coalesce(%s, ''))), '[^a-z]+', ' ', 'g'))", x)

fjc_cols <- names(q(sprintf("SELECT * FROM '%s/fjc_idb_civil.parquet' LIMIT 0", pq)))
plt_sql <- if ("PLT" %in% fjc_cols) "CAST(f.PLT AS VARCHAR)" else "CAST(NULL AS VARCHAR)"
if (!"PLT" %in% fjc_cols) warning("The FJC file has no PLT column; step 1 fills nothing.", call. = FALSE)

# ---- Names from the two sources, for every training case --------------------------------------
# FJC PLT: blank, -8 and similar placeholders count as empty.
# Case name: the text before the first " v. " / " v " / " vs. " / " vs " (any capitals).
ex(sprintf("CREATE OR REPLACE TEMP TABLE pf_names AS
  SELECT t.ucid, t.court, t.nature_suit, t.first_plaintiff_type AS scales_type,
         t.jury_demand IS NULL AS jury_na,
         CASE WHEN regexp_matches(coalesce(%s, ''), '^\\s*(-?8|0|unknown|n/?a|none)?\\s*$', 'i') THEN NULL
              ELSE trim(%s) END AS fjc_name,
         regexp_matches(coalesce(c.case_name, ''), '^\\s*(in re|in the matter of|matter of|re:)\\b', 'i') AS caption_in_re,
         nullif(trim(regexp_extract(coalesce(c.case_name, ''), '^(.*?)\\s+vs?\\.?\\s+', 1, 'i')), '') AS caption_name
  FROM train_fjc t
  LEFT JOIN '%s/fjc_idb_civil.parquet' f ON f.fjc_row = t.fjc_row
  LEFT JOIN '%s/cases.parquet' c ON c.ucid = t.ucid", plt_sql, plt_sql, pq, pq))
ex(sprintf("CREATE OR REPLACE TEMP TABLE pf AS
  WITH a AS (SELECT *, %s AS n FROM pf_names),
       b AS (SELECT * EXCLUDE (n), %s AS fjc_type FROM a),
       c AS (SELECT *, %s AS n FROM b),
       d AS (SELECT * EXCLUDE (n), %s AS caption_type FROM c)
  SELECT *,
         CASE WHEN scales_type <> 'no plaintiff listed' THEN 'SCALES party table'
              WHEN jury_na THEN 'left out (jury demand NA)'
              WHEN fjc_name IS NOT NULL THEN 'filled from FJC plaintiff name'
              WHEN caption_name IS NOT NULL AND NOT caption_in_re THEN 'filled from case name'
              WHEN caption_in_re THEN 'still missing: \"In re\" caption'
              ELSE 'still missing' END AS source
  FROM d", norm("fjc_name"), entity_sql, norm("caption_name"), entity_sql))

# ---- 1. The steps ------------------------------------------------------------------------------
steps <- q("SELECT source, count(*) AS n_training_cases FROM pf WHERE scales_type = 'no plaintiff listed' GROUP BY 1")
order_ <- c("left out (jury demand NA)", "filled from FJC plaintiff name", "filled from case name",
            "still missing: \"In re\" caption", "still missing")
steps <- steps[order(match(steps$source, order_)), ]
steps <- rbind(data.frame(source = "no plaintiff listed (all)", n_training_cases = sum(steps$n_training_cases)), steps)
save_csv(steps, "1_steps")
cat("\n'No plaintiff listed' training cases, step by step:\n"); print(steps, row.names = FALSE)

# ---- 2. What the filled plaintiffs are --------------------------------------------------------
types <- q("SELECT source, CASE WHEN source LIKE '%FJC%' THEN fjc_type ELSE caption_type END AS entity_type, count(*) AS n
            FROM pf WHERE source LIKE 'filled%' GROUP BY ALL ORDER BY 1, 3 DESC")
save_csv(types, "2_types")
cat("\nEntity type of the filled plaintiffs:\n"); print(types, row.names = FALSE)

# ---- 3. How far to trust each source: agreement with SCALES where SCALES has a plaintiff -----
agree <- q("SELECT 'FJC plaintiff name' AS source, count(*) FILTER (WHERE fjc_name IS NOT NULL) AS n_with_name,
                   round(100 * avg(CASE WHEN fjc_name IS NOT NULL THEN CAST(fjc_type = scales_type AS INTEGER) END), 1) AS pct_same_type
            FROM pf WHERE scales_type NOT IN ('no plaintiff listed', 'name not recorded')
            UNION ALL
            SELECT 'case name', count(*) FILTER (WHERE caption_name IS NOT NULL AND NOT caption_in_re),
                   round(100 * avg(CASE WHEN caption_name IS NOT NULL AND NOT caption_in_re THEN CAST(caption_type = scales_type AS INTEGER) END), 1)
            FROM pf WHERE scales_type NOT IN ('no plaintiff listed', 'name not recorded')")
by_type <- q("SELECT scales_type, fjc_type, count(*) AS n FROM pf
              WHERE scales_type NOT IN ('no plaintiff listed', 'name not recorded') AND fjc_name IS NOT NULL
              GROUP BY ALL ORDER BY 1, 3 DESC")
save_csv(rbind(cbind(part = "summary", agree, scales_type = NA, fjc_type = NA, n = NA),
               cbind(part = "SCALES type vs FJC-name type", source = NA, n_with_name = NA, pct_same_type = NA, by_type)), "3_agreement")
cat("\nOn cases WITH a SCALES plaintiff: does each source give the same entity type?\n"); print(agree, row.names = FALSE)

# ---- 4. Still missing: party roles not mapped to a side --------------------------------------------
roles <- q(sprintf("SELECT coalesce(nullif(lower(trim(CAST(p.role AS VARCHAR))), ''), '(blank role)') AS role,
    coalesce(nullif(lower(trim(CAST(p.party_type AS VARCHAR))), ''), '(blank)') AS party_type,
    -- the side rule in 01_build_features.R: role starts plaintiff/petitioner or defendant/respondent, else party_type
    CASE WHEN regexp_matches(lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))), '^(plaintiff|petitioner|defendant|respondent)')
           OR lower(coalesce(CAST(p.party_type AS VARCHAR), '')) LIKE 'plaintiff%%'
           OR lower(coalesce(CAST(p.party_type AS VARCHAR), '')) LIKE 'defendant%%' THEN 'yes' ELSE 'NO' END AS mapped_to_side,
    count(*) AS n_parties, count(DISTINCT p.ucid) AS n_cases
  FROM '%s/parties.parquet' p WHERE p.ucid IN (SELECT ucid FROM pf WHERE source LIKE 'still missing%%')
  GROUP BY 1, 2, 3 ORDER BY 3, 5 DESC", pq))
no_parties <- q(sprintf("SELECT count(*) AS n FROM pf WHERE source LIKE 'still missing%%'
                         AND ucid NOT IN (SELECT ucid FROM '%s/parties.parquet')", pq))$n
roles <- rbind(roles, data.frame(role = "(case has no parties at all)", party_type = NA, mapped_to_side = NA, n_parties = 0, n_cases = no_parties))
save_csv(roles, "4_unmapped_roles")
cat("\nParty roles on the cases still missing a plaintiff (mapped_to_side = NO are the unmapped roles):\n"); print(head(roles, 25), row.names = FALSE)

# ---- 5. Still missing: natures of suit ----------------------------------------------------------
nos <- q("SELECT nature_suit, count(*) AS n FROM pf WHERE source LIKE 'still missing%' GROUP BY 1 ORDER BY 2 DESC")
save_csv(nos, "5_nature_suit")
cat("\nNatures of suit of the cases still missing a plaintiff:\n"); print(head(nos, 15), row.names = FALSE)

# ---- 6. "In re" captions: how many, and where --------------------------------------------------
in_re <- q("SELECT CASE WHEN scales_type <> 'no plaintiff listed' THEN 'SCALES lists a plaintiff'
                        WHEN jury_na THEN 'no plaintiff listed: jury demand NA (left out)'
                        WHEN fjc_name IS NOT NULL THEN 'no plaintiff listed: FJC has a plaintiff name'
                        ELSE 'no plaintiff listed: no FJC plaintiff name (still missing)' END AS grp,
                   count(*) AS n_in_re_captions
            FROM pf WHERE caption_in_re GROUP BY 1 ORDER BY 2 DESC")
in_re <- rbind(data.frame(grp = "ALL training cases with an \"In re\" caption", n_in_re_captions = sum(in_re$n_in_re_captions)), in_re)
in_re_nos <- q("SELECT nature_suit, count(*) AS n_in_re_captions,
                       count(*) FILTER (WHERE scales_type = 'no plaintiff listed') AS of_which_no_plaintiff_listed
                FROM pf WHERE caption_in_re GROUP BY 1 ORDER BY 2 DESC LIMIT 20")
save_csv(rbind(cbind(part = "by group", in_re, nature_suit = NA, of_which_no_plaintiff_listed = NA),
               cbind(part = "by nature of suit (largest 20)", grp = NA, in_re_nos[c("n_in_re_captions")],
                     nature_suit = in_re_nos$nature_suit, of_which_no_plaintiff_listed = in_re_nos$of_which_no_plaintiff_listed)), "6_in_re")
cat("\nTraining cases whose case name starts \"In re\" / \"In the matter of\":\n"); print(in_re, row.names = FALSE)
cat("\nBy nature of suit:\n"); print(head(in_re_nos, 10), row.names = FALSE)

# ---- Spot check: up to 40 still-missing cases (IDs, no names) ------------------------------------
set.seed(226)
spot <- q(sprintf("SELECT m.ucid, m.court, m.nature_suit, m.source, m.fjc_name IS NOT NULL AS has_fjc_name,
    m.caption_in_re, (SELECT string_agg(DISTINCT coalesce(nullif(lower(trim(CAST(p.role AS VARCHAR))), ''), '(blank)'), '; ')
                      FROM '%s/parties.parquet' p WHERE p.ucid = m.ucid) AS party_roles
  FROM pf m WHERE m.source LIKE 'still missing%%'", pq))
spot <- spot[sample(nrow(spot), min(40, nrow(spot))), ]; spot <- spot[order(spot$nature_suit, spot$ucid), ]
save_csv(spot, "spotcheck")
cat("\nTables saved in", checks_dir, "(plaintiff_fill_*.csv)\n")
