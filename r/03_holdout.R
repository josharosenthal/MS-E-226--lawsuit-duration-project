# =============================================================================
# 03_holdout.R — set aside 20% of the sample as a holdout, ONCE
#
# Draws a random 20% of CONSOLIDATION GROUPS in the chosen population (seed 226;
# a lead case and its members stay together, other cases are their own group)
# and saves the assignment to ~/scales_project/holdout_split_<population>.csv,
# with a note of when and how it was made. From then on 00_sample.R loads that
# file every time this population is chosen, so the split never changes between
# sessions, and train_cases / train_fjc hold the other 80%.
# Each population gets its own split. Choose the population first, e.g.
#     population <- "fee_requests"; source("~/scales_setup/r/03_holdout.R")
#
# Run this BEFORE any analysis that compares outcomes across groups.
# It refuses to run again once the file exists, so the holdout can't be
# redrawn by accident. To redraw on purpose, delete that population's
# holdout_split_<population>.csv AND .md5 first, and record why in CHANGES.md.
# 00_sample.R checks the .md5 fingerprint every session and stops if the split
# file has changed.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))

holdout_share <- 0.20
holdout_seed  <- 226

if (file.exists(split_file)) {
  stop("A holdout split already exists: ", split_file,
       "\nIt was not changed. Delete it only if you really mean to redraw the holdout.")
}

# SPLIT BY CONSOLIDATION GROUP (Josh, 24 Oct 2026): a lead case and its member
# cases go entirely into training or entirely into the holdout, because related
# cases tend to move together. Every other case is its own group. (MDL members
# are already excluded from the sample by 00_sample.R.) Groups are keyed by court
# plus the lead case's number (year + sequence, leading zeros ignored).
has_role <- "consolidation_role" %in% dbListFields(con, "analysis_cases")
if (!has_role) cat("Note: covariates not built, so lead cases are recognised only from their own lead_case_id.\n")
groups <- dbGetQuery(con, sprintf("
  WITH k AS (
    SELECT ucid, court,
      regexp_extract(CAST(case_id AS VARCHAR), '([0-9]{2})-[a-z]{2}-', 1) || '-' ||
        ltrim(regexp_extract(CAST(case_id AS VARCHAR), '-[a-z]{2}-([0-9]+)', 1), '0') AS own_key,
      CASE WHEN nullif(trim(CAST(lead_case_id AS VARCHAR)), '') IS NOT NULL
           THEN regexp_extract(CAST(lead_case_id AS VARCHAR), '([0-9]{2})-[a-z]{2}-', 1) || '-' ||
                ltrim(regexp_extract(CAST(lead_case_id AS VARCHAR), '-[a-z]{2}-([0-9]+)', 1), '0') END AS lead_key,
      %s AS is_lead
    FROM analysis_cases)
  SELECT ucid,
    CASE WHEN lead_key IS NOT NULL AND lead_key <> '-' THEN court || '|' || lead_key
         WHEN is_lead AND own_key <> '-'                THEN court || '|' || own_key
         ELSE ucid END AS group_key
  FROM k", if (has_role) "consolidation_role = 'lead'" else "false"))
# Sort in a fixed, locale-independent order before drawing, so the same seed
# always gives the same split.
groups <- groups[order(groups$ucid, method = "radix"), ]
group_ids <- sort(unique(groups$group_key), method = "radix")
set.seed(holdout_seed)
holdout_groups <- sample(group_ids, size = round(holdout_share * length(group_ids)))
split <- data.frame(ucid = groups$ucid, is_holdout = groups$group_key %in% holdout_groups)
write.csv(split, split_file, row.names = FALSE)
gsize <- table(groups$group_key)
ids <- split$ucid

writeLines(c(
  "Holdout split for the MS&E 226 SCALES project",
  paste("Population:", population),
  paste("Made:", format(Sys.time(), "%Y-%m-%d %H:%M %Z")),
  paste("Cases in sample:", length(ids)),
  paste("Holdout share:", holdout_share, "of GROUPS   Seed:", holdout_seed,
        "  Method: random sample of consolidation groups (a lead case and its members stay together; other cases are their own group)"),
  paste("Groups:", length(group_ids), "  of which with more than one case:", sum(gsize > 1), "  largest group:", max(gsize), "cases"),
  "Sample definition: r/00_sample.R (2016-17 civil cases, open or closed; minus 28 USC 2241/2254/2255,",
  "42 USC 1983pr, MDL member cases and cases ending by MDL transfer out; duplicates removed; minus",
  paste0("overlong cases beyond the ", duration_cap_days, "-day cap, and cases with no FJC record), restricted to the population above"),
  if (population == "fee_shifting") paste("Codes used:", paste(readLines(fee_codes_file)[!grepl("^#", readLines(fee_codes_file))][-1], collapse = " | ")) else NULL,
  paste("Holdout cases:", sum(split$is_holdout), sprintf("(%.1f%% of cases)", 100 * mean(split$is_holdout)),
        "  Training cases:", sum(!split$is_holdout))
), sub("\\.csv$", "_README.txt", split_file))

writeLines(c(unname(tools::md5sum(split_file)),
             paste("recorded", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "for", basename(split_file))),
           sub("\\.csv$", ".md5", split_file))
cat("Saved", split_file, "and its fingerprint (.md5)\n")
cat(sprintf("Split by consolidation group: %s groups (%s with more than one case; largest %s cases). Holdout: %s cases = %.1f%% of the sample.\n",
            format(length(group_ids), big.mark = ","), format(sum(gsize > 1), big.mark = ","), max(gsize),
            format(sum(split$is_holdout), big.mark = ","), 100 * mean(split$is_holdout)))

# Reload the sample so the training/holdout views pick up the new split.
source(file.path(r_dir, "00_sample.R"))
