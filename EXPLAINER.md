# Getting the SCALES data onto FarmShare: a plain-language guide

> **Project data set:** The data set will be civil cases filed in 2016 and 2017, not including habeas cases or cases marked 1983pr. (This is a change, since the set formerly included only closed cases.)
>
> In the code (`r/00_sample.R`), "filed in 2016 and 2017" means the year in the case number (e.g. `16` in `1:16-cv-04871`), which is how SCALES built the data. Habeas means 28 U.S.C. § 2241, 2254 and 2255. Duplicates are removed. Open and closed cases are both included, and `case_closed` marks which is which.
>
> **Also excluded (Josh, 24 Oct 2026): MDL member cases**, flagged by SCALES `is_mdl` or FJC `ORIGIN` 6/13, about 78,600 cases. Their timing is driven by the MDL, and members of one MDL often end together. **Cases that ended by MDL transfer out** (FJC `DISP` 10, about 4,250 more) are excluded with them. These were sent to an MDL court, so leaving this court wasn't a real ending, and they're MDL-bound cases that neither source flags as MDL members on this side. The holdout is drawn **by consolidation group**, so a lead case and its members stay on the same side of the split.
>
> **Also excluded (Josh, 24 Oct 2026): OVERLONG cases.** These are the 748 cases that lasted longer than the 3,103-day cap, or were still pending in the FJC file on 30 June 2026. They're removed from the sample **before the split**, so they appear in neither training nor holdout. **The analysis population excludes the 748 cases still pending (or lasting) beyond 3,103 days; results describe cases resolved within about 8.5 years.** This choice selects on the outcome:
> - **Duration estimates will be somewhat shorter** than for all 2016–17 cases, because the longest cases are missing.
> - **The models can't say anything about cases that last longer than about 8.5 years.**
> - **State this in the write-up.** At about 0.2% of the sample, the effect is small.
>
> **Also excluded (Josh, 24 Oct 2026, after the split): cases with NO FJC record**, about 7,500 cases, 1.9% (5,982 of them in training). These cases have no matching record in the FJC Integrated Database. `r/02-a_data_checks_fjc.R` showed they are mostly administrative case numbers closed within days, not ordinary litigation:
> - median duration 3 days, against 235 for linked cases; 74% end within 30 days
> - median 3 docket entries, against 23
> - "transfer" wording three times as often
> - concentrated in a few courts: S.D. Florida alone holds 27% of them
>
> So "no FJC record" partly records the outcome, and their "endings" are often not real ones. **Results describe cases with an FJC record**, so every FJC covariate is recorded for every case in the sample.
>
> **The split was not redrawn.** The same rule removes these cases from training and holdout alike, and the split itself never depended on FJC status. `02_data_checks.R` reports how many each side lost and the holdout share afterwards.
>
> **Also excluded (Josh, 25 Oct 2026, after the split): habeas and prisoner-petition cases by nature of suit.** The cause-based rules (28 U.S.C. 2241/2254/2255 and 42:1983pr) missed cases whose **nature of suit** is a habeas or prisoner code but whose cause is something else. These are now excluded too:
> - **Habeas:** 463 Alien Detainee, 510 Motions to Vacate Sentence, 530 General, 535 Death Penalty
> - **Prisoner petitions:** 540 Mandamus & Other, 550 Prisoner: Civil Rights, 555 Prison Condition, 560 Civil Detainee
>
> **Size:** about **14.3%** of the sample: 44,720 training and 11,259 holdout cases. 550 (27,727 training) and 555 (14,510) are the bulk.
>
> **Balance was tested before deciding,** for each code, each group and all together, and every one passed: largest |z| = 2.38, all-codes z = −0.65 (`checks/presplit_nos_candidate_balance.csv`). The split isn't redrawn. **Results describe civil cases other than habeas and prisoner petitions.** Pro se plaintiffs and fee waivers are much rarer as a result. Some prisoner suits filed under other natures of suit, such as 440, remain.
>
> **Dependent variable: duration**, from filing to termination, **capped at 3,103 days**: the time from 31 Dec 2017 to 30 Jun 2026, the date the FJC data run to. Because overlong cases are excluded, no case in the sample reaches the cap. In `analysis_fjc` / `train_fjc`:
> - `duration_capped_days` is the variable itself.
> - `is_overlong` is always FALSE in the sample, since overlong cases are excluded. It's kept so the variable works if that decision is reversed.
> - **Cases transferred to another district** (FJC `DISP` 0) continued elsewhere, so their duration is the time until they left. They're marked `duration_status = 'transferred_out'` and treated as **censored**. Remands (to state court or a U.S. agency) count as ordinary endings.
> - `event_observed` is TRUE if the case ended in this court, and FALSE if it's censored (transferred out). For survival models, use `Surv(duration_capped_days, event_observed)`.
> - **Cases without a duration value are left out** of the duration analysis (about 0.06%: 233 `unknown_end`, 2 `end_before_start`).
> - `duration_status` says why a case has no value: `unknown_end` (open in SCALES, no FJC record), `pending_short_followup`, `no_filing_date` or `end_before_start`.
> - `end_date_source` says whether the end date came from SCALES or the FJC.
>
> The settings are at the top of `r/00_sample.R`.
>
> **Before choosing covariates, read section 7 (leakage warnings).**

These scripts do two jobs.

