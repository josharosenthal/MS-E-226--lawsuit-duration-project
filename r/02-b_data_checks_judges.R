# =============================================================================
# 02-b_data_checks_judges.R — how often was the judge REASSIGNED during the case?
#
# Why: SCALES's judge field is the judge when SCALES COLLECTED the docket
# (2020-21), not the judge at filing. Long cases are more likely to be reassigned
# (judge retires, takes senior status, recuses; new judges take over dockets), so
# judge_group and judge_type partly reflect duration (leakage).
#
# On a random sample of TRAINING cases (default 10,000):
#   (1) finds the FIRST "assigned to Judge ..." entry on the docket and checks
#       whether the SCALES judge's surname appears in it (match / mismatch)
#   (2) searches the whole docket for reassignment wording: "reassign",
#       "no longer assigned", "recus(al/ed)", "transferred to Judge"
# and tabulates both, together and by duration band.
#
# Name matching: the SCALES judge's surname (last word, after the same clean-up
# 01_build_features.R uses: accents removed, titles like "Judge"/"Hon." dropped)
# must appear in the ~150 characters after "assigned to". Two-word surnames
# (e.g. "Van Tatenhove") are also tried joined together.
# Not every docket records the initial assignment as an entry - the share where
# one is found is reported, and the comparison uses only those cases.
#
# Output: printed tables, plus ~/scales_project/checks/judges_reassign_*.csv,
# including judges_reassign_spotcheck.csv (200 comparable cases with the extracted
# assignment text) and judges_reassign_spotcheck_wording.csv (200 cases flagged by the
# wording, with ~120 characters around the match) - to check the rules by hand.
# Version 2 (CHANGES.md change 44) tightened both rules after the first spot-check.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
save_csv <- function(x, name) write.csv(x, file.path(checks_dir, paste0("judges_reassign_", name, ".csv")), row.names = FALSE)
n_sample <- 10000      # training cases to check; 10,000 gives about +/- 1 point on an overall percentage

