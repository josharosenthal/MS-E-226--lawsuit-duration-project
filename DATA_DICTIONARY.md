# Data dictionary

Covariates of `analysis_fjc` / `train_fjc`, built by `r/00_sample.R` and `r/01_build_features.R`, grouped by the model runs that use them (`model_spec.xlsx` → `r/model_spec.csv`). Counts are training cases (266,444). Sources, leakage tiers and the other runs are in section 3. *(Reorganized 5 Nov 2026, change 105; the previous layout is kept locally as `DATA_DICTIONARY_2026-11-05.md`.)*

**Leakage:** *filing* = known when the case is filed; *partly* = recorded later (EXPLAINER 7C); **leaky** = kept knowingly despite leakage (EXPLAINER 7B). **Bold** in "Smallest level" marks a level with fewer than about 50 training cases (section 2). "% missing" counts missing labels ("not recorded", "no judge listed", ...) and blanks; a real category such as "unassigned" isn't missing.

## 1. Covariates by model and run

### 1A. Log duration, run 1 (OLS, ridge, group lasso, quantile; 27 covariates + 3 interactions)

| Variable | What it is | Source | Type | Levels | Smallest level | % missing | Leakage |
|----|----|----|----|----|----|----|----|
| `n_parties` | Number of parties listed (+1 where the plaintiff was filled, change 76) | SCALES parties, at collection | count (logged) | — | — | 0 | partly |
| `n_plaintiffs` | Number of plaintiffs (1 where the plaintiff was filled) | SCALES parties by role | count (logged) | — | — | 0 | partly |
| `n_defendants` | Number of defendants | SCALES parties by role | count (logged) | — | — | 0 | partly |
| `year_dir` | Year in the case number (16 or 17) | SCALES case number | category | 2 | 131,882 | 0 | filing |
| `filing_month` | Month filed (1–12) | filing date (SCALES; FJC if blank) | category | 12 | 20,066 | 0 | filing |
| `filing_weekday` | Day of the week filed | filing date | category | 7 | 2,192 (Saturday) | 0 | filing |
| `case_number_parity` | Odd or even last digit of the case sequence number (some courts split work between clerks by parity) | SCALES case number | category | 2 | 133,064 | 0 | filing |
| `court` | District court, e.g. `ilnd` | SCALES | category | 94 | **36** | 0 | filing |
| `nature_suit` | Nature of suit, e.g. "440 Other Civil Rights" (blank filled from the FJC) | SCALES (FJC) | category | 84 | **3** | 0 | filing |
| `cause_group` | Cause of action as title:section if at least 100 training cases, else title:other; "(no cause)" its own category. Typos corrected; blank filled from the FJC section where possible (change 65) | SCALES cause (FJC), training counts | category | 200 | **1** | 0 | filing |
| `jurisdiction` | Basis of jurisdiction (blank filled from the FJC) | SCALES (FJC) | category | 5 | **12** | 0 | filing |
| `jury_demand` | Who demanded a jury (cases with it blank dropped, change 76) | SCALES | category | 4 | 17,828 | 0 | partly |
| `arrival_route` | How the case arrived (FJC `ORIGIN`) | FJC | category | 5 | **40** | 0 | filing |
| `class_action_alleged` | Class action alleged (FJC `CLASSACT`) | FJC | category | 2 | 11,353 | 0 | filing |
| `in_forma_pauperis` | Filing-fee waiver (FJC `IFP`) | FJC, recorded at termination | category | 2 | 35,149 | 0 | partly |
| `diversity_residence` | Citizenship pair in diversity cases (FJC `RESIDENC`), or "not diversity"; "diversity, not recorded" kept as its own category (change 72) | FJC | category | 35 | **5** | 0 | filing |
| `county_area_class` | First plaintiff's county: urban / suburban / rural (NCHS 2013), out of state, US territory, non-US | FJC `COUNTY` plus NCHS | category | 7 | **1** | 0 | filing |
| `first_plaintiff_type` | Kind of party, from the first plaintiff's name (if none: the case name, then the FJC plaintiff name; `plaintiff_from_fill`). "Name not recorded" counts as "individual" (change 82) | SCALES parties; case name; FJC `PLT` | category | 5 | 1,338 | 0 | partly |
| `first_defendant_type` | The same, for the first defendant | SCALES parties | category | 7 | **8** | 0.3 | partly |
| `plaintiff_firm_cases` | How many cases the first plaintiff's lead firm appears in, or pro se: the single plaintiff representation variable. "No firm listed" and "no plaintiff listed" (filled plaintiffs) count as "1–10 cases" (changes 72, 82) | SCALES counsel | category | 5 | 25,511 | 0 | partly |
| `defendant_firm_appeared` | First defendant's lead firm by BCG headcount rank (groups of 20); "no counsel listed" folded into "not in list", "rank 181–200" merged with "headcount not given" (change 70) | SCALES counsel plus the BCG list | category | 12 | 450 | 0.3 | partly (a ranked level needs a lawyer to have appeared) |
| `defendant_pro_se` | FJC `PROSE` says the defendant (or both sides) is pro se (change 70) | FJC, recorded at termination | category | 2 | 9,369 | 0 | partly |
| `plaintiff_org_attorney` | Any plaintiff-side attorney with a `.org` email | SCALES counsel | category | 2 | 4,689 | 0 | partly |
| `has_related_case` | Related cases listed | SCALES | category | 2 | 11,218 | 0 | partly |
| `consolidation_role` | Lead / member / not consolidated | SCALES `lead_case_id` | category | 3 | 1,597 | 0 | **leaky** |
| `tro_pi_motion_60d` | TRO or preliminary-injunction motion within 60 days of filing | SCALES docket text | category | 2 | 6,757 | 0 | partly |
| `amicus` | An amicus appears in the case | SCALES docket text or party role | category | 2 | 822 | 0 | **leaky** |

