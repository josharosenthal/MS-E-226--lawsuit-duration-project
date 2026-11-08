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
> **Sample sizes** (population "all"; holdout = 20% of consolidation groups, seed 226, `r/03_holdout.R`):
>
> | | Total | Training | Holdout |
> |---|---|---|---|
> | When the split was made (24 Oct 2026; `holdout_split_all_README.txt`) | 398,403 | 318,709 | 79,694 (20.0%) |
> | Now, after the exclusions above and the missing-data drops (change 76) | 333,027 | 266,444 | 66,583 (20.0%) |
>
> The later exclusions applied the same rules to both sides; the split wasn't redrawn. Of the current training cases, the log-duration models use the 258,847 that ended in court and the 60-day models 264,161 (2,283 transferred out before day 60 dropped). The holdout count is as printed by `00_sample.R` ("Holdout split loaded"); it's a count only, and no holdout case has been looked at.
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
| `r/00_sample.R` | The one place the analysis sample is defined: 2016–17 civil cases (by case-number year), open or closed (`case_closed` says which), minus habeas (§ 2241, 2254, 2255) and 42:1983pr, duplicates removed, joined to the FJC data. Every other R file starts by loading it. Set `population` first: `"all"` (default), `"fee_requests"` or `"fee_shifting"`. It also fills a missing first plaintiff from the case name or FJC plaintiff name, and drops cases with jury demand blank or no plaintiff anywhere (change 76; the list is in `population_drops`). | Only to change the sample |
| `r/01_build_features.R` | **Run once** (and again if the data change): builds the covariates you chose in `covariates.xlsx` and saves them to `~/scales_project/parquet/case_features.parquet`, which `00_sample.R` then joins automatically. Includes case-number parity, referral, related case, consolidation, circuit, diversity residence, county urban/suburban/rural, senior judge at filing, party counts and types, plaintiff-firm experience, defendant-firm size rank, `.org` plaintiff attorney, TRO/PI motion within 60 days and amicus. It also writes `checks/features_report_*.csv` (coverage, judge, county and firm match checks). Takes several minutes. | No |
| `r/02_data_checks.R` | **Run before making the split**, and again whenever the data or covariates change. **Part 1**, a PASS / FLAG / INFO / OPEN summary: sample size; duplicates; whether the covariates are built and current, and how well judges, counties and firms matched; duration coverage; related cases (MDL, consolidated); removed and transferred cases (FJC `ORIGIN`) compared with `is_multi` and `is_mdl`; cases that ended by transfer or remand (counts only); decisions still open; software versions. **Part 2**, detailed tables: duplicates, missing values, SCALES-vs-FJC consistency, class-action codes, duration coverage. **Part 3**, open cases across all of `cases.parquet`, and what the FJC says happened to them later. Structure only: no outcome comparisons. Merged from the former `01_data_checks.R`, `02_data_checks.R` and `07_presplit_checks.R`. | No |
| `r/02-a_data_checks_fjc.R` | **Training cases only.** The cases with no FJC record (no match, or an FJC record shared by two cases). For them it reports: how many; their durations against linked cases; SCALES status and docket size; how often their dockets mention "opened in error", duplicate or re-filed, transfer, remand, consolidation, voluntary dismissal or sealing (against a same-size random sample of linked cases); which years, courts and natures of suit they come from; and how closely SCALES and FJC end dates agree for linked cases. It checks whether a missing FJC record is a linking gap or reflects how the case ended (leakage). Counts only. Writes `checks/fjc_missing_*.csv`. | No |
| `r/02-b_data_checks_judges.R` | **Training cases only.** How often the judge was **reassigned**, on a fixed random sample of 10,000 training cases (`n_sample`). (1) It finds the first "assigned to" entry on the docket, skipping magistrate referrals, and checks whether the SCALES judge, recorded at collection, is the same judge. (2) It searches the docket for "reassign", "no longer assigned", "recus" or "transferred to Judge". Tables: both measures, their cross-tab, by duration band and by court. Writes `checks/judges_reassign_*.csv`, including a 200-case spot-check file for checking the name matching by hand. | `n_sample` |
| `r/02-c_data_checks_oddities.R` | **Training cases only.** The case header for every training case with an odd value: blank nature of suit, blank jurisdiction, "Local Question", a cause title cited by only one case, unmatched county code, or a defendant whose name isn't recorded. It shows the SCALES header next to what the FJC record says (NOS, JURIS, county, cause). The console shows counts and a table without names; the full headers, with case names, go to `checks/oddities_cases.csv`. | No |
| `r/02-d_data_checks_prose.R` | **Training cases only.** Do SCALES and the FJC agree on who has no lawyer? It cross-tabulates SCALES "pro se / no counsel" (first plaintiff) and "no counsel listed" (first defendant) against FJC `PROSE`, for each side. It reports the share of each source's "no lawyer" confirmed by the other, the agreement and Cohen's kappa, and the largest natures of suit and courts among disagreements. Counts only. Writes `checks/prose_*.csv`. | No |
| `r/02-e_data_checks_nocause.R` | **Training cases only.** The cases with no cause of action (`cause_group` "(no cause)"), compared with all training cases. It covers whether they have a jurisdiction and a nature of suit (and which), their courts, pro se status (FJC and SCALES), whether the FJC has a cause title that could fill the gap, and, to tell an ordinary case with a missing field from an odd record, their duration, docket size, arrival route, filing year, party types, fee waivers, class actions and the SCALES stub flags. Counts only. Writes `checks/nocause_*.csv`. | No |
| `r/02-f_data_checks_endings.R` | Cases that left this court without being resolved here, by FJC `DISP`: transferred to another district (0), remanded to state court (1) or a U.S. agency (11), award of arbitrator (15), stayed pending bankruptcy (16), statistical closing (18), and groups of these. For each, the training vs holdout share with the z-test from `02_data_checks.R`, to check balance before deciding whether to drop them. Counts only. Also, training only: how often the docket mentions sending the case to arbitration, by `DISP`. Writes `checks/endings_*.csv`. | No |
| `r/02-g_data_checks_counsel.R` | **Training cases only.** Where `n_counsel`'s leakage comes from. For each side and duration band: distinct lawyers at collection vs those named in the docket within 7 days of filing (added after filing = the difference), terminated listings, pro hac vice listings, listings for dismissed parties, and pro se plus lawyer. Also withdrawal and substitution docket entries, `n_counsel` split into its parts, Spearman correlation of each count with duration, and how often lawyers are named in the docket at all. Counts only, no names. Writes `checks/counsel_*.csv`. Batch job. | Filing window (7 days) at the top |
| `r/02-h_data_checks_missing.R` | **Training cases only.** Spot check of two undecided missing-type categories: `first_plaintiff_type` "no plaintiff listed" and `jury_demand` "(NA)". Each is compared with the rest: courts, natures of suit, years, pro se, IFP, parties and how the case ended. Also shown: the party roles of no-plaintiff cases, the FJC `JURY` field for jury (NA) cases, and the type of each case's first docket entry. Plus 25 random case IDs per group to look up. No names. Writes `checks/missing_*.csv`. | No |
| `r/02-i_check_cause_exclusion.R` | Before cutting a cause of action from the population: how many training and holdout cases it would remove, with the balance z-test. Set up for 33:2701 (Oil Pollution Act, the Deepwater Horizon cases), compared with other ways of drawing the same group. Covariates only. Writes `checks/cause_exclusion_*.csv`. | The cause at the top |
| `r/02-j_data_checks_plaintiff_fill.R` | **Training cases only; a diagnostic.** For "no plaintiff listed" cases, leaving out the jury demand "(NA)" batch: how many get a plaintiff from the FJC plaintiff name, then from the case name, and how many are still missing. Also how well each source agrees with SCALES (by entity type), and the unmapped party roles and natures of suit of the cases still missing. No names. Writes `checks/plaintiff_fill_*.csv`. | No |
| `r/02-k_check_fold_stability.R` | **Training cases only.** Do 07-c, 07-d and 07-e get the same cross-validation folds every time? Reads the training data 4 times in fresh DuckDB connections, with different thread counts, and compares row order and folds. Writes `checks/fold_stability.csv` and prints PASS/FLAG. Batch job. | Settings at the top (thread counts) |
| `r/03_holdout.R` | Sets aside 20% of the chosen population's **consolidation groups** as its holdout (a lead case and its members stay together; other cases are their own group), **once**, and saves it to `~/scales_project/holdout_split_<population>.csv`, with a README and a fingerprint (`.md5`) | No |
| `r/04_random_case.R` | One case, at random or one you name, as a readable markdown page in `~/scales_project/case_views/`, with the FJC codes translated into words and the docket listed. It draws from training cases only once the holdout exists. `case_pool <- "1983pr"`, `"habeas"` or `"mdl"` shows an excluded case instead. | No |
| `r/05_feature_selection.R` | **Training cases only.** How the chosen covariates relate to each other and to duration, to help decide which to keep. It uses the measure that fits each pair, since `cor()` works only for numbers: Spearman for counts, Cramér's V (bias-corrected) for two categorical variables, and eta (correlation ratio) for a count with a categorical variable. All run from 0 to 1. Each pair uses only cases where both variables are recorded: missing-value labels are left out, since a shared "no FJC record" label would otherwise look like association. Lists pairs at or above 0.7 as possibly redundant, flags constant variables, and gives each covariate's association with duration for cases that ended in court: on the rank of duration and on log(1 + duration), each for all cases and for cases where the covariate is recorded. A big drop on recorded cases means the "missing" category is doing the work. Writes `feature_selection/fs_*.csv`. The covariate list and leakage tier are at the top of the file. **Annotated walk-through: `FEATURE_SELECTION_GUIDE.md`.** | Covariate list, `assoc_threshold` |
| `r/06_plots_and_correlations.R` | **Training cases only.** Plots, saved as PNGs in `~/scales_project/plots/`: first, a general histogram of all case durations (ended and transferred-out cases stacked, 30-day bins); then duration histograms (days and log days); Kaplan–Meier curves, overall and by jurisdiction, arrival route, plaintiff representation and class action, with transferred-out cases censored; box plots of log duration by category for every main and sensitivity categorical; median log duration by each count covariate; a heatmap of covariate associations; and each covariate's association with duration. The last two come from `05_feature_selection.R`'s tables, so run 05 first. Base R plus the survival package. | Covariate lists at the top |
| `r/06-a_judge_duration_plot.R` | **Training cases only.** Box-and-whisker plot of days to ending for the 25 judges with the most training cases (cases that ended in court), ordered by median: left, days (log scale); right, relative to the judge's own court median, so court and judge are separated. Not adjusted for case mix. Rows labelled "court J1 (n)" with (M) magistrate / (S) senior; `show_names <- TRUE` labels by judge name. Writes `plots/judge_duration_top<N>.png` and `.csv`. Quick (change 103). | `n_judges`, `show_names` |
| `r/06-b_circuit_duration.R` | **Training cases only.** Duration by circuit for cases that ended in court: cases, mean, median and geometric mean days, standard deviation, and the share ending within 60 days. Not adjusted for case mix. Writes `plots/circuit_duration.csv`. Quick (change 104). | No |
| `r/07-a_random_forest.R` | **Training cases only.** Random forests (`ranger` package) for the **main**, **main_plus_counsel** and **sensitivity** covariate sets (defined in `r/covariate_sets.R`). Two kinds (`rf_outcome`): `"log_duration"`, a regression on log(1 + days) for cases that ended in court, or `"survival"`, a random survival forest with transferred-out cases censored. Judged by out-of-bag error (OOB R², RMSE and median absolute error in days, or the OOB C-index), with permutation variable importance; the holdout isn't used. The gap between the two sets is an upper bound on what the leaky variables add. Writes `~/scales_project/models/rf_*`. Needs `install.packages("ranger")` once; run as a batch job with 8 CPUs and 32 GB. | Settings at the top (outcome, trees, sample size) |
| `r/07-b_short_case_forest.R` | **Training cases only.** Classification (probability) random forests for two yes/no outcomes: **ended within 60 days?** and **ended within 120 days?**, for the same three covariate sets as 07-a. A case transferred out after the cutoff counts as "no"; one transferred out before it is dropped for that cutoff. Out-of-bag AUC, Brier score and Brier skill, with permutation importance; the holdout isn't used. Writes `~/scales_project/models/short_*`. Run as a batch job with 8 CPUs and 32 GB. | Settings at the top (cutoffs, trees) |
| `r/07-c_xgboost.R` | **Training cases only.** Gradient-boosted trees (`xgboost` package) for the same outcomes as 07-a and 07-b: log(1 + days) for cases that ended in court, and ended within 60 / 120 days (yes/no). Uses the same three covariate sets. Boosting has no out-of-bag error, so it's judged by 5-fold cross-validation within training (R², RMSE and median absolute error, or AUC, Brier score and Brier skill). The number of trees is set by early stopping on a further 10% of each fold's training part. Importance is gain, added up over each variable's categories. The holdout isn't used. Writes `~/scales_project/models/xgb_*`. **Change 97:** two more sets, `reg_run1` and `reg_run2`, with exactly the 08 regressions' variables from `model_spec.csv`; each case's cross-validated prediction saved in `models/xgb_cv/` for 08-y. Outcomes and sets can be picked on the command line: `Rscript 07-c_xgboost.R log_duration,short_60 reg_run1,reg_run2`. **Change 99:** set `reg_run3` (run 3, without `n_counsel`); SHAP values for a sample of 20,000 cases from the all-cases model, saved per case in `models/xgb_shap/` with the model itself, plus `xgb_<outcome>_<set>_shap_summary.csv` (mean \|SHAP\| by variable), `_shap_location.csv` (court and judge effects split into between circuits, between courts in a circuit, between judges in a court, and within) and `_shap_by_court.csv`. Needs `install.packages("xgboost")` once; run as a batch job with 8 CPUs and 32 GB. | Settings at the top (outcomes, folds, learning rate, depth) |
| `r/07-d_interactions.R` | **Training cases only.** Do interactions between covariates matter? **Step 1, the depth check:** XGBoost refitted with trees of depth 1 (additive: no interactions), 2 (two-way) and 6 (as 07-c), on the same folds, for log duration and ended within 60 / 120 days, main set. The gaps, with fold-to-fold standard errors, show what interactions are worth. Steps 2–4 (which pairs, what they look like, whether they help the regression) are to be added only if step 1 shows they matter. Writes `models/interactions_*`. Batch job. | Settings at the top (outcomes, sets, depths) |
| `r/07-e_interaction_pairs.R` | **Training cases only.** Interaction steps 2–4, main set. **Step 2:** which pairs interact (SHAP interaction values from a depth-2 XGBoost model). **Step 3:** what the top pairs look like, level by level. **Step 4:** whether adding them to a cross-validated OLS helps. Log duration and ended within 60 days by default. Writes `models/interactions_2_*`, `_3_*`, `_4_*`, one set per outcome, as each finishes. Batch job, about 2–4 hours per outcome; an outcome can be named after the script to run it as its own job. | Settings at the top (outcomes, number of pairs, lumping, `n_shap`) |
| `r/covariate_sets.R` | The covariate sets (`main`, `main_plus_counsel`, `sensitivity`) shared by 06, 07-a, 07-b and 07-c, so they can't drift apart. Sourced by those scripts, not run on its own. | Edit to move a variable between sets |
| `r/xgb_helpers.R` | Shared XGBoost pieces for 07-c, 07-d and 07-e: reading the training data, the folds, the one-hot design matrix, and fitting with early stopping. **Folds** come from a hash of each case's consolidation group, so they're the same in every script and run, and a lead case and its members share a fold (change 84). Sourced by those scripts, not run on its own. | No |
| `r/07-f_forest_cv.R` | **Training cases only.** The random forests of 07-a / 07-b (log duration; ended within 60 days) on the 08 regressions' variables (`reg_run1`, `reg_run2`, `reg_run3` from `model_spec.csv`), judged on the same 5 folds as XGBoost and the 08 models instead of out-of-bag, so they can go into 08-y. Also reports the out-of-bag score on the same cases, to show how much it differs. Saves each case's cross-validated prediction in `models/forest_cv/`, and permutation importance from the all-cases forest in `rf_<outcome>_<set>_importance.csv` (change 99). Batch job, 8 CPUs, 48 GB. | Settings at the top (trees, leaf size) |
| `r/08-a_ols.R` … `r/08-g_logistic_lasso.R` | **Training cases only.** The regression models from `model_spec.xlsx`: OLS (08-a), ridge (08-b) and group lasso (08-c) of log duration; quantile regression at the median (08-d1) and 90th percentile (08-d2); plain (08-e), ridge (08-f) and lasso (08-g) logistic regression of ended within 60 days. Each job is one model, one run (1 = without the sensitivity variables, 2 = with them, 3 = run 2 without `n_counsel`, change 99; 4 = run 3 with the post-filing judge labels pooled, change 100) and one fold (1–5, or `full` for the coefficients): `Rscript 08-a_ols.R 1 3`. Writes `models/reg/`. Batch jobs. | The specification (`model_spec.xlsx` → `model_spec.csv`) |
| `r/08-0_install_packages.R` | Installs glmnet, doParallel, grpreg and quantreg into your own R library. Run once on the login node. | No |
| `r/07-g_decision_tree.R` | **Training cases only.** Run as an illustration (a single tree whose splits can be read, next to the forest and XGBoost), not as a candidate for the final model. A single decision tree (CART, rpart; comes with R) for log duration and for ended within 60 days (a regression tree on 0/1, so leaves give the share of short cases), on the run 1 and run 4 variables (`reg_run1`, `reg_run4`), scored on the same 5 folds as the other models. In each outer fold the tree is grown large and pruned back at the complexity (cp) with the smallest error on the inner folds (seed 227, as the 08 penalty tuning). Saves cross-validated predictions in `models/tree_cv/` (read by `08-y_compare_models.R tree`), the all-cases tree, its variable importance (`tree_<outcome>_<set>_importance.csv`), and a picture of its first 3 levels (`plots/tree_<outcome>_<set>_top.png`; judge splits shown as "k of n levels", no names). Change 106. Batch job, 1 CPU, 16 GB. Needs rpart, which FarmShare's R module lacks: install once on the login node with `Rscript -e 'install.packages("rpart", lib = Sys.getenv("R_LIBS_USER"), repos = "https://cloud.r-project.org")'`. | Settings at the top (smallest cp, leaf size, plot depth) |
| `r/09-a_holdout_xgboost.R` | **READS THE HOLDOUT (Project Part 2).** Applies the final XGBoost models (run 4 variables; log duration and ended within 60 days) to the holdout cases: the same `00_sample.R` coding (judge, cause and cause-fill rules fitted on training cases), the same reader (`xgb_training_data(..., from = "holdout_fjc")`), `recode_run4()`, one-hot columns for the training categories only (unseen categories coded as zeros and counted), and the model 07-c saved (`xgb_shap/xgb_<outcome>_reg_run4_full.json`), not refitted. Checks first that the reloaded model reproduces 07-c's predictions on training cases. Scores as 08-y against the training mean or share, next to the cross-validated score, with 95% bootstrap intervals over consolidation groups. Needs the word `use_holdout`; every run is logged in `models/holdout/holdout_use_log.csv`. Change 108. | Settings at the top (outcomes, bootstrap) |
| `r/08-x_error_by_duration.R` | **Training cases only.** For curiosity (change 107): where log duration's squared error comes from, by the case's actual duration (0–29, 30–179, 180–364, 365–729, 730+ days). For the baseline, XGBoost, and the forest and tree when their files exist, runs 1 and 4: each band's share of cases, RMSE and share of the squared error on the log scale and in days, and mean predicted minus actual days. Reads the saved cross-validated predictions; writes `models/reg/error_by_duration.csv`. Quick. | Settings at the top (runs, bands) |
| `r/08-y_compare_models.R` | **Training cases only.** The 08 regressions and XGBoost side by side on the same cases, folds and variables: OLS, ridge, group lasso, quantile median, XGBoost and the 07-f forest for log duration; plain, ridge and lasso logistic, XGBoost and the forest for ended within 60 days (with `tree` as an argument, also the 07-g decision tree, written to `compare_scores_with_tree.csv` and `compare_pairs_with_tree.csv` instead; change 106); each run separately (runs 1–4; runs 3 and 4 have OLS, the quantile median, plain logistic, XGBoost and the forest; changes 99–100). A "baseline" row (each fold's training mean or share; change 101). Every model on every metric (each should win its own loss), and paired differences with standard errors from the 5 per-fold differences. Needs all 5 folds of the 08 models and 07-c's / 07-f's `reg_run<r>` predictions; a model that's missing is listed as not included. Writes `models/reg/compare_scores.csv` and `compare_pairs.csv`. Quick. | No |
| `r/08-z_regression_summary.R` | Scores the 08 models from their saved fold predictions once all 5 folds are in: R², errors in days, pinball loss, coverage, AUC, Brier skill and more, with fold-to-fold standard errors; baselines from each fold's training part. FLAGs plain logistic folds that didn't converge and penalties at the end of their path, and won't score a model whose folds came from different versions of `model_spec.csv` (change 93). Runs 1–4 (changes 99–100). Quick. | No |
| `r/submit_regressions.sh` | Submits every 08 job (or the models named after it), one per model × run × fold, each with a 2-day limit: `bash ~/scales_setup/r/submit_regressions.sh`. Runs 1 and 2 by default; run 3 with `env RUNS="3" bash ~/scales_setup/r/submit_regressions.sh ols quantile_50 quantile_90 logistic` (change 99). | Memory per model |
| `r/reg_helpers.R`, `r/model_spec.csv` | Shared code for the 08 scripts (design matrices, fits, one job), and the specification exported from `model_spec.xlsx` (regenerate it when the sheet changes). | No |
| `r/run_overnight.sh` | Batch script that runs 05, 06, 07-a, 07-b and 07-c in order as one job (12 hours, 8 CPUs, 32 GB). If one script fails, the next still runs. Submit with `sbatch ~/scales_setup/r/run_overnight.sh`; log in `~/overnight_<job>.out`. | The list of scripts |
| `DATA_DICTIONARY.md` | The 37 candidate covariates: meaning, source, type, number of levels, smallest level and % missing (training), leakage tier, and main or sensitivity model; the values of the covariates with few categories, with a rough mix; and the rare categories worth merging. | As decisions change |
| `r/90_transfer_matching.R` | Whether training cases transferred out can be matched to the case they became in the receiving district: through the receiving docket naming the origin case number, the origin docket naming the new number, or (as a measure of ambiguity) FJC transferred-in records with the same nature of suit filed soon after. Holdout cases are never used as receiving cases, so the counts are lower bounds. Counts only, plus case IDs of up to 50 matched pairs to check by hand. Writes `checks/transfers_*.csv`. Batch job. | No |
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
| `plots/*.png` | `06_plots_and_correlations.R` | Duration histograms, Kaplan–Meier curves, box plots by category, count plots, association heatmap, association with duration |
| `models/rf_*` | `07-a_random_forest.R` | Random forest OOB performance (`_summary.csv`), permutation importance (`_importance.csv`, `.png`), and fitted forests if `save_models = TRUE` |
| `models/short_*` | `07-b_short_case_forest.R` | Short-case classification forests: OOB AUC, Brier score and Brier skill by cutoff and set (`short_summary.csv`), permutation importance (`short_<cutoff>d_<set>_importance.csv`, `short_<cutoff>d_importance.png`), and the 120-day AUC split by duration band (`short_120d_by_band.csv`: 0–60 vs over 120, 61–120 vs over 120, 0–60 vs 61–120) |
| `models/xgb_*` | `07-c_xgboost.R` | XGBoost cross-validated performance by outcome and set (`xgb_summary.csv`), gain importance (`xgb_<outcome>_<set>_importance.csv`, `xgb_<outcome>_importance.png`) |
| `models/interactions_1_*` | `07-d_interactions.R` | Depth check: cross-validated performance by tree depth (`interactions_1_depth_check.csv`) and the gaps between depths, with standard errors (`interactions_1_depth_gaps.csv`) |
| `models/interactions_2_*`, `_3_*`, `_4_*` | `07-e_interaction_pairs.R` | One set per outcome (file names end in `_log_duration` or `_short_60`): pairs ranked by strength, with a summary and bar chart (2); level-by-level grids and heat maps for the top pairs (3); the cross-validated OLS with and without them (4) |
| `models/reg/*` | the 08 scripts | Per job: `<model>_run<r>_fold<f>.rds` (predictions, or the full fit's details) and `_foldfull_coefficients.csv`; from 08-z: `reg_summary.csv`, `reg_per_fold.csv`, `reg_calibration.csv`; from 08-y: `compare_scores.csv`, `compare_pairs.csv` |
| `models/forest_cv/*`, `models/forest_cv_summary_*.csv` | `07-f_forest_cv.R` | Each case's cross-validated forest prediction (and out-of-bag prediction), by outcome and set; cross-validated vs out-of-bag scores (change 98) |
| `models/holdout/*` | `09-a_holdout_xgboost.R` | Holdout scores with intervals and the cross-validated estimate (`holdout_scores.csv`), each holdout case's prediction, and the log of holdout runs (change 108) |
| `models/tree_cv/*`, `models/tree_cv_summary_*.csv`, `models/tree_*_importance.csv`, `plots/tree_*_top.png` | `07-g_decision_tree.R` | Each case's cross-validated tree prediction and the all-cases tree, by outcome and set; chosen cp and leaves per fold with the scores; variable importance; the top of the tree (change 106) |
| `models/xgb_shap/*`, `models/xgb_*_shap_*.csv` | `07-c_xgboost.R` | SHAP per sampled case (with the variables' values and circuit), the all-cases model (`.json`), and the SHAP summaries by variable, by location level and by court (change 99) |
| `models/xgb_cv/*` | `07-c_xgboost.R` | Each case's cross-validated XGBoost prediction, with its fold and outcome, by outcome and set (`xgb_<outcome>_<set>_cv.rds`; change 97) |
| `models/*.rds` | `07-a`, `07-b` | The fitted forests (`rf_<outcome>_<set>.rds`, `short_<cutoff>d_<set>.rds`), saved for the interaction steps; about 1 GB each for 07-a. Stay on FarmShare. |
| `checks/oddities_cases.csv` | `02-c_data_checks_oddities.R` | Case headers, SCALES next to FJC, for training cases with odd covariate values, with a flag column for each kind of oddity |
| `checks/prose_*.csv` | `02-d_data_checks_prose.R` | SCALES-vs-FJC cross-tabs of "no lawyer" for each side, agreement and kappa, and the largest groups among disagreements |
| `checks/counsel_*.csv` | `02-g_data_checks_counsel.R` | `n_counsel` split by side and duration band: lawyers at filing vs collection, terminated, pro hac vice, dismissed-party listings, withdrawals, correlations with duration, docket match rate |
| `checks/missing_*.csv` | `02-h_data_checks_missing.R` | "No plaintiff listed" and jury demand (NA) vs the rest, party roles, SCALES vs FJC jury demand, first docket entry type, and a spot-check list of case IDs |
| `checks/plaintiff_fill_*.csv` | `02-j_data_checks_plaintiff_fill.R` | Plaintiff-fill steps, entity types of the filled plaintiffs, agreement with SCALES, unmapped roles and natures of suit of the cases still missing, spot-check IDs |
| `checks/cause_exclusion_*.csv` | `02-i_check_cause_exclusion.R` | Training vs holdout counts and z-tests for cutting cause 33:2701 and related groups; where the 33:2701 training cases are |
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
source("~/scales_setup/r/02-e_data_checks_nocause.R") # what we know about cases with no cause of action
source("~/scales_setup/r/02-f_data_checks_endings.R")  # transfers, remands, arbitration: training vs holdout balance
source("~/scales_setup/r/02-g_data_checks_counsel.R")  # where n_counsel's leakage comes from (batch job)
source("~/scales_setup/r/02-h_data_checks_missing.R")  # spot check: no plaintiff listed, jury demand (NA)
source("~/scales_setup/r/02-i_check_cause_exclusion.R")  # balance if a cause (33:2701) is cut
source("~/scales_setup/r/02-j_data_checks_plaintiff_fill.R")  # can no-plaintiff cases get a plaintiff from FJC / case name?
source("~/scales_setup/r/05_feature_selection.R") # how covariates relate to each other and to duration (training only)
source("~/scales_setup/r/06_plots_and_correlations.R") # plots of duration and covariates (run 05 first)
source("~/scales_setup/r/07-a_random_forest.R")       # random forests, main vs sensitivity (better as a batch job)
source("~/scales_setup/r/07-b_short_case_forest.R")   # classification forests: ended within 60 / 120 days? (batch job)
source("~/scales_setup/r/07-c_xgboost.R")             # XGBoost: log duration and ended within 60 / 120 days (batch job)
source("~/scales_setup/r/07-d_interactions.R")        # do interactions matter? depth check (batch job)
source("~/scales_setup/r/07-e_interaction_pairs.R")   # which pairs interact; do they help an OLS? (batch job)
```

**The regression models (08 scripts)** run as Slurm jobs from the FarmShare shell, not in RStudio:
```bash
module load r && Rscript ~/scales_setup/r/08-0_install_packages.R   # once, on the login node
bash ~/scales_setup/r/submit_regressions.sh                         # every model x run x fold (96 jobs)
env RUNS="3" bash ~/scales_setup/r/submit_regressions.sh ols quantile_50 quantile_90 logistic   # run 3 (24 jobs)
env RUNS="4" bash ~/scales_setup/r/submit_regressions.sh ols quantile_50 quantile_90 logistic   # run 4 (24 jobs)
squeue -u joshr85                                                   # still running?
module load r && Rscript ~/scales_setup/r/08-z_regression_summary.R # once the fold jobs are done
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
- **FJC outcome codes.** Settlements are spread across `DISP` 12, 13 and 5. `JUDGMENT` and `NOJ` only apply to the ~18.5% of cases that ended in a judgment. A judgment awarding money *and* an injunction is `NOJ` 2, not 3. `AMTREC` (amount received) is unreliable, and the FJC advises against using it. The FJC records no settlement amounts and no fee requests. `-8` usually means missing, but in `CLASSACT` and `IFP` it means **no**: "no class action alleged" and "not in forma pauperis". Neither field has a separate code for no (in matched cases, `CLASSACT` is 1 in about 3% and −8 in the rest).
- **Missing values are labelled, not left blank.** Covariates use explicit categories such as "no judge listed", "no plaintiff listed", "no defendant listed" and "county not recorded", so no case is silently dropped by a model. The FJC fields `ORIGIN`, `CLASSACT`, `IFP` and `PROSE` also have labelled versions (`arrival_route`, `class_action_alleged`, `in_forma_pauperis`, `pro_se`), where `-8` in `CLASSACT` and `IFP` is read as "no" ("no class action alleged", "not IFP"; Josh, 31 Oct 2026, change 81). Use these rather than the raw codes.
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
| `judge_type` = **"unassigned"** | A case still has no judge at collection mostly because it **ended before a judge was assigned**. It strongly signals a short case. |
| `judge_type` = **"appointed after filing"** | The judge at collection was appointed after filing, so the case was **reassigned** during its life. Long cases are more likely to be reassigned. |
| `judge_group` | Built from the judge **at collection**, not at filing. It carries the same reassignment issue. |
| `n_counsel` | Lawyers are added during the case; long, contested cases gain more |
| `any_referral` | Referral to a magistrate usually happens after filing |
| `is_consolidated`, `consolidation_role` | Consolidation happens after filing. These are built from SCALES `lead_case_id` only. **`is_multi` is not used**: it flags any docket that refers to another case number, including removal and transfer origins. |
| `amicus` | Amicus filings come during the case, and longer cases have more time to attract them |

**In the regression models (08 scripts; changes 87 and 89), not every variable above is held out of run 1.** Run 2 adds `judge_group`, `judge_type`, `any_referral` and `n_counsel` in every model. `consolidation_role` and `amicus` are in run 1 of the **duration** models (OLS, ridge, group lasso, quantile), so for duration the run 1 vs run 2 comparison doesn't show what those two add; it does for the short-case models, where they (with `has_related_case` and `tro_pi_motion_60d`) enter only in run 2. `defendant_firm_rank` and `is_consolidated` aren't used; `defendant_firm_appeared` and `consolidation_role` stand in for them. **Run 3 (Josh, 2 Nov 2026; change 99)** is run 2 without `n_counsel`: Josh judged there is too much evidence that it leaks (in run 2 it took 24–30% of XGBoost's gain, and counsel counts can grow while a case is open). **Run 4 (change 100)** is run 3 with the judge labels that show what happened after filing pooled: in `judge_group`, "unassigned", "(no judge listed)" and cases whose judge was appointed after filing join "other (fewer than 20 training cases)"; in `judge_type` those labels and "not matched" become "unknown". Named judges keep their levels. Not fixed: reassignments between sitting judges, and `any_referral`.
| `defendant_firm_rank` = **"no counsel listed"** (23% of training cases since the prisoner exclusion; about a third before) | A defendant with no lawyer at collection usually **never appeared**: it defaulted, or the case was dismissed or settled before an answer. So the category partly reflects how the case went. |

#### Decision (Josh, 25 Oct 2026): one plaintiff representation variable

**`plaintiff_firm_cases` is the single variable for plaintiff representation in the main model.** Its categories are:
- pro se / no counsel
- firm in 1–10, 11–20, 21–50 or over 50 cases

"Lawyer, no firm listed" counts as "1–10 cases" (change 72), and so do the filled plaintiffs that were "no plaintiff listed" (change 82). The original list also had those two as categories of their own.

**No separate plaintiff pro se flag is added.** `02-d_data_checks_prose.R` found that SCALES's "pro se / no counsel" (first plaintiff, at collection) and FJC `PROSE` (plaintiff or both) agree on 98.7% of training cases, with kappa 0.93, after the prisoner exclusion. So a second variable would measure the same thing twice and split its effect between two coefficients.

**How to read it:** the pro se category is the plaintiff pro se effect. The firm categories compare represented plaintiffs by their firm's experience.

**What happens to `pro_se` (FJC):** it no longer supplies the plaintiff pro se measure. SCALES's "no counsel listed" mostly means the defendant never appeared, so 89% of those defendants aren't pro se in the FJC, and kappa is 0.14. **The defendant side was settled in change 70:** the main set uses `defendant_pro_se` (FJC `PROSE` defendant or both) and `defendant_firm_appeared` (`defendant_firm_rank` with "no counsel listed" folded into "not in list"). `pro_se` and `defendant_firm_rank` themselves are in no regression model (change 87).

#### Decision (Josh, 24 Oct 2026): court in the main model; judge variables only in a sensitivity model

**The main model uses `court`, and not the judge variables.** Three covariates go only in a separate **sensitivity model**: `judge_group`, `judge_type`, and the magistrate-judge referral `any_referral`. The sensitivity model is court plus these three.

**Why: the judge is recorded at collection, and reassignment rises with case length.**
- **The check.** `r/02-b_data_checks_judges.R` (version 2, change 44) looked at a random sample of 10,000 training cases.
  - About **16%** have docket wording showing a change of district judge: "reassigned to Judge …", "Judge X no longer assigned", recusal, or "transferred to Judge …". Magistrate-only changes aren't counted.
  - That share rises from **10%** of cases ending within 90 days to **36%** of cases lasting over 3 years.
  - Where the docket records the first assignment, the SCALES judge is a different judge in **25%** of cases.
- **Neither rule is accurate enough to fix the variable case by case.** Both still have false positives on the spot-check; where they agree, the result is accurate but misses many cases. So the judge field can't be cleaned. Instead it's kept out of the main model.
- **Senior status comes from the same field.** `judge_type` is built from the same SCALES judge, so it has the same problem.
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