1. **Build the data** (sections 1–5). They take the case archive you downloaded from SCALES, turn it into tables you can query, and describe what's in them. A later step adds the Federal Judicial Center's (FJC) civil data, which records how each case ended. This part doesn't filter cases, choose a sample or start any analysis: every case, party, lawyer and docket line is kept.
2. **Define and check the analysis sample in R** (section 6). One shared R file defines the sample. The others check data quality, search the dockets for attorney's-fee entries, set aside the holdout, and show individual cases.

Every change to these files is recorded in `CHANGES.md`, for the project's AI-use disclosure. `RUN_SUMMARY.md` records what the first real run found.

---

## 1. What you start with and what you end with

**You start with** one file from the SCALES file server:

| File | What's inside |
|---|---|
| Cross-Sectional Data (JSONs), ~2.2 GB `.gz` | 676,809 federal cases, one JSON file each, packed into a single compressed archive. JSON is a text format for nested records: a case contains a list of parties, each party contains a list of lawyers, and so on. |

Step 05 also downloads the **FJC Integrated Database civil file** (`cv88on.zip`, ~330 MB). It holds one record for every federal civil case terminated since 1988, plus cases still pending, with coded outcomes.

**You end with** these tables, each saved as a Parquet file in `~/scales_project/parquet/`:

| Table | One row is… | Comes from |
|---|---|---|
| `cases` | one case: court, case number, filing and termination dates, case type, judge, nature of suit, flags, and counts of docket entries, parties and lawyers | case JSONs |
| `parties` | one party in a case: name, role (e.g. "Plaintiff"), SCALES's party category, the description PACER shows under the name, and contact details | case JSONs |
| `counsel` | one lawyer listed for a party: pro se, lead attorney, pro hac vice, firm, and contact details | case JSONs |
| `docket_entries` | one line of a docket sheet: date, entry number, full text | case JSONs |
| `criminal_counts` | one criminal charge against a defendant (criminal cases only) | case JSONs |
| `fjc_idb_civil` | one FJC record: every row and column of the FJC file, kept as text | FJC file (step 05) |
| `scales_fjc_link` | one match between a SCALES civil case and an FJC record, with the FJC outcome fields: disposition, judgment, nature of judgment, procedural progress and more. `fjc_rank = 1` marks the best match when a case has several. | step 05 |

The SCALES tables link through **`ucid`**, SCALES's case ID: the court plus the PACER case number, e.g. `azd;;2:16-cv-00001`. A lawyer links to their client through `ucid` + `party_index`. FJC records link to cases through `scales_fjc_link`, which matches on court + office + docket number. 98.3% of SCALES civil cases found a match.

You also get shape reports and 10,000-row samples in `~/scales_project/profiles/` (section 4).

**Privacy:** `config.sh` has `KEEP_CONTACT_INFO="yes"`, so parties' and lawyers' addresses, phone numbers, fax numbers and emails **are included** in `parties` and `counsel`. Party descriptions (`raw_info`) can also contain addresses. These are public court records, but keep the raw files, the tables and any pages showing names on FarmShare, and don't share them.

---

## 2. Vocabulary (just enough)

| Term | What it means here |
|---|---|
| **Terminal** | A text window where you type commands. |
| **bash script (`.sh`)** | A text file of terminal commands, run in order with `bash name.sh`. |
| **Python script (`.py`)** | A program in Python. The Python scripts here use only Python's built-in tools, so there's nothing to install. |
| **R script (`.R`)** | A program in R, run in RStudio (or R in a terminal) with `source("file.R")`. |
| **`.tar.gz`** | Many files bundled together (`tar`) and compressed (`gz`), like a `.zip`. |
| **Streaming** | Reading the archive from start to finish one case at a time, without unpacking it. That avoids creating 676,809 separate files, which could exceed FarmShare's limit on the number of files you can store. |
| **Flattening** | Turning nested records (case → parties → lawyers) into separate flat tables that link by ID. That's the shape R and SQL expect. |
| **DuckDB** | A small, fast database program that turns the flattened files into Parquet and answers questions in SQL. The R scripts use it too. |
| **Parquet** | A compressed table format that keeps column types (dates, numbers). R, Python and DuckDB all read it. |
| **View** | A saved query inside DuckDB (e.g. `analysis_fjc`). Use it inside SQL: `dbGetQuery(con, "SELECT … FROM analysis_fjc")`. It isn't an R object until you pull it in with `dbGetQuery`. |
| **Slurm / `sbatch`** | FarmShare's queue for long jobs, which keep running after you log out. |
| **Holdout** | The 20% of cases set aside, untouched, until the final evaluation. |

---

## 3. The files in this folder

**Building the data (bash and Python, run on FarmShare)**

| File | What it does | Edit it? |
|---|---|---|
| `config.sh` | All the settings: file names, folders, privacy, FJC download address | **Yes** |
| `00_setup.sh` | Makes folders, checks tools, installs DuckDB, shows disk space, checks the case archive is in place | No |
| `01_check_files.sh` | Tests the case archive isn't corrupted, shows what's inside, records its size and checksum (fingerprint) in a manifest | No |
| `02_flatten_cases.sh` + `flatten_scales.py` | Streams through the case archive and builds the five case tables | No |
| `04_profile.sh` | Writes the shape reports and samples | No |
| `run_all.sh` | Runs 00, 01, 02 and 04 in order and keeps a log. There's no step 03: it converted the SCALES event log, which is no longer used. | No |
| `submit_farmshare.sbatch` | Runs `run_all.sh` as a background job | Maybe the resource lines |
| `05_import_fjc.sh` | Run separately: downloads the FJC civil file, converts it to Parquet and links it to the SCALES cases | No |
| `fix_fjc_text.py` | Used by step 05: repairs the few malformed lines in the FJC file (tabs inside names, non-UTF-8 text) so every row is kept | No |
| `fjc_district_crosswalk.csv` | Used by step 05: FJC district codes → SCALES court abbreviations, all 94 districts | No |