| Interaction | Models | 07-e step 4 (lumped to 8 levels) |
|----|----|----|
| `nature_suit` × `plaintiff_firm_cases` | OLS, ridge, group lasso (not quantile) | +0.0054 R² |
| `nature_suit` × `jurisdiction` | OLS, ridge, group lasso | +0.0035 R² |
| `n_parties` × `n_defendants` | OLS, ridge, group lasso | +0.0011 R² |

### 1B. Log duration, added in run 4 (30 covariates + the same 3 interactions)

| Variable | What it is | Source | Type | Levels | Smallest level | % missing | Leakage |
|----|----|----|----|----|----|----|----|
| `judge_group` | Judge at collection (court \| name); "other (fewer than 20 training cases)" for judges with fewer than 20 training cases. **Run 4:** "unassigned", "(no judge listed)" and cases whose judge was appointed after filing pooled into "other" (change 100) | SCALES judge, training counts | category | 1,448 (before pooling) | 20 | 0 | **leaky** |
| `judge_type` | Type of the collection-time judge on the filing date: active, senior, magistrate, territorial court. **Run 4:** unassigned, no judge listed, appointed after filing and not matched become "unknown" (change 100). Renamed from `senior_judge_at_filing` (change 79) | SCALES judge plus the FJC Biographical Directory | category | 8 (5 in run 4) | 228 | 0.4 | **leaky** |
| `any_referral` | Referred to a magistrate judge | SCALES | category | 2 | 123,587 | 0 | **leaky** |

No interactions are added.

### 1C. Ended within 60 days, run 1 (plain, ridge and lasso logistic; 23 covariates + 6 interactions)

The covariates of 1A (definitions there) except the four duration-only ones (`has_related_case`, `consolidation_role`, `tro_pi_motion_60d`, `amicus`, which wait for run 4):

