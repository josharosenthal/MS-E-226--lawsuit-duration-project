# =============================================================================
# PARKED (24 Oct 2026): not used in the current project; kept, working, for a
# possible future project on attorney's fees. Nothing else depends on it.
# 99_fee_search.R — attorney's-fee REQUESTS and RULINGS in the docket entries
#
# 1. Finds every docket entry in the sample that mentions attorney's fees.
# 2. Classifies each by the kind of document it is (docket clerks put the
#    document type first). A ruling usually repeats the request's name -
#    "ORDER granting [45] MOTION for Attorney Fees" - so an entry is classified
#    by how it STARTS, in this order:
#      recommendation       Report and Recommendation / Findings and Recommendation
#      ruling               an order type AND grant/deny/award/moot, or a Judgment
#      order_other          an order or minute entry without those words
#                           (briefing schedules, "entered and continued", ...)
#      response_or_support  Response, Reply, Memorandum in support, Declaration,
#                           Objection, Notice, ... (these repeat the motion name too)
#      stipulation          Stipulation
#      request              Motion / Petition / Application FOR fees (not motions
#                           to extend time or for leave to file)
#      other_motion         any other motion that mentions fees
#      possible_ruling      no recognised document type, but grant/deny/award: check
#      other_mention        anything else
# 3. Links each ruling to the fee request it cites: rulings cite the entry they
#    decide by its docket number, e.g. "[45]", which is matched to `ind`.
#
# WHICH CASES:
#   * fee_request_cases - REQUESTS ONLY, for the whole BASE sample, whatever
#     population is chosen. This list defines the "fee_requests" population
#     (see 00_sample.R), so it is made before that population's holdout is
#     drawn. Saved to ~/scales_project/fee_request_cases.csv. Run this script
#     once with population <- "all" to create it.
#   * fee_entries, fee_cases - everything, including RULINGS (a likely outcome),
#     for the chosen population: training cases only once that population's
#     holdout exists; all of its cases before that.
#
# This is a first pass built on common docket wording. Read a sample of
# fee_entries$docket_text in each category before relying on it.
# Reads ~20 million docket entries, so it may take a few minutes.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))

# ---- 1-2. Every fee-related docket entry in the sample, classified ---------------
dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW fee_entries_all AS
  WITH d AS (
    SELECT d.ucid, d.entry_index, d.ind, d.date_filed, d.docket_text,
           lower(d.docket_text) AS t
    FROM '%s/docket_entries.parquet' d
    WHERE d.ucid IN (SELECT ucid FROM all_cases)
      AND regexp_matches(lower(d.docket_text),
            'attorney[^a-z]{0,3}s?[^a-z]{0,3}fee|fees and costs|(^|[^a-z])eaja([^a-z]|$)|equal access to justice')),
  f AS (
    SELECT *,
      regexp_matches(t, '^[^a-z]*(report and recommendation|findings and recommendations?)([^a-z]|$)') AS lead_recommendation,
      regexp_matches(t, '^[^a-z]*(order|orders|minute order|minute entry|memorandum opinion|memorandum and order|memorandum order|opinion and order|opinion|text order|electronic order|entered order|agreed order|consent order|stipulated order)([^a-z]|$)') AS lead_order,
      regexp_matches(t, '^[^a-z]*(judgment|amended judgment|final judgment|clerk.?s judgment)([^a-z]|$)') AS lead_judgment,
      regexp_matches(t, '^[^a-z]*(response|reply|memorandum|brief|declaration|affidavit|objection|objections|opposition|notice|exhibit|statement|supplement|sur.?reply|surreply)([^a-z]|$)') AS lead_support,
      regexp_matches(t, '^[^a-z]*(stipulation|joint stipulation)([^a-z]|$)') AS lead_stipulation,
      regexp_matches(t, '^[^a-z]*([a-z]+[^a-z]+){0,3}(motion|petition|application)([^a-z]|$)') AS lead_request,
      regexp_matches(t, '(^|[^a-z])(grant|grants|granting|granted|deny|denies|denying|denied|award|awards|awarding|awarded|moot)([^a-z]|$)') AS ruling_words,
      regexp_matches(t, '(motion|petition|application)[^.;]{0,60}(attorney[^a-z]{0,3}s?[^a-z]{0,3}fee|fees and costs|eaja|equal access to justice|fees)') AS asks_for_fees,
      regexp_matches(t, 'extension of time|extend (the )?(time|deadline)|enlargement of time|leave to file|to stay') AS procedural_motion,
      regexp_extract_all(docket_text, '\\[ *([0-9]+) *\\]', 1) AS cited_entries
    FROM d)
  SELECT ucid, entry_index, ind, date_filed,
    CASE WHEN lead_recommendation                    THEN 'recommendation'
         WHEN (lead_order AND ruling_words) OR lead_judgment THEN 'ruling'
         WHEN lead_order                             THEN 'order_other'
         WHEN lead_support                           THEN 'response_or_support'
         WHEN lead_stipulation                       THEN 'stipulation'
         WHEN lead_request AND asks_for_fees AND NOT procedural_motion THEN 'request'
         WHEN lead_request                           THEN 'other_motion'
         WHEN ruling_words                           THEN 'possible_ruling'
         ELSE 'other_mention' END AS category,
    cited_entries, docket_text
  FROM f", pq))

