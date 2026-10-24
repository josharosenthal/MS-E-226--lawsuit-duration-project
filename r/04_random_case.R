# =============================================================================
# 04_random_case.R — one case from the merged SCALES + FJC table, as a readable
# markdown page
#
# Picks one case at random from the chosen population and writes a markdown
# file with:
#   * the key SCALES facts (court, dates, cause, nature of suit, judge, ...)
#   * the FJC outcome codes, translated into words using the FJC codebook
#   * every other non-empty SCALES field
#   * the case's docket entries (first and last ones if the docket is long)
# The file opens in RStudio; click "Preview" (or use the Viewer) to read it.
#
# WHICH CASES (case_pool):
#   "sample"  (default) the chosen population: training cases only once its
#             holdout exists (03_holdout.R), so holdout outcomes stay unseen;
#             all of the population before that.
#   "1983pr"  a case EXCLUDED from every population: prisoner civil rights
#             (cause 42:1983pr). Not in any sample or holdout, so it is safe to
#             browse. (Prisoner cases coded plain 42:1983 are still in the sample.)
#   "habeas"  a case EXCLUDED from every population: 28 USC 2241, 2254, 2255.
#   "mdl"     a case EXCLUDED from every population: an MDL member (SCALES is_mdl
#             or FJC ORIGIN 6 / 13), excluding habeas and 1983pr cases.
#   Excluded cases come from the 2016-17 civil cases (open or closed) before
#   duplicate removal, with their best FJC match.
#
# Options - set any of these BEFORE source(), e.g.
#     population <- "fee_shifting"; case_seed <- 42
#     source("~/scales_setup/r/04_random_case.R")
#   case_pool    "sample" (default), "1983pr", "habeas" or "mdl" - see above
#   population   "all" (default), "fee_requests" or "fee_shifting"
#   case_seed    a number, to get the same "random" case again
#   case_ucid    a specific case, e.g. "ilnd;;1:16-cv-04871" (skips the draw)
#   max_entries  most docket entries to list (default 60: first 50 and last 10)
#
# The page is saved in ~/scales_project/case_views/ and stays on FarmShare.
# Docket text names parties and lawyers, so keep these pages there.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))

if (!exists("max_entries")) max_entries <- 60
if (!exists("case_pool")) case_pool <- "sample"
stopifnot("case_pool must be \"sample\", \"1983pr\", \"habeas\" or \"mdl\"" = case_pool %in% c("sample", "1983pr", "habeas", "mdl"))

if (case_pool == "sample") {
  source_view <- if (file.exists(split_file)) "train_fjc" else "analysis_fjc"
} else {
  excluded_rule <- switch(case_pool,
    "1983pr" = "cause_title = 42 AND cause_section = '1983pr'",
    "habeas" = "cause_title = 28 AND regexp_matches(cause_section, '^(2241|2254|2255)([a-z]|$)')",
    "mdl"    = "ucid IN (SELECT ucid FROM mdl_flagged WHERE is_mdl_any)")
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP VIEW excluded_fjc AS
    SELECT c.*, l.* EXCLUDE (ucid)
    FROM (SELECT * FROM civil_cases WHERE %s) c
    LEFT JOIN (SELECT * FROM '%s/scales_fjc_link.parquet' WHERE fjc_rank = 1) l USING (ucid)",
    excluded_rule, pq))
  source_view <- "excluded_fjc"
}

# ---- 1. Pick the case ---------------------------------------------------------
if (exists("case_ucid") && !is.null(case_ucid)) {
  row <- dbGetQuery(con, sprintf("SELECT * FROM %s WHERE ucid = ?", source_view), params = list(case_ucid))
  if (nrow(row) == 0) stop("Case ", case_ucid, " is not in ", source_view,
                          if (case_pool == "sample") paste0(" for population \"", population, "\"") else "", ".")
  how <- "chosen by case_ucid"
} else {
  n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s", source_view))$n
  if (n == 0) stop("No cases in ", source_view,
                   if (case_pool == "sample") paste0(" for population \"", population, "\"") else "", ".")
  if (exists("case_seed")) set.seed(case_seed)
  k <- sample.int(n, 1) - 1
  row <- dbGetQuery(con, sprintf("SELECT * FROM %s ORDER BY ucid LIMIT 1 OFFSET %d", source_view, k))
  how <- if (exists("case_seed")) sprintf("random draw, case_seed = %s", case_seed) else "random draw"
}
r <- as.list(row[1, ])
ucid <- r$ucid