| Counts (logged) | Categories |
|----|----|
| `n_parties`, `n_plaintiffs`, `n_defendants` | `year_dir`, `filing_month`, `filing_weekday`, `case_number_parity`, `court`, `nature_suit`, `cause_group`, `jurisdiction`, `jury_demand`, `arrival_route`, `class_action_alleged`, `in_forma_pauperis`, `diversity_residence`, `county_area_class`, `first_plaintiff_type`, `first_defendant_type`, `plaintiff_firm_cases`, `defendant_firm_appeared`, `defendant_pro_se`, `plaintiff_org_attorney` |

| Interaction | 07-e step 4 (lumped to 8 levels) |
|----|----|
| `nature_suit` × `plaintiff_firm_cases` | +0.0025 AUC |
| `nature_suit` × `jurisdiction` | not in short_60's top 6 |
| `cause_group` × `arrival_route` | +0.0031 AUC |
| `jury_demand` × `arrival_route` | +0.0015 AUC |
| `nature_suit` × `in_forma_pauperis` | +0.0012 AUC |
| `n_parties` × `n_defendants` | +0.0008 AUC |

### 1D. Ended within 60 days, added in run 4 (30 covariates + 7 interactions)

| Added | Defined in |
|----|----|
| `has_related_case`, `consolidation_role`, `tro_pi_motion_60d`, `amicus` | 1A |
| `judge_group`, `judge_type` (pooled as in run 4), `any_referral` | 1B |
| Interaction `arrival_route` × `defendant_firm_appeared` (may be leaky; +0.0032 AUC in 07-e) | — |

### 1E. Considered but not used in the final runs

| Variable | What it is | Type | Levels | Smallest level | Leakage | Why not used |
|----|----|----|----|----|----|----|
| `n_counsel` | Number of lawyer listings (SCALES counsel, at collection) | count | — | — | **leaky** | In run 2 only; dropped from runs 3 and 4 (change 99): took 24–30% of XGBoost's gain in run 2, and counts grow while a case is open (`02-g_data_checks_counsel.R`). The tree scripts' `main_plus_counsel` set shows what it would add |
| `circuit` | Federal circuit (0 = D.C., 1–11; FJC district crosswalk) | category | 12 | 3,459 | filing | Court instead (courts nest in circuits). Used only to group SHAP values (07-c) and in `06-b_circuit_duration.R` |
| `city` | Courthouse or divisional office (SCALES) | category | 283 | **2** | filing | Court instead; duplicate labels |
| `cause_title` | U.S. Code title of the cause | category | 44 | **1** | filing | `cause_group` instead. Blank for the 1,766 "(no cause)" cases |
| `pro_se` | Who is self-represented (FJC `PROSE`, at termination) | category | 4 | 1,296 | partly | `defendant_pro_se` is built from it; plaintiffs' pro se is in `plaintiff_firm_cases` (change 88) |
| `defendant_firm_rank` | First defendant's lead firm by BCG rank, with "no counsel listed" | category | 14 | 173 | **leaky** ("no counsel listed": the defendant mostly never appeared) | `defendant_firm_appeared` is built from it (changes 70, 88) |
| `is_consolidated` | Has a lead case (lead or member; SCALES `lead_case_id`) | category | 2 | 5,382 | **leaky** | `consolidation_role` instead |

## 2. Values and rare categories

All counts are **training cases with a duration value (266,444)**, from `misc/run_2026-10-30/feature_selection/fs_levels.csv` (31 Oct 2026): every category of variables with up to 15 categories; for larger ones, the 5 most common and the 10 rarest.

### Few categories

