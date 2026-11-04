# Data dictionary: candidate covariates

These are the 37 covariates in `r/05_feature_selection.R` (35, plus the two added in change 70), all columns of `analysis_fjc` / `train_fjc`, built by `r/00_sample.R` and `r/01_build_features.R`.

**Where the numbers come from:**
- **All counts:** the FarmShare run of 31 Oct 2026, on **266,444 training cases**. That's after every exclusion: no-FJC (change 42), habeas and prisoner natures of suit (change 57), the recodes (changes 56–57, 65, 70, 72) and the missing-data drops (change 76: jury demand blank, and no plaintiff anywhere; 1,563 training cases fewer than the 268,007 of 25–29 Oct).
  - Levels, smallest level and % missing: `misc/run_2026-10-30/feature_selection/fs_covariates.csv`
  - Counts for each category (section 2): `misc/run_2026-10-30/feature_selection/fs_levels.csv`
  - Pairs that say nearly the same thing: `misc/run_2026-10-30/feature_selection/fs_high_pairs.csv`
- **Leakage tiers:** from EXPLAINER section 7. *filing* means known when the case is filed; *partly* means recorded later (7C); *leaky* means kept knowingly despite leakage (7B).
- **Model:** the regression specification in `model_spec.xlsx` (changes 85–89). **main** = in both runs; **sensitivity** = added only in the second run ("with sensitivity"); where the duration and short-case models differ, both are given; **not used** = in no regression model. Counts are logged in every model. There is no separate main + `n_counsel` regression model. **Run 3** (Josh, 2 Nov 2026; change 99) = the second run without `n_counsel` (too much evidence that it leaks), fitted for OLS, both quantile models, plain logistic, XGBoost and the forests; the variables are otherwise the same as the second run's. **Run 4** (Josh, 2 Nov 2026; change 100) = run 3 with the post-filing judge labels pooled (see `judge_group` and `judge_type`), same models. Interactions are in section 5. The tree models (06 and the 07 scripts) use the sets in `r/covariate_sets.R`; **07-a, 07-b and 07-c also fit a main + `n_counsel` set (`main_plus_counsel`)**, kept to show what `n_counsel` would add.

## 1. All covariates

