# Run summary: SCALES data on FarmShare

**Run:** Slurm job 1829877, 10 October 2026
**Result:** all five steps (00–04) finished. Every case and every event-log row was read.
**Log:** `~/scales_setup/scales_setup_1829877.out`. A copy is in `~/scales_project/logs/run_<date>_<time>.log`.
**Script edits:** see `CHANGES.md`.

> **Update, 10 October 2026:** Josh decided not to use the SCALES event log, and it has since been removed from the pipeline (`CHANGES.md`, change 8). The event-log results below are kept as a record of this run only. Open items 1 and 4 no longer apply.

---

## What ran, and how long it took

| Step | Started | Time taken |
|---|---|---|
| 00 setup, 01 file checks | before 12:58 | not shown in the lines I saw |
| 02 flatten cases | 12:58 | 24 min (23.0 min reading the archive, about 1 min converting to Parquet) |
| 03 convert event log | 13:22 | about 1 min |
| 04 profile | 13:23 | end time not checked |

Run `sacct -j 1829877 --format=JobID,State,Elapsed,MaxRSS` on FarmShare to get the total time and peak memory.

## The inputs

| File | Size | What was found |
|---|---|---|
| `raw/cross_sectional.tar.gz` | 2.37 GB | A tarball laid out as `cross_sectional/<court>/<yy>/<case>.json`, e.g. `innd/17/2-17-cv-00211.json`. Made on a Mac, so it contains hidden `._` and `.DS_Store` files. |
| `raw/event_log.csv` | 2.87 GB | A CSV with a `ucid` column in the same format as the case IDs |

Checksums are in `~/scales_project/raw/download_manifest.txt`.

## The tables (`~/scales_project/parquet/`)

| Table | Rows | Columns | Parquet size |
|---|---:|---:|---:|
| `cases` | 676,809 | 54 | 40 MB |
| `parties` | 3,215,086 | 22 | 52 MB |
| `counsel` | 4,491,692 | 17 | 71 MB |
| `docket_entries` | 23,216,702 | 8 | 976 MB |
| `criminal_counts` | 335,846 | 6 | 4.9 MB |
| `eventlog` | 4,811,483 | as in the CSV (see `profiles/eventlog.columns.csv`) | 24 MB |

The Parquet files total about 1.2 GB. Contact details (addresses, phones, faxes, emails) **are included** in `parties` and `counsel`, because `KEEP_CONTACT_INFO="yes"`.

The temporary `.jsonl.gz` files in `~/scales_project/flat/` can be deleted to free space once you're happy with the Parquet files. Check how much room they take with `du -sh ~/scales_project/*`.

## Quality checks

| Check | Result |
|---|---|
| Cases read vs. SCALES's stated count | **676,809 = 676,809** |
| Case files that couldn't be read | **0** |
| Files skipped | 3: two hidden Mac `._` files and one file with no extension (the `.DS_Store`). No case files were skipped. |
| Row counts after converting to Parquet | Same as written in step 02 for every table |
| Event-log lines the CSV reader couldn't parse | **0** |

## Cases by year folder and case type

From `profiles/cases.by_year_dir_and_type.csv`. The year folder (`year_dir`) is the two-digit year in the PACER case number, e.g. `17` in `2:17-cv-00211`. The rows add up to exactly 676,809.

| Year folder | Civil (`cv`) | Criminal (`cr`) | Total | % with a termination date |
|---|---:|---:|---:|---|
| 16 | 284,245 | 61,951 | 346,196 | civil 94.4, criminal 97.2 |
| 17 | 265,715 | 64,245 | 329,960 | civil 91.9, criminal 95.7 |
| 13–15 | | | 318 | |
| 18–21 | | | 270 | |
| 05–12 and 30 | | | 13 | |
| 61–98 (probably 1961–1998) | | | 52 | |
| **All** | **550,438** | **126,371** | **676,809** | |

- **Only two case types appear:** civil and criminal.
- **653 cases (0.1%) are outside 2016–17.** These are probably cases filed in 2016–17 but numbered under another year, or old cases reopened. They're a structural note, not a problem.
- **The totals don't match SCALES's published counts:**

  | Year | Published by SCALES | In this archive | Difference |
  |---|---:|---:|---:|
  | 2016 | 247,416 | 346,196 | **+98,780** |
  | 2017 | 319,718 | 329,960 | +10,242 |
  | Other years | | 653 | +653 |
  | **Total** | **567,134** | **676,809** | **+109,675** |

  Almost all of the extra cases are 2016 cases. That fits the 2016 cases having been collected differently, for example with some coming from third parties like RECAP. `profiles/cases.by_source.csv` should show whether that's the reason. It hasn't been checked yet.