| Variable | Categories: training cases (%) |
|----|----|
| `year_dir` | 17: 134,562 (50.5) · 16: 131,882 (49.5) |
| `filing_month` | between 7.5% (January, 20,066) and 9.1% (June, 24,119); December 7.8% |
| `filing_weekday` | Friday 58,951 (22.1) · Wednesday 52,427 (19.7) · Thursday 52,310 (19.6) · Tuesday 50,019 (18.8) · Monday 48,138 (18.1) · Sunday 2,407 (0.9) · Saturday 2,192 (0.8) |
| `case_number_parity` | odd 133,380 (50.1) · even 133,064 (49.9) |
| `circuit` | 9th 51,326 (19.3) · 11th 35,443 (13.3) · 2nd 30,364 (11.4) · 5th 28,601 (10.7) · 3rd 23,491 (8.8) · 7th 21,230 (8.0) · 6th 20,517 (7.7) · 4th 17,558 (6.6) · 8th 13,992 (5.3) · 10th 12,536 (4.7) · 1st 7,927 (3.0) · D.C. ("0") 3,459 (1.3) |
| `jurisdiction` | Federal Question 153,793 (57.7) · Diversity 64,478 (24.2) · U.S. Government Defendant 41,048 (15.4) · U.S. Government Plaintiff 7,113 (2.7) · **Local Question 12** |
| `jury_demand` | None 114,982 (43.2) · Plaintiff 99,343 (37.3) · Both 34,291 (12.9) · Defendant 17,828 (6.7) |
| `arrival_route` | original filing 214,415 (80.5) · removed from state court 48,304 (18.1) · transferred in 3,556 (1.3) · **reopened 129** (0.05) · **remanded from court of appeals 40** (0.02) |
| `class_action_alleged` | no 255,091 (95.7) · yes 11,353 (4.3) |
| `in_forma_pauperis` | no 231,295 (86.8) · yes 35,149 (13.2) |
| `pro_se` | none 227,309 (85.3) · plaintiff 29,766 (11.2) · defendant 8,073 (3.0) · both 1,296 (0.5) |
| `judge_type` | active 182,477 (68.5) · senior 50,073 (18.8) · magistrate 26,944 (10.1) · appointed after filing 4,678 (1.8) · no judge listed 981 (0.4) · unassigned 726 (0.3) · territorial court 337 (0.1) · not matched 228 (0.1). Run 4: the last four and "appointed after filing" are "unknown" (6,613) |
| `county_area_class` | urban 108,413 (40.7) · rural 80,951 (30.4) · suburban 50,196 (18.8) · out of state 23,050 (8.7) · US territory 1,993 (0.7) · non-US 1,840 (0.7) · **unmatched county code 1** |
| `first_plaintiff_type` | individual 203,576 (76.4; includes the 3 "name not recorded") · business 48,437 (18.2) · federal government 7,864 (3.0) · other organization 5,229 (2.0) · state or local government 1,338 (0.5). Includes the 468 filled cases |
| `first_defendant_type` | business 140,189 (52.6) · individual 80,323 (30.1) · federal government 24,618 (9.2) · state or local government 15,140 (5.7) · other organization 5,287 (2.0) · no defendant listed 879 (0.3) · **property (in rem) 8** |
| `plaintiff_firm_cases` | over 50 cases 93,599 (35.1) · 1–10 cases 82,525 (31.0; includes "no firm listed" and the 468 filled cases) · 21–50 cases 35,040 (13.2) · pro se / no counsel 29,769 (11.2) · 11–20 cases 25,511 (9.6) |
| `defendant_firm_rank` | not in list 160,393 (60.2) · **no counsel listed 61,511 (23.1)** · rank 41–60: 9,700 (3.6) · 21–40: 7,966 (3.0) · 61–80: 6,577 (2.5) · 1–20: 4,825 (1.8) · 81–100: 4,187 (1.6) · 101–120: 3,813 (1.4) · 121–140: 2,523 (0.9) · 161–180: 2,195 (0.8) · 141–160: 1,425 (0.5) · no defendant listed 879 (0.3) · headcount not given 277 (0.1) · 181–200: 173 (0.1) |
| `defendant_firm_appeared` | not in list 221,904 (83.3) · rank 41–60: 9,700 · 21–40: 7,966 · 61–80: 6,577 · 1–20: 4,825 · 81–100: 4,187 · 101–120: 3,813 · 121–140: 2,523 · 161–180: 2,195 · 141–160: 1,425 · no defendant listed 879 · 181–200 or headcount not given 450 (0.2) |
| `defendant_pro_se` | no 257,075 (96.5) · yes 9,369 (3.5) |
| `consolidation_role` | not consolidated 261,062 (98.0) · member 3,785 (1.4) · lead 1,597 (0.6) |
| Yes/no flags (% TRUE) | `any_referral` 123,587 (46.4) · `has_related_case` 11,218 (4.2) · `tro_pi_motion_60d` 6,757 (2.5) · `is_consolidated` 5,382 (2.0) · `plaintiff_org_attorney` 4,689 (1.8) · `amicus` 822 (0.3) |