| Variable | What it is | Source | Type | Levels (training) | Smallest level (training cases) | % missing | Leakage | Model |
|---|---|---|---|---|---|---|---|---|
| `n_parties` | Number of parties listed (+1 where the plaintiff was filled, change 76) | SCALES parties, at collection | count | — | — | 0 | partly | main (logged) |
| `n_counsel` | Number of lawyer listings | SCALES counsel, at collection | count | — | — | 0 | **leaky** | **sensitivity** (logged). No separate main + `n_counsel` regression model (Josh, 1 Nov 2026; change 89); the 07-a/b/c tree scripts do fit one (`main_plus_counsel`). Out of main: too leaky (`02-g_data_checks_counsel.R`; change 70). **Dropped from run 3** (change 99): in run 2 it took 24–30% of XGBoost's gain |
| `n_plaintiffs` | Number of plaintiffs (set to 1 where the plaintiff was filled, change 76) | SCALES parties by role | count | — | — | 0 | partly | main (logged) |
| `n_defendants` | Number of defendants | SCALES parties by role | count | — | — | 0 | partly | main (logged) |
| `year_dir` | Year in the case number (16 or 17) | SCALES case number | category | 2 | 131,882 | 0 | filing | main |
| `filing_month` | Month filed (1–12) | filing date (SCALES; FJC if blank) | category | 12 | 20,066 | 0 | filing | main |
| `filing_weekday` | Day of the week filed | filing date | category | 7 | 2,192 (Saturday) | 0 | filing | main |
| `case_number_parity` | Odd or even last digit of the case sequence number (some courts split work between clerks by parity) | SCALES case number | category | 2 | 133,064 | 0 | filing | main |
| `court` | District court, e.g. `ilnd` | SCALES | category | 94 | **36** | 0 | filing | main |
| `circuit` | Federal circuit (0 = D.C., 1–11) | FJC district crosswalk | category | 12 | 3,459 | 0 | filing | not used (court instead) |
| `city` | Courthouse or divisional office | SCALES | category | 283 | **2** | 0 | filing | not used (court instead) |
| `judge_group` | Judge at collection (court \| name); "other" if fewer than 20 training cases; "unassigned" and "(no judge listed)" kept separate | SCALES judge, plus training counts | category | 1,448 | 20 | 0 | **leaky** | **sensitivity**. Run 4 (change 100): "unassigned", "(no judge listed)" and cases whose judge was appointed after filing pooled into "other (fewer than 20 training cases)" |
| `judge_type` | The collection-time judge's type on the filing date: active, senior, magistrate, appointed after filing, territorial court, unassigned, no judge listed or not matched. Renamed from `senior_judge_at_filing` (change 79), since it also records magistrate judges | SCALES judge plus the FJC Biographical Directory | category | 8 | 228 | 0.4 | **leaky** | **sensitivity**. Run 4 (change 100): unassigned, no judge listed, appointed after filing and not matched become "unknown" |
| `nature_suit` | Nature of suit, e.g. "440 Other Civil Rights" (blank filled from the FJC) | SCALES (FJC) | category | 84 | **3** | 0 | filing | main |
| `cause_title` | U.S. Code title of the cause of action, e.g. 28 (typos corrected; blank filled from the FJC section where possible, change 65). **Blank for the 1,766 "(no cause)" cases**: `lm()`, `glm()` and `rq()` drop those rows unless the blank is recoded first | SCALES cause (FJC) | category | 44 | **1** | 0.7 | filing | not used (`cause_group` instead) |
| `cause_group` | Title:section if at least 100 training cases, otherwise title:other; "(no cause)" if there's no cause (kept as its own category, change 65) | SCALES cause, plus training counts | category | 200 | **1** | 0 | filing | main |
| `jurisdiction` | Basis of jurisdiction (blank filled from the FJC) | SCALES (FJC) | category | 5 | **12** | 0 | filing | main |
| `jury_demand` | Who demanded a jury. Cases with it blank are dropped (change 76) | SCALES | category | 4 | 17,828 | 0 | partly | main |
| `arrival_route` | How the case arrived (FJC `ORIGIN`) | FJC | category | 5 | **40** | 0 | filing | main |
| `class_action_alleged` | Class action alleged (FJC `CLASSACT`) | FJC | category | 2 | 11,353 | 0 | filing | main |
| `in_forma_pauperis` | Filing-fee waiver (FJC `IFP`) | FJC, recorded at termination | category | 2 | 35,149 | 0 | partly | main |
| `pro_se` | Who is self-represented (FJC `PROSE`) | FJC, recorded at termination | category | 4 | 1,296 | 0 | partly | not used (main uses `defendant_pro_se`, which is built from it; change 88) |
| `diversity_residence` | Citizenship pair in diversity cases (FJC `RESIDENC`), or "not diversity". "Diversity, not recorded" (a diversity case with no usable residence code) stays its own category: Josh chose to disregard it (change 72) | FJC | category | 35 | **5** | 0 | filing | main |
| `county_area_class` | First plaintiff's county, classified urban / suburban / rural (NCHS 2013) | FJC `COUNTY` plus NCHS | category | 7 | **1** | 0 | filing | main |
| `first_plaintiff_type` | Kind of party, guessed from the first plaintiff's name. If SCALES lists no plaintiff, from the case name, then the FJC plaintiff name (`plaintiff_from_fill` = TRUE). A name with no letters ("name not recorded") counts as "individual" (change 82). Cases with no plaintiff anywhere are dropped (change 76) | SCALES parties; case name; FJC `PLT` | category | 5 | 1,338 | 0 | partly | main |
| `first_defendant_type` | The same, for the first defendant | SCALES parties | category | 7 | **8** | 0.3 | partly | main |
| `plaintiff_firm_cases` | How many cases the first plaintiff's lead firm appears in, or pro se | SCALES counsel | category | 5 | 25,511 | 0 | partly | **main: the single plaintiff representation variable** (its "pro se / no counsel" category is the plaintiff pro se measure; kept as is in change 70; "no firm listed" counts as "1–10 cases" since change 72, and so does "no plaintiff listed" (the filled plaintiffs, which have no counsel data) since change 82. "No defendant listed" stays its own level in the defendant variables: it may carry information) |
| `defendant_firm_rank` | First defendant's lead firm, by BCG headcount rank (groups of 20) | SCALES counsel plus the BCG list | category | 14 | 173 | 0.3 | **leaky** ("no counsel listed") | not used (main uses `defendant_firm_appeared`, which is built from it; change 88) |
| `plaintiff_org_attorney` | Any plaintiff-side attorney with a `.org` email | SCALES counsel | category | 2 | 4,689 | 0 | partly | main |
| `defendant_firm_appeared` | `defendant_firm_rank` with "no counsel listed" folded into "not in list", and "rank 181–200" merged with "headcount not given" (change 70) | SCALES counsel plus the BCG list | category | 12 | 450 | 0.3 | partly (the ranked levels still need a lawyer to have appeared) | **main** |
| `defendant_pro_se` | FJC `PROSE` says the defendant (or both sides) is pro se (change 70) | FJC, recorded at termination | category | 2 | 9,369 | 0 | partly | **main** |
| `any_referral` | Referred to a magistrate judge | SCALES | category | 2 | 123,587 | 0 | **leaky** | **sensitivity** |
| `has_related_case` | Related cases listed | SCALES | category | 2 | 11,218 | 0 | partly | main for duration; **sensitivity** for short-case (change 87) |
| `is_consolidated` | Has a lead case (lead or member) | SCALES `lead_case_id` | category | 2 | 5,382 | 0 | **leaky** | not used (`consolidation_role` instead) |
| `consolidation_role` | Lead / member / not consolidated | SCALES `lead_case_id` | category | 3 | 1,597 | 0 | **leaky** | main for duration; **sensitivity** for short-case (change 87) |
| `tro_pi_motion_60d` | TRO or preliminary-injunction motion within 60 days of filing | SCALES docket text | category | 2 | 6,757 | 0 | partly | main for duration; **sensitivity** for short-case (change 87) |
| `amicus` | An amicus appears in the case | SCALES docket text or party role | category | 2 | 822 | 0 | **leaky** | main for duration; **sensitivity** for short-case (change 87) |

