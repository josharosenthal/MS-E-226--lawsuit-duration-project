# Changes to the SCALES setup scripts

This is a record of every edit to the scripts, for the project's AI-use disclosure. Edits were made by Claude Code (Claude Opus 5.5) unless marked otherwise.

---

## 2026-10-10

### Made by Josh: keep contact information
- **File:** `config.sh`
- **Change:** `KEEP_CONTACT_INFO="yes"`, with a comment explaining why.
- **Why:** I haven't decided yet whether city, state or email domain could be useful, so I'm keeping them for now.

### 1. A corrupted download now stops the pipeline
- **File:** `01_check_files.sh` (the case-archive check, and the event-log check when it is a `.gz`)
- **Before:** `gzip -t FILE && echo "OK"`. In bash, a failed command joined by `&&` doesn't stop a script, even with `set -e`. A corrupted file printed an error, and the 1–2 hour flattening step then ran anyway.
- **After:** if `gzip -t` fails, the script prints `STOP: ... Re-download it.` and exits with an error, so `run_all.sh` stops too.
- **Effect on outputs:** none.

### 2. Skipped files are reported, and a run that reads no cases stops
- **Files:** `flatten_scales.py`, `02_flatten_cases.sh`, `config.sh`
- **Before:** files in the tarball whose names didn't end in `.json` were skipped without a count. If the real archive used another extension (e.g. `.json.gz`), the script would read 0 cases and the pipeline would carry on as if all were well.
- **After:**
  - The first skipped file name is printed, and at the end there is a count of skipped files by extension.
  - If no cases at all are read, the script stops with an error.
  - New setting in `config.sh`: `EXPECTED_CASES=676809`. Step 02 passes it to the script (`--expected-cases`), which prints a warning if it read a different number. This is only a warning; nothing stops.
  - The final summary now also says how many cases could not be read.
- **Effect on outputs:** no tables or columns changed. Only the log messages are new.

### 3. A case that fails partway no longer leaves partial rows
- **File:** `flatten_scales.py` (the `Writers` class and the main loop)
- **Before:** each row was written to disk as soon as it was built. If a case failed partway, for example on bad text in one docket entry, its parties and lawyers were already saved but its `cases` row was not. That left rows that didn't link to any case, and the failed case was still added to the total.
- **After:** a case's rows are held in memory until the whole case has been read, then written together. If anything fails, all of that case's rows are thrown away and the case is listed in `parse_errors.csv`. Failed cases are no longer added to the "cases read" total. Text is also converted to UTF-8 while the case is being read, so a text-encoding problem counts as a failure of that case rather than happening halfway through writing it.
- **Effect on outputs:** every row in `parties`, `counsel`, `docket_entries` and `criminal_counts` now belongs to a case in `cases`. The tables and columns are unchanged.

### 4. Hidden Mac files in the archive are skipped
- **File:** `flatten_scales.py` (`iter_cases`)
- **Why:** listing the real archive showed a `._cross_sectional` entry, which means it was made on a Mac. Macs can add a hidden `._` copy beside some files. Copies named like `._case.json` would have been logged as cases that couldn't be read, hiding any real errors.
- **After:** files whose names start with `._` are skipped. They're counted in the end-of-run line as `._ (Mac metadata)`, and the first one is printed by name.
- **Effect on outputs:** no tables or columns changed. These files hold Mac metadata, not case data. `parse_errors.csv` no longer lists them.
- **Tested:** on the fake archive, 6 `._` files were skipped and counted, and the only entry left in `parse_errors.csv` was the deliberately broken case.

### 5. Year and court folders read in the right order
- **File:** `flatten_scales.py` (start of `flatten_case`)
- **Why:** the brief expected paths like `…/<year>/<court>/<case>.json`. Listing the real archive showed `cross_sectional/<court>/<yy>/<case>.json` (e.g. `cross_sectional/innd/17/2-17-cv-00211.json`), with the court first and a two-digit year. The old code would have put the court in `year_dir` and the year in `court_dir`.
- **After:** of the two folders just above each file, the one made only of digits becomes `year_dir` and the other becomes `court_dir`, whichever order they're in. If there's no year folder, `year_dir` is left empty.
- **Effect on outputs:** same columns. `year_dir` and `court_dir` now hold the right values. `year_dir` keeps the folder name as it is (`17`, not `2017`).
- **Tested:** on three fake layouts: `innd/17` → year 17, court innd; `2016/azd` → year 2016, court azd; `vid` with no year folder → year empty, court vid.

### 6. New: matching cause-of-action codes to US Code section headings
- **New files:** `match_us_code.py` (the script) and `closed_civil_by_cause_titlesection_usc.csv` (its output)
- **Input:** Josh's `closed_civil_by_cause_titlesection.csv`, made in R: counts of closed 2016–17 civil cases by `cause_title` and `cause_section`. Those two fields were derived by Josh in R from `cause`. They aren't in the Parquet tables.
- **Reference data:** the 43 title files the input needs (306 MB), downloaded from https://github.com/CourtGPT/us-code. That repository mirrors uscode.house.gov at **release point 119-100 (26 June 2026)**, so it is the *current* US Code, not the 2016–17 version. The files were kept in a temporary scratch folder, not in the project.
- **What it does:** adds the title name, the matched section number, the section heading, how the match was made, a status flag (Repealed, Transferred, Omitted, …) and a link to the section on uscode.house.gov. The matching rules are described at the top of `match_us_code.py`. In short:
  - It tries an exact match first.
  - It then drops trailing letters one at a time (`1983pr` → § 1983). A letter followed by a digit is read as a subsection (`227b3` → § 227, not § 227b).
  - Duplicate entries picked up from the repository's editorial notes, which have ALL-CAPS headings, are ignored when a real section exists.
- **Result:** 1,186 rows covering 512,572 cases. **96.4% of cases got a heading** (94.2% exact). 2.2% had no matching section in the current Code, 1.3% had no title, and 0.1% used placeholder codes such as `88:8888`.
- **Effect on the pipeline:** none. The scripts and Parquet tables are unchanged.
- **Tested:** spot-checked tricky cases by hand: `42:2000e2o` → § 2000e–2, `47:227b3` → § 227, `42:1973gg6` → § 1973gg–6 (Transferred), `28:1605A` → § 1605A. That check found and fixed the § 227b mistake.

### 7. New step: FJC Integrated Database (civil outcomes), linked to SCALES cases
- **Requested by Josh** after we found that the SCALES tables record whether and when a case closed, but not how.
- **New files:** `05_import_fjc.sh` (the step), `fjc_district_crosswalk.csv` (FJC district codes → SCALES court abbreviations, all 94 districts, typed from the FJC codebook). `config.sh` gained `FJC_URL` and `FJC_ZIP`.
- **Source:** the FJC's *Civil Cases Cumulative File* (`cv88on.zip`, 330 MB zipped, 2.0 GB of tab-separated text, 46 columns). It covers cases terminated from 1988 through June 30, 2026, plus cases pending at that date. From https://www.fjc.gov/research/idb. Codebook: *Civil Codebook 1988 Forward* (25 October 2023).
- **New outputs:**
  - `parquet/fjc_idb_civil.parquet`: **every row and column** of the FJC file, kept as text so codes like `3A` and `-8` aren't altered, plus `fjc_row` (the record's line number in the file).
  - `parquet/scales_fjc_link.parquet`: one row per (SCALES civil case, matching FJC record). It holds the FJC outcome fields (`DISP`, `JUDGMENT`, `NOJ`, `PROCPROG`, `AMTREC`, filing and termination dates, `ORIGIN`, `STATUSCD`, and more), `filedate_agrees`, `n_fjc_matches` and `fjc_rank`.
  - `profiles/fjc.link_summary.csv`, `fjc.link_by_court.csv`, `fjc.link_by_year.csv`, `fjc.scales_courts_not_in_crosswalk.csv` and `fjc.rejected_lines.csv`.
- **Matching rule:** court (via the crosswalk) + office + docket number. SCALES `ilnd;;1:16-cv-04871` matches FJC district 52, office 1, docket 1604871. When a case has several FJC records (e.g. it was reopened), `fjc_rank = 1` goes to the record whose filing date equals the SCALES filing date, then to terminated records over pending ones, then to the latest file year. All matches are kept, so the choice can be changed later.
- **The download is recorded** in `raw/download_manifest.txt` (size and checksum).
- **Effect on existing outputs:** none. Steps 00–04 and their tables are unchanged.
- **Tested** on a Mac with DuckDB 1.4.1 (Python package standing in for the command-line tool), using fake SCALES cases and a fake FJC file with the real header. It correctly handled:
  - a reopened case (two records, original ranked first)
  - the `3A` (Florida Middle) and `7-` (Alaska) district codes
  - an unmatched case
  - a criminal case (left out)
  - a name containing quote marks
  - a court missing from the crosswalk (reported)

  **Not yet run on the real file or on FarmShare.**

### 8. Event log removed from the pipeline
- **Why:** Josh won't be using the SCALES event log. It covers only N.D. Illinois (see `RUN_SUMMARY.md`).
- **Deleted:** `03_convert_eventlog.sh`.
- **Edited:**
  - `config.sh`: removed `EVENTLOG_FILE`.
  - `00_setup.sh`: checks only that the case archive is in place, and the disk-space note was updated.
  - `01_check_files.sh`: removed the event-log check and the unused `peek` helper. The manifest now lists only the case archive.
  - `04_profile.sh`: removed the event-log section (columns, samples, events per case, value counts, link to cases).
  - `run_all.sh`: runs 00, 01, 02 and 04.
  - `EXPLAINER.md`: event-log content removed, and step 05 added to the list of files.
  - `RUN_SUMMARY.md`: a note that the event-log results are historical.
- **Not changed:** `BRIEF_for_Claude_Code.md`, which is the original brief and is kept as written. Steps 02 and 05 never used the event log. The files already on FarmShare (`raw/event_log.csv`, `parquet/eventlog.parquet`, `profiles/eventlog.*`) were not touched. Josh can delete them to free space.
- **Effect on outputs:** a future run won't create `eventlog.parquet` or the `eventlog.*` reports. Nothing else changes.
- **Checked:** all scripts pass a bash syntax check, and none of them refers to the event log any more.

### 9. FJC import: repair malformed lines so every row is kept
- **Why:** the first real run of step 05 read 10,959,525 FJC rows but rejected 1,200 lines: 1,190 "too many columns" and 10 "invalid encoding". Rejected rows are left out of the Parquet file, which goes against the keep-everything rule. Checking the zip on FarmShare showed:
  - rows from Ohio Northern (district 47, filed 2005–2010) where a **tab inside a party name** split it into two columns and shifted every later field one place right
  - lines that **aren't UTF-8** (accented characters in Latin-1)

  `awk` counted 86 over-long rows where DuckDB rejected 1,190. The likely reason is that DuckDB also treats a stray carriage return inside a line as a line break.
- **New file:** `fix_fjc_text.py` (standard-library Python). It runs between `unzip` and DuckDB and, for each line:
  - rejoins split names: fields 1–21 and the last 23 are fixed, so PLT gets the first piece in between and DEF the rest, joined with spaces
  - reads non-UTF-8 lines as Latin-1
  - replaces stray carriage returns with a space
  - pads short rows with blanks

  It lists every changed line (line number and reason only) in `profiles/fjc.repaired_lines.csv`, and stops if the header doesn't have 46 columns.
- **Edited:** `05_import_fjc.sh`. Part A pipes the unzipped text through `fix_fjc_text.py`, and Part B tells DuckDB that lines end only at `\n`.
- **Effect on outputs:** `fjc_idb_civil.parquet` should now hold every row. In repaired rows the coded fields are in their correct columns. Party names that contained a tab come out with a space instead, and if the tab was in the plaintiff's name, part of it moves into DEF. New report: `fjc.repaired_lines.csv`.
- **Tested** on a Mac with fake lines modelled on the real problems: a split defendant like the real `"<tab>BUDZIK"` row, a row with tabs in both names, a Latin-1 name, a stray carriage return and a short row. All were read with 0 rejects, and the coded fields came out correct. **Not yet re-run on the real file.**

### 10. New: R code for missingness and consistency checks
- **New file:** `missing_data_check_code.txt`, R code to paste into RStudio. Nothing in the pipeline changes.
- **What it does:** it builds the same sample as `fee_search_code.txt` (closed 2016–17 civil cases, minus 28 USC 2241/2254/2255 and 42 USC 1983pr), joins the best FJC match (`fjc_rank = 1`), and reports:
  - **A.** how many cases have an FJC record
  - **B.** missing values in the FJC fields, using the codebook's rules. `-8` counts as missing, except in `IFP`, where it means "not IFP". `JUDGMENT` and `NOJ` count as not applicable unless the case ended in a judgment, `TRCLACT` unless a class action was alleged, and the termination date for pending cases.
  - **C.** missing values in every SCALES column: NULL, blank text or `[]`
  - **D.** agreement between SCALES and the FJC on nature of suit, jurisdiction, filing date and termination date (exact, and within 7 days for dates), with a check of the jurisdiction text-to-code mapping and the most common nature-of-suit disagreements
- **Scope, at Josh's request:** overall figures only. Nothing is broken down by court, case type or outcome.
- **Added the same day, at Josh's request: duplicate checks and removal** (section 0, built in steps 4–5).
  - **Same case number:** each case gets a `case_number_key` (court | office | year + 5-digit sequence, the key used for the FJC match). Rows sharing a key are reduced to one: the most docket entries, then the latest `download_timestamp`, then the first `ucid` alphabetically. This removes both the same `ucid` listed twice and the same case under two spellings of its `ucid`. A `ucid` that doesn't fit the usual pattern is its own key and is never merged.
  - **Shared FJC record:** if one FJC record is the best match for two cases, neither case gets FJC data, but both stay in the sample.
  - **Reporting:** `dup_report` gives the counts before and after, and `dup_examples` lists up to 20 duplicate groups.
  - **Effect:** sections A–D now run on the de-duplicated sample. The view previously called `analysis_cases` is now `analysis_cases_raw`, and `analysis_cases` is the de-duplicated version.
  - **Tested** on fake data: an exact duplicate row, two spellings of one case with different docket counts, two unusual IDs and two cases sharing an FJC record. All were handled as intended, with 0 duplicate rows left in the final table.
- **Tested:** every SQL statement was taken from the file as written and run with DuckDB 1.4.1 against fake tables using the real column names. The results matched hand-calculated values. Testing caught that DuckDB doesn't accept `UNPIVOT` written around a subquery, so the queries use the SQL-standard form (`FROM … UNPIVOT INCLUDE NULLS (val FOR field IN (…))`). **Not yet run on the real data.**