**Analysis sample and checks (R, run in RStudio on FarmShare): the `r/` folder**

| File | What it does | Edit it? |
|---|---|---|
| `r/00_sample.R` | The one place the analysis sample is defined: 2016–17 civil cases (by case-number year), open or closed (`case_closed` says which), minus habeas (§ 2241, 2254, 2255) and 42:1983pr, duplicates removed, joined to the FJC data. Every other R file starts by loading it. Set `population` first: `"all"` (default), `"fee_requests"` or `"fee_shifting"`. | Only to change the sample |
| `r/01_build_features.R` | **Run once** (and again if the data change): builds the covariates you chose in `covariates.xlsx` and saves them to `~/scales_project/parquet/case_features.parquet`, which `00_sample.R` then joins automatically. Includes case-number parity, referral, related case, consolidation, circuit, diversity residence, county urban/suburban/rural, senior judge at filing, party counts and types, plaintiff-firm experience, defendant-firm size rank, `.org` plaintiff attorney, TRO/PI motion within 60 days and amicus. It also writes `checks/features_report_*.csv` (coverage, judge, county and firm match checks). Takes several minutes. | No |
| `r/02_data_checks.R` | **Run before making the split**, and again whenever the data or covariates change. **Part 1**, a PASS / FLAG / INFO / OPEN summary: sample size; duplicates; whether the covariates are built and current, and how well judges, counties and firms matched; duration coverage; related cases (MDL, consolidated); removed and transferred cases (FJC `ORIGIN`) compared with `is_multi` and `is_mdl`; cases that ended by transfer or remand (counts only); decisions still open; software versions. **Part 2**, detailed tables: duplicates, missing values, SCALES-vs-FJC consistency, class-action codes, duration coverage. **Part 3**, open cases across all of `cases.parquet`, and what the FJC says happened to them later. Structure only: no outcome comparisons. Merged from the former `01_data_checks.R`, `02_data_checks.R` and `07_presplit_checks.R`. | No |
| `r/02-a_data_checks_fjc.R` | **Training cases only.** The cases with no FJC record (no match, or an FJC record shared by two cases). For them it reports: how many; their durations against linked cases; SCALES status and docket size; how often their dockets mention "opened in error", duplicate or re-filed, transfer, remand, consolidation, voluntary dismissal or sealing (against a same-size random sample of linked cases); which years, courts and natures of suit they come from; and how closely SCALES and FJC end dates agree for linked cases. It checks whether a missing FJC record is a linking gap or reflects how the case ended (leakage). Counts only. Writes `checks/fjc_missing_*.csv`. | No |
| `r/02-b_data_checks_judges.R` | **Training cases only.** How often the judge was **reassigned**, on a fixed random sample of 10,000 training cases (`n_sample`). (1) It finds the first "assigned to" entry on the docket, skipping magistrate referrals, and checks whether the SCALES judge, recorded at collection, is the same judge. (2) It searches the docket for "reassign", "no longer assigned", "recus" or "transferred to Judge". Tables: both measures, their cross-tab, by duration band and by court. Writes `checks/judges_reassign_*.csv`, including a 200-case spot-check file for checking the name matching by hand. | `n_sample` |
| `r/02-c_data_checks_oddities.R` | **Training cases only.** The case header for every training case with an odd value: blank nature of suit, blank jurisdiction, "Local Question", a cause title cited by only one case, unmatched county code, or a defendant whose name isn't recorded. It shows the SCALES header next to what the FJC record says (NOS, JURIS, county, cause). The console shows counts and a table without names; the full headers, with case names, go to `checks/oddities_cases.csv`. | No |
| `r/02-d_data_checks_prose.R` | **Training cases only.** Do SCALES and the FJC agree on who has no lawyer? It cross-tabulates SCALES "pro se / no counsel" (first plaintiff) and "no counsel listed" (first defendant) against FJC `PROSE`, for each side. It reports the share of each source's "no lawyer" confirmed by the other, the agreement and Cohen's kappa, and the largest natures of suit and courts among disagreements. Counts only. Writes `checks/prose_*.csv`. | No |
| `r/03_holdout.R` | Sets aside 20% of the chosen population's **consolidation groups** as its holdout (a lead case and its members stay together; other cases are their own group), **once**, and saves it to `~/scales_project/holdout_split_<population>.csv`, with a README and a fingerprint (`.md5`) | No |
| `r/04_random_case.R` | One case, at random or one you name, as a readable markdown page in `~/scales_project/case_views/`, with the FJC codes translated into words and the docket listed. It draws from training cases only once the holdout exists. `case_pool <- "1983pr"`, `"habeas"` or `"mdl"` shows an excluded case instead. | No |
| `r/05_feature_selection.R` | **Training cases only.** How the chosen covariates relate to each other and to duration, to help decide which to keep. It uses the measure that fits each pair, since `cor()` works only for numbers: Spearman for counts, Cramér's V (bias-corrected) for two categorical variables, and eta (correlation ratio) for a count with a categorical variable. All run from 0 to 1. Each pair uses only cases where both variables are recorded: missing-value labels are left out, since a shared "no FJC record" label would otherwise look like association. Lists pairs at or above 0.7 as possibly redundant, flags constant variables, and gives each covariate's association with duration for cases that ended in court: on the rank of duration and on log(1 + duration), each for all cases and for cases where the covariate is recorded. A big drop on recorded cases means the "missing" category is doing the work. Writes `feature_selection/fs_*.csv`. The covariate list and leakage tier are at the top of the file. **Annotated walk-through: `FEATURE_SELECTION_GUIDE.md`.** | Covariate list, `assoc_threshold` |
| `DATA_DICTIONARY.md` | The 35 candidate covariates: meaning, source, type, number of levels, smallest level and % missing (training), leakage tier, and main or sensitivity model; the values of the covariates with few categories, with a rough mix; and the rare categories worth merging. | As decisions change |
| `r/99_fee_search.R` | *(Parked: not used in the current project.)* Attorney's-fee docket entries, classified as requests, rulings, responses and so on. Writes the list of cases with a fee request (which defines the `"fee_requests"` population). Rulings are shown for training cases only once the holdout exists. | No |
| `r/fee_shifting_codes.csv` | *(Parked.)* **Your list** of causes of action and nature-of-suit codes that define the `"fee_shifting"` population. Examples are included but switched off. | **Yes** |
| `reference/` | Lookup tables from outside sources used by `01_build_features.R`: the FJC judge directory (senior status), the NCHS 2013 county urban–rural codes, and the BCG large-firm headcount ranking. Sources and caveats are in `reference/README.md`. | No |