# ---- The sample ---------------------------------------------------------------------
# A fixed random order (hash of the case ID), so the same cases are drawn every run.
s <- dbGetQuery(con, sprintf("SELECT ucid, court, judge, duration_capped_days, event_observed
  FROM train_fjc ORDER BY hash(ucid || 'judges226') LIMIT %d", n_sample))
dbWriteTable(con, "judge_sample", s[, "ucid", drop = FALSE], temporary = TRUE, overwrite = TRUE)
cat(sprintf("Sample: %s training cases.\n", format(nrow(s), big.mark = ",")))

# Only docket entries that mention assignment, reassignment or recusal are read into R.
entries <- dbGetQuery(con, sprintf("SELECT e.ucid, e.entry_index, lower(left(e.docket_text, 600)) AS txt
  FROM '%s/docket_entries.parquet' e SEMI JOIN judge_sample USING (ucid)
  WHERE regexp_matches(lower(e.docket_text), 'assign|recus|transferred to (the )?(hon|honorable|judge|chief|district|senior)')
  ORDER BY e.ucid, e.entry_index", pq))
cat(sprintf("Docket entries mentioning assignment / reassignment / recusal: %s.\n", format(nrow(entries), big.mark = ",")))

# ---- Name clean-up (same rules as 01_build_features.R) ------------------------------
norm_words <- function(x) {
  x <- iconv(enc2utf8(as.character(x)), from = "UTF-8", to = "ASCII//TRANSLIT", sub = "")
  x <- tolower(gsub("['`^~\"]", "", x))
  x <- gsub("[^a-z ]", " ", x)
  w <- strsplit(trimws(gsub(" +", " ", x)), " ")[[1]]
  setdiff(w, c("judge", "honorable", "hon", "chief", "senior", "district", "us", "u", "s", "the",
               "presiding", "jr", "sr", "ii", "iii", "iv", "united", "states", "court", "of",
               "magistrate", "mag"))
}

# ---- (1) First assignment entry vs the SCALES judge --------------------------------
# Version 2 (after the first real run's spot-check): "assigned to" must be followed by a
# judge title (Hon./Honorable/Judge/Chief/District/Senior/Magistrate/U.S.), optionally
# after "the calendar of" / "the docket of". This drops the main false positives:
#   "Judge X no longer assigned to the case" (a REASSIGNMENT entry, read as the first assignment)
#   "assigned to serve as panel mediator", "assigned to the standard track",
#   "assigned to a judge who participates in ...", "assigned to this case. Please use the new number"
title_pat   <- "(the )?((calendar|docket) of (the )?)?(hon\\.?|honorable|judge|chief|district|senior|magistrate|u\\.?s\\.?|united states)\\b"
initial_pat <- paste0("(?<!re)(?<!re-)(?<!longer )assigned to\\s+(", title_pat, ".{0,140})")
reassign_pat <- c(
  # district-judge changes
  reassigned_to_judge  = "re-?assigned to (the )?(?!(hon\\.? |honorable )?(u\\.?s\\.? |united states )?magistrate)(hon|honorable|judge|chief|district|senior|u\\.?s\\.? district)",
  judge_no_longer      = "(?<!magistrate )judge [a-z.,' -]{2,40}? no longer assigned",
  recusal              = "recus",
  transferred_to_judge = "transferred to (the )?(?!(hon\\.? |honorable )?(u\\.?s\\.? )?magistrate)(hon|honorable|judge|chief|district|senior)",
  # magistrate-judge changes only (not a change of the judge in judge_group)
  magistrate_change    = "magistrate judge [a-z.,' -]{2,40}? no longer assigned|re-?assigned to (the )?(hon\\.? |honorable )?(u\\.?s\\.? |united states )?magistrate",
  # the version-1 broad rule, kept for comparison
  broad_v1             = "re-?assign|no longer assigned|recus|transferred to (the )?(hon|honorable|judge|chief|district|senior)")
district_flags <- c("reassigned_to_judge", "judge_no_longer", "recusal", "transferred_to_judge")
m <- regexpr(initial_pat, entries$txt, perl = TRUE)
first_assign <- entries[m > 0, ]
cs <- attr(m, "capture.start")[m > 0, 1]; cl <- attr(m, "capture.length")[m > 0, 1]
first_assign$window <- substr(first_assign$txt, cs, cs + cl - 1)
# Prefer the first assignment that is NOT to a magistrate judge ("assigned to Magistrate
# Judge X for discovery" is a referral, not the initial assignment); if a case only has
# magistrate assignments (e.g. consent cases), use its first one.
first_assign$to_magistrate <- grepl("^\\W*(the )?((calendar|docket) of (the )?)?(hon\\.? |honorable )?(u\\.?s\\.? )?(united states )?magistrate", first_assign$window)
first_assign <- first_assign[order(first_assign$ucid, first_assign$to_magistrate, first_assign$entry_index), ]
first_assign <- first_assign[!duplicated(first_assign$ucid), ]
s$initial_window <- first_assign$window[match(s$ucid, first_assign$ucid)]

s$judge_status <- vapply(seq_len(nrow(s)), function(i) {
  j <- s$judge[i]
  if (is.na(j) || trimws(j) == "") return("SCALES judge blank")
  if (grepl(unassigned_pattern, tolower(j))) return("SCALES judge 'unassigned'")
  if (is.na(s$initial_window[i])) return("no initial assignment entry found")
  w <- norm_words(j); if (!length(w)) return("SCALES judge blank")
  win_words <- norm_words(s$initial_window[i]); win_joined <- paste(win_words, collapse = "")
  keys <- unique(c(tail(w, 1), if (length(w) >= 2) paste(tail(w, 2), collapse = "")))
  if (tail(w, 1) %in% win_words || any(vapply(keys, function(k) grepl(k, win_joined, fixed = TRUE), TRUE)))
    "same judge as first assignment" else "DIFFERENT judge from first assignment"
}, "")

# ---- (2) Reassignment wording anywhere on the docket --------------------------------
snippet <- function(txt, pat) {                 # ~120 characters around the first match
  p <- regexpr(pat, txt, perl = TRUE); ifelse(p > 0, substr(txt, pmax(1, p - 40), p + 80), NA)
}
for (nm in names(reassign_pat)) {
  hit_rows <- grepl(reassign_pat[[nm]], entries$txt, perl = TRUE)
  s[[nm]] <- s$ucid %in% unique(entries$ucid[hit_rows])
}
s$any_reassign_wording <- Reduce(`|`, s[district_flags])      # district-judge change wording (version 2)
# first district-level wording hit per case, for the spot-check file
district_any <- paste0("(", paste(reassign_pat[district_flags], collapse = ")|("), ")")
hits <- entries[grepl(district_any, entries$txt, perl = TRUE), ]; hits <- hits[!duplicated(hits$ucid), ]
hits$snippet <- snippet(hits$txt, district_any)
s$reassign_snippet <- hits$snippet[match(s$ucid, hits$ucid)]

# ---- Tables ---------------------------------------------------------------------------
pct <- function(x) round(100 * x, 1)
order_status <- c("same judge as first assignment", "DIFFERENT judge from first assignment",
                  "no initial assignment entry found", "SCALES judge 'unassigned'", "SCALES judge blank")
t1 <- as.data.frame(table(factor(s$judge_status, levels = order_status)), stringsAsFactors = FALSE)
names(t1) <- c("judge_status", "n_cases"); t1$pct_of_sample <- pct(t1$n_cases / nrow(s))
comparable <- s$judge_status %in% order_status[1:2]
t1$pct_of_comparable <- ifelse(t1$judge_status %in% order_status[1:2], pct(t1$n_cases / sum(comparable)), NA)
save_csv(t1, "1_initial_vs_scales")
cat("\n(1) First 'assigned to' entry on the docket vs the SCALES judge\n"); print(t1, row.names = FALSE)

t2 <- data.frame(wording = c(names(reassign_pat), "ANY district-judge change (first four)"),
                 n_cases = c(vapply(names(reassign_pat), function(nm) sum(s[[nm]]), 1L), sum(s$any_reassign_wording)))
t2$pct_of_sample <- pct(t2$n_cases / nrow(s))
save_csv(t2, "2_wording")
cat("\n(2) Cases whose docket contains reassignment wording\n"); print(t2, row.names = FALSE)

t3 <- as.data.frame.matrix(table(factor(s$judge_status, levels = order_status),
                                 ifelse(s$any_reassign_wording, "reassign wording", "no reassign wording")))
t3 <- cbind(judge_status = rownames(t3), t3, row.names = NULL)
save_csv(t3, "3_crosstab")
cat("\n(1) x (2): number of cases\n"); print(t3, row.names = FALSE)

# By duration band - training cases only, so comparing with duration is allowed here.
s$duration_band <- cut(s$duration_capped_days, c(-Inf, 90, 365, 730, 1095, Inf),
                       labels = c("90 days or less", "91 days - 1 year", "1-2 years", "2-3 years", "over 3 years"))
t4 <- do.call(rbind, lapply(split(s, s$duration_band, drop = TRUE), function(g) data.frame(
  n_cases = nrow(g),
  pct_initial_entry_found = pct(mean(g$judge_status %in% order_status[1:2])),
  pct_different_judge = pct(sum(g$judge_status == order_status[2]) / max(1, sum(g$judge_status %in% order_status[1:2]))),
  pct_reassign_wording = pct(mean(g$any_reassign_wording)),
  pct_unassigned = pct(mean(g$judge_status == order_status[4])))))
t4 <- cbind(duration_band = rownames(t4), t4, row.names = NULL)
save_csv(t4, "4_by_duration")
cat("\nBy duration band (pct_different_judge is among cases with an initial entry found)\n"); print(t4, row.names = FALSE)

t5 <- do.call(rbind, lapply(split(s, s$court), function(g) data.frame(
  n_cases = nrow(g),
  pct_initial_entry_found = pct(mean(g$judge_status %in% order_status[1:2])),
  pct_different_judge = pct(sum(g$judge_status == order_status[2]) / max(1, sum(g$judge_status %in% order_status[1:2]))),
  pct_reassign_wording = pct(mean(g$any_reassign_wording)))))
t5 <- cbind(court = rownames(t5), t5, row.names = NULL); t5 <- t5[order(-t5$n_cases), ]
save_csv(t5, "5_by_court")
cat("\nBy court (15 largest in the sample; full list in the CSV)\n"); print(head(t5, 15), row.names = FALSE)

# Spot-check file: 200 comparable cases (judge names and the assignment text only).
set.seed(226)
idx <- which(comparable); idx <- idx[sample.int(length(idx), min(200, length(idx)))]
save_csv(s[idx, c("ucid", "court", "judge", "initial_window", "judge_status", "any_reassign_wording", "reassign_snippet")], "spotcheck")
# ... and 200 cases flagged by the district-level wording, with the matching text
idx <- which(s$any_reassign_wording); idx <- idx[sample.int(length(idx), min(200, length(idx)))]
save_csv(s[idx, c("ucid", "court", "judge", "judge_status", "reassign_snippet", district_flags, "magistrate_change")], "spotcheck_wording")

cat("\nPrecision: with", nrow(s), "cases, an overall percentage is accurate to about +/-",
    round(100 * 1.96 * sqrt(0.25 / nrow(s)), 1), "points (95%); per-court figures are much rougher.\n")
cat("Check the matching by hand in judges_reassign_spotcheck.csv before relying on it.\n")
cat("Tables saved in", checks_dir, "(judges_reassign_*.csv)\n")