# ---- 2. Helpers -----------------------------------------------------------------
present <- function(x) !is.null(x) && length(x) == 1 && !is.na(x) && !(trimws(as.character(x)) %in% c("", "[]"))
txt <- function(x) gsub("[\r\n\t]+", " ", as.character(x))           # one line
cell <- function(x, max_chars = 300) {                                 # safe inside a table cell
  x <- txt(x)
  if (nchar(x) > max_chars) x <- paste0(substr(x, 1, max_chars), "…")
  gsub("|", "\\|", x, fixed = TRUE)
}
kv_table <- function(fields, labels = fields) {
  keep <- vapply(fields, function(f) f %in% names(r) && present(r[[f]]), logical(1))
  if (!any(keep)) return(character(0))
  c("| Field | Value |", "|---|---|",
    sprintf("| %s | %s |", labels[keep], vapply(fields[keep], function(f) cell(r[[f]]), character(1))))
}

# FJC codebook ("Civil Codebook 1988 Forward", 25 Oct 2023)
codebook <- list(
  ORIGIN = c("1" = "original proceeding", "2" = "removed from state court",
             "3" = "remanded from court of appeals", "4" = "reinstated/reopened",
             "5" = "transferred from another district", "6" = "multidistrict litigation (transferred in)",
             "7" = "appeal from a magistrate judge", "8" = "second reopen", "9" = "third reopen",
             "10" = "fourth reopen", "11" = "fifth reopen", "12" = "sixth reopen",
             "13" = "multidistrict litigation originating in the district"),
  JURIS = c("1" = "U.S. government plaintiff", "2" = "U.S. government defendant",
            "3" = "federal question", "4" = "diversity of citizenship", "5" = "local question"),
  PROCPROG = c("1" = "before issue joined: no court action", "2" = "before issue joined: order entered",
               "11" = "before issue joined: hearing held", "12" = "before issue joined: order decided",
               "3" = "after issue joined: no court action", "4" = "after issue joined: judgment on motion",
               "5" = "pretrial conference held", "6" = "during court trial", "7" = "during jury trial",
               "8" = "after court trial", "9" = "after jury trial", "10" = "other",
               "13" = "request for trial de novo after arbitration"),
  DISP = c("0" = "transferred to another district", "1" = "remanded to state court",
           "10" = "multidistrict litigation transfer", "11" = "remanded to U.S. agency",
           "2" = "dismissed: want of prosecution", "3" = "dismissed: lack of jurisdiction",
           "12" = "dismissed: voluntarily", "13" = "dismissed: settled", "14" = "dismissed: other",
           "4" = "judgment: default", "5" = "judgment: consent", "6" = "judgment: motion before trial",
           "7" = "judgment: jury verdict", "8" = "judgment: directed verdict", "9" = "judgment: court trial",
           "15" = "judgment: award of arbitrator", "16" = "judgment: stayed pending bankruptcy",
           "17" = "judgment: other", "18" = "statistical closing",
           "19" = "appeal affirmed (magistrate judge)", "20" = "appeal denied (magistrate judge)"),
  NOJ = c("0" = "no monetary award", "1" = "monetary award only", "2" = "monetary award and other",
          "3" = "injunction", "4" = "forfeiture/foreclosure/condemnation, etc.", "5" = "costs only",
          "6" = "costs and attorney fees"),
  JUDGMENT = c("1" = "plaintiff", "2" = "defendant", "3" = "both", "4" = "unknown", "0" = "missing"),
  CLASSACT = c("1" = "class action alleged"),
  TRCLACT = c("2" = "class certification denied", "3" = "class certification granted"),
  PROSE = c("0" = "no pro se parties", "1" = "pro se plaintiff(s) only", "2" = "pro se defendant(s) only",
            "3" = "pro se plaintiff(s) and defendant(s)"),
  IFP = c("FP" = "in forma pauperis", "-8" = "not in forma pauperis"),
  STATUSCD = c("L" = "terminated", "S" = "pending")
)
decode <- function(field) {
  code <- if (field %in% names(r)) trimws(as.character(r[[field]])) else NA
  if (is.na(code) || code == "") return(c(code = "(blank)", meaning = ""))
  dict <- codebook[[field]]
  meaning <- if (!is.null(dict) && code %in% names(dict)) dict[[code]]
             else if (code == "-8") "missing / not recorded"
             else if (!is.null(dict)) "not in the codebook"
             else ""
  c(code = code, meaning = meaning)
}

# ---- 3. Build the page ------------------------------------------------------
title <- if (present(r$case_name)) txt(r$case_name) else ucid
pool_note <- if (case_pool == "sample") sprintf("population **%s**", population) else
             sprintf("**excluded case (%s)** - not in any sample or holdout", case_pool)
md <- c(
  sprintf("# %s", title), "",
  sprintf("`%s`  ·  %s  ·  from `%s`  ·  %s", ucid, pool_note, source_view, how), "")