### Many categories (most common and rarest)

| Variable | 5 most common | 10 rarest |
|----|----|----|
| `court` (94) | cacd 18,570 (7.0) · nysd 12,973 · flsd 11,468 · ilnd 11,126 · nyed 10,259 | wvnd 525 · iand 421 · akd 409 · vtd 379 · ndd 367 · sdd 356 · wyd 287 · vid 204 · gud 105 · **nmid 36** |
| `city` (283) | Western Division – Los Angeles 12,075 · Foley Square 11,320 · Chicago 10,773 · Brooklyn 6,874 · Philadelphia 6,283 | Pine Bluff 34 · Juneau 23 · Moscow – Central 23 · Brattleboro 21 · NMI 20 · Northern Mariana Islands 16 · 7 North Platte 14 · Ketchikan 11 · Port Huron 8 · **Nome 2** |
| `nature_suit` (84) | 440 Other Civil Rights 22,504 (8.4) · 442 Employment 18,528 · 190 Other Contract 16,416 · 480 Consumer Credit 15,720 · 110 Insurance 14,275 | 861 HIA 144 · 740 Railway Labor Act 94 · 871 IRS–Third Party 80 · 315 Airplane Product Liability 38 · 153 Recovery of Overpayment of Veterans' Benefits 28 · 345 Marine Product Liability 21 · 460 Deportation 18 · 400 State Reapportionment 10 · 862 Black Lung 5 · **999 Miscellaneous 3** |
| `cause_title` (44) | 28: 111,042 (41.7) · 42: 71,707 (26.9) · 15: 28,517 (10.7) · 29: 22,579 (8.5) · 17: 5,375 (2.0) | 10: 26 · 30: 24 · 39: 22 · 19: 20 · 22: 18 · 41: 9 · 52: 5 · 50: 4 · **36: 1 · 44: 1**. Blank (no cause): 1,766 (0.7) |
| `cause_group` (200) | 28:1332 41,986 (15.8) · 42:405 21,053 (7.9) · 28:1441 20,121 (7.6) · 28:1331 17,737 (6.7) · 42:1983 15,281 (5.7) | 30:other 24 · 39:other 22 · 19:other 20 · 22:other 18 · 40:other 13 · 41:other 9 · 52:other 5 · 50:other 4 · **36:other 1 · 44:other 1**. "(no cause)": 1,766 (0.7) |
| `diversity_residence` (35) | not diversity 201,969 (75.8) · 15: 24,653 (9.3) · 12: 9,426 (3.5) · 45: 4,848 (1.8) · 21: 4,526 (1.7) | 44: 62 · 64: 54 · 46: 47 · 33: 37 · 65: 25 · 26: 21 · 56: 16 · 62: 14 · 36: 13 · **66: 5** |
| `judge_group` (1,448) | in `fs_levels.csv` (judge names) | every named judge has at least 20 training cases, by construction |

**`diversity_residence` codes:** first digit plaintiff, second defendant (FJC codebook): 1 = citizen of this state, 2 = citizen of another state, 3 = foreign citizen, 4 = corporation incorporated or based in this state, 5 = corporation from another state, 6 = foreign nation. So **15**, the commonest, is a local individual suing an out-of-state corporation. Check against the codebook before relying on them.

### Rare categories

A category with a handful of training cases can't be estimated reliably and may be missing from a cross-validation fold. **Decision (Josh, 31 Oct 2026; change 82):** apart from the rows marked **done**, no merge is made; regularization, or a later choice for a particular model, deals with them. Any merge would be built in `00_sample.R` from training counts. The plain logistic model's 10/10 rule (section 3) merges small levels in that model only.