**Bold** in the "Smallest level" column marks a level with fewer than about 50 training cases; see section 4. "% missing" counts the missing labels ("not recorded", "no judge listed", "no defendant listed", "no plaintiff listed" and so on) and blanks. It isn't the same as a category like "unassigned", which is real information.

**Pairs that say nearly the same thing** (from `fs_high_pairs.csv`): use one of each pair, or know that you're using both.
- court / circuit / city (Cramér's V 0.97–1.0)
- `cause_title` / `cause_group` (1.0)
- `is_consolidated` / `consolidation_role` (1.0)
- `pro_se` / `defendant_pro_se` (1.0) and `defendant_firm_rank` / `defendant_firm_appeared` (1.0): each main-set variable is built from the other one, so the regression models use only the main-set version (change 88)
- `judge_group` / court (0.98), circuit (0.98) and `judge_type` (0.94)
- `judge_group` / `any_referral` (0.86); court and city / `any_referral` (0.76)
- `n_parties` / `n_defendants` (Spearman 0.85)
- `cause_group` / `jurisdiction` (0.73)

## 2. Values: exact training counts

All counts are **training cases with a duration value (266,444)**, from `misc/run_2026-10-30/feature_selection/fs_levels.csv` (31 Oct 2026). That file has every category of covariates with up to 15 categories; for larger ones, the 5 most common and the 10 rarest.

### Covariates with few categories

| Variable | Categories: training cases (%) |
|---|---|
| `year_dir` | 17: 134,562 (50.5) · 16: 131,882 (49.5) |
| `filing_month` | between 7.5% (January, 20,066) and 9.1% (June, 24,119); December 7.8% |
| `filing_weekday` | Friday 58,951 (22.1) · Wednesday 52,427 (19.7) · Thursday 52,310 (19.6) · Tuesday 50,019 (18.8) · Monday 48,138 (18.1) · Sunday 2,407 (0.9) · Saturday 2,192 (0.8) |
| `case_number_parity` | odd 133,380 (50.1) · even 133,064 (49.9) |
| `circuit` | 9th 51,326 (19.3) · 11th 35,443 (13.3) · 2nd 30,364 (11.4) · 5th 28,601 (10.7) · 3rd 23,491 (8.8) · 7th 21,230 (8.0) · 6th 20,517 (7.7) · 4th 17,558 (6.6) · 8th 13,992 (5.3) · 10th 12,536 (4.7) · 1st 7,927 (3.0) · D.C. ("0") 3,459 (1.3) |
| `jurisdiction` | Federal Question 153,793 (57.7) · Diversity 64,478 (24.2) · U.S. Government Defendant 41,048 (15.4) · U.S. Government Plaintiff 7,113 (2.7) · **Local Question 12** |
| `jury_demand` | None 114,982 (43.2) · Plaintiff 99,343 (37.3) · Both 34,291 (12.9) · Defendant 17,828 (6.7). The blank "(NA)" cases (1,509 on 29 Oct) are dropped (change 76) |
| `arrival_route` | original filing 214,415 (80.5) · removed from state court 48,304 (18.1) · transferred in 3,556 (1.3) · **reopened 129** (0.05) · **remanded from court of appeals 40** (0.02) |
| `class_action_alleged` | no 255,091 (95.7) · yes 11,353 (4.3) |
| `in_forma_pauperis` | no 231,295 (86.8) · yes 35,149 (13.2) |
| `pro_se` | none 227,309 (85.3) · plaintiff 29,766 (11.2) · defendant 8,073 (3.0) · both 1,296 (0.5) |
| `judge_type` | active 182,477 (68.5) · senior 50,073 (18.8) · magistrate 26,944 (10.1) · appointed after filing 4,678 (1.8) · no judge listed 981 (0.4) · unassigned 726 (0.3) · territorial court 337 (0.1) · not matched 228 (0.1) |
| `county_area_class` | urban 108,413 (40.7) · rural 80,951 (30.4) · suburban 50,196 (18.8) · out of state 23,050 (8.7) · US territory 1,993 (0.7) · non-US 1,840 (0.7) · **unmatched county code 1** |
| `first_plaintiff_type` | individual 203,576 (76.4; includes the 3 "name not recorded", change 82) · business 48,437 (18.2) · federal government 7,864 (3.0) · other organization 5,229 (2.0) · state or local government 1,338 (0.5). Includes the 468 cases filled from the case name or FJC name (change 76) |
| `first_defendant_type` | business 140,189 (52.6) · individual 80,323 (30.1) · federal government 24,618 (9.2) · state or local government 15,140 (5.7) · other organization 5,287 (2.0) · no defendant listed 879 (0.3) · **property (in rem) 8** |
| `plaintiff_firm_cases` | over 50 cases 93,599 (35.1) · 1–10 cases 82,525 (31.0; includes "no firm listed", 18,988 on 29 Oct, change 72, and the 468 "no plaintiff listed" filled cases, change 82) · 21–50 cases 35,040 (13.2) · pro se / no counsel 29,769 (11.2) · 11–20 cases 25,511 (9.6) |
| `defendant_firm_rank` | not in list 160,393 (60.2) · **no counsel listed 61,511 (23.1)** · rank 41–60: 9,700 (3.6) · 21–40: 7,966 (3.0) · 61–80: 6,577 (2.5) · 1–20: 4,825 (1.8) · 81–100: 4,187 (1.6) · 101–120: 3,813 (1.4) · 121–140: 2,523 (0.9) · 161–180: 2,195 (0.8) · 141–160: 1,425 (0.5) · no defendant listed 879 (0.3) · headcount not given 277 (0.1) · 181–200: 173 (0.1) |
| `defendant_firm_appeared` | not in list 221,904 (83.3) · rank 41–60: 9,700 · 21–40: 7,966 · 61–80: 6,577 · 1–20: 4,825 · 81–100: 4,187 · 101–120: 3,813 · 121–140: 2,523 · 161–180: 2,195 · 141–160: 1,425 · no defendant listed 879 · 181–200 or headcount not given 450 (0.2) |
| `defendant_pro_se` | no 257,075 (96.5) · yes 9,369 (3.5) |
| `consolidation_role` | not consolidated 261,062 (98.0) · member 3,785 (1.4) · lead 1,597 (0.6) |
| Yes/no flags (% TRUE) | `any_referral` 123,587 (46.4) · `has_related_case` 11,218 (4.2) · `tro_pi_motion_60d` 6,757 (2.5) · `is_consolidated` 5,382 (2.0) · `plaintiff_org_attorney` 4,689 (1.8) · `amicus` 822 (0.3) |

### Covariates with many categories (most common and rarest)

| Variable | 5 most common | 10 rarest |
|---|---|---|
| `court` (94) | cacd 18,570 (7.0) · nysd 12,973 · flsd 11,468 · ilnd 11,126 · nyed 10,259 | wvnd 525 · iand 421 · akd 409 · vtd 379 · ndd 367 · sdd 356 · wyd 287 · vid 204 · gud 105 · **nmid 36** |
| `city` (283) | Western Division – Los Angeles 12,075 · Foley Square 11,320 · Chicago 10,773 · Brooklyn 6,874 · Philadelphia 6,283 | Pine Bluff 34 · Juneau 23 · Moscow – Central 23 · Brattleboro 21 · NMI 20 · Northern Mariana Islands 16 · 7 North Platte 14 · Ketchikan 11 · Port Huron 8 · **Nome 2** |
| `nature_suit` (84) | 440 Other Civil Rights 22,504 (8.4) · 442 Employment 18,528 · 190 Other Contract 16,416 · 480 Consumer Credit 15,720 · 110 Insurance 14,275 | 861 HIA 144 · 740 Railway Labor Act 94 · 871 IRS–Third Party 80 · 315 Airplane Product Liability 38 · 153 Recovery of Overpayment of Veterans' Benefits 28 · 345 Marine Product Liability 21 · 460 Deportation 18 · 400 State Reapportionment 10 · 862 Black Lung 5 · **999 Miscellaneous 3** |
| `cause_title` (44) | 28: 111,042 (41.7) · 42: 71,707 (26.9) · 15: 28,517 (10.7) · 29: 22,579 (8.5) · 17: 5,375 (2.0) | 10: 26 · 30: 24 · 39: 22 · 19: 20 · 22: 18 · 41: 9 · 52: 5 · 50: 4 · **36: 1 · 44: 1**. Blank (no cause): 1,766 (0.7) |
| `cause_group` (200) | 28:1332 41,986 (15.8) · 42:405 21,053 (7.9) · 28:1441 20,121 (7.6) · 28:1331 17,737 (6.7) · 42:1983 15,281 (5.7) | rare titles as "title:other": 30:other 24 · 39:other 22 · 19:other 20 · 22:other 18 · 40:other 13 · 41:other 9 · 52:other 5 · 50:other 4 · **36:other 1 · 44:other 1**. "(no cause)": 1,766 (0.7) |
| `diversity_residence` (35) | not diversity 201,969 (75.8) · 15: 24,653 (9.3) · 12: 9,426 (3.5) · 45: 4,848 (1.8) · 21: 4,526 (1.7) | 44: 62 · 64: 54 · 46: 47 · 33: 37 · 65: 25 · 26: 21 · 56: 16 · 62: 14 · 36: 13 · **66: 5** |
| `judge_group` (1,448) | in `fs_levels.csv` (judge names) | every named judge has at least 20 training cases, by construction |

**`diversity_residence` codes:** first digit plaintiff, second defendant. Under the FJC codebook: 1 = citizen of this state, 2 = citizen of another state, 3 = foreign citizen, 4 = corporation incorporated or based in this state, 5 = corporation from another state, 6 = foreign nation. So **15** (the commonest) is a local individual suing an out-of-state corporation. **Check these code meanings against the codebook before relying on them.**

## 3. Things the counts turned up

1. **Weekend filings** (Saturday and Sunday) are 1.7% of cases. That's probably electronic filing; it's not an error.
2. **Duplicate and odd city labels.** "NMI" (20) and "Northern Mariana Islands" (16) are the same place. "7 North Platte" carries a stray office number, and "Moscow – Central" is a division name. If you use `city`, clean these labels first. Court avoids the problem.
3. **Habeas and prisoner cases** are excluded by nature of suit (463, 510, 530, 535, 540, 550, 555, 560; change 57). That was 14.2% of training cases, balanced with the holdout. **What changed most** (25 Oct counts):
   - `pro_se` "plaintiff": 22.6% to 11.2%
   - `in_forma_pauperis` "yes": 18.8% to 13.1%
   - `cause_title` 42: 35.5% to 26.5%
   - `defendant_firm_rank` "no counsel listed": 30.3% to 23.0%
   - nature of suit 550 is gone; 440 is now the most common nature of suit
4. **Single-case categories:** cause titles 36 and 44 (Army Corps rules, and Presidential Records) and the one unmatched county code. All are real, and the titles are left for the rare-title merge. The blank jurisdiction and nature of suit are filled from the FJC, and the other one-case titles are corrected (change 57).
5. **`defendant_firm_rank`:** "no counsel listed" is 23% of training cases. This is the leaky category: it mostly means the defendant never appeared. Only 11% of these defendants are pro se in the FJC (kappa 0.14; `02-d_data_checks_prose.R`).
6. **`defendant_firm_rank` = "large-firm list, headcount not given"** (277 training cases). These are 5 firms that appear in BCG's list without an attorney headcount: Steptoe, Kelley Drye, Porter Wright, Milberg and GrayRobinson. Outside sources (ILRG, U.S. News, the firms' own sites; change 53) put four of them at roughly ranks 101–180. Milberg, a plaintiffs' class-action firm with about 60 attorneys, is smaller than any ranked firm. In `defendant_firm_appeared` it's merged with "rank 181–200" (change 70).
7. **The missing-data drops (change 76)** removed 1,563 training cases: 1,509 with jury demand blank and 54 with no plaintiff anywhere. Most were Deepwater Horizon claims in E.D. La. (`02-h`), so the 5th Circuit fell from 30,122 to 28,601 cases. "No defendant listed" fell from 2,377 to 879, and "no plaintiff listed" in `first_plaintiff_type` is gone: the 468 remaining cases were filled. The drops were checked for balance between training and holdout (`checks/presplit_missing_data_drops_balance.csv`).

