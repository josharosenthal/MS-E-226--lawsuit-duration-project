# Data dictionary: candidate covariates

These are the 37 covariates in `r/05_feature_selection.R` (35, plus the two added in change 70), all columns of `analysis_fjc` / `train_fjc`, built by `r/00_sample.R` and `r/01_build_features.R`.

**Where the numbers come from:**
- **All counts:** the FarmShare run of 25 Oct 2026, on **268,007 training cases**. That's after every exclusion: no-FJC (change 42), habeas and prisoner natures of suit (change 57), and the recodes (changes 56–57).
  - Levels, smallest level and % missing: `misc/feature_selection/fs_covariates.csv`
  - Counts for each category (section 2): `misc/feature_selection/fs_levels.csv`
- **Leakage tiers:** from EXPLAINER section 7. *filing* means known when the case is filed; *partly* means recorded later (7C); *leaky* means kept knowingly despite leakage (7B).
- **Model:** **main**, or **sensitivity** only (changes 45, 58 and 70). The sets used by 06 and the 07 scripts are defined in `r/covariate_sets.R`.

## 1. All covariates

| Variable | What it is | Source | Type | Levels (training) | Smallest level (training cases) | % missing | Leakage | Model |
|---|---|---|---|---|---|---|---|---|
| `n_parties` | Number of parties listed | SCALES parties, at collection | count | — | — | 0 | partly | main |
| `n_counsel` | Number of lawyer listings | SCALES counsel, at collection | count | — | — | 0 | **leaky** | **sensitivity only** (out of main: too leaky, `02-g_data_checks_counsel.R`; change 70) |
| `n_plaintiffs` | Number of plaintiffs | SCALES parties by role | count | — | — | 0 | partly | main |
| `n_defendants` | Number of defendants | SCALES parties by role | count | — | — | 0 | partly | main |
| `year_dir` | Year in the case number (16 or 17) | SCALES case number | category | 2 | 132,366 | 0 | filing | main |
| `filing_month` | Month filed (1–12) | filing date (SCALES; FJC if blank) | category | 12 | 20,162 | 0 | filing | main |
| `filing_weekday` | Day of the week filed | filing date | category | 7 | 2,346 (Saturday) | 0 | filing | main |
| `case_number_parity` | Odd or even last digit of the case sequence number (some courts split work between clerks by parity) | SCALES case number | category | 2 | 133,845 | 0 | filing | main |
| `court` | District court, e.g. `ilnd` | SCALES | category | 94 | **36** | 0 | filing | main |
| `circuit` | Federal circuit (0 = D.C., 1–11) | FJC district crosswalk | category | 12 | 3,465 | 0 | filing | main (alternative to court) |
| `city` | Courthouse or divisional office | SCALES | category | 283 | **2** | 0 | filing | main |
| `judge_group` | Judge at collection (court \| name); "other" if fewer than 20 training cases; "unassigned" and "(no judge listed)" kept separate | SCALES judge, plus training counts | category | 1,448 | 20 | 0 | **leaky** | **sensitivity** |
| `senior_judge_at_filing` | The collection-time judge's status on the filing date | SCALES judge plus the FJC Biographical Directory | category | 8 | 228 | 0.4 | **leaky** | **sensitivity** |
| `nature_suit` | Nature of suit, e.g. "440 Other Civil Rights" (blank filled from the FJC) | SCALES (FJC) | category | 84 | **3** | 0 | filing | main |
| `cause_title` | U.S. Code title of the cause of action, e.g. 28 (typos corrected) | SCALES cause | category | 44 | **1** | 1.4 | filing | main (or `cause_group`) |
| `cause_group` | Title:section if at least 100 training cases, otherwise title:other | SCALES cause, plus training counts | category | 201 | **1** | 0 | filing | main (or `cause_title`) |
| `jurisdiction` | Basis of jurisdiction (blank filled from the FJC) | SCALES (FJC) | category | 5 | **12** | 0 | filing | main |
| `jury_demand` | Who demanded a jury | SCALES | category | 5 | 1,509 | 0.6 | partly | main |
| `arrival_route` | How the case arrived (FJC `ORIGIN`) | FJC | category | 5 | **40** | 0 | filing | main |
| `class_action_alleged` | Class action alleged (FJC `CLASSACT`) | FJC | category | 2 | 11,353 | 0 | filing | main |
| `in_forma_pauperis` | Filing-fee waiver (FJC `IFP`) | FJC, recorded at termination | category | 2 | 35,153 | 0 | partly | main |
| `pro_se` | Who is self-represented (FJC `PROSE`) | FJC, recorded at termination | category | 4 | 1,296 | 0 | partly | sensitivity (main uses `defendant_pro_se`; change 70) |
| `diversity_residence` | Citizenship pair in diversity cases (FJC `RESIDENC`), or "not diversity" | FJC | category | 35 | **5** | 0 | filing | main |
| `county_area_class` | First plaintiff's county, classified urban / suburban / rural (NCHS 2013) | FJC `COUNTY` plus NCHS | category | 7 | **1** | 0 | filing | main |
| `first_plaintiff_type` | Kind of party, guessed from the first plaintiff's name | SCALES parties | category | 6 | 1,338 | 0.8 | partly | main |
| `first_defendant_type` | The same, for the first defendant | SCALES parties | category | 7 | **8** | 0.9 | partly | main |
| `plaintiff_firm_cases` | How many cases the first plaintiff's lead firm appears in, or pro se | SCALES counsel | category | 7 | 2,016 | 0.8 | partly | **main: the single plaintiff representation variable** (its "pro se / no counsel" category is the plaintiff pro se measure; kept as is in change 70) |
| `defendant_firm_rank` | First defendant's lead firm, by BCG headcount rank (groups of 20) | SCALES counsel plus the BCG list | category | 14 | 174 | 0.9 | **leaky** ("no counsel listed") | sensitivity (main uses `defendant_firm_appeared`; change 70) |
| `plaintiff_org_attorney` | Any plaintiff-side attorney with a `.org` email | SCALES counsel | category | 2 | 4,690 | 0 | partly | main |
| `defendant_firm_appeared` | `defendant_firm_rank` with "no counsel listed" folded into "not in list", and "rank 181–200" merged with "headcount not given" (change 70) | SCALES counsel plus the BCG list | category | 12 | 451 | 0.9 | partly (the ranked levels still need a lawyer to have appeared) | **main** |
| `defendant_pro_se` | FJC `PROSE` says the defendant (or both sides) is pro se (change 70) | FJC, recorded at termination | category | 2 | 9,458 | 0 | partly | **main** |
| `any_referral` | Referred to a magistrate judge | SCALES | category | 2 | 125,092 | 0 | **leaky** | **sensitivity** |
| `has_related_case` | Related cases listed | SCALES | category | 2 | 11,279 | 0 | partly | main |
| `is_consolidated` | Has a lead case (lead or member) | SCALES `lead_case_id` | category | 2 | 5,383 | 0 | **leaky** | main (or `consolidation_role`) |
| `consolidation_role` | Lead / member / not consolidated | SCALES `lead_case_id` | category | 3 | 1,598 | 0 | **leaky** | main (or `is_consolidated`) |
| `tro_pi_motion_60d` | TRO or preliminary-injunction motion within 60 days of filing | SCALES docket text | category | 2 | 6,758 | 0 | partly | main |
| `amicus` | An amicus appears in the case | SCALES docket text or party role | category | 2 | 822 | 0 | **leaky** | main |