| Variable | Rare categories (training cases) | Possible merge |
|----|----|----|
| `jurisdiction` | Local Question 12 (real: Guam and the Virgin Islands, FJC JURIS 5) | keep, or merge with the territorial courts |
| `arrival_route` | reopened 129 · remanded from court of appeals 40 | "other route" |
| `county_area_class` | unmatched county code 1 (South Boston, Va.) | nearest class (probably "rural") |
| `first_plaintiff_type` | name not recorded 3 | **done** (change 82): "individual" |
| `first_defendant_type` | property (in rem) 8 | keep, or "other organization" |
| `plaintiff_firm_cases` | no plaintiff listed 468 (filled cases) | **done** (change 82): "1–10 cases" |
| `nature_suit` | 7 suit types under 40 cases | suit types under about 100 cases into "other", or group by first digit |
| `cause_title` / `cause_group` | 10 titles under 30 cases | titles under about 100 cases into "other title" |
| `diversity_residence` | 10 pairs under 65 cases | pairs under about 100 cases into "diversity, other" |
| `city` | 10 offices under 35 cases, plus duplicate labels | clean the labels; or use court (done: court is used) |
| `court` | nmid 36, gud 105, vid 204 | usually kept; or the three territorial courts into "territorial" |
| `defendant_firm_rank` | rank 181–200: 173 · headcount not given 277 | **done** in `defendant_firm_appeared` (change 70) |

## 3. Notes

**Where the numbers come from:** the FarmShare run of 31 Oct 2026, on 266,444 training cases, after every exclusion: no FJC record (change 42), habeas and prisoner natures of suit (change 57), the recodes (changes 56–57, 65, 70, 72) and the missing-data drops (change 76). Levels, smallest level and % missing: `fs_covariates.csv`; counts per category: `fs_levels.csv`; near-duplicate pairs: `fs_high_pairs.csv` (all in `misc/run_2026-10-30/feature_selection/`).