md <- c(md, "## Key facts (SCALES)", "",
  kv_table(c("court", "case_id", "case_name", "year_dir", "filing_date", "terminating_date", "case_status",
             "case_closed", "duration_status", "duration_capped_days", "end_date_source",
             "cause", "cause_title", "cause_section", "nature_suit", "jurisdiction", "judge",
             "jury_demand", "monetary_demand", "n_docket_entries", "n_parties", "n_counsel",
             "is_mdl", "source"),
           c("Court", "Case number", "Case name", "Year folder", "Filed", "Terminated", "Status",
             "Closed when SCALES collected it", "Duration status", "Duration (days, capped)",
             "End date taken from",
             "Cause of action", "Cause: title", "Cause: section", "Nature of suit", "Jurisdiction",
             "Judge", "Jury demand", "Monetary demand", "Docket entries", "Parties", "Lawyer listings",
             "Multidistrict litigation", "Source")), "")

# FJC outcome fields, decoded
fjc_fields <- c(ORIGIN = "How the case arrived", JURIS = "Jurisdiction", NOS = "Nature of suit",
                CLASSACT = "Class action alleged", TRCLACT = "Class certification", PROCPROG = "Procedural progress",
                DISP = "Disposition", NOJ = "Nature of judgment", JUDGMENT = "Judgment for",
                AMTREC = "Amount received ($000s; FJC advises against using)", PROSE = "Pro se",
                IFP = "Fee status", STATUSCD = "Record status")
if (present(r$fjc_row)) {
  rows <- vapply(names(fjc_fields), function(f) {
    d <- decode(f); sprintf("| %s | `%s` | %s |", fjc_fields[[f]], cell(d[["code"]]), cell(d[["meaning"]]))
  }, character(1))
  md <- c(md, "## How it ended (FJC Integrated Database)", "",
    sprintf("FJC record %s · filed %s · terminated %s · filing dates agree: %s · FJC records for this case: %s",
            r$fjc_row, txt(r$fjc_filedate), txt(r$fjc_termdate), txt(r$filedate_agrees), txt(r$n_fjc_matches)), "",
    "| Field | Code | Meaning |", "|---|---|---|", rows, "")
} else {
  md <- c(md, "## How it ended (FJC Integrated Database)", "", "_No FJC record matched this case._", "")
}

# Every other non-empty SCALES field
shown <- c("ucid", "court", "case_id", "case_name", "year_dir", "filing_date", "terminating_date",
           "case_status", "case_closed", "duration_status", "duration_capped_days", "end_date_source",
           "duration_days", "start_date", "end_date", "is_overlong", "cause", "cause_title", "cause_section", "nature_suit", "jurisdiction", "judge",
           "jury_demand", "monetary_demand", "n_docket_entries", "n_parties", "n_counsel", "is_mdl",
           "source", "is_holdout", "case_number_key",
           "fjc_row", "n_fjc_matches", "fjc_rank", "filedate_agrees", "fjc_filedate", "fjc_termdate",
           "TAPEYEAR", names(fjc_fields))
others <- setdiff(names(r), shown)
other_table <- kv_table(others)
if (length(other_table)) md <- c(md, "## Other SCALES fields (non-empty only)", "", other_table, "")

# Docket entries
dk <- dbGetQuery(con, sprintf("SELECT entry_index, ind, date_filed, docket_text
                               FROM '%s/docket_entries.parquet' WHERE ucid = ? ORDER BY entry_index", pq),
                 params = list(ucid))
md <- c(md, sprintf("## Docket (%d entries)", nrow(dk)), "")
fmt_entry <- function(i) sprintf("- **%s** · #%s · %s",
                                 if (is.na(dk$date_filed[i])) "no date" else as.character(dk$date_filed[i]),
                                 if (is.na(dk$ind[i]) || dk$ind[i] == "") "–" else dk$ind[i],
                                 if (is.na(dk$docket_text[i])) "" else txt(dk$docket_text[i]))
if (nrow(dk) == 0) {
  md <- c(md, "_No docket entries._")
} else if (nrow(dk) <= max_entries) {
  md <- c(md, vapply(seq_len(nrow(dk)), fmt_entry, character(1)))
} else {
  head_n <- max_entries - 10
  md <- c(md, vapply(seq_len(head_n), fmt_entry, character(1)),
          sprintf("- _… %d entries not shown (set max_entries to see more) …_", nrow(dk) - max_entries),
          vapply((nrow(dk) - 9):nrow(dk), fmt_entry, character(1)))
}

# ---- 4. Save and open -------------------------------------------------------
out_dir <- file.path(project_dir, "case_views")
dir.create(out_dir, showWarnings = FALSE)
md_file <- file.path(out_dir, paste0(gsub("[^A-Za-z0-9]+", "_", ucid), ".md"))
writeLines(md, md_file, useBytes = TRUE)
cat("Case:", ucid, "\nSaved:", md_file, "\n")
# In RStudio, open the page. In R in a terminal, don't (file.edit would start a
# text editor such as vi); read it with: less <the path above>  (q to quit).
if (interactive() && Sys.getenv("RSTUDIO") == "1") file.edit(md_file)