### 11. R code reorganised: one shared sample definition, plus a holdout step
- **Why:** the sample was defined separately in each `.txt` file, and the copies had already drifted apart (`fee_search_code.txt` didn't remove duplicates). Josh chose a shared setup file loaded by separate task files.
- **New folder `r/`:**
  - `00_sample.R`: the only place the sample is defined (closed 2016–17 civil cases, minus 28 USC 2241/2254/2255 and 42 USC 1983pr, duplicates removed, best FJC match joined). It creates the views `analysis_cases`, `analysis_fjc`, `train_cases` and `train_fjc`. It loads the holdout split if one exists, and warns if some sample cases aren't in it, which would mean the sample definition changed after the split was made.
  - `01_data_checks.R`: the duplicate, missingness and consistency checks from `missing_data_check_code.txt`, unchanged. They run on the whole sample, since they're data-quality checks.
  - `02_fee_search.R`: the fee search from `fee_search_code.txt`. It now uses the de-duplicated sample, and once the holdout exists it searches **training cases only**.
  - `03_holdout.R`: **new.** It draws a simple random 20% holdout once (seed 226, IDs sorted in a fixed order first so the same seed always gives the same split) and saves it to `~/scales_project/holdout_split.csv`, with a README recording when and how. It refuses to run if the file already exists.
- **Also fixed:** `00_sample.R` connects with `duckdb(shared_home = FALSE)` when the package supports it. Newer duckdb versions otherwise stop in RStudio to ask where to keep their files, and that question is probably what swallowed a pasted line earlier ("Unrecognized response").
- **Removed:** `fee_search_code.txt` and `missing_data_check_code.txt`, both replaced by `r/`.
- **Updated:** `EXPLAINER.md`, which now lists the R files.
- **Tested** on a Mac with R 4.6.1 and the duckdb R package 1.5.6, on fake data, running all four files in the real order:
  - the checks matched the earlier test
  - the fee search before the split found all three fee entries and skipped a "filing fee" entry
  - the split was saved with its README
  - the fee search after the split left out the holdout case
  - a second `03_holdout.R` stopped without changing the file
  - running `00_sample.R` twice reused the connection

  **Not yet run on FarmShare.**

### 12. Fix: "not applicable" could hide real values; new class-action table
- **File:** `r/01_data_checks.R`
- **The bug (mine, from change 10):** section B marked `TRCLACT` as *not applicable* whenever `CLASSACT` ≠ 1, and `JUDGMENT`/`NOJ` whenever the case didn't end in a judgment, **even when the field had a value**. Inconsistent records, such as a certification ruling with no class allegation recorded, were therefore hidden instead of counted. Found while Josh was looking into class-action discrepancies.
- **Fix:** a field now counts as *not applicable* only when it is also empty (`-8`, blank, or `0` for `JUDGMENT`/`NOJ`). If it has a value, it counts as present.
- **New table `class_action_codes`** (section D): every `CLASSACT` × `TRCLACT` combination among matched cases, with a plain-language reading. The readings are: alleged and certified, alleged and denied, alleged with no ruling recorded, **inconsistent** (ruling recorded but no allegation), not a class action, or **undocumented code**.
- **Tested** in R on 7 fake cases covering every combination. The counts and percentages matched hand calculations, and the inconsistent and undocumented cases now appear.

### 13. Duplicate reports saved as CSV files
- **File:** `r/01_data_checks.R`, at Josh's request.
- **Change:** section 0 now always writes three CSV files to `~/scales_project/checks/` (the folder is created if needed):
  - `duplicates_summary.csv`: the `dup_report` counts
  - `duplicates_all_groups.csv`: **every** duplicate group, not just the 20 shown on screen, with a `kept` column marking the row that stayed in the sample
  - `duplicates_shared_fjc_records.csv`: FJC records that were the best match for more than one case, whose FJC data was blanked
- The optional, commented-out `write.csv` lines for the other tables now point to the same `checks/` folder, and one was added for `class_action_codes`.
- **Tested** in R on fake data with duplicates (all rows listed, the right copy marked as kept) and without (the files are written with headings only).

### 14. Fee search: requests separated from rulings
- **File:** `r/02_fee_search.R`, rewritten at Josh's request.
- **Why:** a ruling usually repeats the request's name ("ORDER granting [45] MOTION for Attorney Fees"), and so do responses and supporting memoranda, so a keyword match can't tell them apart.
- **How:** each fee-related entry is classified by the document type it **starts with**, checked in a fixed order: `recommendation`, `ruling` (an order type plus grant/deny/award/moot, or a Judgment), `order_other`, `response_or_support`, `stipulation`, `request` (a motion/petition/application *for* fees, excluding extension and leave-to-file motions), `other_motion`, `possible_ruling` and `other_mention`. Rulings are linked to the request they decide through the docket number they cite (`[45]`), matched to the entry number `ind`.
- **Which cases (Josh's question about the holdout):**
  - `fee_request_cases` (requests only) covers the **whole sample** and is saved to `~/scales_project/fee_request_cases.csv`. Finding fee requests can define the population, and that should happen before the holdout is drawn.
  - `fee_entries` and `fee_cases`, which include rulings (a likely outcome), cover **training cases only** once the split exists. Before then they cover the whole sample, with a printed warning.
- **New outputs:** `fee_cases`, one row per case with request and ruling counts and dates, and `fee_request_cases.csv`.
- **Tested** in R on 17 fake docket entries written in typical wording, including rulings, a response and a memorandum that repeat the motion name, a scheduling order, an "entered and continued" minute entry, an extension motion, a magistrate's recommendation, a judgment, a stipulation and a filing-fee entry. All 16 fee entries were classified as expected and the filing-fee entry was excluded. Rulings citing a request were linked, and after the split the ruling details covered training cases only. **Not yet run on real docket text**, where the wording will vary more.

### 15. Three populations: all cases, fee-request cases, fee-shifting cases
- **Requested by Josh** after discussing that fee requests come mostly from parties who have won, so restricting to them selects on part of the outcome. He wants to be able to compare that population with all cases and with a population he defines by fee-shifting causes of action.
- **Design:** `r/00_sample.R` stays the single definition of the **base sample**. A `population` setting, chosen before sourcing any script (default `"all"`), then restricts it:
  - `"all"`: the whole base sample
  - `"fee_requests"`: base-sample cases listed in `fee_request_cases.csv`, which `02_fee_search.R` creates (run it once with population `"all"`)
  - `"fee_shifting"`: base-sample cases matching **any** row of the new `r/fee_shifting_codes.csv`, which Josh fills in. Cause codes can be exact (`42:1983`), the section followed only by letters (`42:1983+`, catching PACER tags such as `1983cv`), or "starts with" (`42:121*`). Nature-of-suit rows (`nos,440`) match the 3-digit code in SCALES `nature_suit`. The template has common fee-shifting statutes as **commented-out examples only**. Nothing is included until Josh adds rows.
- **Each population has its own holdout split:** `~/scales_project/holdout_split_<population>.csv`, with a README recording the population and, for `"fee_shifting"`, the codes used. An existing `holdout_split.csv` is treated as the `"all"` split.
- **Other changes:**
  - `all_cases` is the new name of the de-duplicated base sample, and `analysis_cases` is now the chosen population.
  - The duplicate reports in `01_data_checks.R` describe the base sample, so they are the same for every population. The optional CSV names include the population.
  - `02_fee_search.R` always finds requests across the whole base sample. Its ruling outputs follow the chosen population and its holdout.
  - The shared-FJC-record check runs on the base sample, so a record shared with a case outside the population still counts as ambiguous.
  - `EXPLAINER.md` was updated.
- **Tested** in R on fake data with 8 cases of varied causes and fee requests in some dockets:
  - population `"all"`: requests found, and the "each side bears its own fees" order ignored
  - `"fee_requests"`: exactly the cases with a request, with its own split file
  - `"fee_shifting"`: stops while the codes file has only examples. Exact, letters-only and prefix codes matched as intended, including a leading zero, upper-case letters, a nature-of-suit-only list and a case with no cause. A malformed code stops with a clear message.
  - the data checks still ran

### 16. New: one case as a readable markdown page
- **New file:** `r/04_random_case.R`, at Josh's request.
- **What it does:** picks one case from the merged SCALES + FJC table, at random or by `case_ucid`, with `case_seed` to repeat a draw. It writes `~/scales_project/case_views/<ucid>.md`, containing:
  - the key SCALES fields
  - the FJC outcome codes with their meanings from the FJC codebook (`ORIGIN`, `JURIS`, `PROCPROG`, `DISP`, `NOJ`, `JUDGMENT`, `CLASSACT`, `TRCLACT`, `PROSE`, `IFP`, `STATUSCD`), with `-8` shown as "missing / not recorded" and unknown codes flagged
  - every other non-empty SCALES field
  - the docket, cut to the first and last entries when it's long (`max_entries`, default 60)

  The file opens in RStudio.
- **Which cases:** for the chosen population, **training cases only once its holdout exists**. Josh's tweak: `case_pool <- "1983pr"` or `"habeas"` shows a case **excluded from every population** instead, taken from the closed 2016–17 civil cases before duplicate removal with its best FJC match, so he can see what was dropped without touching any sample or holdout.
- **Tested** in R on fake data:
  - the 1983pr and habeas pools returned only those cases
  - the sample pool never returned an excluded case over eight seeds
  - the same seed gave the same case, and a 1983pr case requested from the sample pool was refused
  - long dockets were shortened, and pipes and line breaks in docket text didn't break the page

  Testing also caught an R syntax error (an `else` at the start of a line), which was fixed.
- **Fix after Josh's first run:** the page now opens automatically only in RStudio. In R in a terminal, `file.edit()` would have started a text editor such as `vi`, so the script just prints the path to read with `less`. (His run had actually failed for a different reason: FarmShare still had the pre-change-15 `00_sample.R`, which doesn't define `population`.)
- **Also:** Claude's test copies of DuckDB (Python 1.4.1, R 1.5.6) now live in `~/.cache/scales_setup_test`, outside the temporary folder macOS keeps clearing and outside Dropbox. They're test tools only, with no data, and are safe to delete.
- **Done later (see change 17):** adding `04_random_case.R` to `EXPLAINER.md`. It was delayed because Dropbox had made that file online-only.

### 17. EXPLAINER.md brought up to date
- **Why:** Josh asked once the Dropbox folder was available offline again. The guide was out of date in several places.
- **Changes:**
  - The two FJC tables are added to section 1.
  - The privacy note now says contact details **are** kept (`KEEP_CONTACT_INFO="yes"`). It used to say they were left out.
  - Section 3 lists every file, grouped as data-building, `r/` and other, including `fix_fjc_text.py`, `match_us_code.py`, `04_random_case.R`, `CHANGES.md` and `RUN_SUMMARY.md`.
  - Section 4 lists the new FJC and R outputs and gives the answer to the year-count question.
  - Section 5 adds step 05 (FJC), the R workflow and practical tips: tcsh, prompts, two Terminal windows, passwords, Dropbox online-only files.
  - Section 6 adds analysis cautions: per-population holdouts, fee-request selection, closed-cases-only sampling, FJC code quirks, one cause per case, MDL dockets.
  - Section 7 now gives the testing status.
- No scripts changed.

### 18. New: count of un-terminated cases
- **New file:** `r/05_open_cases.R`, at Josh's request.
- **What it does:** looks at **all** cases in `cases.parquet`, not just the sample, which keeps closed cases only. A case counts as un-terminated if `case_status` isn't "closed", ignoring capitals and spaces, with blanks counting as not closed. It reports:
  - closed vs not closed by case type and year (2016, 2017, other), with totals
  - cases where `case_status` and the termination date disagree
  - every `case_status` value
  - for open 2016–17 civil cases, whether the FJC file (to mid-2026) shows them terminated later, and in which year, or still pending, or has no record

  This measures the size of the closed-cases-only restriction. Nothing is broken down by court or outcome. Four CSV files are saved to `~/scales_project/checks/`.
- **Tested** in R on 11 fake cases, including mixed-case and blank statuses, a closed case with no date, an open case with a date, criminal cases, an "other year" case, and open civil cases that later closed, are still pending, or have no FJC record. All counts matched.
- **Also updated:** `EXPLAINER.md` lists the new file and its outputs.

### 19. Project data set defined: open cases now included
- **Josh's decision:** the data set is civil cases filed in 2016 and 2017, excluding habeas cases and cases marked 1983pr. **This is a change: the sample previously included only closed cases.** "Filed in 2016 and 2017" stays defined by the year in the case number (`year_dir`), as Josh chose, which is how SCALES built the data.
- **`r/00_sample.R`:**
  - removed the `case_status = 'closed'` filter
  - renamed the first view from `closed_civil` to `civil_cases`
  - added `case_closed` (TRUE if SCALES recorded the case as closed at collection, ignoring capitals; blanks count as not closed)
- **Other R files:** `04_random_case.R` uses `civil_cases` for the excluded-case pools and shows `case_closed` on the page. Descriptions were updated in `03_holdout.R` (README text) and `05_open_cases.R`.
- **`EXPLAINER.md`:**
  - Josh's definition is at the top, with a note on how the code implements it
  - the `00_sample.R` row is updated
  - the closed-cases caution is replaced by one on open (censored) cases, pointing to the FJC end dates and `05_open_cases.R`
- **Consequences for files already on FarmShare:**
  - `fee_request_cases.csv` was built from the closed-only sample. Re-run `02_fee_search.R` with population `"all"` to include open cases.
  - Any holdout split made before this change no longer matches its population. `00_sample.R` warns about this. Delete those `holdout_split_*.csv` files and redraw them with `03_holdout.R`.
- **Tested** in R on fake data: the base sample kept all eight 2016–17 civil cases, open and closed, and dropped the 2015 and criminal cases. `case_closed` was correct for "closed", "open", "Open" and a blank status. `01_data_checks.R`, `04_random_case.R` and `05_open_cases.R` all ran. In the termination-date consistency check, open cases that the FJC shows ending later appear as "FJC only", which is expected.

### 20. Dependent variable: duration, capped, with an overlong marker
- **Josh's decision:** the dependent variable is case duration. Any case longer than the time from **30 Dec 2017** to the **last FJC update date** is marked "longer than [that number of days]".
- **`r/00_sample.R`:**
  - New settings: `duration_cap_start` = 2017-12-30, and `fjc_data_through` = 2026-06-30, the FJC file's stated coverage ("cases terminated … through June 30, 2026", from its download page). `duration_cap_days` = **3,104**.
  - New columns in `analysis_fjc` and `train_fjc`:
    - `start_date`: SCALES filing date, or the FJC's if SCALES has none
    - `end_date`: the SCALES termination date if the case was closed at collection, otherwise the FJC termination date if it ended by mid-2026
    - `end_date_source`
    - `duration_days`: uncapped
    - **`duration_capped_days`:** the dependent variable. The days, or 3,104 if overlong.
    - **`is_overlong`**
    - `duration_status`: `ended`, `longer_than_cap`, `unknown_end`, `pending_short_followup`, `no_filing_date` or `end_before_start`
  - A case still pending in the FJC file is overlong if it has been followed for at least the cap.
- **`r/01_data_checks.R`:** new section E, `duration_coverage`, counting cases by `duration_status` and end-date source (coverage only, no duration statistics). Also `fjc_dates_check`, which confirms no FJC termination date is later than `fjc_data_through`.
- **`r/04_random_case.R`:** the case page shows duration status, capped duration and end-date source.
- **`EXPLAINER.md`:** the dependent variable is described at the top. The open-cases caution now points to it.
- **Tested** in R on 8 fake cases, one per scenario: ended in SCALES; open but ended in the FJC (1,855 days, matching a hand calculation); ended after the cap; still pending; open with no FJC record; missing SCALES filing date; end before start; and filed 31 Dec 2017 and still pending. All were classified as designed.
- **Noted for Josh:** with a 30 Dec start, a case filed on 31 Dec 2017 that is still pending has been followed one day less than the cap, so it gets `pending_short_followup` and no value. Starting on 31 Dec 2017 (cap 3,103) would avoid that. Left at Josh's 30 Dec date pending his decision.

### 21. New: covariate spreadsheet
- **New file:** `covariates.xlsx`, at Josh's request.
- **Covariates sheet:** one row for each of the 86 columns in `analysis_fjc` / `train_fjc` (checked against `flatten_scales.py`, the derived fields in `00_sample.R`, the FJC link and the duration fields: none missing, none extra). Each row has a group, a description, **continuous / categorical** (also binary, date, text, ID), **known at filing?** (Yes / Partly / No / n/a), and notes on leakage, coding and missingness. Column A is a **Use? (Yes / Maybe / No)** drop-down for Josh, with counts at the top.
- **Not yet joined sheet:** 19 variables that exist in the data but aren't in the merged table: FJC fields such as `DEMANDED`, `CIRCUIT`, `RESIDENC` and `COUNTY`, and features that could be built from parties, counsel or early docket entries.
- **Legend sheet:** how to use it, and what the type and filing-time categories mean.
- **Formatting:** rows that aren't known at filing (which would leak duration) are shaded red, and dependent-variable rows blue.
- The "known at filing" judgments are Claude's reading of the data and codebook, for Josh to check. The only formulas are the two `COUNTIF` counts. LibreOffice wasn't available to recalculate them, so Excel calculates them on opening.

### 22. Covariate spreadsheet: questions on Josh's choices, and an amicus variable
- **Josh filled in** `covariates.xlsx`: Use? marks plus JR Notes (column I on Covariates, column H on Not yet joined).
- **Claude added** a "Claude: needs clarifying" column (J on Covariates, I on Not yet joined), with the row's variable cell highlighted orange, for 18 items:
  - unclear treatment: `case_name`, `judge`, `referred_judges_json`, `cause_section`, `is_multi`, `lead_case_id`, `CIRCUIT`, `RESIDENC`, `COUNTY`, government party, firm size, the `.org` email flag, the TRO/PI window
  - possible leakage in a Yes or Maybe choice: `n_counsel`, `referred_judges_json`, `is_multi`, `lead_case_id`
  - unmarked rows: `summary_presiding`, `PLT / DEF`
  - one assumption to confirm: case-number parity

  None of Josh's entries were changed (checked cell by cell against a backup).
- **New row (Josh's request):** "amicus brief filed" on Not yet joined, marked Yes. Binary, not known at filing. To be built from docket text and party roles containing "amicus". The note explains the leakage (longer cases have more time to attract amici), with a question on how to handle it. The drop-down and Yes/Maybe counts now include the new row.

### 23. Covariates built, as specified in covariates.xlsx
- **Josh's specifications** (JR notes and answers in `covariates.xlsx`, plus decisions in chat):
  - **Case-number parity:** odd/even of the last digit of the sequence (courts and judges sometimes split work by odd/even).
  - **Filing month and weekday.**
  - **Judge:** grouped, with judges with fewer than 20 training cases as "other". Plus **senior judge at filing**, from the FJC directory.
  - **Referral:** yes/no, despite leakage.
  - **Cause:** title/section pairs with at least 100 training cases, otherwise "title:other".
  - **Related case:** yes/no.
  - **Consolidation:** `is_multi` yes/no, plus lead/member.
  - **`n_counsel`:** kept, despite leakage.
  - **Circuit:** kept, as an alternative to court.
  - **Diversity residence:** the plaintiff–defendant pair, plus "not diversity".
  - **County:** urban/suburban/rural/out of state/non-US, using the **2013** NCHS scheme with **only large central metro counted as urban**.
  - **First plaintiff and defendant entity types; party counts.**
  - **Plaintiff firm:** one **4-level** variable by number of cases (1–10, 11–20, 21–50, over 50).
  - **Defendant firm:** **BCG headcount rank in buckets of 20.**
  - **`.org` attorney:** plaintiff side only.
  - **TRO/PI motion:** within **60 days** of filing.
  - **Amicus:** any time, despite leakage.
  - Dropped as redundant: `case_name`, `PLT/DEF`, government party.
- **New `reference/` folder:** lookup tables built by `reference/build_reference.py`, with sources and caveats in `reference/README.md`. The FJC Article III judge directory (1,081 district judgeships active in 2016–17, 91 courts); the NCHS 2013 county codes (3,149 counties) with Josh's mapping; and the BCG firm list (188 firms, 183 with headcount), kept as firm name and headcount only, ranked by headcount, with 2016–17 names added for later mergers (e.g. Troutman Sanders → Troutman Pepper Locke).
- **New `r/06_build_features.R`:** run once. It builds the case-level covariates for all 2016–17 civil cases into `parquet/case_features.parquet`, and writes `checks/features_report_*.csv` covering coverage, judge, county and firm matches, and the top plaintiff firms.
  - Judges are matched by name within court (handling accents, multi-word and hyphenated surnames). Magistrate judges are flagged separately.
  - Entity types are guessed from party names using keyword rules.
  - Firm names are cleaned. "&" and "and" are dropped for large-firm matching, and entity endings are also dropped for counting, so "Mid Firm P.C." and "Mid Firm PC" count as one firm. "Steptoe & Johnson PLLC" is deliberately not matched to Steptoe LLP.
- **`r/00_sample.R`:** joins `case_features.parquet` when it exists. Adds `filing_month` and `filing_weekday`, and the training-based `judge_group` and `cause_group`, whose thresholds use the population's **training** cases once its holdout exists, and all its cases before that.
- **`covariates.xlsx`:** a "Built as" column names each resulting variable, and answered questions are now green. None of Josh's entries were changed (checked against a backup).
- **Tested** in R on fake data with real N.D. Illinois judge names (senior before and after the senior-status date, an accent, a two-word and a hyphenated surname, a magistrate, an unknown judge), real county FIPS codes, firms under 2016 and current names, and look-alike firm names. Also 60 filler cases for the firm-size buckets, and docket entries testing the 60-day TRO window and amicus wording. Testing found and fixed two firm-matching bugs: "&" stopped Kirkland & Ellis matching, and "P.C." vs "PC" split one firm into two. **Not yet run on the real data.**
- **To review on the real data:** the judge match rate, the county match rate (this checks the assumption that FJC county codes are FIPS codes), the large-firm matches, and a sample of entity types.

### 24. Holdout split fingerprint check
- **Josh's request:** make sure the split stays the same across FarmShare sessions.
- **`r/03_holdout.R`:** when it makes a split, it also writes `holdout_split_<population>.md5`, holding the file's MD5 checksum and when it was recorded.
- **`r/00_sample.R`:** every session, it compares the split file with its fingerprint. If they differ, it **stops**, loads nothing, and explains how to restore the file or record a deliberate redraw. A split made before this check (no `.md5` yet) is fingerprinted the first time it's loaded. Redrawing on purpose now means deleting both the `.csv` and the `.md5`.
- **`EXPLAINER.md`:** describes the fingerprint and the habits that protect the split (check the printed counts, make it read-only, keep a backup, don't change the population afterwards).
- **Answered (no change):** `config.sh` holds only the data-building settings. The R settings are `population`, set before `source()`; the holdout share and seed in `03_holdout.R`; the duration cap in `00_sample.R`; the thresholds in `00_sample.R`; and `fee_shifting_codes.csv`. A single `r/settings.R` was offered.
- **Tested** in R on fake data: making a split wrote the fingerprint; an unchanged file loaded; an altered file was refused with the message; restoring the backup loaded again; and a split with no fingerprint was fingerprinted on its first load and loaded normally afterwards.

### 25. Warning when the covariates are out of date; fee work parked
- **Stale-features check (Josh's request):**
  - **`r/06_build_features.R`** now writes `parquet/case_features_inputs.csv` when it finishes. It records what the features were built from: size and modification time for the six data tables (`cases`, `parties`, `counsel`, `docket_entries`, `fjc_idb_civil`, `scales_fjc_link`), and an MD5 checksum for the three reference tables, the court crosswalk and the script itself. Checksums are used for the small files so that re-copying an unchanged file with `scp` isn't taken as a change.
  - **`r/00_sample.R`** compares the current files with that record each session. If anything has changed, it warns: "case_features.parquet may be OUT OF DATE", naming the files. Features built before this check give a one-time warning until 06 is re-run.
  - **For the version without this check,** a manual alternative is to list inputs newer than the features file with `find … -newer case_features.parquet`.
- **Also fixed:** `06_build_features.R` now converts `case_id`, `judge`, `lead_case_id` and the JSON list columns to text when it reads the cases, so a column that is entirely blank can't cause a type error.
- **Tested** in R on fake data: no warning right after a build; no warning when a reference file was re-copied unchanged; a warning naming `counsel.parquet` after it was rebuilt; a warning naming `large_firms_bcg_2026.csv` after it was edited; a one-time warning when the record was missing.
- **Fee work parked (Josh's decision):** `r/02_fee_search.R`, the `"fee_requests"` and `"fee_shifting"` populations and `fee_shifting_codes.csv` are kept and still work, but are no longer part of the current project. `EXPLAINER.md` labels them "Parked" and its R workflow no longer includes them. `02_fee_search.R` has a note saying so at the top. No code was removed.

### 26. New: pre-split check report
- **New file:** `r/07_presplit_checks.R`, at Josh's request, including a check of removed and transferred cases, which Josh suspected are part of what `is_multi` captures.
- **What it reports,** as PASS / FLAG / INFO / OPEN lines, with tables in `checks/presplit_*.csv` and the report in `presplit_report.txt`:
  1. sample size, open vs closed, and the year split
  2. duplicates
  3. covariates: built and up to date; missing for over 10%; judge match rate; county codes not found in the FIPS list; large-firm match rate
  4. duration coverage, and no FJC termination dates after the cap date
  5. related cases: number of MDL cases and MDLs, share held by the 10 largest, `is_multi` and lead-case counts and how they overlap
  6. how cases arrived (FJC `ORIGIN`: original, removed, transferred in, MDL in or originating, reopened) cross-tabulated with `is_multi`, `is_mdl`, lead case and listed other courts; agreement between SCALES `is_mdl` and FJC `ORIGIN` 6/13; and cases that **ended** by transfer or remand (`DISP` 0, 1, 10, 11), **overall counts only**, because `DISP` is an outcome and isn't compared with any covariate before the split
  7. decisions still open: the cap start date, how to split given related cases, and how to treat transferred or remanded cases and cases without a duration
  8. R and DuckDB versions and `sessionInfo()`, saved for the write-up
- **Thresholds for FLAG:** any duplicates left; covariates missing or out of date; more than 10% of a covariate missing; more than 10% of judges unmatched; more than 5% of county codes unmatched; more than 5% of cases without a duration; MDL cases over 5% of the sample; SCALES/FJC MDL agreement under 80%.
- **Tested** in R on 100 fake cases (40 original, 20 removed with half flagged `is_multi`, 10 transferred in, 20 MDL transfers in, 5 MDL filed directly, 5 MDL originating, one with no FJC record, and some ending by remand or transfer). Every count matched the design. It also ran correctly before the covariates were built, flagging them and running the other checks.
- **`EXPLAINER.md`:** lists the script and adds it to the R workflow before `03_holdout.R`.

### 27. Check scripts merged; R scripts renumbered in the order they're run
- **Josh's request:** merge the check scripts (including the open-cases script), number the scripts in sequence, and give the parked fee script 99.
- **New numbering** (`r/` folder; the bash data-building scripts 00–05 keep their numbers):

  | Now | Was |
  |---|---|
  | `00_sample.R` | unchanged |
  | `01_build_features.R` | `06_build_features.R` |
  | `02_data_checks.R` | **merged** from `01_data_checks.R` + `05_open_cases.R` + `07_presplit_checks.R` |
  | `03_holdout.R` | unchanged |
  | `04_random_case.R` | unchanged |
  | `99_fee_search.R` | `02_fee_search.R` (parked) |

- **`02_data_checks.R`:** **Part 1** is the PASS / FLAG / INFO / OPEN summary (the former 07). **Part 2** is the detailed tables (the former 01). **Part 3** is the open-case counts across all cases (the former 05). The setup is done once at the top; the content of each check is unchanged. Output files keep their names (`presplit_*`, `duplicates_*`, `open_*`).
- **References updated** in `00_sample.R` (including the stale-features record, which now lists `01_build_features.R`), `01_build_features.R`, `99_fee_search.R`, `reference/README.md` and `EXPLAINER.md`. Earlier entries in this log use the old names, as they were at the time.
- **On FarmShare:** delete the old files (`01_data_checks.R`, `02_fee_search.R`, `05_open_cases.R`, `06_build_features.R`, `07_presplit_checks.R`) so they aren't run by mistake. If features were already built, the first session will show a one-time "out of date" warning because the builder's name changed. Re-run `01_build_features.R`.
- **Tested** in R on fake data, in workflow order: every R file parses; `00` → `01` (features built, input record names the new builder) → `02` (all three parts ran and saved their files) → `03` (split and fingerprint) → `04` (case page) → `99` (still runs).

### 28. "Unassigned" as a judge category
- **Josh's request:** after the data checks showed judge entries reading "Judge Unassigned", make **unassigned** its own judge category.
- **`r/00_sample.R`:** new setting `unassigned_pattern` (unassigned / not assigned / no judge assigned / judge not yet assigned, ignoring capitals). In `judge_group`, **"unassigned"** and **"(no judge listed)"** (blank) are now always their own categories, whatever their training count. They're no longer grouped into "other" or split by court.
- **`r/01_build_features.R`:** `senior_judge_at_filing` gains an **"unassigned"** value; these cases were previously "not matched".
- **`r/02_data_checks.R`:** the judge match rate now counts only cases with an assigned judge, and a new INFO line reports the number of unassigned cases.
- **Leakage note (told to Josh):** every case is unassigned at the moment of filing. A case still shows "unassigned" in SCALES because it **ended before a judge was assigned** (e.g. quickly dismissed, remanded, transferred or consolidated). So the category partly reflects the outcome and will predict short durations for that reason. Treat it like the other knowingly leaky variables: report it, or compare models with and without it.
- **Tested** in R on fake data: "Judge Unassigned" and "Not Assigned" became "unassigned" in both variables and stayed their own category despite few cases; a blank judge became "(no judge listed)"; a magistrate with one case went to "other"; and the match rate left unassigned cases out.

### 29. Judge matching fixed, after reviewing the unmatched judges
- **Prompted by** Josh's download of `features_report_judges_not_matched.csv` from the real run (top 40 unmatched names). They fell into five groups, each now handled:
  1. **Accented names** (Juan R. **Sánchez**, E.D. Pa.): he was in the directory, but under a plain-ASCII locale, as FarmShare's R may use, R dropped the "á" instead of converting it ("snchez"). Names are now read and converted as UTF-8 explicitly. *Tested under `LANG=C`.*
  2. **Judges appointed after 2017** (e.g. Michael L. Brown, Doughty, Scholer, Noreika, Albright, Ashe, Self): the directory only covered judgeships active in 2016–17, but **SCALES's judge field is the judge at collection (2020–21)**. The directory is rebuilt for **2016–2021** (`reference/fjc_district_judges.csv`, 1,279 judgeships; `build_reference.py` was restructured so each table can be rebuilt alone). A judge commissioned after the filing date is labelled **"appointed after filing"**: the case was reassigned during its life, which partly reflects duration (leakage).
  3. **Visiting judges** (David A. Ezra of D. Haw. in W.D. Tex.; Barbara Rothstein of W.D. Wash. in W.D. Pa.; William G. Young of D. Mass. in D.P.R.): if there's no match in the case's court, a unique match in another court is used. New column `judge_visiting`.
  4. **Magistrate judges named without "Magistrate"** (N.D. Ill.: Finnegan, Cox, Gilbert, Valdez, Kim; W.D. Ark.: Bryant, Wiedemann, Ford; W.D. Wash.: Theiler, Tsuchida, Donohue, Christel; D. Idaho: Dale): these are now recognised from each court's magistrate surnames, learned from SCALES referral lists (`referred_judges_json`) and "Magistrate Judge …" names. Judges who were magistrates at filing and later became district judges (Rowland, Iain Johnston) count as **magistrate**, not "appointed after filing".
  5. **Territorial courts** (Tydingco-Gatewood, Guam; Gomez, Virgin Islands): **"territorial court"**.
- **`senior_judge_at_filing` values now:** senior / active / appointed after filing / magistrate / unassigned / territorial court / not matched.
- **`r/02_data_checks.R`:** the judge summary reports each group, with a leakage note for "unassigned" and "appointed after filing".
- **Caveat (told to Josh):** `judge_group` in `00_sample.R` also uses the judge at collection, so it carries the same reassignment issue.
- **Tested** in R on 18 fake cases using the real names above as SCALES writes them, plus referral lists naming the magistrates. Every name was classified as expected, including Sánchez under a plain-ASCII locale, where the old method produced "snchez".

### 30. Leakage warnings collected in one place
- **Josh asked** whether the leakage warnings were clearly marked anywhere. They weren't in one place: they were spread across `covariates.xlsx` ("Known at filing?"), several entries in this log, and parts of the explainer.
- **New section 7 in `EXPLAINER.md`, "Leakage warnings: read before choosing covariates",** in four parts:
  - **A. Never use:** the outcome and its parts, and variables that grow with the case.
  - **B. Kept by Josh's choice, knowingly leaky:** "unassigned" and "appointed after filing" judges, `judge_group`, `n_counsel`, `any_referral`, consolidation, `amicus`. Report them and compare models with and without them.
  - **C. Mostly known at filing but recorded later:** party and counsel fields, `PROSE`/`IFP`, `is_mdl`, `jury_demand`, related cases, the TRO window, and filing-date features that also pick up collection timing and COVID.
  - **D. Leakage from the set-up:** related cases on both sides of the split, training-only summaries, and choosing settings by looking at the holdout.
- **Other edits:** the note at the top of the explainer points to the new section; "What was tested" is now section 8.

### 31. is_multi dropped; consolidation, MDL and transfers redefined
- **What the data checks showed:** `is_multi` covers 153,848 cases (32%). It's flagged for 68% of removed cases, 86% of transferred-in cases and 90–99% of MDL cases, and it travels with "other courts listed" (removals and transfers) and with lead cases (consolidation and MDL). It means **"the docket refers to another case number"**, not "consolidated".
- **Josh's decisions:**
  1. **Drop `is_multi` as a covariate.** `is_consolidated` now means **has a lead case**. `consolidation_role` (lead / member / not consolidated) is built from SCALES `lead_case_id` alone: *member* if it names a different case, *lead* if another case in the same court names this one as its lead. The arrival route stays in FJC `ORIGIN`.
  2. **MDL from either source:** new covariate **`mdl_any`** = SCALES `is_mdl` OR FJC `ORIGIN` 6/13. SCALES and FJC agreed on 50,566 cases. The 21,815 SCALES-only cases were almost all FJC "original filings", most likely because FJC code 13 (MDL originating here) only began on 1 July 2016. There were 5,442 FJC-only cases. Use `mdl_any` for grouping the split.
  3. **Transfers out are censored:** cases with FJC `DISP` 0 (transferred to another district) or 10 (MDL transfer out) get `duration_status = 'transferred_out'`, with duration = days until the transfer. New column **`event_observed`**: TRUE only if the case ended in this court within the cap, for `Surv(duration_capped_days, event_observed)`. Remands (`DISP` 1 and 11) stay as ordinary endings. `DISP` is used only to define the dependent variable, never as a covariate.
- **Files changed:**
  - `r/01_build_features.R`: consolidation and `mdl_any`.
  - `r/00_sample.R`: `transferred_out`, `event_observed`.
  - `r/02_data_checks.R`: MDL counts use `mdl_any`; censoring counts added; the transfer decision is removed from the open list.
  - `EXPLAINER.md`: dependent-variable note and leakage section.
  - `covariates.xlsx`: "Built as" updated.
- **Tested** in R on 100 fake cases: removed and transferred cases flagged `is_multi` came out "not consolidated" (the old rule would have called them leads); leads and members were found from lead-case links; `mdl_any` picked up an FJC-only MDL case; the 4 transfers out were censored with their time until transfer; remands stayed as endings.

### 32. Cap start date settled; cases without a duration left out
- **The data checks showed** 401 cases with no duration value: 398 `unknown_end` (open at collection, no FJC record), 2 `end_before_start` (date errors) and 1 `pending_short_followup`. That's about 0.08% of the sample.
- **Josh's decisions:**
  - **Cap start moved to 31 Dec 2017** (`duration_cap_start` in `r/00_sample.R`), so the cap is now **3,103 days** (31 Dec 2017 → 30 Jun 2026). The case filed 31 Dec 2017 and still pending is now simply overlong, and no 2017 filing lacks enough follow-up.
  - **Cases without a duration value are left out** of the duration analysis. Censoring the `unknown_end` cases at the SCALES collection date was offered and not chosen. No code change was needed, since these cases already have no value.
- **`r/02_data_checks.R`:** the cap line is now PASS/FLAG (FLAG only if any case is followed for less than the cap), and the "no duration value" item is no longer open.
- **Also updated:** `EXPLAINER.md` (the dependent-variable note) and `covariates.xlsx` (cap length in two descriptions).
- **Checked** in R that the cap is 3,103 days, and that a case filed 31 Dec 2017 and still pending becomes `longer_than_cap`.

### 33. Missing values in covariates labelled, not blank
- **What the data checks showed** (`presplit_covariate_missing.csv`, `features_report_coverage.csv`; run before changes 28–32, all 2016–17 civil cases): no built covariate was missing for more than 1.7%, and each gap had a clear cause.
  - **No FJC record:** 9,554 cases, missing every FJC-based field.
  - **Blank judge:** 1.1%.
  - **No plaintiff or no defendant party:** 0.6–0.8%.
  - **County code not in the FIPS list:** 0.6%.
- **Josh's decisions:** keep the cases with no FJC record, labelled "no FJC record"; give every other gap an explicit label; no imputation.
- **`r/01_build_features.R`:**
  - `circuit`, `diversity_residence`, `county_area_class`: "no FJC record" (or "not recorded" / "county not recorded")
  - `senior_judge_at_filing`: "no judge listed" / "filing date missing"
  - `first_plaintiff_type`, `first_defendant_type`: "no plaintiff listed" / "no defendant listed" / "name not recorded"
  - `plaintiff_firm_cases`, `defendant_firm_rank`: "no plaintiff listed" / "no defendant listed"
  - `case_number_parity`: "not recorded"
- **`r/00_sample.R`:** new labelled covariates built from the FJC fields Josh chose:
  - `arrival_route` (`ORIGIN` in words)
  - `class_action_alleged` (`CLASSACT`: 1 = yes; -8 = no, per the codebook)
  - `in_forma_pauperis` (`IFP`: FP = yes; -8 = no)
  - `pro_se` (`PROSE`: none / plaintiff / defendant / both)

  Each is "no FJC record" when there's no match. The raw columns are unchanged.
- **`r/02_data_checks.R`:** the covariate missing-data check now counts these labels as missing (and reports the share with no FJC record).
- **Leakage section (`EXPLAINER.md`, 7B):** added `defendant_firm_rank` = "no counsel listed" (about a third of cases). A defendant with no lawyer at collection usually never appeared, so the category partly reflects how the case went. The explainer's analysis notes describe the labels.
- **`covariates.xlsx`:** "Built as" now names the labelled versions for `ORIGIN`, `CLASSACT`, `IFP` and `PROSE`.
- **Tested** in R on fake data with no judge, no plaintiff, a `-8` county and a case with no FJC record: each got the right label; the FJC codes came out in words; no blanks were left in any labelled covariate; and the data check counted the labels.
- **Still to look at after the rerun:** missingness in the raw SCALES covariates (`city`, `jury_demand`, `nature_suit`, `jurisdiction`), shown in `scales_missing` in `02_data_checks.R`.

### 34. MDL cases excluded; split by consolidation group; small matching fixes; cap setting fixed
- **From the rerun reports:**
  - MDL cases are 78,626 (16.3%). The largest MDL (2592) has 17,491 cases, and the 10 largest hold 78% of SCALES-flagged MDL cases.
  - Only 511 judge-case matches failed. Most were appeals judges sitting by designation, plus "Executive Committee".
  - The unmatched county codes were almost all US territories, plus Dade County's pre-1997 FIPS code.
- **Josh's decisions:**
  1. **MDL member cases are excluded from the sample** (`r/00_sample.R`, step 2). MDL means SCALES `is_mdl` OR FJC `ORIGIN` 6/13. New views: `non_habeas_cases`, and `mdl_flagged`, which keeps the flags for the checks.
  2. **The holdout is drawn by consolidation group** (`r/03_holdout.R`). A lead case and its members, keyed by court plus lead case number, go entirely to one side; other cases are their own group. 20% of groups are drawn, and the README records the number of groups, the largest group and the actual share of cases in the holdout.
  3. **Small fixes applied:**
     - Appeals-court and international-trade judgeships were added to the judge directory, for visiting judges only (`reference/build_reference.py`, `fjc_district_judges.csv`, now 1,638 rows).
     - "Executive Committee" now counts as unassigned.
     - County codes in Puerto Rico, Guam, the Virgin Islands, American Samoa and the Northern Mariana Islands become **"US territory"**.
     - FIPS 12025 (old Dade County) is mapped to 12086 (Miami-Dade).
- **Bug fixed (found in the rerun):** the report still showed the old cap (30 Dec 2017) because the setting in `00_sample.R` only applied if `duration_cap_start` didn't already exist in the R session, so an old value lingered. The cap dates are now set from the file every time. A deliberate override is `duration_cap_start_override` / `fjc_data_through_override`.
- **`r/02_data_checks.R`:** the related-cases section reports the MDL cases excluded (with the SCALES/FJC agreement, computed before exclusion), that none are left, and the consolidation groups. The split item is no longer open.
- **`r/04_random_case.R`:** new `case_pool <- "mdl"` to view an excluded MDL case.
- **Also updated:** `EXPLAINER.md` (data-set note, the `03` and `04` rows, leakage section D), `reference/README.md` and `covariates.xlsx`.
- **Tested** in R on fake data:
  - 31 MDL cases excluded, including one flagged only by the FJC, leaving 69
  - two consolidation groups each kept on one side of the split, and no MDL cases in the split file
  - "Executive Committee" counted as unassigned, and Denny Chin matched as a visiting judge
  - Puerto Rico and Guam counties counted as "US territory", and 12025 counted as urban
  - an old cap value in the session ignored, and the override working
- **Consequence:** the sample is smaller (about 403,400 cases instead of 482,028). No split had been drawn yet, so nothing needs redrawing.

### 35. MDL transfer-outs and overlong cases excluded from the sample
- **Josh's decisions, before drawing the split:**
  1. **Cases that ended by MDL transfer out** (FJC `DISP` 10; 4,251 in the previous sample) are excluded, alongside the MDL member cases. They were sent to an MDL court, so leaving this court wasn't a real ending.
  2. **Overlong cases are excluded** (748 in the previous sample): cases lasting longer than the 3,103-day cap, or still pending in the FJC file on 30 Jun 2026.
- **The explainer (Josh's wording, verbatim):** "The analysis population excludes the 748 cases still pending (or lasting) beyond 3,103 days; results describe cases resolved within about 8.5 years."
- **Selection on the outcome (told to Josh):** both exclusions use how the case ended. The MDL transfer-out exclusion follows the same reasoning as the MDL exclusion. The overlong exclusion **truncates the dependent variable**: duration estimates will be somewhat shorter than for all 2016–17 cases, and the models say nothing about cases lasting over about 8.5 years. The effect is small (about 0.2%), but it must be stated in the write-up. Both exclusions are applied **before the split**.
- **`r/00_sample.R`, restructured so duration is calculated once:**
  - `mdl_flagged` gains `mdl_transfer_out`, and `analysis_cases_raw` drops those cases.
  - The de-duplicated cases are now `all_cases_dedup`.
  - The best FJC link (`best_link`, `best_link_unique`) and a new per-case **`case_duration`** view are computed on them.
  - **`all_cases`** (the base sample) = `all_cases_dedup` minus `longer_than_cap` cases.
  - `analysis_fjc_base` now joins the population to `best_link_unique` and `case_duration`, rather than recalculating duration, so the exclusion and the dependent variable use the same calculation.
  - `is_overlong` is kept but is always FALSE in the sample. `event_observed` is FALSE only for transfers to another district.
- **`r/02_data_checks.R`:** new lines report both exclusions (with the outcome-selection warning). The duplicate checks now compare against `all_cases_dedup`, so excluded overlong cases aren't counted as duplicates.
- **Also updated:**
  - `EXPLAINER.md`: data-set note (MDL transfer-outs next to the MDL decision; overlong exclusion stated explicitly, with Josh's sentence), dependent-variable note, and leakage section D ("Selecting the sample on the outcome")
  - `covariates.xlsx`: the `is_overlong` description
- **Tested** in R on fake data:
  - a non-MDL case ending by MDL transfer out and an open case still pending in the FJC file (overlong) were both removed, leaving 67 of 69
  - the duplicate check still showed 0
  - the report named both exclusions
  - the split ran on the reduced sample
- **Expected effect on the real sample:** about 403,402 − 4,251 − 748 ≈ 398,400 cases. Confirm with the rerun.

### 36. Holdout split made, locked and backed up
- **Made on FarmShare** by `r/03_holdout.R` on 24 Oct 2026 at 17:56 UTC, for population `"all"`. It is a random 20% of consolidation groups, seed 226.
- **Result:**
  - 398,403 cases: holdout **79,694 (20.0%)**, training 318,709
  - holdout share by year: 2016 20.2%, 2017 19.8%
  - 393,053 groups, 1,598 of them with more than one case; the largest has 1,136 cases
  - 0 duplicate case IDs
- **Locked** with `chmod a-w ~/scales_project/holdout_split_*`. **Backed up** to the Dropbox `misc/` folder (`holdout_split_all.csv`, `_README.txt`, `.md5`). The backup's MD5 matches the recorded fingerprint: `1ea22af93366a54497e2798b91899040`.
- **Note:** the split's README text lists the MDL exclusion but not the later exclusions of MDL transfer-outs and overlong cases (change 35). The template in `03_holdout.R` hadn't been updated. **The split itself was drawn from the full definition** (398,403 cases). The template is now fixed for any future split. The existing README is locked and was left as made.
- **From here on:** analysis uses `train_fjc` / `train_cases`. `judge_group` and `cause_group` now count training cases only. The holdout stays untouched until the final evaluation.

### 37. New script: feature selection (`r/05_feature_selection.R`)
- **Why:** Josh asked for a feature-selection file and whether to use something other than `cor()` for the correlation table. `cor()` measures linear association between numeric variables only. Most covariates are categorical, with arbitrary codes, so the script uses the measure that fits each pair: |Spearman| for two counts (rank-based, so skewed counts don't dominate), bias-corrected Cramér's V (Bergsma 2013) for two categorical variables, and the correlation ratio eta for one of each. All run from 0 to 1.
- **What it does:**
  - **Uses training cases only** (`train_fjc`). Stops if the holdout split doesn't exist.
  - **The covariate list** is the 35 chosen in `covariates.xlsx` that are built (the constant `is_mdl`/`mdl_any` and `is_overlong` are left out). Each has a type and leakage tier from EXPLAINER section 7, and the list is easy to edit.
  - **Outputs:** the number of levels and the smallest level's count; the missing or labelled-missing share; constant variables flagged; every pair's association; pairs at or above 0.7 listed; and each covariate's association with log(1 + duration) for cases that ended in court (`event_observed`). Censored cases are left out there, so it's a screening tool, not a survival model.
  - Writes to `~/scales_project/feature_selection/`. It changes no data and drops no variables; the decisions are Josh's.
- **Tested** on fake data:
  - The formulas were checked against known answers: Cramér's V is 1 for a variable with itself and about 0 for independent ones, and eta equals the square root of R² from `lm`.
  - A planted duration effect was picked up (arrival route, eta 0.99).
  - Constant variables are flagged.
  - Not yet run on the real data.

### 38. Feature selection: pairs use only cases where both variables are recorded
- **Why:** on the real data, the first run (change 37) gave a cluster of pairs at 0.707–0.725 among unrelated FJC variables: in forma pauperis, class action, county type, diversity residence and arrival route. The cause is the missing-value label. Cases with no FJC record carry "no FJC record" in every FJC variable, and Cramér's V reads that perfectly shared level as association. A perfectly shared level forces V to at least 0.707, however rare it is. In a simulation, two unrelated variables scored 0.707 with a 1.5% shared label, and 0 on the cases with both recorded. Josh approved the fix.
- **Change in `r/05_feature_selection.R`:**
  - Each pair is now computed on cases where **both** variables are recorded. Missing labels ("no FJC record", "not recorded", "county not recorded", "no judge listed", "filing date missing", "no plaintiff listed", "no defendant listed", "name not recorded", and blanks) are left out of that pair.
  - Real categories such as "unassigned", "no counsel listed" and "pro se / no counsel" are kept.
  - `fs_association_matrix.csv` gains an `n_both` column, the number of cases used for each pair.
  - The association with duration is unchanged: missing labels stay there as their own category, because duration is never labelled.
- **Tested** on fake data by planting a shared "no FJC record" label in two unrelated variables: the pair now scores 0, on the 48 cases with both recorded.

### 39. Feature selection: rank-based and recorded-only duration measures
- **Why:** in the second real run (after change 38), six FJC-derived variables scored almost the same against duration (0.33–0.39): pro se, county type, diversity residence, arrival route, class action and in forma pauperis. That suggested the shared "no FJC record" category was driving them. Separately, Josh asked why log duration was used. It was Claude's choice, made to tame the long right tail; a rank-based measure avoids choosing a scale at all. Josh asked for both additions.
- **Change in `r/05_feature_selection.R`:** `fs_dv_association.csv` now has four measures per covariate, for cases that ended in court:
  - `rank_all`: eta on the rank of duration. This equals the square root of the Kruskal–Wallis epsilon-squared, H / (n − 1). The table is now sorted by this.
  - `log_all`: eta with log(1 + duration), as before.
  - `rank_recorded`, `log_recorded`: the same measures, on cases where the covariate is recorded (missing labels left out).
  - For the four counts, all columns are |Spearman|, which is rank-based anyway.
  - Also added: `n_ended` and `n_ended_recorded`.
  - A big drop from `_all` to `_recorded` means the missing category is doing the work.
- **Tested** on fake data:
  - Eta on ranks equals sqrt(H / (n − 1)) from `kruskal.test` (0.414 both).
  - With planted short durations for "no FJC record" cases, in forma pauperis scored 0.97 (log) and 0.48 (rank) on all cases, against about 0.15 on recorded cases only.
  - The log measure reacted much more than the rank one to the planted cluster of very short cases.

### 40. New script: `r/02-a_data_checks_fjc.R` (cases with no FJC record)
- **Why:** in change 39's real run, the six FJC-derived covariates lost almost all of their association with duration once the "no FJC record" cases were left out. So whether a case has an FJC record is itself strongly related to duration. The question is whether that's a linking gap (harmless) or reflects how the case ended (leakage), for example cases opened in error, re-filed or sealed. Josh asked for a separate script with this name.
- **What it reports,** for training cases only, with counts only and no docket text or party details:
  1. Cases by FJC status: linked; shared record (an FJC record matched to two cases, so neither gets FJC data); no match.
  2. Duration percentiles and the share ending within 0, 30 or 90 days or lasting over 3 years, by status.
  3. SCALES case status, duration status and end-date source; docket size; and the share of cases whose docket mentions opened in error, duplicate or re-filed, transfer, remand, consolidation, voluntary dismissal or sealing. This compares every no-FJC case with a same-size random sample of linked cases, ordered by hash with seed 226 so the sample is the same each run.
  4. The no-FJC share by year, court and nature of suit, and the courts holding the most no-FJC cases.
  5. For linked cases: how closely the SCALES and FJC termination dates agree, since no-FJC cases rely on SCALES dates alone.
- **Tested** on fake data in which 6 training cases had no FJC match, 2 shared one record, and one docket said "Case opened in error". The counts (44 / 6 / 2) and the wording share (12.5%, 1 of 8) came out right. Not yet run on the real data.

### 41. New guide: `FEATURE_SELECTION_GUIDE.md`
- **Why:** Josh asked for a heavily annotated document explaining the functions in `r/05_feature_selection.R`, with links to explainers on Spearman and Cramér's V.
- **What it covers:**
  - Why `cor()` isn't enough for categorical covariates.
  - Each section of the script, with the code and a line-by-line explanation of `cramers_v()` (chi-square, bias correction), `eta()`, `assoc()`, the pair loop and the rank and log duration measures.
  - How to read each output file, worked examples and cautions (leaky variables, many levels, one-at-a-time associations).
  - A quick reference of the R functions used.
  - Links to Laerd Statistics, Statology, Wikipedia, Bergsma (2013) and the R documentation, all checked to load.
- No code changed.

### 42. Cases with no FJC record EXCLUDED from the sample (after the split; split not redrawn)
- **Decision (Josh, 24 Oct 2026):** "let's just drop the no fjc cases."
- **Why:** `02-a_data_checks_fjc.R` (change 40) on real training data found 5,982 training cases (1.88%) with no FJC match, and none with a shared record. Compared with linked cases:
  - median duration 3 days, against 235
  - 29.6% ended on day 0, against 0.2%; 74% within 30 days, against 8%
  - median 3 docket entries, against 23; 63% had 5 or fewer, against 4.5%
  - "transfer" in the docket 24.3% of the time, against 7.9%; voluntary dismissal 4.5%, against 18.4%; remand 2.6%, against 11.0%; "opened in error" 6.6%, against 4.3%
  - S.D. Florida had 1,622 of them (27%; 11.9% of its cases), and E.D. North Carolina 7.3% of its cases
  - When both dates exist, SCALES and FJC end dates agree on the same day 96.7% of the time, so the short durations are real; the cases just aren't ordinary litigation.

  They look like administrative case numbers: cases moved within days, opened in error and so on. So "no FJC record" partly records the outcome (leakage), and with no FJC `DISP` code, transfers among them couldn't be censored.
- **Change:**
  - `r/00_sample.R`: `all_cases` now also requires an FJC record in `best_link_unique`. This drops both kinds of case: no match, and an FJC record shared with another case.
  - Results describe cases with an FJC record, so all FJC covariates are now recorded for every case in the sample.
- **The split was not redrawn.** It was a random draw of consolidation groups that didn't depend on FJC status, so removing the same rule-defined subset from both sides leaves a random holdout of the smaller population. The rule was chosen from training data only.
- **New check in `r/02_data_checks.R`:** the number excluded, plus a PASS/FLAG line comparing the share dropped from training and holdout. It FLAGs if the shares differ by 0.3 points or more, or if the holdout share leaves 19.5–20.5%. It also gives the holdout share by year, and saves `checks/presplit_no_fjc_split_balance.csv`. Counts only.
- **Other edits:**
  - `r/02-a_data_checks_fjc.R` now reads the split's training cases from *before* the exclusion, so it still documents the excluded cases.
  - `r/03_holdout.R`'s README template lists the exclusion. The existing locked README is unchanged.
  - The EXPLAINER has a new top note and a leakage-section note.
- **Side effects:**
  - `judge_group` and `cause_group` thresholds (20 and 100 training cases) are recounted on the smaller sample, so a few judges or causes may move into or out of "other".
  - `05_feature_selection.R` results will change: the "no FJC record" categories disappear.
- **Tested** on fake data with 8 no-FJC training cases (6 with no match, 2 shared): the population fell from 69 to 61; the balance check FLAGged the deliberately lopsided fake set (8 training, 0 holdout); `02-a`, `04` and `05` ran. Not yet run on the real data.

### 43. New script: `r/02-b_data_checks_judges.R` (judge reassignment)
- **Why:** SCALES's judge field is the judge at collection (2020–21), so `judge_group` and `senior_judge_at_filing` may reflect reassignments that happen more often in long cases (leakage). Josh asked for a check on a random training sample of about 10,000 cases: (1) the initial assignment on the docket compared with the SCALES judge; (2) reassignment wording; and a frequency table of each.
- **What it does:**
  - **Sample:** 10,000 training cases (`n_sample`), in a fixed random order (hash of the case ID), so each run draws the same cases.
  - **Docket entries:** only entries mentioning assign, recus or "transferred to Judge" are read into R.
  - **(1) First assignment:** the first "assigned to" entry, excluding "reassigned to" and preferring a non-magistrate assignment, so a referral like "assigned to Magistrate Judge X for discovery" isn't mistaken for the initial assignment. It's a match if the SCALES judge's surname, cleaned as in `01_build_features.R`, appears in the 150 characters after "assigned to".
  - **Categories:** same judge; DIFFERENT judge; no initial assignment entry found; SCALES judge "unassigned"; blank.
  - **(2) Wording:** reassign / re-assign, "no longer assigned", recus(al), "transferred to (the) Hon./Judge…".
  - **Tables:** (1); (2); (1) × (2); by duration band (training only); by court.
  - **Spot-check file:** 200 cases with the 150-character assignment text, judge names only, to check the matching by hand.
- **Tested** on fake dockets with 44 training cases. All were classified correctly: 10 same judge; 5 with a different first judge plus reassignment wording; 3 where a magistrate referral came first, correctly skipped (same judge); 2 recusals with no assignment entry; 24 with no assignment wording. Not yet run on the real data.

### 44. Judge reassignment check, version 2: tighter rules after the spot-check
- **Why:** on the first real run (10,000 training cases), Josh found both rules noisy:
  - (1) gave "different judge" for 45.5% of comparable cases, and 100% in S.D. Fla. and E.D. Mich.
  - (2) flagged 24.7% of cases.
  - Of the 99 "different judge" cases in the 200-case spot-check, the matched entry was often not an initial assignment:
    - 49 were text like "Judge X **no longer assigned to the case**", which is itself a reassignment entry, read as the first assignment.
    - 16 were phrases like "assigned to serve as panel mediator", "assigned to the standard track", "assigned to a judge who participates in the cameras pilot" or "assigned to this case. Please use the new case number".
    - 34 looked like real assignments.
  - 14 of the 101 "same judge" cases also had reassignment wording, for example magistrate-only changes.
- **Changes in `r/02-b_data_checks_judges.R`:**
  - **(1)** "assigned to" must now be followed by a judge title (Hon., Honorable, Judge, Chief, District, Senior, Magistrate, U.S.), optionally after "the calendar of" or "the docket of", and not preceded by "no longer". Magistrate referrals are still skipped where possible.
  - **(2)** Wording is split into district-judge changes (reassigned to [non-magistrate] judge; "Judge X no longer assigned" not preceded by "magistrate"; recusal; transferred to [non-magistrate] judge) and **magistrate-only changes**, reported separately and not counted. The version-1 broad rule is kept as a column for comparison. "Motion to reassign" no longer counts.
  - **New spot-check file** `judges_reassign_spotcheck_wording.csv`: 200 wording-flagged cases with about 120 characters around the match. The comparable-case spot-check gains a `reassign_snippet` column.
- **Tested:** the new patterns were checked on 14 phrases modelled on real docket text, and each was classified as intended. The fake-docket test gives the same correct classification as in change 43. Not yet run on the real data.

### 45. Decision: court in the main model; judge, senior status and magistrate referral only in a sensitivity model
- **Decision (Josh, 24 Oct 2026):** the main model uses `court`. `judge_group`, `senior_judge_at_filing` and `any_referral` (referral to a magistrate judge, which is how "magistrate" was read) are used only in a sensitivity model: court plus these three.
- **Why:**
  - The SCALES judge field is the judge at collection.
  - Version 2 of `r/02-b_data_checks_judges.R` (change 44), on 10,000 training cases, found:
    - district-judge reassignment wording in 16.4% of cases, rising from 10.4% of cases ending within 90 days to 36.3% of cases over 3 years
    - a different SCALES judge from the first docketed assignment in 25.2% of the cases where that entry exists (3,358)
  - Both rules are still too noisy to correct the variable case by case (Josh's review of the spot-check files).
  - `senior_judge_at_filing` comes from the same field. `any_referral` happens after filing and is associated with `judge_group` (Cramér's V 0.84).
- **Why not drop reassigned cases instead,** as Dobbie & Song (2015) do for undocumented original judges:
  - Their exclusions followed judge retirements, unrelated to individual cases.
  - Here, reassignment rises with duration, so dropping those cases would select the sample on the outcome.
- **Recorded in:** `EXPLAINER.md` section 7B, a new subsection "Decision: court in the main model…". It includes the costs of the choice, wording for the write-up, and references:
  - Dobbie & Song 2015; Ganglmair, Helmers & Love 2024; Schwartz et al. 2024 (SCALES)
  - Kaufman et al. 2012; Montgomery, Nyhan & Torres 2018; Fong & Tyler 2021

  The references were found and checked by a research subagent. The first three were read for the relevant passages; the links were checked.
- No code changed. The three variables are still built and stay in `05_feature_selection.R`'s covariate list.

### 46. Project put on GitHub (private)
- **Josh's request:** push the files to GitHub, as a private repository named "MS&E 226--lawsuit duration project". GitHub doesn't allow "&" or spaces in names, so it's `josharosenthal/MS-E-226--lawsuit-duration-project`, with the full title as its description.
- **Contents:** code and docs only, as Josh chose:
  - shell, Python and R scripts
  - `EXPLAINER.md`, `CHANGES.md`, `FEATURE_SELECTION_GUIDE.md`, `BRIEF_for_Claude_Code.md`, `RUN_SUMMARY.md`
  - `covariates.xlsx`
  - `reference/` tables and `fjc_district_crosswalk.csv`
- **Left out** via `.gitignore`:
  - `misc/`: FarmShare outputs, including the holdout split and reports with judge and firm names and docket snippets
  - any `.parquet` file
  - the early output `closed_civil_by_cause_titlesection_usc.csv`
  - rendered `.html` copies of the docs
  - the empty `unzip` file, and Mac and R clutter
- The staged files were scanned for passwords and keys before the push; none were found.
- **Note:** the git repository lives inside the Dropbox folder. Avoid editing the same files on two machines at once.

### 47. New `DATA_DICTIONARY.md`
- **Josh's request:** a data dictionary of the feature candidates, including a sense of the values of the covariates with few categories.
- **Contents:**
  - **All 35 covariates in `05_feature_selection.R`:** meaning, source (SCALES / FJC / derived), type, levels, smallest level and % missing, leakage tier, and main or sensitivity model (change 45). Levels, smallest level and % missing come from the 25 Oct 2026 FarmShare run: 312,727 training cases, after the no-FJC exclusion.
  - **The values** of every covariate with 15 or fewer categories (plus `diversity_residence`). The code meanings come from the R code. The rough mix of values comes from the best counts on the Mac: `features_report_coverage.csv` (all 549,960 civil cases, before exclusions) and the pre-split data-check tables. Each source is labelled.
  - **Rare categories** (fewer than about 50 training cases) with possible merges. These are suggestions only, not decisions.
- **Not yet available:** exact training counts per category, especially jurisdiction, jury demand and pro se. That needs a small addition to `05_feature_selection.R` and one FarmShare run.
- **The FJC `RESIDENC` code meanings** are given from the FJC codebook, flagged to check before relying on them.
- No code changed.

### 48. `05_feature_selection.R` also writes `fs_levels.csv` (training counts per category)
- **Why:** to put exact training counts in `DATA_DICTIONARY.md` (change 47), which had only rough shares from wider case sets, and none for jurisdiction, jury demand or pro se. Josh approved.
- **What it writes:** one row per category: variable, value, training cases, % of training cases with a duration value. For covariates with up to 15 categories it lists every category; for larger ones, the 5 most common and the 10 rarest. Counts only.
- **Tested** on fake data (every covariate has 15 or fewer categories there, so all were listed) and on simulated data with a 30-category variable (5 most common plus 10 rarest shown). Nothing else in the script changed.

### 49. `DATA_DICTIONARY.md` filled in with exact training counts
- **Source:** `fs_levels.csv` from the 25 Oct 2026 FarmShare run, 312,727 training cases. It replaces the rough shares from wider case sets used in change 47, and adds jurisdiction, jury demand and pro se.
- **New section "Things the counts turned up":**
  - weekend filings (1.6%)
  - duplicate or odd city labels ("NMI" and "Northern Mariana Islands", "7 North Platte")
  - 48 training cases with a habeas-type nature of suit (510, 535) but a non-habeas cause, which remain because the habeas exclusion works on the cause. This is flagged for Josh's decision; the sample is not changed.
  - single-case categories
  - "no counsel listed" at 30% for `defendant_firm_rank`
- **The rare-categories table** now uses training counts; the merge options are still suggestions only.
- No code changed.

### 50. Residual habeas cases excluded by nature of suit (after the split; split not redrawn)
- **Josh's request:** "take out the residual habeas cases for cleanliness". The data dictionary (change 49) found 36 training cases with nature of suit 510 (Motions to Vacate Sentence) and 12 with 535 (Death Penalty) still in the sample, because the habeas rule worked on the cause (28 U.S.C. 2241/2254/2255) only.
- **Change in `r/00_sample.R`:** `non_habeas_cases` also drops any case whose nature-of-suit code is in `habeas_nos_codes`. That's `463` Habeas Corpus – Alien Detainee, `510` Motions to Vacate Sentence, `530` Habeas Corpus – General and `535` Death Penalty, whatever its cause.
  - **Codes 463 and 530 were added by Claude** as the other habeas natures of suit. Their training counts aren't known yet: each has at least 38, since neither was among the 10 rarest. The list is one line, so Josh can trim it.
  - Cases with no nature of suit are kept.
- **The split is not redrawn,** as in change 42: the same rule applies to training and holdout.
- **New PASS/FLAG line in `r/02_data_checks.R`:** cases dropped from each side and by code, saved as `checks/presplit_habeas_nos_split_balance.csv`. It FLAGs if the two sides' shares differ by 0.1 points or more.
- **Fix to the no-FJC balance line (change 42):** it now counts only cases still in the de-duplicated sample. Otherwise cases removed by another rule, such as these habeas cases, would also count as "no FJC record", since excluded cases get no FJC link.
- **Docs:** the EXPLAINER has a top note on the exclusion, and `DATA_DICTIONARY.md` section 3 is updated. The dictionary's counts are from before this exclusion.
- **Tested** on fake data, with two training cases and one holdout case given habeas natures of suit (530, 510 with a leading space, 535) and one given a blank nature of suit:
  - the population went from 61 to 58; the blank case was kept
  - the balance line reported 2 training and 1 holdout, by code
  - the no-FJC line stayed at 8
  - with no habeas cases, the line is PASS with "none"
  - `05` and `02-c` ran
  - Not yet run on the real data.

### 51. New script: `r/02-d_data_checks_prose.R` (SCALES vs FJC: who has no lawyer)
- **Named 02-d** (first written as 02-c, then renamed before upload so Josh's oddities script could be 02-c).
- **Josh's request:** confirm the cross-accuracy of a missing firm (plaintiff or defendant) and that party being marked pro se.
- **What it does:** on training cases, it compares SCALES `plaintiff_firm_cases` = "pro se / no counsel" with FJC `PROSE` = plaintiff or both, and SCALES `defendant_firm_rank` = "no counsel listed" with FJC `PROSE` = defendant or both. For each side it reports:
  - the cross-tab (plaintiffs with a lawyer split into "with firm" and "no firm listed")
  - the share of SCALES "no lawyer" that the FJC calls pro se, and the reverse
  - overall agreement and Cohen's kappa
  - the 10 largest natures of suit and courts in each kind of disagreement

  "No plaintiff/defendant listed" is left out as not comparable. Counts only.
- **Expected result:** good agreement for plaintiffs. Weaker for defendants, because defendants who never appear have no counsel in SCALES but aren't recorded as pro se by the FJC; that's the leakage noted in EXPLAINER 7B.
- **Tested** on fake data with planted values:
  - plaintiffs: 10 flagged by both, 2 by SCALES only, 1 by the FJC only, giving 93.2% agreement and kappa 0.824
  - defendants: 20 with no counsel, 3 of them pro se in the FJC, giving kappa 0.161
  - one crash, when a disagreement group had a single value, was fixed
  - Not yet run on the real data.

### 52. New script: `r/02-c_data_checks_oddities.R` (case headers for odd values)
- **Josh's request:** as 02-c, a script to pull up the header information for cases with:
  - a blank nature of suit
  - a blank jurisdiction, or "Local Question"
  - a single-case cause title
  - an unmatched county code
  - a defendant whose name isn't recorded
- **What it does:**
  - Flags these cases among training cases; a case can have several flags.
  - For each one, shows the SCALES header (court, case number, case name if present, office, filing date, status, judge, nature of suit, cause, jurisdiction, jury demand, party counts) next to the FJC record's NOS, JURIS, COUNTY, TITL/SECTION and ORIGIN, where the FJC file has them.
  - For "name not recorded", also shows the first defendant's party row (name, role, party type).
- **Privacy:** the console shows counts and a compact table without names. The full headers, with case names, are saved to `checks/oddities_cases.csv` only.
- **Tested** on fake data with one planted case per flag: all six were found, plus one blank nature of suit already in the test data. Optional columns are skipped when missing. Not yet run on the real data.

### 53. Decision: "large-firm list, headcount not given" left as is
- **The question:** this `defendant_firm_rank` category (277 training cases) covers the 5 firms BCG lists without a headcount: Steptoe LLP, Kelley Drye & Warren, Porter Wright Morris & Arthur, Milberg Coleman Bryson Phillips Grossman, and GrayRobinson.
- **Web search of their size** (25 Oct 2026):
  - **Steptoe:** more than 500 lawyers and staff, and 300+ lawyers in D.C. (firm site), so about ranks 101–140.
  - **Kelley Drye:** 248 attorneys (ILRG, undated) or about 350 (U.S. News), so ranks 121–160.
  - **Porter Wright:** 177 attorneys (ILRG 2025), so ranks 161–180.
  - **GrayRobinson:** 244 attorneys (ILRG), so ranks 141–160.
  - **Milberg:** 60+ attorneys (firm site, Oct 2024), smaller than any ranked firm. It's also a plaintiffs' class-action firm, so its matches as a defendant's lead counsel are worth checking if this variable matters.
- **Decision (Josh):** leave the category as is. The outside sources count differently from BCG/Am Law, and only 277 cases are affected, so it isn't worth editing the reference file and rebuilding the features.
- **Recorded** in `DATA_DICTIONARY.md` section 3. No code or reference data changed.

### 54. Nature of suit 550 (Prisoner: Civil Rights) excluded, for consistency with 1983pr (after the split; split not redrawn)
- **Decision (Josh, 25 Oct 2026):** "let's drop 550 (prisoner civil rights) for consistency."
- **Why:** prisoner civil-rights cases were meant to be excluded through the cause rule (42:1983pr). But nature of suit 550 was still the most common nature of suit in training: 27,727 cases, 8.9% (`fs_levels.csv`, change 49). These cases list other causes, such as plain 42:1983.
- **Change in `r/00_sample.R`:** `550` is added to `habeas_nos_codes`, the nature-of-suit exclusion from change 50. 555 Prison Condition and 560 Civil Detainee are not excluded (not requested).
- **The split is not redrawn,** as in changes 42 and 50.
- **`r/02_data_checks.R`:** the balance line is relabelled "Habeas / prisoner nature-of-suit exclusion". It now uses a **two-proportion z-test** (FLAG if |z| > 3) instead of a fixed 0.1-point tolerance. At about 9% of cases, a fixed tolerance would FLAG on chance differences; on the real data a 0.2-point chance gap gives z ≈ 1.8.
- **Expected effects:**
  - About 27,700 fewer training cases, and about 6,900 fewer holdout cases
  - The pro se plaintiff and in forma pauperis shares fall
  - The `judge_group` and `cause_group` thresholds are recounted
  - `05_feature_selection.R` results change
  - `DATA_DICTIONARY.md` counts are from before this exclusion; they need a refresh after the next run
- **Docs:** the EXPLAINER's data-set note and top exclusion note are updated, and the dictionary has a note.
- **Tested** on fake data with one planted 550 case added to the change-50 test: the population fell from 58 to 57, the balance line lists "550 1" with z = −0.02 (PASS), and with no such cases it shows "none" and PASS. Not yet run on the real data.

### 55. Nature-of-suit exclusions put ON HOLD; balance test first; 540, 555, 560 added as candidates
- **Josh's request:** check the balance as a statistical test before deciding to exclude. If excluding, also take out 555, 560 and 540, so include all of those among the potential exclusions.
- **This supersedes the exclusions in changes 50 (habeas natures of suit) and 54 (550).** Nothing is excluded by nature of suit for now. Claude treated the four habeas codes from change 50 as candidates too, so the whole set is decided together.
- **Change in `r/00_sample.R`:**
  - `candidate_nos_codes` = 463, 510, 530, 535 (habeas) and 540, 550, 555, 560 (prisoner).
  - `exclude_nos_codes` = none. Putting codes there applies them, by the same both-sides rule as change 42; the split is not redrawn.
  - The old `habeas_nos_codes` is gone.
- **`r/02_data_checks.R`:**
  - **(a) "APPLIED" line:** what `exclude_nos_codes` removed from each side, with a two-proportion z-test (PASS if |z| ≤ 3).
  - **(b) New "CANDIDATE" check:** for each candidate code not yet applied, plus the habeas group, the prisoner group and all candidates together, the training and holdout cases that excluding it would remove from the current sample, the share of each side, the z-score and whether it's balanced. Printed and saved as `checks/presplit_nos_candidate_balance.csv`. Counts only.
- **What the test can and can't say:** a balanced result means the holdout would stay representative after the exclusion. It doesn't say whether excluding is right; that's a decision about the population.
- **Docs:** the EXPLAINER's data-set note is restored, its top note now describes the candidates as under consideration, and the dictionary note is updated.
- **Tested** on fake data with planted 510, 530, 550 (training) and 535 (holdout):
  - With nothing applied, the population stays at 61, and the candidate table counts each code by side (all codes together: 3 training, 1 holdout, z = 0.13).
  - With 530 and 550 applied, the population is 59, the APPLIED line reports 2 training and 0 holdout, and the other six candidates are still tested.
  - Not yet run on the real data.

### 56. Oddity cells highlighted
- **`misc/oddities_cases.xlsx`** (Josh's resave of `oddities_cases.csv`): for each flagged case, the cell(s) that made it odd are highlighted in yellow, with a comment naming the flag, and the flag column is shaded orange. The cells by flag:
  - `nature_suit` for blank nature of suit
  - `jurisdiction` for blank or "Local Question"
  - `cause_title` for single-case titles
  - `county_area_class` and `fjc_COUNTY` for unmatched county
  - `first_defendant_type` and `first_defendant_name` for name not recorded

  71 flags across 70 cases: 1 blank nature of suit, 1 blank jurisdiction, 12 Local Question, 6 single-case titles, 39 unmatched county, 12 name not recorded. A backup of the unhighlighted file was kept in the session scratchpad. `misc/` is not on GitHub.
- **02-d result** (real data, training): plaintiffs 98.6% agreement, kappa 0.962; defendants 70.9% agreement, kappa 0.084. Only 7,279 of 94,701 SCALES "no counsel listed" defendants are FJC pro se.
- No code changed.

### 56. Recodes for odd values (rules in a new section 7a of `r/00_sample.R`)
- **Decisions (Josh, 25 Oct 2026)** were made in a forked session reviewing `misc/oddities_cases.xlsx` (from `02-c_data_checks_oddities.R`, training cases). The fork relayed them here, since this session owns `CHANGES.md`.
- **The rules:** every fix is a general rule, not a list of cases, so training and holdout are treated alike. They're applied in a new view `analysis_fjc_recoded`, which `analysis_fjc` now reads, so `case_features.parquet` is not rebuilt.
  1. **Jurisdiction "Local Question":** left as is. All 12 are in Guam (7) and the Virgin Islands (5), and the FJC agrees (JURIS 5).
  2. **`county_area_class`:** "unmatched county code" with FJC `COUNTY` 75010 (the FJC's code for the Northern Mariana Islands; 38 training cases, all nmid) becomes "US territory". South Boston (51780, W.D. Va., 1 case) stays "unmatched county code", per Josh.
  3. **`first_defendant_type` = "name not recorded"** (12 training cases), by the first defendant's name in `parties.parquet`. The first defendant is defined as in `01_build_features.R`.
     - starts with "$" becomes **"property (in rem)"**, a new category (forfeitures such as "United States v. $X in currency", and the txsd "v. $200,000,000.00")
     - "7-11" / "7-Eleven" becomes "business"
     - digits and hyphens only (e.g. "8877380", "6-27750") becomes **"individual"**. These are SCALES-anonymized people, including S.D. Fla. "Schedule A" trademark defendants (anonymous online sellers); Josh chose to treat them as individuals.
  4. **Cause typos:** 3:4301 becomes 38:4301 (USERRA), and 1:102 becomes 42:12102 (ADA). Applied to `cause_title` and `cause_section` before `cause_group` is built.
- **Not yet decided:**
  - **(5)** the other single-case cause titles: 73:201 (Pennsylvania consumer statute) to 28:1332?; 99:9999 (placeholder) to "(no cause)"?; 44:2107 and 36:327 left, to be merged with rare titles
  - **(6)** filling the D. Mass. case's blank nature of suit and jurisdiction from the FJC (NOS 890, JURIS 1)
- **Tested** on fake data with planted cases and decoys:
  - "$12,345.00 in U.S. Currency" became "property (in rem)"; "7-11" became "business"; "8877380" (training) and "6-27750" (holdout) became "individual"; "???" stayed "name not recorded"
  - county 75010 became "US territory"; 51780 was unchanged
  - 3:4301 became 38:4301 and 1:102 became 42:12102, with matching cause groups
  - no rows were added (61 before and after)
  - the oddities check then flagged only the decoys; `02`, `02-c` and `05` ran, and a project without the features file also ran
  - Not yet run on the real data.
- **Docs:** `DATA_DICTIONARY.md` has a "Recodes applied" note and updated rows in the rare-categories table.

### 57. Nature-of-suit exclusion applied (all 8 codes); remaining cause fixes; blank NOS and jurisdiction filled from the FJC
- **Decisions (Josh, 25 Oct 2026):** "1. fix the other odd cases; 2. copy from DMass; 3. move forward with the exclusions."
- **(3) Exclusion, in `r/00_sample.R`:** `exclude_nos_codes <- candidate_nos_codes`, so all eight codes are dropped: 463, 510, 530, 535 (habeas) and 540, 550, 555, 560 (prisoner petitions).
  - **Balance test first** (FarmShare run of 25 Oct, `presplit_nos_candidate_balance.csv`): all eight together remove 44,720 training (14.30%) and 11,259 holdout (14.39%) cases, z = −0.65. Every code and group was balanced (largest |z| = 2.38, for 560).
  - The split is not redrawn. `02_data_checks.R` now reports the exclusion as APPLIED, with its z-test.
- **(1) Cause fixes,** in the recodes section 7a (adding to change 56):
  - 73:201 ("Pennsylvania Consumer Fraud Act", a state statute, 73 P.S. § 201-1) becomes 28:1332 (diversity)
  - 99:9999 ("Report cause code (DO NOT DELETE)", a placeholder) becomes no cause, so `cause_group` "(no cause)"
  - 44:2107 (Presidential Records) and 36:327 (36 C.F.R. Part 327, miscited) are left as they are; they're real but rare, and will go into the rare-title merge
- **(2) FJC fill, as a general rule:** where SCALES `nature_suit` is blank and the FJC record has an NOS code, the code is used, written in SCALES's own wording (its most common label for that code). Where SCALES `jurisdiction` is blank, FJC JURIS is used: 1 = U.S. Government Plaintiff, 2 = U.S. Government Defendant, 3 = Federal Question, 4 = Diversity, 5 = Local Question. This covers the D. Mass. case (FJC NOS 890, JURIS 1).
  - **Caveat:** the fill happens in the analysis view, *after* the nature-of-suit exclusion. So a case with a blank SCALES nature of suit and a prisoner FJC code would not be excluded. That's at most a handful of cases; the 02-c oddities check found only one blank nature of suit in training, and its FJC code is 890.
- **Docs:** the EXPLAINER's top note now records the exclusion as applied, with its size and balance, and says results describe civil cases other than habeas and prisoner petitions. The `DATA_DICTIONARY.md` notes are updated; its counts are from before the exclusion.
- **Tested** on fake data:
  - 73:201 became 28:1332, and 99:9999 became "(no cause)"
  - a case with blank nature of suit and jurisdiction, and FJC NOS 890 / JURIS 3, became "890 Other" / "Federal Question"
  - a planted 555 case was excluded (61 to 60 cases); the APPLIED line reported 1 training and 0 holdout (PASS), and no pending candidates remain
  - 02, 02-a, 02-b, 02-c, 02-d, 04 and 05 all ran
  - Not yet run on the real data.

### 58. Decision: plaintiff representation is one variable, `plaintiff_firm_cases`
- **Evidence:** `02-d_data_checks_prose.R` on training cases after the prisoner exclusion (268,007 cases).
  - **Plaintiffs:** SCALES "pro se / no counsel" (29,772) against FJC `PROSE` plaintiff or both (31,022) agree 98.7%, kappa 0.934. Before the exclusion the figures were 98.6% and 0.962.
  - **Defendants:** SCALES "no counsel listed" (61,558) against FJC defendant pro se (9,342): only 11% of no-counsel defendants are pro se in the FJC, kappa 0.138 (before: 7.7%, 0.084). The remaining mismatches are default-prone case types: 440 civil rights, consumer credit, 446 ADA, copyright, trademark and patent, ERISA, foreclosure.
- **Decision (Josh, 25 Oct 2026):** `plaintiff_firm_cases` is the single plaintiff representation variable in the main model. Its "pro se / no counsel" category is the plaintiff pro se measure, and no separate plaintiff pro se flag is added, to avoid duplicating it. Claude also set out two alternatives, which were not chosen:
  - the same variable with pro se defined by the FJC
  - two variables, a pro se flag plus firm experience among represented plaintiffs, which are collinear in regressions
- **Defendant side:** still open. Josh asked for an explainer on sensitivity models before deciding whether `defendant_firm_rank`, and the defendant part of `pro_se`, move to the sensitivity model.
- **Recorded in:** `EXPLAINER.md` section 7B (new subsection) and the `DATA_DICTIONARY.md` model column for `pro_se` and `plaintiff_firm_cases`. No code changed.

### 59. `DATA_DICTIONARY.md` refreshed with post-exclusion counts
- **Source:** the 25 Oct 2026 FarmShare run (`fs_covariates.csv`, `fs_levels.csv`, `fs_high_pairs.csv`), 268,007 training cases. That's after the no-FJC exclusion, the habeas and prisoner nature-of-suit exclusion, and the recodes (changes 42, 56, 57).
- **Updated:**
  - every level count, smallest level and % missing in section 1
  - every category count in section 2
  - the "pairs that say nearly the same thing", with values
  - section 3: what the exclusion changed most (pro se plaintiffs 22.6% to 11.2%, fee waivers 18.8% to 13.1%, "no counsel listed" 30.3% to 23.0%)
  - section 4: the rare categories, now that the recodes have removed the one-case jurisdiction, nature of suit and cause oddities
  - `defendant_firm_rank`'s model column, now "undecided"
- No code changed.

### 60. Changes 47–59 pushed to GitHub
- Josh asked to push the files to GitHub (25 Oct 2026). Committed and pushed to `josharosenthal/MS-E-226--lawsuit-duration-project`.
- **New files:** `DATA_DICTIONARY.md`, `r/02-c_data_checks_oddities.R`, `r/02-d_data_checks_prose.R`.
- **`.gitignore`:** also excludes the rendered `DATA_DICTIONARY.html` and the private `NOTES_TO_SELF.md`. `misc/` stays excluded.

### 61. New script: `r/06_plots_and_correlations.R`
- **Josh's request:** a new set of files, starting with plots and correlations.
- **What it does:** on training cases, it writes PNGs to `~/scales_project/plots/`:
  - **first, a general histogram of all case durations** (added at Josh's request; he wrote "n-gram", read as histogram): every training case with a duration, in 30-day bins to the cap, with ended and transferred-out (censored) cases stacked in two colours, yearly gridlines, and the quartiles and cap printed underneath (`00_duration_histogram_all.png`)
  - duration histograms, in days and log(1 + days), for cases that ended in court
  - Kaplan–Meier curves (survival package), overall and by jurisdiction, arrival route, `plaintiff_firm_cases` and class action, with transferred-out cases censored
  - box plots of log duration for the 15 largest categories of each main-model categorical, and of the sensitivity categoricals, marked leaky
  - median log duration by each count covariate (50 or more pooled)
  - a heatmap of the covariate association matrix, with values of 0.7 or more labelled
  - a bar chart of each covariate's rank-based association with duration, all cases against recorded-only
- The last two read `05_feature_selection.R`'s saved tables rather than recomputing them.
- Uses base R graphics, so no new packages are needed.
- **Tested** on fake data, including a version with varied planted durations: all 34 plots were produced and checked by eye. Two fixes were made: dropping the explicit Cairo PNG type, which failed on the Mac, and skipping the duration chart when all its values are blank. Not yet run on the real data.

### 62. New script: `r/07-a_random_forest.R`
- **Josh's request:** code to run a random forest on the data.
- **What it does:**
  - Fits `ranger` random forests on training cases for two covariate sets: **main** (the dictionary's main covariates, using court rather than circuit or city, `cause_group` rather than `cause_title`, and `consolidation_role` rather than `is_consolidated`) and **sensitivity** (main plus `judge_group`, `senior_judge_at_filing`, `any_referral`, `defendant_firm_rank` and `pro_se`). `defendant_firm_rank` sits in the sensitivity set for now, pending Josh's decision.
  - **Two kinds** (`rf_outcome`): a regression on log(1 + days) for cases that ended in court, or a random survival forest (log-rank splitting) with transferred-out cases censored.
  - **Judged by out-of-bag error only:** OOB R², RMSE on the log scale and median absolute error in days, or the OOB C-index. The holdout isn't touched.
  - Permutation importance, with each variable's number of categories, because many-category variables can look more important than they are.
  - Unordered factors use `respect.unordered.factors = "order"`, which handles 94 courts and 201 cause groups efficiently.
  - Settings: 500 trees, minimum leaf size 5, seed 226, optional random subsample (`rf_sample_n`), threads from Slurm, and fitted forests saved only if `save_models = TRUE`.
  - **Outputs** in `~/scales_project/models/`: a summary CSV, importance CSVs and an importance plot (leaky variables in red).
- **Needs the `ranger` package.** It isn't part of base R: on FarmShare run `install.packages("ranger")` once. For local testing, Claude installed ranger 0.18.0 from CRAN into the test library only, with Josh's permission.
- **Tested** on fake data with planted durations (removed cases last about 400 days, others about 100), 100 trees:
  - both outcomes ran
  - arrival route was by far the top variable in both forests
  - OOB R² 0.63 (main); OOB C-index 0.65–0.68
  - all output files were written
  - the main-vs-sensitivity message was reworded, since a tiny sample can give a negative gap
  - Not yet run on the real data.

### 63. New script: `r/02-e_data_checks_nocause.R` (cases with no cause of action)
- **Josh's request:** the training data has 3,676 "(no cause)" cases. He asked for summary statistics on whether each has a jurisdiction and a nature of suit, and on court and pro se; then he asked what other data points would be useful.
- **What it does:** on training cases, it compares no-cause cases (`cause_group` "(no cause)": a blank SCALES cause, or the recoded 99:9999 placeholder) with cases that have a cause.
  - **Summary table:** % with a jurisdiction; % with a nature of suit; % pro se plaintiff by the FJC and by SCALES; % where the FJC has a cause title (TITL); median duration of cases that ended; % ending within 30 days; % transferred out; median docket entries; % SCALES stubs; % with no docket; % fee waiver; % class action.
  - **Distributions** for no-cause cases, with each category's no-cause share: jurisdiction, nature of suit, court, FJC pro se, plaintiff representation, arrival route, filing year, first plaintiff type and first defendant type.
  - **The FJC cause title** for no-cause cases.
- **The extra data points were Claude's suggestion** (duration, docket size, arrival route, year, party types, fee waivers, class actions, stub flags), to tell "ordinary case with a missing field" from "odd record", as the no-FJC check did. The stub flags are used only if those columns exist.
- Counts only; it looks at duration, which is allowed on training data.
- **Tested** on fake data with 6 planted no-cause cases (one with a blank jurisdiction, three pro se) plus the recoded 99:9999 case. It found 7, and the summary and distributions match the planted values. Not yet run on the real data.

### 64. First real random-forest run; a "main without n_counsel" set added
- **First FarmShare run of `07-a_random_forest.R`** (log duration, 260,403 training cases that ended in court, 500 trees, about 2.5 minutes per forest):
  - **main:** OOB R² 0.472, RMSE 0.856 (log scale), median absolute error 94 days
  - **sensitivity:** OOB R² 0.523, RMSE 0.814, median absolute error 89 days, so the leaky variables add at most +0.051
  - **Main-forest importance:** `n_counsel` 0.83, far ahead of `nature_suit` 0.35, `cause_group` 0.33, `court` 0.28 and `n_parties` 0.17. In the sensitivity forest, `judge_group` (0.30) and `defendant_firm_rank` (0.28) come next after `n_counsel`.
- **Concern:** `n_counsel` is in the main set but its leakage tier is "leaky": lawyers are added as a case goes on. The `06` plot shows median duration rising from about 48 days with 0 counsel to about 550 days with 20 or more.
- **Change (Josh's request):** `07-a` now also fits **`main_no_counsel`** (main minus `n_counsel`) by default (`model_sets`). It prints "main minus main_no_counsel" and the top 10 variables of both main forests.
- **Also noted:** the Kaplan–Meier plots (`06`, plots 02–03) weren't produced on FarmShare, apparently because the `survival` package isn't available there. Josh doesn't plan to run the survival forest.
- **Tested** on fake data: all three sets ran and the output files were written. The fake data has no `n_counsel`, so the two main sets are identical there. Not yet run on the real data.

### 65. No-cause cases: cause filled from the FJC section (rule a)
- **Why:** `02-e` and two follow-up tables (`nocause_fjc_by_nos.csv`, `nocause_top_causes_by_nos.csv`) showed that for many of the 3,773 no-cause training cases, the FJC record has a statute **section** even when its title is blank or 0. Of the 2,836 cases in the top 60 rows, 1,678 had a numeric section (e.g. 0227 = 47 U.S.C. 227, the TCPA; 2601 = FMLA; 1210 = ADA 12101, cut off by the FJC's 4-character field). The rest were -8 (missing, 529), letter codes (541; Josh noted MI/SC is the FJC's "miscellaneous") and placeholders 99/999 (88).
- **Change (Josh, 28 Oct 2026), `00_sample.R` section 7a:** a case with no SCALES cause (including the 99:9999 placeholder) whose FJC SECTION is a number other than 0, 99, 999 or 9999 gets the SCALES cause that is **most common among training cases with the same nature-of-suit code** whose section matches: exactly, with letters after it, or (for a 4-digit FJC section, which may be cut off) starting with it. If the FJC title is a real number, the title must match too. No match: stays "(no cause)". New column `cause_from_fjc` marks filled cases. The lookup uses training cases only; the same rule applies to holdout cases.
- **Not done:** option (b), filling the rest with the most common cause for their nature of suit. It would invent a cause, and nature of suit is already in the models. MI/SC and other letter codes stay "(no cause)".
- `02-e` now prints how many causes were filled, by cause group (`nocause_0_filled_from_fjc.csv`).
- **Tested** on fake data with 11 planted cases: numeric section, cut-off section (1210 to 12101), title 0, the 99:9999 placeholder and a holdout case were all filled correctly. MI/SC, -8, 99/99, a title mismatch, a section with no match and a nature of suit with no known causes all stayed "(no cause)". The lookup ignored holdout cases (a cause made more common by holdout cases did not win). Fake data without FJC TITL/SECTION columns still runs.
- **Real run (28 Oct 2026, `02-e`):** about 1,990 of 3,773 no-cause training cases filled: 47:227 962, 42:12131 580 (almost all M.D. Fla., from the cut-off FJC "1213"), 28:1332 68, 29:2601 63, 42:12101 48, then small groups. 1,784 stay "(no cause)" (0.7% of training). They differ from cases with a cause: FJC pro se plaintiff 37% vs 12%, IFP 26% vs 13%, ended within 30 days 23% vs 7%, median 152 vs 245 days. Kept as their own group (Josh: no merge with rare causes).

### 66. New script: `r/07-b_short_case_forest.R` (classification forests: is the case short?)
- **History:** first written as a quantile-forest script (`07-b_quantile_forest.R`), never run on the real data. Josh judged it a red herring, because ranger builds the same mean-based trees. A version fitting log duration on short cases only was a misunderstanding and was replaced the same day (28 Oct 2026). The file was renamed.
- **What it does:** two yes/no outcomes, one ranger probability forest each: **ended within 60 days?** and **ended within 120 days?** (`short_cutoffs`). Each is fitted for main, main_no_counsel and sensitivity. The splits target the quick end directly.
- **Which cases:** all training cases with a duration. Cases that ended in court count as short if the duration is at or below the cutoff. A case transferred out after the cutoff is known not to be short, so it's kept as "no". A case transferred out before the cutoff has an unknown outcome and is dropped for that cutoff. Remands count as endings, as elsewhere.
- **Judging (out-of-bag):** AUC, Brier score, and Brier skill (1 − Brier / Brier of predicting the overall share). Also permutation importance (rise in OOB Brier score). It prints "main minus main_no_counsel" and "sensitivity minus main" in AUC for each cutoff. `min.node.size` is 10.
- **Output:** `~/scales_project/models/short_summary.csv`, `short_<cutoff>d_<set>_importance.csv`, `short_<cutoff>d_importance.png`.
- **Tested** on fake data (100 trees): both cutoffs and all three sets ran, and all outputs were written. The planted effect (arrival route) was found (AUC 0.73 at 60 days, 0.83 at 120). Cases transferred out before the cutoff were dropped (7 at 120 days).
- **Fix after the first real run (28 Oct 2026):** every `oob_auc` came out NA. On about 265,000 cases, n_short × n_other is too big for R's whole-number type, so R returned NA. Those counts are now stored as ordinary decimal numbers. Checked on 265,000 fake cases, the AUC is now computed. The Brier scores and importances from the first run were unaffected. First run: Brier skill for main / main_no_counsel / sensitivity was 0.313 / 0.251 / 0.348 at 60 days and 0.332 / 0.257 / 0.361 at 120 days. Rerun after the fix: OOB AUC 0.872 / 0.827 / 0.887 at 60 days and 0.851 / 0.811 / 0.865 at 120 days.
- **AUC by duration band (Josh, 28 Oct 2026):** asks how much of the 120-day result comes from the same cases as the 60-day one. The 120-day short cases split into 0–60 and 61–120 days. The overall AUC is exactly the weighted average of "0–60 vs over 120" and "61–120 vs over 120", weighted by each band's share of the short cases. Also reported: "0–60 vs 61–120" (can the forest tell very quick cases from merely quick ones?). New output: `models/short_120d_by_band.csv` (comparison, pair counts, weight, OOB AUC, per set). The log prints each band's share of the main minus main_no_counsel gap. Counts only, no case identifiers; the other outputs are unchanged. **Tested** on fake data: the weighted band AUCs added up to the overall AUC (0.7234 main, 0.8223 sensitivity), and a band file was written for 120 only.

### 67. New script: `r/02-f_data_checks_endings.R` (balance of cases that left the court)
- **Why (Josh, 28 Oct 2026):** if transferred-out cases can't be matched to their receiving case, they may be dropped. Remands to state court, arbitration and similar endings should be looked at too.
- **What it does:** counts of cases by FJC `DISP`: 0 transferred, 1 remanded to state court, 11 remanded to a U.S. agency, 15 award of arbitrator, 16 stayed pending bankruptcy, 18 statistical closing, plus groups (remands; left for another forum = 0, 1, 11; all six). For each, the training vs holdout share and the two-proportion z-test from `02_data_checks.R` (FLAG if |z| > 3). This uses an outcome in the holdout, so counts only. Training only: docket mentions of sending a case to arbitration (compel / stay / refer ... arbitration), by `DISP`. Outputs: `checks/endings_1_split_balance.csv`, `endings_2_arbitration_by_disp.csv`.
- **Nothing is dropped yet;** the decision is Josh's after the check.
- **Tested** on fake data: planted transfers, remands, an arbitration award, statistical closings and an arbitration docket entry, on both sides. All were counted correctly; PASS.
- **Real run (28 Oct 2026):** FLAG, 8 of 9 rows balanced. Remanded to state court (DISP 1) is 3.45% of training vs 3.79% of the holdout (z = −4.35). Every other type and group is within |z| ≤ 3. The split is by consolidation group, so the case-level z-test may overstate the gap; this wasn't checked. 6,611 training dockets mention sending the case to arbitration (54% of DISP 15 cases, 11% of DISP 18).
- **Decision (Josh, 28 Oct 2026):** remands to state court stay counted as endings, as before, so the imbalance isn't a concern. No code change.

### 68. New script: `r/90_transfer_matching.R` (can transferred cases be followed?)
- **Why (Josh, 28 Oct 2026):** transferred-out cases are censored. If each could be matched to its receiving-district case, the full time to resolution could be followed.
- **What it does,** for training cases with `duration_status = 'transferred_out'`:
  1. **Receiving docket:** an early entry (first 10) of a case in another court mentions a transfer and the origin's case number (year and number; "1:16-cv-00023", "16-cv-23" and N.D. Ill.'s "16 C 23" all match).
  2. **Origin docket:** a transfer entry in the origin docket gives another case number that exists in another court.
  Both require the receiving case to be filed between 30 days before and 365 days after the transfer. An origin with more than one candidate is counted as ambiguous. Method 3 (FJC only) counts FJC transferred-in records with the same nature of suit filed 0–60 days after the transfer, as a measure of ambiguity (only if `fjc_idb_civil.parquet` has ORIGIN, NOS and FILEDATE).
- **Holdout:** holdout cases are never used as receiving cases, so all counts are lower bounds. A receiving case filed after 2017 is findable only if `cases.parquet` holds that year; the script prints the years it holds.
- **Outputs:** `checks/transfers_1_pool_years.csv`, `_2_summary.csv`, `_3_receiving_cases.csv`, `_4_by_origin_court.csv`, `_5_fjc_candidates.csv`, `_spotcheck.csv` (case IDs of up to 50 matched pairs, no names).
- **Tested** on fake data with 6 planted transfers: receiving-docket, origin-docket and "16 C" style matches were found. A holdout receiver and a receiver outside the window were not matched. A case with two receivers was counted as ambiguous. Not yet run on the real data.

### 69. New script: `r/02-g_data_checks_counsel.R` (where does `n_counsel`'s leakage come from?)
- **Why (Josh, 28 Oct 2026):** `n_counsel` counts every lawyer listing on the docket as SCALES collected it, usually after the case ended. This check splits it into parts, to see which grow with case length.
- **What it does (training cases only, by side and by duration band: 0–60, 61–120, 121–365, 366–730, over 730 days, transferred out):**
  - **Lawyers at collection:** distinct lawyer names on each side. A lawyer listed for several parties counts once; pro se listings aren't lawyers.
  - **Lawyers at filing:** those named in a docket entry within `filing_window_days` (7) of filing. A name matches when both its first and last word appear in the entry. The counsel table has no dates, so docket text is the only source.
  - **Added after filing:** at collection minus at filing.
  - **Terminated listings:** a counsel field says TERMINATED. SCALES has no separate field, so the script also reports which fields contain it.
  - **Pro hac vice listings:** `is_pro_hac_vice`, or a field says "pro hac vice".
  - **Listings for dismissed parties:** lawyers for a party with its own terminating date.
  - **Pro se plus lawyer:** the side has both a pro se listing and a lawyer.
  - **Case level:** docket entries about withdrawal or substitution of counsel.
  - **Spearman correlation with days to ending:** each count, for cases that ended in court.
  - **Check on the method:** how often each lawyer is named in the docket at all, by side and court.
  - **Check on the count:** how often `n_counsel` differs from the listings counted here (should be about 0).
- **Outputs:** `checks/counsel_1_fields.csv`, `_2_by_band.csv`, `_3_withdrawals.csv`, `_4_decomposition.csv`, `_5_correlations.csv`, `_6_match_rate.csv`, `_spotcheck.csv` (30 random training case IDs with counts). No names are printed or saved. DuckDB is limited to 24 GB, with a temporary spill folder, so it stays inside the batch job.
- **Tested** on fake data with planted cases. Every count matched what was planted:
  - one lawyer listed for two plaintiffs
  - lawyers named on day 0–2 (at filing) vs days 30–100 (later)
  - a "TERMINATED: date" listing in `bar_status`
  - a pro hac vice listing with a middle initial and "Jr."
  - a lawyer for a dismissed defendant
  - a pro se plaintiff who later had a lawyer
  - a withdrawal entry
  - an intervenor's lawyer counted as "other"

  The count-mismatch check caught a fake `n_counsel`. Not yet run on the real data.

### 70. `n_counsel` out of main; representation measured only where a lawyer appeared; XGBoost (07-c)
- **Decisions (Josh, 28 Oct 2026), after `02-g_data_checks_counsel.R`:**
  - **`n_counsel` is out of main: too leaky.** In 02-g, defense lawyers added after filing correlate 0.454 with days to ending, while defense lawyers at filing correlate −0.007. It stays in the sensitivity set.
  - **Keep defense firm information, but only where a lawyer appeared.** "No counsel listed" is folded into a common category, so it can't be picked out.
  - **Plaintiffs keep `plaintiff_firm_cases` as it is,** with "pro se / no counsel" as its own level, because plaintiff pro se is mostly known at filing. An earlier version of this change folded it into "1–10 cases"; that wasn't what Josh meant, so it was removed before anything ran.
  - **Bring back a pro se defendant variable.**
  - **Merge** defense "headcount not given" with "rank 181–200".
- **`r/00_sample.R` (section 7b), two new columns.** The originals are unchanged.
  - `defendant_firm_appeared`: `defendant_firm_rank`, with "no counsel listed" folded into "not in list", and "rank 181–200" merged with "large-firm list, headcount not given" into "rank 181–200 or headcount not given".
  - `defendant_pro_se`: "yes" if FJC `PROSE` is 2 (defendant) or 3 (both); "no" if it's 0 or 1; otherwise "not recorded" or "no FJC record".
  - **Known limits** (discussed before deciding):
    - The ranked defense levels still need a lawyer to have appeared, so the leak shrinks but doesn't vanish.
    - The new baseline mixes defended and undefended cases.
    - `defendant_pro_se` carries some of the information that was folded away.
- **New `r/covariate_sets.R`:** one place for the sets, now sourced by 06, 07-a, 07-b and 07-c.
  - `main`: no `n_counsel`. `plaintiff_firm_cases` as before, plus `defendant_firm_appeared` and `defendant_pro_se`.
  - `main_plus_counsel`: main + `n_counsel`. This replaces `main_no_counsel`, so the comparison now shows what `n_counsel` would add.
  - `sensitivity`: main + `judge_group`, `senior_judge_at_filing`, `any_referral`, `defendant_firm_rank`, `pro_se` and `n_counsel`.
- **Other scripts:**
  - `05_feature_selection.R`: the two new variables are added to its list (37 covariates).
  - `06`: now takes its lists from `covariate_sets.R`.
  - `07-a` and `07-b`: use `make_sets()`. The headlines report main_plus_counsel minus main.
  - `DATA_DICTIONARY.md`: Model column updated, two new rows. Their counts are derived from the 25 Oct counts and will be confirmed by the overnight 05.
- **New `r/07-c_xgboost.R`:** XGBoost for log duration and for ended within 60 / 120 days, for the same three sets.
  - 5-fold cross-validation within training. Early stopping uses a further 10% of each fold's training part, so a case's own fold is used only for scoring.
  - Settings: learning rate 0.05, depth 6, minimum leaf weight 10, 80% row and column subsampling, at most 3,000 trees, stopping after 50 without improvement.
  - Importance is gain, from one model on all training cases with the median number of trees, added up over each variable's one-hot columns.
  - Outputs: `models/xgb_summary.csv`, `xgb_<outcome>_<set>_importance.csv`, `xgb_<outcome>_importance.png`.
  - Needs `install.packages("xgboost")` on FarmShare. It works with xgboost 1.x to 3.x, where the validation argument changed name.
- **New `r/run_overnight.sh`:** runs 05 → 06 → 07-a → 07-b → 07-c as one 12-hour batch job. A failed script doesn't stop the rest.
- **Tested on fake data:**
  - The recode rules were checked on planted values: every fold and merge, PROSE 0/1/2/3/−8, and no FJC record.
  - 05, 06, 07-a and 07-b ran with the new sets.
  - 07-c ran on 5,200 synthetic cases with planted effects. It found arrival route and defense firm as the top variables, and showed the gain from a planted `n_counsel` effect (+0.18 R²).
  - A 50-case set too small to grow any tree no longer crashes. Its importances come out as 0.
  - xgboost 3.2.1 was installed in the local test library for this, with Josh's OK.
- **Not yet run on the real data.**

### Suggested but not made (Josh's decision)
- **Party `raw_info` may contain addresses.** This is the text PACER shows under a party's name, and for people representing themselves it can include an address and phone number. Kept unchanged, which fits the decision above to keep contact information.
- **Unreadable event-log rows.** `03_convert_eventlog.sh` leaves rows the CSV reader can't parse out of `eventlog.parquet` and lists them in `profiles/eventlog.rejected_lines.csv`. Kept unchanged; check that this count is small after the first real run.

### How these changes were tested
On a Mac, with a small fake archive (one good case, one case with an invalid character in its docket text, one `.txt` file):
- The good case produced one row in each table. The bad case produced no rows in any table and appeared in `parse_errors.csv`.
- The skipped `.txt` file was reported, and the 676,809 warning was printed.
- An archive containing no `.json` files stopped with an error.
- A truncated archive stopped `01_check_files.sh` with the `STOP` message.

None of this has been run on the real files or on FarmShare.
