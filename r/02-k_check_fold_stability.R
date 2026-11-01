# =============================================================================
# 02-k_check_fold_stability.R — do 07-c, 07-d and 07-e get the same cross-validation
# folds every time they run? TRAINING CASES ONLY (Josh, 31 Oct 2026).
#
# xgb_training_data() in xgb_helpers.R reads the training cases with no ORDER BY and
# assigns folds by shuffling the rows in the order DuckDB returns them. train_fjc is
# built from several joins, so the order could change from run to run (more threads,
# a different machine), and with it every case's fold.
#
# This script calls the real xgb_training_data() 4 times, each in a FRESH DuckDB
# connection (00_sample.R re-run each time), with the thread counts in run_threads:
# DuckDB's default (all the cores it sees, which differs between FarmShare machines),
# then fixed counts. Each time it reads two column lists:
#   07-c   main + main_plus_counsel + sensitivity columns (07-c's three sets)
#   07-d/e main set only
# and compares the row order and the folds with run 1. Cases are matched by their
# values (all covariates, duration, ended-in-court), since the query doesn't read ucid;
# exactly identical rows are interchangeable, so that doesn't affect the result.
#   same_order            TRUE if every row came back in the same position
#   pct_same_fold         % of cases in the same fold (100 = identical folds; about 20
#                         would mean the folds are effectively reshuffled)
# PASS if every comparison is identical; FLAG otherwise.
# Output: ~/scales_project/checks/fold_stability.csv
# Batch job: --cpus-per-task=8 --mem=24G, under an hour (00_sample.R runs 4 times).
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
if (!requireNamespace("xgboost", quietly = TRUE))
  stop("The xgboost package isn't installed (xgb_helpers.R needs it). Run once in R:  install.packages(\"xgboost\")")
library(DBI)

# ---- Settings ------------------------------------------------------------------------
run_threads <- c(NA, NA, 4, 1)     # NA = DuckDB's default; the others are fixed thread counts
n_folds     <- 5                   # as 07-c / 07-d / 07-e
xgb_seed    <- 226
lists       <- list(`07-c`   = c("main", "main_plus_counsel", "sensitivity"),
                    `07-d/e` = "main")

runs <- list()
for (k in seq_along(run_threads)) {
  cat(sprintf("\n===== Run %d of %d (threads: %s) %s\n", k, length(run_threads),
              if (is.na(run_threads[k])) "DuckDB default" else run_threads[k], format(Sys.time(), "%H:%M:%S")))
  if (exists("con") && dbIsValid(con)) dbDisconnect(con, shutdown = TRUE)
  cfg <- if (is.na(run_threads[k])) list() else list(threads = as.character(run_threads[k]))
  drv <- if ("shared_home" %in% names(formals(duckdb::duckdb))) duckdb::duckdb(shared_home = FALSE, config = cfg) else duckdb::duckdb(config = cfg)
  con <- dbConnect(drv)                       # a new, empty database; 00_sample.R reuses it
  source(file.path(r_dir, "00_sample.R"))
  if (!file.exists(split_file)) stop("No holdout split for population \"", population, "\" yet - run 03_holdout.R first.")
  source(file.path(r_dir, "covariate_sets.R")); source(file.path(r_dir, "xgb_helpers.R"))
  threads_used <- dbGetQuery(con, "SELECT current_setting('threads') AS t")$t
  have <- dbListFields(con, "train_fjc")
  common <- c(intersect(main_vars, have), "duration_capped_days", "event_observed")
  runs[[k]] <- lapply(lists, function(l) {
    d <- xgb_training_data(make_sets(have, l), n_folds, xgb_seed)
    key <- function(cols) do.call(paste, c(lapply(d[cols], as.character), sep = "\r"))
    list(full = key(setdiff(names(d), "fold")), common = key(common), fold = d$fold, threads = threads_used)
  })
}
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)

# a case's identity: its values, numbered among exactly identical rows
ids <- function(key) paste(key, ave(seq_along(key), key, FUN = seq_along), sep = "\r#")
compare <- function(a, b, a_key, b_key, label, run) {
  same <- identical(a[[a_key]], b[[b_key]])
  ia <- ids(a[[a_key]]); ib <- ids(b[[b_key]])
  m <- match(ia, ib)
  data.frame(comparison = label, run = run, threads = b$threads, n_cases = length(ia),
             same_order = same,
             pct_rows_same_position = round(100 * mean(a[[a_key]] == b[[b_key]][seq_along(a[[a_key]])]), 2),
             pct_cases_matched = round(100 * mean(!is.na(m)), 2),
             pct_same_fold = round(100 * mean(a$fold == b$fold[m], na.rm = TRUE), 2))
}
rows <- list()
for (l in names(lists)) for (k in seq_along(runs)[-1])
  rows[[length(rows) + 1]] <- compare(runs[[1]][[l]], runs[[k]][[l]], "full", "full",
                                      sprintf("%s columns: run %d vs run 1", l, k), k)
for (k in seq_along(runs))                  # do 07-c and 07-d/e give a case the same fold?
  rows[[length(rows) + 1]] <- compare(runs[[k]][["07-c"]], runs[[k]][["07-d/e"]], "common", "common",
                                      sprintf("07-d/e vs 07-c columns, run %d", k), k)
res <- do.call(rbind, rows)
write.csv(res, file.path(checks_dir, "fold_stability.csv"), row.names = FALSE)

cat(sprintf("\nFold stability (training cases only; run 1 used %s threads):\n", runs[[1]][[1]]$threads))
print(res, row.names = FALSE)
ok <- all(res$same_order) && all(res$pct_same_fold == 100)
cat(if (ok) "\nPASS: every run gave the same row order and the same folds, for both column lists.\n"
    else "\nFLAG: the folds are not the same in every run (see pct_same_fold). Cross-script comparisons of 07-c / 07-d / 07-e used different folds.\n")
cat("Saved", file.path(checks_dir, "fold_stability.csv"), "\n")