## How the tables link

- All case tables link through `ucid` (e.g. `innd;;2:17-cv-00211`).
- **For 2016–17 civil cases, the event log covers N.D. Illinois (`ilnd`) and no other court** (confirmed by the count by court below). Across all years and types, its example IDs were all `ilnd` too. It has 175,268 cases in all. 23,065 of them are in the case file, and the rest are N.D. Illinois cases from other years (e.g. 2009, 2018).
- **Of the 23,512 N.D. Illinois cases in the case file, 23,065 (98.1%) have events.** Cases from the other 93 districts have none.
- So **any use of the event log limits the sample to N.D. Illinois 2016–17.** The case tables on their own cover all 94 districts.

### Count by court: 2016–17 civil cases only

Only cases whose number contains `:16-cv-` or `:17-cv-` are counted. Courts are sorted by event-log cases, then case-file cases, and the top 20 are shown. Every court after `ilnd` has 0 event-log cases, so no other court has any.

| Court | Event-log cases | Case-file cases | In both |
|---|---:|---:|---:|
| **ilnd** | **21,508** | **21,722** | **21,332** |
| laed | 0 | 34,408 | 0 |
| cacd | 0 | 28,586 | 0 |
| njd | 0 | 23,243 | 0 |
| nysd | 0 | 20,284 | 0 |
| flsd | 0 | 20,069 | 0 |
| wvsd | 0 | 17,405 | 0 |
| flmd | 0 | 17,103 | 0 |
| nyed | 0 | 14,776 | 0 |
| cand | 0 | 14,466 | 0 |
| paed | 0 | 12,542 | 0 |
| gand | 0 | 12,004 | 0 |
| txsd | 0 | 11,893 | 0 |
| azd | 0 | 11,414 | 0 |
| txnd | 0 | 11,072 | 0 |
| insd | 0 | 10,327 | 0 |
| mnd | 0 | 9,901 | 0 |
| caed | 0 | 9,304 | 0 |
| mied | 0 | 8,521 | 0 |
| txed | 0 | 8,144 | 0 |

For N.D. Illinois 2016–17 civil cases:
- **21,332 of the 21,722 in the case file (98.2%) have events.** 390 don't.
- **176 event-log cases aren't in the case file.**
- **E.D. Louisiana (`laed`) and S.D. West Virginia (`wvsd`) have more civil cases than their size would suggest.** This is probably multidistrict litigation (MDL), which can add tens of thousands of member cases to one court. The `is_mdl` column and `cases.by_court.csv` (% MDL) show this. Keep it in mind when picking courts.

## Not yet checked, or not sure

1. **The event log shrank from 2.87 GB to 24 MB**, about 120 times smaller. That's plausible if columns repeat the same values within each case, but it hasn't been confirmed. To check, compare `wc -l ~/scales_project/raw/event_log.csv` with the 4,811,483 rows, and look through `profiles/eventlog.columns.csv` for columns that are mostly empty.
2. **Why there are more 2016 cases than SCALES published.** The year split is done (see "Cases by year folder and case type"): the archive has 98,780 more 2016 cases than SCALES's published count. Whether the extra cases come from another source, such as RECAP, hasn't been checked. See `profiles/cases.by_source.csv`.
3. **The field report (`profiles/keys_report.csv`) hasn't been reviewed.** It may list fields that the scripts don't extract, or that are stored in a different form than the scripts expect.
4. **447 N.D. Illinois cases have no events** (390 of them are 2016–17 civil cases), and **176 N.D. Illinois 2016–17 civil cases in the event log aren't in the case file.** Neither group has been looked into.
5. **Some descriptions are out of date.** `EXPLAINER.md` and `BRIEF_for_Claude_Code.md` still say contact details are left out by default.
6. **Your FarmShare login shell is `tcsh`, not `bash`.** Commands with `$` inside double quotes fail there. Type `bash` first, or use single quotes. The scripts themselves run under `bash` and aren't affected.
7. **Two suggestions were left unchanged at your request:** party `raw_info` may contain addresses, and unparseable event-log rows would be dropped. In this run, 0 event-log rows were dropped.