### Recodes applied in `00_sample.R` (changes 56–57)
These are rules, applied to training and holdout alike. The counts above include them.
- **`county_area_class`:** "unmatched county code" with FJC county 75010 becomes **"US territory"** (the Northern Mariana Islands). 1 case remains unmatched: South Boston, Va., kept by choice.
- **`first_defendant_type`:** "name not recorded" is split by the first defendant's name:
  - **"property (in rem)"**, a new category, for names starting with "$" (forfeitures; 8 training cases)
  - "business" for 7-11
  - "individual" for digits-only names (SCALES-anonymized people, and anonymous online sellers in "Schedule A" trademark cases)
- **Cause typos:**
  - 3:4301 becomes **38:4301** (USERRA)
  - 1:102 becomes **42:12102** (ADA)
  - 73:201 (Pennsylvania's consumer-protection statute, state law) becomes **28:1332** (diversity)
  - 99:9999 (a placeholder) becomes **no cause**
  - 44:2107 and 36:327 are left as they are.

  `cause_group` is built from the corrected values.
- **No cause in SCALES, filled from the FJC section** (change 65): when the FJC record gives a numeric statute section, the case gets the most common matching SCALES cause for its nature of suit, from training cases (`cause_from_fjc` = TRUE). FJC letter codes such as MI/SC ("miscellaneous") and -8 stay "(no cause)": **1,766 training cases (0.7%)**, kept as their own category (Josh: no merge with rare causes). The counts above include the fill.
- **Blank nature of suit or jurisdiction in SCALES** is filled from the FJC record: the NOS code, written in SCALES's own wording for that code, and JURIS 1–5 in words. This covers the D. Mass. case.
- **"Local Question" jurisdiction** is kept: it's real, all in Guam and the Virgin Islands (FJC JURIS 5).

## 4. Rare categories worth deciding on

A category with only a handful of training cases can't be estimated reliably, and in cross-validation it may be missing from a fold altogether. Options:
- merge it, deciding on training data before modelling
- rely on regularization (lasso or ridge shrinks small categories)

| Variable | Rare categories (training cases) | A possible merge |
|---|---|---|
| `jurisdiction` | Local Question 12 | keep (real), or merge with the territorial courts |
| `arrival_route` | reopened 129 · remanded from court of appeals 40 | merge into "other route" |
| `county_area_class` | unmatched county code 1 | merge into the nearest class (South Boston is now part of Halifax County, probably "rural"; check the NCHS code) |
| `first_plaintiff_type` | name not recorded 3 | **done** (change 82): counts as "individual" |
| `first_defendant_type` | property (in rem) 8 | keep (distinct), or merge into "other organization" |
| `plaintiff_firm_cases` | no plaintiff listed 468 (the filled cases; no counsel data) | **done** (change 82): counts as "1–10 cases" |
| `nature_suit` | 7 suit types under 40 cases | merge suit types with under about 100 training cases into "other", or group by first digit |
| `cause_title` / `cause_group` | 10 titles under 30 cases | merge titles with under about 100 cases into "other title" |
| `diversity_residence` | 10 pairs under 65 cases | keep pairs with at least about 100 cases; the rest become "diversity, other" |
| `city` | 10 offices under 35 cases, plus duplicate labels | clean the labels, merge offices under about 100 cases into "[court], other", or use court instead |
| `court` | nmid 36, gud 105, vid 204 | usually kept; the three territorial courts could be merged into "territorial" |
| `defendant_firm_rank` | rank 181–200: 173 · headcount not given 277 | **done in `defendant_firm_appeared`** (change 70): merged into "rank 181–200 or headcount not given" (450) |

**Decision (Josh, 31 Oct 2026; change 82):** apart from the rows marked **done**, none of these merges is made. The rare categories stay as they are; regularization, or a choice made later for a particular model, can deal with them. Any merge would be built in `00_sample.R` from **training** counts, like `judge_group` and `cause_group`.

## 5. Interactions in the regression models

From `model_spec.xlsx` (Josh, 1 Nov 2026; changes 85–89), chosen after `07-e_interaction_pairs.R`. Category × category interactions cross **all levels** of both variables (no lumping); empty combinations drop out. Count × count is the product of the two logged counts, each **centred** at its training mean first (as in `model_spec.xlsx`). That doesn't change the fit, but it means each count's main-effect coefficient is its effect at the average of the other count, not at zero. The main effects of both variables stay in. Quantile regression has **no** interactions.

| Interaction | Duration: OLS / ridge / group lasso | Duration: quantile (0.5, 0.9) | Short-case: logistic, ridge, lasso | 07-e step 4 (lumped to 8 levels) |
|---|---|---|---|---|
| `nature_suit` × `plaintiff_firm_cases` | both runs | — | both runs | +0.0054 R² (log duration); +0.0025 AUC (short_60) |
| `nature_suit` × `jurisdiction` | both runs | — | both runs | +0.0035 R² (log duration); not in short_60's top 6 |
| `n_parties` × `n_defendants` | both runs | — | both runs | +0.0011 R² (log duration); +0.0008 AUC (short_60) |
| `cause_group` × `arrival_route` | — | — | both runs | +0.0031 AUC (short_60) |
| `jury_demand` × `arrival_route` | — | — | both runs | +0.0015 AUC (short_60) |
| `nature_suit` × `in_forma_pauperis` | — | — | both runs | +0.0012 AUC (short_60) |
| `arrival_route` × `defendant_firm_appeared` | — | — | **sensitivity run only** (may be leaky) | +0.0032 AUC (short_60) |

**Plain logistic regression only: in a category × category interaction, a cell gets its own term only if it has at least 10 training cases that ended within 60 days and at least 10 that didn't** (Josh, 1 Nov 2026). Smaller cells get no interaction term; their cases are predicted from the two main effects. This guards against separation (a cell where every case has the same outcome). Ridge and lasso keep every cell. (`n_parties` × `n_defendants` has no cells, so the rule doesn't apply to it.)