**The runs** (`spec_keep()` in `r/xgb_helpers.R`; the tree models' `reg_run1`–`reg_run4` sets use the same variables, without logs or interaction terms):
- **Run 1:** rows of `model_spec.csv` with set = main and "Yes" (sections 1A, 1C). Fitted for every model.
- **Run 2:** also the sensitivity rows and "Sensitivity only" rows: run 4's variables plus `n_counsel`, without the judge pooling. Fitted for every model.
- **Run 3** (change 99): run 2 without `n_counsel`. OLS, both quantiles, plain logistic, XGBoost, forests.
- **Run 4** (change 100): run 3 with the post-filing judge labels pooled (`recode_run4()`; sections 1B, 1D). Same models as run 3. Not fixed: reassignments between judges already on the bench, and `any_referral`.
- The older tree sets in `r/covariate_sets.R` (`main`, `main_plus_counsel`, `sensitivity`) are used by 07-a, 07-b, 07-d and 07-e.

**Pairs that say nearly the same thing** (Cramér's V unless noted): court / circuit / city (0.97–1.0); `cause_title` / `cause_group` (1.0); `is_consolidated` / `consolidation_role` (1.0); `pro_se` / `defendant_pro_se` and `defendant_firm_rank` / `defendant_firm_appeared` (1.0, one built from the other); `judge_group` / court (0.98), circuit (0.98), `judge_type` (0.94); `judge_group` / `any_referral` (0.86); court and city / `any_referral` (0.76); `n_parties` / `n_defendants` (Spearman 0.85); `cause_group` / `jurisdiction` (0.73).

**Things the counts turned up:**
1. **Weekend filings** are 1.7% of cases, probably electronic filing; not an error.
2. **City labels:** "NMI" and "Northern Mariana Islands" are the same place; "7 North Platte" has a stray office number. Court avoids the problem.
3. **Habeas and prisoner natures of suit** (463, 510, 530, 535, 540, 550, 555, 560) were excluded (change 57): 14.2% of training cases, balanced with the holdout. Plaintiff pro se fell from 22.6% to 11.2%, fee waivers from 18.8% to 13.1%, cause title 42 from 35.5% to 26.5%.
4. **`defendant_firm_rank` "no counsel listed"** (23%) mostly means the defendant never appeared; only 11% of these defendants are pro se in the FJC (kappa 0.14; `02-d`). "Headcount not given" (277) is five firms BCG lists without a headcount (Steptoe, Kelley Drye, Porter Wright, Milberg, GrayRobinson; change 53).
5. **The missing-data drops (change 76)** removed 1,563 training and 394 holdout cases (1,509 / 372 with jury demand blank, mostly Deepwater Horizon claims in E.D. La.; 54 / 22 with no plaintiff anywhere), balanced between the sides.

**Recodes in `00_sample.R`** (rules, applied to training and holdout alike; counts above include them):
- `county_area_class`: FJC county 75010 → "US territory" (Northern Mariana Islands).
- `first_defendant_type` "name not recorded": names starting with "$" → "property (in rem)" (forfeitures); 7-11 → "business"; digits-only names → "individual".
- Cause typos: 3:4301 → 38:4301 (USERRA); 1:102 → 42:12102 (ADA); 73:201 (a Pennsylvania statute) → 28:1332; 99:9999 (placeholder) → no cause.
- **No cause, filled from the FJC section** (change 65): the most common SCALES cause among training cases with the same nature of suit and section (`cause_from_fjc`). 1,766 training cases stay "(no cause)", their own category.
- Blank nature of suit or jurisdiction filled from the FJC record.

**Interactions:** chosen after `07-e_interaction_pairs.R` (Josh, 1 Nov 2026; changes 85–89). Category × category crosses all levels; empty combinations drop out. Count × count is the product of the two logged counts, each centred at its training mean, so each count's main effect is at the average of the other. Main effects stay in. Quantile regression has no interactions.

**Plain logistic only, the 10/10 rule:** an interaction cell gets its own term only with at least 10 training cases that ended within 60 days and 10 that didn't; a main-effect level failing the rule merges into "other (small)", which joins the reference level if it still fails. Guards against separation. Mostly affects `judge_group`, rare courts, natures of suit, cause groups and diversity pairs. **The counts use all training cases, not each fold's training part**, so the plain logistic's cross-validated scores are slightly optimistic. *(Merging into "other (small)" is Claude's default; Josh decided the rule.)*

**Other model settings** (changes 90–96):
- Reference level = each category's most common level (OLS, quantile, plain logistic). Reference levels, the SD-0.5 scaling and the centring of the count product come from each fold's training part (change 93).
- `judge_group` in the unpenalized models: judges nest in courts, so each court's busiest judge (where all its cases have a named judge) and the most common cross-court level are left out. A labelling rule; the fit is the same. Read judge coefficients as differences between judges of the same court.
- Ridge and lasso: dummies not standardized; logged counts and the count product scaled to SD 0.5; penalty `lambda.min`, tuned by an inner 5-fold cross-validation within each outer fold (inner folds by consolidation group, seed 227). Group lasso: one group per variable and per interaction.
- OLS predictions in days use Duan's smearing correction (also applied to ridge and group lasso). A level missing from a fold's training part gets coefficient 0.
- Standard errors (OLS and plain logistic full fits): clustered by court where usable; a column found in only one court (court dummies, judges) uses consolidation-group clustering instead (`se_reported`, `se_type`; changes 93, 95).

**Outcomes:** log(1 + duration) for the duration models, including quantile (Josh, 1 Nov 2026: logs in everything); cases that ended in court. Ended within 60 days for the short-case models; cases transferred out before day 60 dropped.

**Scoring (08-z, 08-y):** baselines from each fold's training part (R² against the training mean, Brier skill against the training share, pseudo-R¹ against the training quantile). Errors in days: absolute errors use exp(prediction) − 1; `rmse_days` uses the smeared mean. 08-y also reports the baseline as its own row (change 101).