# ---- 3. Link rulings to the requests they cite --------------------------------
dbExecute(con, "CREATE OR REPLACE TEMP VIEW fee_entries_linked AS
  SELECT e.*,
         e.category IN ('ruling', 'recommendation', 'possible_ruling')
           AND EXISTS (SELECT 1 FROM fee_entries_all r
                       WHERE r.ucid = e.ucid AND r.category = 'request'
                         AND list_contains(e.cited_entries, r.ind)) AS cites_a_fee_request
  FROM fee_entries_all e")

# ---- REQUESTS, whole base sample: defines the "fee_requests" population ----------
fee_request_cases <- dbGetQuery(con, "
  SELECT ucid, count(*) AS n_fee_requests, min(date_filed) AS first_fee_request_date
  FROM fee_entries_all WHERE category = 'request'
  GROUP BY 1 ORDER BY 1")
write.csv(fee_request_cases, file.path(project_dir, "fee_request_cases.csv"), row.names = FALSE)
cat(sprintf("Cases with at least one fee request (base sample): %s. Saved to %s\n",
            format(nrow(fee_request_cases), big.mark = ","),
            file.path(project_dir, "fee_request_cases.csv")))

# ---- EVERYTHING incl. rulings: training cases only once the holdout exists ------
cases_view <- if (file.exists(split_file)) "train_cases" else "analysis_cases"
if (cases_view == "analysis_cases")
  cat("No holdout split for this population yet: fee_entries and fee_cases below include",
      "RULINGS for all of its cases. Make the split (03_holdout.R) before looking at how",
      "rulings come out.\n")
cat("fee_entries / fee_cases cover:", cases_view, "of population", population, "\n")

fee_entries <- dbGetQuery(con, sprintf("
  SELECT e.ucid, c.court, e.entry_index, e.ind, e.date_filed, e.category,
         e.cites_a_fee_request, e.docket_text
  FROM fee_entries_linked e JOIN %s c USING (ucid)
  ORDER BY e.ucid, e.entry_index", cases_view))

# One row per case: when fees were requested, and whether/when a ruling followed.
fee_cases <- dbGetQuery(con, sprintf("
  SELECT e.ucid,
         count(*) FILTER (WHERE category = 'request')                       AS n_requests,
         min(date_filed) FILTER (WHERE category = 'request')                AS first_request_date,
         count(*) FILTER (WHERE category = 'ruling')                        AS n_rulings,
         count(*) FILTER (WHERE category = 'ruling' AND cites_a_fee_request) AS n_rulings_citing_a_request,
         min(date_filed) FILTER (WHERE category = 'ruling')                 AS first_ruling_date,
         count(*) FILTER (WHERE category = 'recommendation')                AS n_recommendations,
         count(*) FILTER (WHERE category = 'possible_ruling')               AS n_possible_rulings
  FROM fee_entries_linked e JOIN %s c USING (ucid)
  GROUP BY 1 ORDER BY 1", cases_view))

# ---- Look at the results ----------------------------------------------------
table(fee_entries$category)
# Read examples of one category, e.g. requests (first 200 characters):
head(substr(fee_entries$docket_text[fee_entries$category == "request"], 1, 200), 15)
# ...and rulings:
head(substr(fee_entries$docket_text[fee_entries$category == "ruling"], 1, 200), 15)

# Optional: save for later (stays on FarmShare)
# write.csv(fee_entries, file.path(project_dir, "fee_entries.csv"), row.names = FALSE)
# write.csv(fee_cases,   file.path(project_dir, "fee_cases.csv"),   row.names = FALSE)