**The same 10/10 rule applies to main-effect levels in the plain logistic model** (Josh, 1 Nov 2026): a category level with fewer than 10 short or fewer than 10 non-short training cases is merged into one "other (small)" level for that variable, in the plain logistic model only; if that merged level still fails the rule, it joins the variable's reference level (its most common level). This mostly affects `judge_group` (run 2), rare courts, natures of suit, cause groups and diversity pairs. *(Merging into "other (small)" is Claude's default; Josh decided the rule, not where the small levels go.)*

**These cell and level counts are taken from the full training data, across all cross-validation folds, not from each fold's training part. The choice of which cells to keep therefore uses outcomes from cases that, in a given fold, are being predicted.** The effect should be small with folds of about 53,000 cases, but the cross-validated scores of the plain logistic model are slightly optimistic because of it. The holdout is not used.

**Other model settings** (change 90): reference level = each category's most common level (OLS, quantile, plain logistic). Reference levels, the SD-0.5 scaling and the centring of the count product are set from each fold's **training part** only (change 93); the 10/10 rule still counts on all training cases. **`judge_group` (run 2, unpenalized models):** judges are nested in courts, so some judge columns are redundant. In a court whose cases all have a named judge, the court's busiest judge is left out (that court's reference); across all levels, the most common level that spans courts (usually "other (fewer than 20 training cases)") is left out. This is a labelling rule, not a model change: the fit is the same either way (change 93). Read judge coefficients as differences between judges of the same court. Ridge and lasso: dummies not standardized; logged counts and `n_parties` × `n_defendants` scaled to a standard deviation of 0.5; penalty `lambda.min`, tuned within each cross-validation fold. Group lasso: one group per variable and one per interaction; an interaction may enter without its main effects. OLS predictions in days use Duan's smearing correction (the code also applies it to ridge and group lasso; change 91). A level missing from a fold's training part gets coefficient 0: in the unpenalized models its cases are predicted like the reference level; in ridge and lasso, which have no reference level, they're predicted at the intercept. Standard errors of the full-training fits are clustered by court (consolidation groups lie within courts), for **OLS and plain logistic only**: the quantile fits have none, and the penalized fits have none by design. **Court clustering kept, with warnings (Josh, 1 Nov 2026; change 93):** court is also in the model, so the clustered variance has rank at most 93, far below the number of coefficients, and a coefficient whose column appears in only one court (every court dummy, every judge, any cell found in one court) rests on a single cluster. The coefficients files give `n_courts` for each column and mark those standard errors `se_usable = FALSE`. **A second set, clustered by consolidation group, covers those coefficients (option (a); Josh, 1 Nov 2026; change 95):** `se_cluster_group` for every coefficient (most groups are one case, so it's close to ordinary robust standard errors), and `se_reported` uses the court-clustered value where it's usable and the group-clustered one otherwise, with `se_type` saying which. So court and judge effects get group-clustered standard errors, which don't allow for correlation within a court beyond what the dummies absorb; every other coefficient keeps court clustering. *(Change 90 had recorded "clustered by court and consolidation group".)*

**Scoring (08-z; change 93):** every baseline comes from the fold's training part (R² against the training mean, Brier skill against the training share of short cases, pseudo-R¹ against the training quantile). Errors in days use the prediction that suits each loss: absolute errors use exp(prediction) − 1, a median-type prediction; `rmse_days` uses the smeared mean. 08-z also flags plain logistic folds that didn't converge and penalties at the end of their path, and refuses to score a model whose folds came from different versions of `model_spec.csv`.

**Outcomes:** log(1 + duration) for the OLS-type models **and for the quantile regressions** (Josh, 1 Nov 2026: logs in everything, for consistency); a predicted quantile of log duration converts exactly to days. Ended within 60 days for the short-case models.