**Other**

| File | What it does |
|---|---|
| `match_us_code.py` | Matched cause-of-action title and section pairs to US Code section headings (CourtGPT/us-code). Its output is `closed_civil_by_cause_titlesection_usc.csv`. |
| `covariates.xlsx` | Every column in the merged table, plus variables that could be added, with type (continuous/categorical), whether it's known at filing (the leakage test for duration) and a column to mark which to use |
| `CHANGES.md` | Every edit to these files and why, for the AI-use disclosure |
| `RUN_SUMMARY.md` | What the first real run found: counts, timings, quality checks, coverage |
| `BRIEF_for_Claude_Code.md` | The original instructions given to Claude Code, kept as written |

---

## 4. The reports

**Shape reports: `~/scales_project/profiles/`**

| File | What it tells you |
|---|---|
| `<table>.columns.csv` | Every column: type, **% missing**, approximate number of distinct values, min and max (long text cut to 80 characters). Empty lists and blank text count as missing. |
| `<table>.sample_10000.csv` | 10,000 random rows (the same ones every time, seed 226). Open these in RStudio. |
| `keys_report.csv` | **Every field name that actually appears** in the case files, and how often. The SCALES schema documentation may be out of date, so this shows what's really there, including fields the scripts don't extract yet. |
| `parse_errors.csv` | Case files that couldn't be read. The real run had 0. |
| `cases.by_year_dir_and_type.csv` | Cases by year folder × case type (civil `cv`, criminal `cr`), with the share that have a termination date |
| `cases.by_filing_year.csv` | Year folder versus actual filing year. They can differ, because folders follow the year in the PACER case number. |
| `cases.by_court.csv` | Cases per court (civil, criminal, % in multidistrict litigation) |
| `cases.by_source.csv`, `cases.flags.csv` | Where cases came from, and possible junk: MDL members, cases opened in error, missing docket tables, empty dockets, missing filing dates |
| `cases.size_per_case.csv` | How many docket entries, parties and lawyers a typical case has (10th to 99th percentiles) |
| `parties.by_party_type.csv`, `parties.top_roles.csv` | Party categories and the most common role labels |
| `counsel.flags.csv` | How many lawyer listings are pro se, lead, pro hac vice |
| `fjc.link_summary.csv`, `fjc.link_by_court.csv`, `fjc.link_by_year.csv` | (step 05) How many SCALES civil cases found a matching FJC record, overall, by court and by year |
| `fjc.repaired_lines.csv`, `fjc.rejected_lines.csv` | (step 05) FJC lines that were repaired before reading (line number and reason only), and any that still couldn't be read, which should be none |
| `fjc.scales_courts_not_in_crosswalk.csv` | (step 05) SCALES courts with no FJC district code. The real run had none. |