**Bold** in the "Smallest level" column marks a level with fewer than about 50 training cases; see section 4. "% missing" counts the missing labels ("not recorded", "no judge listed" and so on). It isn't the same as a category like "unassigned", which is real information.

**Pairs that say nearly the same thing** (from `fs_high_pairs.csv`): use one of each pair, or know that you're using both.
- court / circuit / city (Cramér's V 0.97–1.0)
- `cause_title` / `cause_group` (1.0)
- `is_consolidated` / `consolidation_role` (1.0)
- `judge_group` / court (0.98) and `senior_judge_at_filing` (0.94)
- `judge_group` / `any_referral` (0.86)
- `n_parties` / `n_defendants` (Spearman 0.82)
- `cause_group` / `jurisdiction` (0.73)

## 2. Values: exact training counts

All counts are **training cases with a duration value (268,007)**, from `misc/feature_selection/fs_levels.csv` (25 Oct 2026). That file has every category of covariates with up to 15 categories; for larger ones, the 5 most common and the 10 rarest.

### Covariates with few categories

| Variable | Categories: training cases (%) |
|---|---|
| `year_dir` | 17: 135,641 (50.6) · 16: 132,366 (49.4) |
| `filing_month` | between 7.5% (January, 20,162) and 9.0% (June, 24,246); December 7.9% |
| `filing_weekday` | Friday 59,251 (22.1) · Wednesday 52,811 (19.7) · Thursday 52,502 (19.6) · Tuesday 50,210 (18.7) · Monday 48,452 (18.1) · Sunday 2,435 (0.9) · Saturday 2,346 (0.9) |
| `case_number_parity` | odd 134,162 (50.1) · even 133,845 (49.9) |
| `circuit` | 9th 51,346 (19.2) · 11th 35,449 (13.2) · 2nd 30,367 (11.3) · 5th 30,122 (11.2) · 3rd 23,491 (8.8) · 7th 21,231 (7.9) · 6th 20,518 (7.7) · 4th 17,559 (6.6) · 8th 13,993 (5.2) · 10th 12,538 (4.7) · 1st 7,928 (3.0) · D.C. ("0") 3,465 (1.3) |
| `jurisdiction` | Federal Question 155,327 (58.0) · Diversity 64,484 (24.1) · U.S. Government Defendant 41,058 (15.3) · U.S. Government Plaintiff 7,126 (2.7) · **Local Question 12** |
| `jury_demand` | None 115,019 (42.9) · Plaintiff 99,356 (37.1) · Both 34,291 (12.8) · Defendant 17,832 (6.7) · (NA) 1,509 (0.6) |
| `arrival_route` | original filing 215,971 (80.6) · removed from state court 48,309 (18.0) · transferred in 3,558 (1.3) · **reopened 129** (0.05) · **remanded from court of appeals 40** (0.01) |
| `class_action_alleged` | no 256,654 (95.8) · yes 11,353 (4.2) |
| `in_forma_pauperis` | no 232,854 (86.9) · yes 35,153 (13.1) |
| `pro_se` | none 228,454 (85.2) · plaintiff 30,095 (11.2) · defendant 8,162 (3.0) · both 1,296 (0.5) |
| `senior_judge_at_filing` | active 184,000 (68.7) · senior 50,074 (18.7) · magistrate 26,946 (10.1) · appointed after filing 4,678 (1.7) · no judge listed 1,004 (0.4) · unassigned 740 (0.3) · territorial court 337 (0.1) · not matched 228 (0.1) |
| `county_area_class` | urban 108,445 (40.5) · rural 82,472 (30.8) · suburban 50,201 (18.7) · out of state 23,054 (8.6) · US territory 1,993 (0.7) · non-US 1,841 (0.7) · **unmatched county code 1** |
| `first_plaintiff_type` | individual 203,357 (75.9) · business 48,218 (18.0) · federal government 7,852 (2.9) · other organization 5,226 (2.0) · no plaintiff listed 2,016 (0.8) · state or local government 1,338 (0.5) |
| `first_defendant_type` | business 140,206 (52.3) · individual 80,359 (30.0) · federal government 24,624 (9.2) · state or local government 15,143 (5.7) · other organization 5,290 (2.0) · no defendant listed 2,377 (0.9) · **property (in rem) 8** |
| `plaintiff_firm_cases` | over 50 cases 93,606 (34.9) · 1–10 cases 63,073 (23.5) · 21–50 cases 35,040 (13.1) · pro se / no counsel 29,772 (11.1) · 11–20 cases 25,512 (9.5) · no firm listed 18,988 (7.1) · no plaintiff listed 2,016 (0.8) |
| `defendant_firm_rank` | not in list 160,407 (59.9) · **no counsel listed 61,558 (23.0)** · rank 41–60: 9,701 (3.6) · 21–40: 7,966 (3.0) · 61–80: 6,577 (2.5) · 1–20: 4,826 (1.8) · 81–100: 4,188 (1.6) · 101–120: 3,813 (1.4) · 121–140: 2,523 (0.9) · no defendant listed 2,377 (0.9) · 161–180: 2,195 (0.8) · 141–160: 1,425 (0.5) · headcount not given 277 (0.1) · 181–200: 174 (0.1) |
| `defendant_firm_appeared` | not in list 221,965 (82.8) · rank 41–60: 9,701 · 21–40: 7,966 · 61–80: 6,577 · 1–20: 4,826 · 81–100: 4,188 · 101–120: 3,813 · 121–140: 2,523 · no defendant listed 2,377 · 161–180: 2,195 · 141–160: 1,425 · 181–200 or headcount not given 451 (0.2) — *derived from the 25 Oct counts; the overnight run of 05 will confirm* |
| `defendant_pro_se` | no 258,549 (96.5) · yes 9,458 (3.5) — *derived from `pro_se`, as above* |
| `consolidation_role` | not consolidated 262,624 (98.0) · member 3,785 (1.4) · lead 1,598 (0.6) |
| Yes/no flags (% TRUE) | `any_referral` 125,092 (46.7) · `has_related_case` 11,279 (4.2) · `tro_pi_motion_60d` 6,758 (2.5) · `is_consolidated` 5,383 (2.0) · `plaintiff_org_attorney` 4,690 (1.8) · `amicus` 822 (0.3) |

### Covariates with many categories (most common and rarest)

| Variable | 5 most common | 10 rarest |
|---|---|---|
| `court` (94) | cacd 18,570 (6.9) · nysd 12,973 · flsd 11,469 · ilnd 11,127 · nyed 10,260 | wvnd 525 · iand 421 · akd 409 · vtd 379 · ndd 367 · sdd 356 · wyd 287 · vid 204 · gud 105 · **nmid 36** |
| `city` (283) | Western Division – Los Angeles 12,075 · Foley Square 11,320 · Chicago 10,774 · Brooklyn 6,875 · Philadelphia 6,283 | Pine Bluff 34 · Juneau 23 · Moscow – Central 23 · Brattleboro 21 · NMI 20 · Northern Mariana Islands 16 · 7 North Platte 14 · Ketchikan 11 · Port Huron 8 · **Nome 2** |
| `nature_suit` (84) | 440 Other Civil Rights 22,511 (8.4) · 442 Employment 18,533 · 190 Other Contract 16,418 · 480 Consumer Credit 15,720 · 110 Insurance 14,277 | 861 HIA 144 · 740 Railway Labor Act 94 · 871 IRS–Third Party 80 · 315 Airplane Product Liability 38 · 153 Recovery of Overpayment of Veterans' Benefits 28 · 345 Marine Product Liability 21 · 460 Deportation 18 · 400 State Reapportionment 10 · 862 Black Lung 5 · **999 Miscellaneous 3** |
| `cause_title` (44) | 28: 111,465 (41.6) · 42: 71,053 (26.5) · 15: 28,520 (10.6) · 29: 22,501 (8.4) · 17: 5,375 (2.0) | 10: 26 · 30: 24 · 39: 22 · 19: 20 · 22: 15 · 41: 9 · 52: 5 · 50: 4 · **36: 1 · 44: 1** |
| `cause_group` (201) | 28:1332 41,921 (15.6) · 42:405 21,055 (7.9) · 28:1441 20,108 (7.5) · 28:1331 17,739 (6.6) · 42:1983 15,285 (5.7) | rare titles as "title:other": 30:other 24 · 39:other 22 · 19:other 20 · 22:other 15 · 40:other 11 · 41:other 9 · 52:other 5 · 50:other 4 · **36:other 1 · 44:other 1** |
| `diversity_residence` (35) | not diversity 203,526 (75.9) · 15: 24,654 (9.2) · 12: 9,429 (3.5) · 45: 4,848 (1.8) · 21: 4,527 (1.7) | 44: 62 · 64: 54 · 46: 47 · 33: 37 · 65: 25 · 26: 21 · 56: 16 · 62: 14 · 36: 13 · **66: 5** |
| `judge_group` (1,448) | in `fs_levels.csv` (judge names) | every named judge has at least 20 training cases, by construction |

**`diversity_residence` codes:** first digit plaintiff, second defendant. Under the FJC codebook: 1 = citizen of this state, 2 = citizen of another state, 3 = foreign citizen, 4 = corporation incorporated or based in this state, 5 = corporation from another state, 6 = foreign nation. So **15** (the commonest) is a local individual suing an out-of-state corporation. **Check these code meanings against the codebook before relying on them.**

## 3. Things the counts turned up

1. **Weekend filings** (Saturday and Sunday) are 1.8% of cases. That's probably electronic filing; it's not an error.
2. **Duplicate and odd city labels.** "NMI" (20) and "Northern Mariana Islands" (16) are the same place. "7 North Platte" carries a stray office number, and "Moscow – Central" is a division name. If you use `city`, clean these labels first. Court avoids the problem.
3. **Habeas and prisoner cases** are now excluded by nature of suit (463, 510, 530, 535, 540, 550, 555, 560; change 57). That's 14.2% of training cases, balanced with the holdout. **What changed most:**
   - `pro_se` "plaintiff": 22.6% to 11.2%
   - `in_forma_pauperis` "yes": 18.8% to 13.1%
   - `cause_title` 42: 35.5% to 26.5%
   - `defendant_firm_rank` "no counsel listed": 30.3% to 23.0%
   - nature of suit 550 is gone; 440 is now the most common nature of suit
4. **Single-case categories:** only two remain, cause titles 36 and 44 (Army Corps rules, and Presidential Records). Both are real, and both are left for the rare-title merge. The blank jurisdiction and nature of suit are filled from the FJC, and the other one-case titles are corrected (change 57).
5. **`defendant_firm_rank`:** "no counsel listed" is 23% of training cases. This is the leaky category: it mostly means the defendant never appeared. Only 11% of these defendants are pro se in the FJC (kappa 0.14; `02-d_data_checks_prose.R`).
6. **`defendant_firm_rank` = "large-firm list, headcount not given"** (277 training cases). These are 5 firms that appear in BCG's list without an attorney headcount: Steptoe, Kelley Drye, Porter Wright, Milberg and GrayRobinson. Outside sources (ILRG, U.S. News, the firms' own sites; change 53) put four of them at roughly ranks 101–180. Milberg, a plaintiffs' class-action firm with about 60 attorneys, is smaller than any ranked firm. **Left as its own category** (Josh, 25 Oct 2026); it can be merged with other rare categories later.

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
- **No cause in SCALES, filled from the FJC section** (change 65): when the FJC record gives a numeric statute section, the case gets the most common matching SCALES cause for its nature of suit, from training cases (`cause_from_fjc` = TRUE). FJC letter codes such as MI/SC ("miscellaneous") and -8 stay "(no cause)". Counts above are from before this fill; rerun `05` to refresh them.
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
| `first_defendant_type` | property (in rem) 8 | keep (distinct), or merge into "other organization" |
| `nature_suit` | 7 suit types under 40 cases | merge suit types with under about 100 training cases into "other", or group by first digit |
| `cause_title` / `cause_group` | 10 titles under 30 cases | merge titles with under about 100 cases into "other title" |
| `diversity_residence` | 10 pairs under 65 cases | keep pairs with at least about 100 cases; the rest become "diversity, other" |
| `city` | 10 offices under 35 cases, plus duplicate labels | clean the labels, merge offices under about 100 cases into "[court], other", or use court instead |
| `court` | nmid 36, gud 105, vid 204 | usually kept; the three territorial courts could be merged into "territorial" |
| `defendant_firm_rank` | rank 181–200: 174 · headcount not given 277 | **done in `defendant_firm_appeared`** (change 70): merged into "rank 181–200 or headcount not given" (451) |

These are suggestions only. If you choose merges, they'd be built in `00_sample.R` from **training** counts, like `judge_group` and `cause_group`.