**Year counts, answered:** SCALES lists 247,416 cases for 2016 and 319,718 for 2017. The archive has 346,196 and 329,960. Almost all of the ~110,000 extra cases are from 2016, and only 653 are numbered under other years. `cases.by_source.csv` may show whether the extras come from another source such as RECAP ([SCALES case lists](https://docs.scales-okn.org/rdf/#case-lists)). See `RUN_SUMMARY.md`.

**From the R scripts: `~/scales_project/`** (plus `parquet/case_features.parquet`, made by `01_build_features.R`)

| File | Made by | What it is |
|---|---|---|
| `checks/duplicates_summary.csv`, `checks/duplicates_all_groups.csv`, `checks/duplicates_shared_fjc_records.csv` | `02_data_checks.R` | Duplicate counts, every duplicate group (with which row was kept), and FJC records matched to more than one case |
| `fee_request_cases.csv` | `99_fee_search.R` (parked) | Every base-sample case with at least one fee request: the `"fee_requests"` population |
| `holdout_split_<population>.csv` + `_README.txt` + `.md5` | `03_holdout.R` | Which cases are in the holdout; how and when the split was made; and its fingerprint (checksum), which `00_sample.R` checks every session, stopping if the split file has changed |
| `checks/fjc_missing_*.csv` | `02-a_data_checks_fjc.R` | Training cases with no FJC record: counts, durations, status, docket size and wording, where they come from, and SCALES-vs-FJC end-date agreement |
| `checks/oddities_cases.csv` | `02-c_data_checks_oddities.R` | Case headers, SCALES next to FJC, for training cases with odd covariate values, with a flag column for each kind of oddity |
| `checks/prose_*.csv` | `02-d_data_checks_prose.R` | SCALES-vs-FJC cross-tabs of "no lawyer" for each side, agreement and kappa, and the largest groups among disagreements |
| `checks/judges_reassign_*.csv` | `02-b_data_checks_judges.R` | Judge reassignment in a 10,000-case training sample: first-assignment match, reassignment wording, cross-tab, by duration and court, and a spot-check file |
| `case_views/<ucid>.md` | `04_random_case.R` | Readable one-case pages |
| `feature_selection/fs_covariates.csv`, `fs_association_matrix.csv`, `fs_association_square.csv`, `fs_high_pairs.csv`, `fs_spearman_numeric.csv`, `fs_dv_association.csv` | `05_feature_selection.R` | Training cases only: each covariate's type, leakage tier, levels and missing share; every pair's association (long and square); the possibly redundant pairs; and each covariate's association with duration |
| `checks/open_cases_*.csv`, `checks/open_civil_cases_*.csv` | `02_data_checks.R` | Un-terminated cases, and what the FJC file says happened to them later |
| `checks/features_report_*.csv` | `01_build_features.R` | How many cases each covariate covers; judges, counties and firms that didn't match; every large-firm match, to check by hand |

---

## 5. How to run it, step by step

**Building the data (done once)**

1. **Download the case archive** from the SCALES file server to your Mac.
2. **Copy it and the scripts to FarmShare.** In a Mac Terminal window (not logged in to FarmShare), swapping in your real file name. You'll do the password and Duo steps for each copy.
   ```bash
   ssh joshr85@login.farmshare.stanford.edu "mkdir -p ~/scales_project/raw"
   scp ~/Downloads/YOUR_CASES_FILE.gz joshr85@login.farmshare.stanford.edu:~/scales_project/raw/
   scp -r "/path/to/scales_setup" joshr85@login.farmshare.stanford.edu:~
   ```
   `scp` handles 2 GB files more reliably than browser uploads.
3. **Log in** with `ssh joshr85@login.farmshare.stanford.edu`, then:
   ```bash
   cd scales_setup
   nano config.sh          # set CASES_ARCHIVE to your real file name
                           # (Ctrl+O then Return saves, Ctrl+X exits)
   bash 00_setup.sh        # quick; checks everything is in place
   bash 01_check_files.sh  # a few minutes; shows what's inside the files
   sbatch submit_farmshare.sbatch   # the long part, run as a background job
   squeue -u joshr85                # still running?
   ```
4. **When it finishes**, read the log with `cat scales_setup_<jobnumber>.out`, then look through `~/scales_project/profiles/`.
5. **Add the FJC data** (step 05). First the download, on the login node because it needs internet:
   ```bash
   bash 05_import_fjc.sh download
   ```
   Then convert and link it as a background job:
   ```bash
   sbatch --time=01:00:00 --cpus-per-task=4 --mem=16G --output=fjc_%j.out --wrap="bash 05_import_fjc.sh"
   ```

**Working in R (RStudio via https://ondemand.farmshare.stanford.edu, or `module load r` then `R` in a terminal)**

```r
source("~/scales_setup/r/01_build_features.R")   # once (and again if 00_sample.R says the features are out of date)
source("~/scales_setup/r/02_data_checks.R")      # all checks: settle every FLAG and OPEN line before the split

population <- "all"                              # the population for this project
source("~/scales_setup/r/03_holdout.R")          # make its holdout ONCE, then: chmod a-w ~/scales_project/holdout_split_*

source("~/scales_setup/r/04_random_case.R")      # look at one (training) case
source("~/scales_setup/r/02-a_data_checks_fjc.R") # training cases with no FJC record: linking gap or leakage?
source("~/scales_setup/r/02-b_data_checks_judges.R") # how often the judge was reassigned (judge leakage)
source("~/scales_setup/r/02-c_data_checks_oddities.R") # case headers for odd values (blank NOS, Local Question, ...)
source("~/scales_setup/r/02-d_data_checks_prose.R")  # do SCALES and FJC agree on who has no lawyer?
source("~/scales_setup/r/05_feature_selection.R") # how covariates relate to each other and to duration (training only)
```

**Parked for a future project: the attorney's-fee work.** `r/99_fee_search.R`, the `"fee_requests"` and `"fee_shifting"` populations and `r/fee_shifting_codes.csv` are kept, working, but aren't part of the current project. Nothing in the current workflow needs them.

For any new analysis script, start with `population <- "…"` and `source("~/scales_setup/r/00_sample.R")`, then work with the `train_cases` or `train_fjc` views. Settings like `population`, `case_seed` and `case_pool` stay set for the whole R session. Use `rm(case_pool)` and so on to clear them.

**Tips that came up along the way**
- **Your FarmShare login shell is `tcsh`, not `bash`.** Commands with `$` inside double quotes fail there ("Illegal variable name"). Type `bash` first, or use single quotes.
- **Copy commands without the prompt.** Don't include the `rice-02:~>` or `$` at the start of a line. On your Mac, a pasted `>` writes output to a file, which is how an empty file called `unzip` appeared in this folder.
- **Keep two Terminal windows open,** one logged in to FarmShare and one on your Mac (Cmd+N). `scp` runs from the Mac window.
- **Type passwords only into the Terminal,** where nothing shows as you type. Never paste them into a chat.
- **Dropbox "online-only" files can make `scp` and edits hang.** Keep this folder set to **Make available offline** in Finder.
- **To see what's on FarmShare:** `ls -lh ~/scales_setup ~/scales_setup/r ~/scales_project`

**To look at the tables directly** in DuckDB (`~/bin/duckdb`, then `.quit` to leave):

```sql
SELECT * FROM '/home/users/joshr85/scales_project/parquet/cases.parquet' LIMIT 10;
SELECT * FROM '/home/users/joshr85/scales_project/parquet/docket_entries.parquet'
WHERE ucid = 'azd;;2:16-cv-00001' ORDER BY entry_index;
```

---

## 6. Things to keep in mind for the analysis

- **Holdout.** Looking at structure (columns, missingness, coverage, how the tables link) is fine at any time. Once you choose a population and an outcome, set aside that population's 20% holdout with `03_holdout.R` **before** looking at how outcomes vary with anything. Each population has its own split, and the split can't be redrawn by accident. To keep it safe across sessions:
  - **Check the line each session.** `00_sample.R` prints `Holdout split loaded … N training, M holdout`, which should match the README, and it stops if the file's fingerprint has changed.
  - **Make the file read-only:** `chmod a-w ~/scales_project/holdout_split_*`.
  - **Keep a backup copy** in Dropbox. It holds only case IDs and TRUE/FALSE.
  - **Don't change the population's definition after splitting.**
- *(Parked fee work.)* **Fee-request cases are selected on part of the outcome.** Fee requests come mostly from parties who have already won, under fee-shifting statutes. That's fine for "what happens to fee requests?", but not for claims about civil cases generally. The `"fee_shifting"` population, defined by cause of action, avoids this.
- **Open cases are in the sample, but have no SCALES end date.** Since 15 October 2026 the sample includes cases that were still open when SCALES collected them (2016 cases mostly in early 2020, 2017 cases in mid-2021; [SCALES pipeline notes](https://docs.scales-okn.org/guide/pipeline/)). `case_closed` marks which is which. Open cases' dockets stop at collection, and their outcome is unknown in SCALES. The FJC file, which runs to mid-2026, often shows how and when they ended later; `02_data_checks.R` counts this. For duration, a case still open at collection is *censored*: you know it lasted *at least* that long. The duration variable handles this: it uses the FJC end date where there is one, and marks cases that were still pending, or ended after the cap, as overlong (see the note at the top). Cases with `duration_status = 'unknown_end'` have no value. Check how many with `duration_coverage` in `02_data_checks.R`.
- **Snapshots, not filing-day data.** Docket lines and party and lawyer lists are as of collection, not as of filing. Features meant to be "known at filing" need care.
- **FJC outcome codes.** Settlements are spread across `DISP` 12, 13 and 5. `JUDGMENT` and `NOJ` only apply to the ~18.5% of cases that ended in a judgment. A judgment awarding money *and* an injunction is `NOJ` 2, not 3. `AMTREC` (amount received) is unreliable, and the FJC advises against using it. The FJC records no settlement amounts and no fee requests. `-8` usually means missing, but in `IFP` it means "not in forma pauperis".
- **Missing values are labelled, not left blank.** Covariates use explicit categories such as "no FJC record" (about 1.7% of cases have no FJC match), "no judge listed", "no plaintiff listed", "no defendant listed" and "county not recorded", so no case is silently dropped by a model. The FJC fields `ORIGIN`, `CLASSACT`, `IFP` and `PROSE` also have labelled versions (`arrival_route`, `class_action_alleged`, `in_forma_pauperis`, `pro_se`), where `-8` is read as the codebook says (e.g. "no class action alleged", "not IFP"). Use these rather than the raw codes.
- **One cause and one nature of suit per case,** taken from the civil cover sheet. The number of counts or claims isn't recorded anywhere.
- **MDL and consolidated member cases** have little activity on their own docket, because it happens on the lead or master docket. Keep that in mind for anything based on docket entries.

---

## 7. Leakage warnings: read before choosing covariates

**Leakage** means using information that wouldn't be known when you'd make the prediction. Here that's **at filing**, since the dependent variable is duration from filing. A leaky covariate can predict duration well *because it was caused by how the case unfolded*, which makes a model look better than it really is. `covariates.xlsx` marks each variable's "Known at filing?" status. This section collects every warning in one place.

### A. Never use as covariates: they are the outcome, or recorded after it

| Variables | Why |
|---|---|
| `duration_*`, `is_overlong`, `start_date`, `end_date`, `end_date_source`, `terminating_date`, `fjc_termdate` | The dependent variable and its parts |
| `DISP`, `NOJ`, `JUDGMENT`, `PROCPROG`, `TRCLACT`, `AMTREC` | How the case ended (FJC) |
| `case_status`, `case_closed`, `STATUSCD`, `TAPEYEAR`, `n_fjc_matches` | Status at collection or termination, and reopenings |
| `n_docket_entries`, `n_docket_reports`, `billable_pages`, `cost`, `summary_date_of_last_filing`, `case_flags_json`, `appeals_case_ids_json` | Grow with the length of the case, or record later events |

### B. Kept by Josh's choice, knowing they leak: report them, and compare models with and without them

| Covariate | What leaks |
|---|---|
| `senior_judge_at_filing` = **"unassigned"** | A case still has no judge at collection mostly because it **ended before a judge was assigned**. It strongly signals a short case. |
| `senior_judge_at_filing` = **"appointed after filing"** | The judge at collection was appointed after filing, so the case was **reassigned** during its life. Long cases are more likely to be reassigned. |
| `judge_group` | Built from the judge **at collection**, not at filing. It carries the same reassignment issue. |
| `n_counsel` | Lawyers are added during the case; long, contested cases gain more |
| `any_referral` | Referral to a magistrate usually happens after filing |
| `is_consolidated`, `consolidation_role` | Consolidation happens after filing. These are built from SCALES `lead_case_id` only. **`is_multi` is not used**: it flags any docket that refers to another case number, including removal and transfer origins. |
| `amicus` | Amicus filings come during the case, and longer cases have more time to attract them |
| `defendant_firm_rank` = **"no counsel listed"** (about a third of cases) | A defendant with no lawyer at collection usually **never appeared**: it defaulted, or the case was dismissed or settled before an answer. So the category partly reflects how the case went. |

#### Decision (Josh, 25 Oct 2026): one plaintiff representation variable

**`plaintiff_firm_cases` is the single variable for plaintiff representation in the main model.** Its categories are:
- pro se / no counsel
- lawyer, no firm listed
- firm in 1–10, 11–20, 21–50 or over 50 cases
- no plaintiff listed

**No separate plaintiff pro se flag is added.** `02-d_data_checks_prose.R` found that SCALES's "pro se / no counsel" (first plaintiff, at collection) and FJC `PROSE` (plaintiff or both) agree on 98.7% of training cases, with kappa 0.93, after the prisoner exclusion. So a second variable would measure the same thing twice and split its effect between two coefficients.

**How to read it:** the pro se category is the plaintiff pro se effect. The firm categories compare represented plaintiffs by their firm's experience.

**What happens to `pro_se` (FJC):** it no longer supplies the plaintiff pro se measure. Its defendant part ("defendant", "both") is undecided. The defendant side (`defendant_firm_rank`, and FJC defendant pro se) is still open: SCALES's "no counsel listed" mostly means the defendant never appeared, so 89% of those defendants aren't pro se in the FJC, and kappa is 0.14.

#### Decision (Josh, 24 Oct 2026): court in the main model; judge variables only in a sensitivity model

**The main model uses `court`, and not the judge variables.** Three covariates go only in a separate **sensitivity model**: `judge_group`, `senior_judge_at_filing`, and the magistrate-judge referral `any_referral`. The sensitivity model is court plus these three.

**Why: the judge is recorded at collection, and reassignment rises with case length.**
- **The check.** `r/02-b_data_checks_judges.R` (version 2, change 44) looked at a random sample of 10,000 training cases.
  - About **16%** have docket wording showing a change of district judge: "reassigned to Judge …", "Judge X no longer assigned", recusal, or "transferred to Judge …". Magistrate-only changes aren't counted.
  - That share rises from **10%** of cases ending within 90 days to **36%** of cases lasting over 3 years.
  - Where the docket records the first assignment, the SCALES judge is a different judge in **25%** of cases.
- **Neither rule is accurate enough to fix the variable case by case.** Both still have false positives on the spot-check; where they agree, the result is accurate but misses many cases. So the judge field can't be cleaned. Instead it's kept out of the main model.
- **Senior status comes from the same field.** `senior_judge_at_filing` is built from the same SCALES judge, so it has the same problem.
- **The magistrate referral is leaky in its own way.** `any_referral` usually happens after filing. Its association with `judge_group` is 0.84: referral habits vary by judge and district.

**Why `court` is safe.** The court is fixed when the case is filed. A transfer to another district ends the case here (it's censored), so the court can't change with how the case goes.

**What this costs:**
- **Some accuracy.** Real differences between judges in the same court are lost, and the court effect is an average over each court's judges, caseload and local rules.
- **Interpretation.** Don't describe the court effect as "court culture" alone, and the main model can't answer questions about judges.
- **How big the loss is:** the sensitivity model shows it. Report its gain in accuracy as an **upper bound**, since part of that gain is leakage.

**Why not drop reassigned cases instead?** Dobbie & Song (2015) keep the judge and drop cases whose original judge isn't documented. The judge is their research design (random assignment as a natural experiment). Their dropped cases were reassigned because a judge **retired**, which has nothing to do with how individual cases were going. Here, reassignment rises with duration, so dropping reassigned or unconfirmed cases would remove long cases disproportionately and **select the sample on the outcome**. Instead, this project keeps the cases and drops the variable. Ganglmair, Helmers & Love (2024) take the same view as Dobbie & Song: when the judge matters, you need the **initially** assigned judge. They get it from Docket Navigator, which isn't available here.

**For the write-up:**
- Judge identity is recorded at collection.
- An estimated 16% of cases (about ±1 point, from a 10,000-case training sample with a noisy rule) had a district-judge change, more often in longer cases.
- The main model therefore uses court. Judge, senior status and magistrate referral appear only in a sensitivity model.
- Report how much the sensitivity model adds.

**References:**
- Dobbie, W. & Song, J. (2015). "Debt Relief and Debtor Outcomes: Measuring the Effects of Consumer Bankruptcy Protection." *American Economic Review* 105(3): 1272–1311. <https://doi.org/10.1257/aer.20130612>
- Ganglmair, B., Helmers, C. & Love, B.J. (2024). "Do Judicial Assignments Matter? Evidence from Random Case Allocation." CRC TR 224 Discussion Paper 561. <https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4726217>
- Schwartz, D.L., Albrecht, K.M., Pah, A.R., et al. (2024). "The SCALES Project: Making Federal Court Records Free." *Northwestern University Law Review* 119: 23. <https://scholarlycommons.law.northwestern.edu/nulr/vol119/iss1/3/>. Describes how SCALES identifies judges; the field doesn't separate the initial judge from the final one.
- Kaufman, S., Rosset, S., Perlich, C. & Stitelman, O. (2012). "Leakage in Data Mining: Formulation, Detection, and Avoidance." *ACM Transactions on Knowledge Discovery from Data* 6(4). <https://doi.org/10.1145/2382577.2382579>. A feature is legitimate only if it's available at the time of prediction, here filing.
- Montgomery, J.M., Nyhan, B. & Torres, M. (2018). "How Conditioning on Posttreatment Variables Can Ruin Your Experiment and What to Do about It." *American Journal of Political Science* 62(3): 760–775. <https://doi.org/10.1111/ajps.12357>
- Fong, C. & Tyler, M. (2021). "Machine Learning Predictions as Regression Covariates." *Political Analysis* 29(4): 467–484. <https://doi.org/10.1017/pan.2020.38>. Text-derived covariates need a hand-labelled validation sample; this is why the reassignment flags aren't used as covariates.

### C. Mostly known at filing, but recorded later: use with care, and say so

| Covariate | Caution |
|---|---|
| `n_parties`, `n_plaintiffs`, `n_defendants`, `first_plaintiff_type`, `first_defendant_type` | Party lists are as of collection; parties added later are included. First-listed parties are the safest. |
| `plaintiff_firm_cases`, `defendant_firm_rank`, `plaintiff_org_attorney` | The lead attorney and emails are as of collection, so counsel may have changed. Firm case counts use all 2016–17 cases (no outcome information involved). |
| `PROSE`, `IFP` | Recorded on the FJC termination record; a party can gain or lose counsel |
| `mdl_any` (and `is_mdl`) | `mdl_any` = SCALES `is_mdl` OR FJC `ORIGIN` 6/13, since neither source is complete. Many cases are transferred into an MDL after filing. |
| `jury_demand` | A defendant's jury demand usually comes with the answer, after filing |
| `has_related_case` | Some related cases are listed at filing, others added later |
| `tro_pi_motion_60d` | Uses a fixed 60-day window, so it can't grow with duration. But a case that ended within 60 days had less time to file such a motion. |
| `filing_month`, `filing_weekday`, `year_dir`, `filing_date` | Known at filing, but they also pick up **when SCALES collected the case** and **COVID-19** timing (2016 and 2017 cases hit 2020 at different ages) |

### D. Leakage from how the data and split are set up

- **Related cases split across training and holdout.** Cases that move together would make the holdout look better than it is. Handled: MDL members are **excluded** from the sample, and `03_holdout.R` draws the split **by consolidation group**, so a lead case and its members can't be split up. Related cases with no lead-case link (e.g. serial suits by one plaintiff) can still fall on both sides.
- **Training-only summaries.** `judge_group` and `cause_group` use counts from **training cases only** once the holdout exists. Any judge-level or court-level average you build yourself, such as a judge's typical duration, must also use training cases only, and leave out each case's own value.
- **Choosing covariates or settings by looking at the holdout** is leakage too. Decide them on the training data.
- **Selecting the sample on the outcome.** Two exclusions use how the case ended: **overlong cases** (748, lasting or pending beyond 3,103 days) and **MDL transfer-outs** (FJC `DISP` 10). The first truncates the dependent variable, so results describe cases resolved within about 8.5 years. The second is part of the MDL exclusion. Both are applied before the split, so training and holdout are treated alike. A third, **no FJC record** (about 1.9%, mostly cases closed within days), was applied **after** the split, by the same rule on both sides. It was chosen from training data only, and must not be revised by looking at the holdout.

---

## 8. What was tested, and what wasn't

**Building the data.** Tested first in a sandbox on a small fake archive built to match the documented SCALES format. It then ran on the real archive on FarmShare: all 676,809 cases were read with 0 errors (see `RUN_SUMMARY.md`). Step 05 ran on the real FJC file (98.3% of civil cases matched). The repair step for malformed FJC lines (`fix_fjc_text.py`) was added after that run, and was tested on fake lines modelled on the real problems.

**The R scripts.** Each was tested on a Mac in R with DuckDB, on small fake data using the real column names, before being handed over. The former `01_data_checks.R` (now part of `02_data_checks.R`) has also run on FarmShare. See `CHANGES.md` for exactly what each test covered.
