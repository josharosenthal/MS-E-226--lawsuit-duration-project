# How `r/05_feature_selection.R` works — an annotated guide

This guide walks through the feature-selection script one section at a time. It explains what each piece of code does, why it's written that way, and how to read what comes out. Code excerpts are copied from the script. Line numbers refer to [r/05_feature_selection.R](r/05_feature_selection.R) as of change 39 in `CHANGES.md`.

**Background reading** (all free):

| Topic | Plain-language explainer | Reference |
|---|---|---|
| Spearman's rank correlation | [Laerd Statistics guide](https://statistics.laerd.com/statistical-guides/spearmans-rank-order-correlation-statistical-guide.php) | [Wikipedia](https://en.wikipedia.org/wiki/Spearman%27s_rank_correlation_coefficient) |
| Cramér's V | [Statology: Cramér's V](https://www.statology.org/cramers-v/) | [Wikipedia](https://en.wikipedia.org/wiki/Cram%C3%A9r%27s_V); bias correction: [Bergsma (2013)](https://doi.org/10.1016/j.jkss.2012.10.002) |
| The chi-square statistic (Cramér's V is built on it) | — | [Wikipedia: Pearson's chi-squared test](https://en.wikipedia.org/wiki/Pearson%27s_chi-squared_test) |
| Correlation ratio (eta) | — | [Wikipedia](https://en.wikipedia.org/wiki/Correlation_ratio) |
| Kruskal–Wallis test (the rank-based duration measure) | — | [Wikipedia](https://en.wikipedia.org/wiki/Kruskal%E2%80%93Wallis_test) |
| Effect sizes in general | — | [Wikipedia](https://en.wikipedia.org/wiki/Effect_size) |
| R's `cor()` function | — | [R documentation](https://stat.ethz.ch/R-manual/R-devel/library/stats/html/cor.html) |

---

## The big picture

The script answers two questions, using **training cases only**:

1. **Which covariates say nearly the same thing as each other?** If two variables are almost perfectly related, such as court and circuit, keeping both adds little and can make a model unstable. This question is answered with an *association* for every pair of covariates.
2. **Which covariates are related to duration?** This is a first screen of which variables might matter. It isn't a model.

**Why not just use `cor()`?** `cor()` computes Pearson's correlation. That measures how well a *straight line* fits two *numeric* variables. Most covariates here are categories: court, nature of suit, judge group, arrival route. R stores categories internally as numbers (1, 2, 3, …), but the numbers are arbitrary. Alphabetising the courts differently would change `cor()`'s answer, which shows the answer means nothing. So the script uses a measure suited to each kind of pair:

| Kind of pair | Measure | Range | Rough meaning |
|---|---|---|---|
| number × number | \|Spearman\| | 0–1 | how well one variable's *ranking* predicts the other's |
| category × category | Cramér's V (bias-corrected) | 0–1 | how far the cross-table is from "no relationship" |
| number × category | eta (correlation ratio) | 0–1 | how much of the number's spread is explained by which category a case is in |

All three are 0 when there's no relationship and 1 when one variable fully determines the other. That's why they can share one table. They aren't on *exactly* the same scale, though: a Cramér's V of 0.3 and a Spearman of 0.3 aren't strictly comparable. Use them to rank and flag pairs, not as precise equivalents.

---

## Section 0 — Setup (lines 35–40)

```r
r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
if (!exists("population")) population <- "all"
source(file.path(r_dir, "00_sample.R"))
if (!file.exists(split_file)) stop("No holdout split ...")
out_dir <- file.path(project_dir, "feature_selection"); dir.create(out_dir, showWarnings = FALSE)
assoc_threshold <- 0.7
```

- **`Sys.getenv("SCALES_R_DIR", "~/scales_setup/r")`** reads an environment variable if one is set, and otherwise uses the FarmShare default. The variable is set only for testing on the Mac with fake data. On FarmShare you never need it.
- **`source(... "00_sample.R")`** runs the shared setup. It defines the sample, loads the holdout split and creates the database views, including `train_fjc`, which is all the training cases with their covariates.
- **`stop(...)` if there's no split.** This is a safety catch. Comparing covariates with duration is outcome analysis, which must only use training data, so the script refuses to run before the holdout exists.
- **`assoc_threshold <- 0.7`** is the cut-off for listing a pair as "possibly redundant". You can change it here; 0.7 is a common rule of thumb, not a law.

## Section 1 — The covariate list (lines 42–105)

```r
covariates <- read.csv(text = "
variable,type,leak
n_parties,numeric,partly
...
")
```

- **`read.csv(text = ...)`** reads a small table typed directly into the script, so the list is easy to edit: add a line, delete a line. Each row has three fields:
  - **`variable`:** the column name in `train_fjc`.
  - **`type`:** `numeric` for the four counts, `categorical` for everything else. Yes/no variables count as categorical with two levels.
  - **`leak`:** the leakage tier from EXPLAINER section 7. It's copied into the output so you see the warning next to the number:
    - `filing` means known when the case is filed.
    - `partly` means recorded later (tier C).
    - `leaky` means kept knowingly despite leakage (tier B).
- **`dbListFields(con, "train_fjc")`** asks the database which columns exist. Any listed variable that's missing is skipped with a warning rather than crashing the script. That usually means `01_build_features.R` hasn't been run.

## Section 2 — Reading the training data (lines 107–121)

```r
d <- dbGetQuery(con, sprintf("SELECT %s, duration_capped_days, event_observed FROM train_fjc
                              WHERE duration_capped_days IS NOT NULL", ...))
```

- **`dbGetQuery`** runs a SQL query in DuckDB and returns an ordinary R data frame, `d`. It holds about 318,500 rows, one per training case with a duration, and only the columns needed. That keeps memory use modest.
- **`sprintf("SELECT %s ...", paste(..., collapse = ", "))`** builds the column list from the covariate table, so editing the list in section 1 automatically changes what's read.

```r
for (v in cat_vars) d[[v]] <- factor(ifelse(is.na(d[[v]]), "(NA)", as.character(d[[v]])))
```

- **`factor()`** tells R that a column is a set of categories, not text or numbers. The functions below rely on this.
- **`ifelse(is.na(...), "(NA)", ...)`** turns any genuinely blank value into a visible "(NA)" category, so nothing silently disappears from the tables.

```r
missing_labels <- c("(NA)", "no FJC record", "not recorded", ...)
recorded <- setNames(lapply(covariates$variable, function(v)
  if (v %in% num_vars) !is.na(d[[v]]) else !(as.character(d[[v]]) %in% missing_labels)), covariates$variable)
```

- **`missing_labels`** lists the labels that mean "we don't know", as opposed to real categories. "Unassigned" and "no counsel listed" are real facts about a case, so they aren't in the list.
- **`recorded`** is a named list with one TRUE/FALSE vector per covariate: TRUE where that case's value is actually recorded. Read `recorded[["pro_se"]]` as "is pro se recorded for each case?". Sections 5 and 6 use it to leave out missing cases where that matters.
- **`lapply(..., function(v) ...)`** applies a small function to each covariate name and collects the results in a list. **`setNames`** labels the list entries with the variable names.

## The three measures (lines 123–151)

### `cramers_v(x, y)`: two categorical variables

```r
cramers_v <- function(x, y) {
  tab <- table(x, y); tab <- tab[rowSums(tab) > 0, colSums(tab) > 0, drop = FALSE]
  n <- sum(tab); r <- nrow(tab); k <- ncol(tab)
  if (r < 2 || k < 2) return(NA_real_)
  expected <- outer(rowSums(tab), colSums(tab)) / n
  chi2 <- sum((tab - expected)^2 / expected)
  phi2 <- max(0, chi2 / n - (k - 1) * (r - 1) / (n - 1))
  rc <- r - (r - 1)^2 / (n - 1); kc <- k - (k - 1)^2 / (n - 1)
  denom <- min(kc - 1, rc - 1); if (denom <= 0) return(NA_real_)
  sqrt(phi2 / denom)
}
```

Line by line:

1. **`table(x, y)`** makes a cross-table (contingency table): rows are the levels of `x`, columns the levels of `y`, and each cell counts the cases with that combination. The second half drops rows or columns that are all zero. `drop = FALSE` keeps it a table even if only one row is left.
2. **`n`, `r`, `k`:** total cases, number of rows, number of columns.
3. **If either variable has only one level,** there's nothing to relate, so the answer is `NA`.
4. **`expected`:** the count each cell *would* have if the two variables were unrelated, which is (row total × column total) / n. `outer()` computes that for every cell at once.
5. **`chi2`:** the [chi-square statistic](https://en.wikipedia.org/wiki/Pearson%27s_chi-squared_test). For each cell it takes (observed − expected)² / expected and adds them up. It's large when the table is far from "unrelated".
6. **`phi2`:** chi-square divided by n, which removes the effect of sample size, *minus a bias correction*. Even unrelated variables produce a little chi-square by chance, and more so with many levels. The term `(k−1)(r−1)/(n−1)` subtracts the amount expected from chance alone. `max(0, ...)` stops the result going negative.
7. **`rc`, `kc`, `denom`:** the corrected number of rows and columns. Plain Cramér's V divides by min(r−1, k−1), the largest value phi² can reach. Bergsma's correction adjusts that maximum in the same way.
8. **`sqrt(phi2 / denom)`:** the final V, between 0 and 1.

**Why the bias correction matters here:** court has 94 levels, city 286 and judge group about 1,500. Uncorrected Cramér's V creeps upwards with more levels even when nothing is going on, so many-level variables would look related to everything. The correction ([Bergsma 2013](https://doi.org/10.1016/j.jkss.2012.10.002); summary on [Wikipedia](https://en.wikipedia.org/wiki/Cram%C3%A9r%27s_V#Bias_correction)) removes most of that.

**Known quirk, and why section 5 leaves out missing values:** if two variables share a level in exactly the same cases, such as "no FJC record", that one shared level forces V to at least about 0.71 for three-level variables, however rare the level is. Change 38 in `CHANGES.md` describes how this showed up in the real data and how it was fixed.

**Tiny example:** pro se (yes/no) against in forma pauperis (yes/no) in 100 cases.

|  | IFP yes | IFP no |
|---|---|---|
| pro se yes | 18 | 2 |
| pro se no | 7 | 73 |

If the two were unrelated, the "pro se yes, IFP yes" cell would expect 20 × 25 / 100 = 5 cases, but it has 18. Differences like that produce a large chi-square, and V comes out around 0.75: strongly related.

### `eta(num, f)`: a number and a categorical variable

```r
eta <- function(num, f) {
  ok <- !is.na(num); num <- num[ok]; f <- droplevels(f[ok])
  if (length(unique(num)) < 2 || nlevels(f) < 2) return(NA_real_)
  m <- mean(num); g <- tapply(num, f, mean); ng <- tapply(num, f, length)
  sqrt(sum(ng * (g - m)^2, na.rm = TRUE) / sum((num - m)^2))
}
```

1. **Keep only cases where the number isn't missing.** `droplevels` removes categories with no cases left.
2. **If the number never varies, or there's only one category,** return `NA`.
3. **`m`:** the overall mean. **`tapply(num, f, mean)`:** the mean within each category. **`ng`:** how many cases are in each category.
4. **The formula:** between-group spread ÷ total spread, then the square root.
   - The bottom, `sum((num - m)^2)`, is the *total spread*: how far every case is from the overall mean.
   - The top, `sum(ng * (g - m)^2)`, is the *between-group spread*: how far each category's mean is from the overall mean, weighted by its size.
   - The ratio is the share of the total spread that "which category are you in" explains. Eta² is exactly the R² you'd get from regressing the number on the category as dummy variables, and eta is its square root. The test on fake data checked that it matches `lm()`.

**Example:** if cases in different courts had *exactly* the same average duration, the top would be 0, so eta = 0. If every case in a court lasted exactly that court's average, all the spread would be between courts, so eta = 1.

### `assoc(a, b)`: choose the right measure for a pair

```r
assoc <- function(a, b) {
  ta <- ...; tb <- ...                                   # the two types
  ok <- recorded[[a]] & recorded[[b]]; x <- d[[a]][ok]; y <- d[[b]][ok]
  ...
  if (ta == "numeric" && tb == "numeric")  -> |Spearman|
  if (ta == "categorical" && tb == "categorical") -> Cramer's V
  otherwise -> eta (the numeric one goes first)
}
```

- **`ok <- recorded[[a]] & recorded[[b]]`** keeps only cases where *both* variables are recorded. This is the change 38 fix.
- **`cor(x, y, method = "spearman")`:** [Spearman's correlation](https://statistics.laerd.com/statistical-guides/spearmans-rank-order-correlation-statistical-guide.php) is Pearson's correlation computed on the *ranks* (1st, 2nd, 3rd, …) instead of the raw values. Reasons to use it here:
  - The counts are very skewed: most cases have 2–3 parties, a few have hundreds. With Pearson, those few cases would dominate the result.
  - Ranks don't care how extreme the largest values are.
  - Spearman also catches relationships that are consistently upward or downward but not straight lines.
- **`abs()`:** the sign (positive or negative) is dropped so Spearman sits on the same 0–1 scale as V and eta. The signed values are kept in `fs_spearman_numeric.csv`.
- The function returns three things: which measure was used, its value, and `n_both`, the number of cases used.

## Section 3 — One row per covariate (lines 153–160) → `fs_covariates.csv`

| Column | Meaning | Why it matters |
|---|---|---|
| `n_levels` | number of categories | Many-level variables, like judge group with about 1,500, can fit noise. They need many cases per level. |
| `smallest_level_n` | number of cases in the rarest category | Tiny levels give unstable estimates and may be worth merging |
| `pct_missing_or_NA` | % of cases with a missing label | High values limit what the variable can tell you |
| `note` | "CONSTANT …" if the variable never varies | A constant carries no information |

- **`vapply(..., 1L)`** is like `lapply`, but promises that each answer is a single number, so the results can go straight into a column.

## Section 4 — Spearman matrix for the counts (lines 162–166) → `fs_spearman_numeric.csv`

```r
sp <- round(suppressWarnings(cor(d[num_vars], method = "spearman", use = "pairwise.complete.obs")), 3)
```

- **Given a whole data frame,** `cor()` returns a matrix comparing every column with every other. This is the one place `cor()` is used on its own, because these four columns really are numbers. The values keep their sign.
- **`use = "pairwise.complete.obs"`:** for each pair, use the cases where both values are present. Without it, a single missing value makes the whole answer `NA`.
- **`suppressWarnings`** hides R's warning when a column never varies. That case is flagged in section 3 instead.

## Section 5 — Every pair of covariates (lines 168–184)

```r
pairs <- t(combn(vars, 2))
res <- do.call(rbind, lapply(seq_len(nrow(pairs)), function(i) { a <- assoc(...); data.frame(...) }))
```

- **`combn(vars, 2)`** lists every possible pair of the 35 covariates: 35 × 34 / 2 = 595 pairs. `t()` turns the result so there's one pair per row.
- **`lapply(... assoc ...)`** computes the association for each pair and puts it in a one-row data frame. **`do.call(rbind, ...)`** stacks all those rows into one table.

Outputs:
- **`fs_association_matrix.csv`:** all 595 pairs, strongest first, with `n_both`.
- **`fs_high_pairs.csv`:** only the pairs at or above `assoc_threshold`.
- **`fs_association_square.csv`:** the same numbers as a 35 × 35 grid, which is easier to scan in Excel. The diagonal is 1, since every variable is perfectly related to itself.

**How to read a high pair:**
- **Is one variable a finer version of the other?** For example court inside circuit, or `cause_group` built from `cause_title`. Then it's a choice of how much detail to keep, not a discovery.
- **Is it a real-world relationship?** For example pro se and in forma pauperis. Then decide whether both add something.

## Section 6 — Each covariate against duration (lines 186–211) → `fs_dv_association.csv`

```r
ended <- d$event_observed %in% TRUE
e <- d[ended, ]
```

- **Only cases that ended in court are used** (`event_observed` TRUE). Transferred-out cases are *censored*: we don't know how long they would have lasted, so a simple comparison can't include them fairly. A survival model can, which is one reason this table is a screen, not the final analysis.
- **`%in% TRUE`** rather than `== TRUE` means a missing `event_observed` counts as FALSE instead of producing `NA`.

```r
dv_measure <- function(v, keep) {
  ...
  c(rank = round(eta(rank(e$duration_capped_days[keep]), x), 3),
    log  = round(eta(y_log[keep], x), 3))
}
```

Two versions of duration are used for categorical covariates:

- **`rank`:** each case's duration is replaced by its rank among the cases (`rank()`; ties share the average rank), and eta is computed on the ranks. This is equivalent to the effect size of a [Kruskal–Wallis test](https://en.wikipedia.org/wiki/Kruskal%E2%80%93Wallis_test): eta on ranks = √(H / (n − 1)). The fake-data test checked this against `kruskal.test()`.
  - **Advantage:** you don't have to decide on a scale for duration (days, log days and so on), because any scale that keeps cases in the same order gives the same ranks.
- **`log`:** eta on log(1 + days) (`log1p`). The log puts durations on a ratio scale, so 30 → 60 days counts the same as 1,000 → 2,000. Adding 1 keeps 0-day cases from breaking it.
  - **Caution:** the log stretches out the short end, so it gives a lot of weight to a cluster of very quick cases.

For the four counts, both columns are |Spearman| with duration, which is already rank-based.

```r
all_cases <- dv_measure(v, rep(TRUE, nrow(e)))
rec_cases <- dv_measure(v, recorded[[v]][ended])
```

- **`_all`:** every ended case. Missing labels such as "no FJC record" count as a category of their own. That's legitimate, since a model can use them.
- **`_recorded`:** only cases where the covariate is recorded.
- **How to read the pair:** if a variable scores high in `_all` but drops sharply in `_recorded`, its signal comes from the *missing* category, not its actual content. Change 39 records the real example: class action fell from 0.335 to 0.032. That's what prompted `02-a_data_checks_fjc.R`.

```r
dv <- merge(dv, covariates[, c("variable", "type", "leak", "n_levels")], by = "variable")
dv <- dv[order(-dv$rank_all), ]
```

- **`merge`** attaches the leakage tier and level count to each row. **`order(-x)`** sorts from largest to smallest, and missing values go last.

**Three cautions for this table:**
1. **Leaky variables will look good.** `n_counsel`, `judge_group` and `defendant_firm_rank` partly reflect how long the case ran. A high score for a `leaky` variable is a warning, not a recommendation.
2. **Many levels inflate eta somewhat.** With k categories and n cases, eta² is about (k − 1) / n from chance alone. For judge group (k ≈ 1,500, n ≈ 300,000) that's about 0.005, so eta ≈ 0.07 from noise. That's small compared with the 0.44 observed, but worth remembering.
3. **These are one-at-a-time associations.** Two variables can each look strong only because they overlap, like court and judge group. A model fitted on several variables together is what tells you their separate contributions.

## Section 7 — The printout (lines 213–223)

The headline tables print to the console. Everything is also saved in `~/scales_project/feature_selection/`.

---

## Quick reference: R functions used

| Function | What it does here |
|---|---|
| `dbGetQuery(con, sql)` | Runs SQL in DuckDB and returns a data frame |
| `sprintf("...%s...", x)` | Fills `x` into a text template (used to build SQL) |
| `factor()`, `droplevels()`, `nlevels()` | Mark a column as categories; drop unused ones; count them |
| `table(x, y)` | Cross-tabulate two categorical variables |
| `outer(a, b)` | Every product a[i] × b[j]: the expected counts |
| `tapply(x, f, mean)` | The mean of `x` within each category of `f` |
| `cor(x, y, method = "spearman")` | Spearman's rank correlation |
| `rank(x)` | Replace values by their ranks |
| `log1p(x)` | log(1 + x) |
| `combn(v, 2)` | All pairs from a list |
| `lapply`, `vapply`, `do.call(rbind, ...)` | Apply a function to each item; stack the results |
| `merge(a, b, by = )` | Join two tables on a shared column |
| `write.csv(x, file, row.names = FALSE)` | Save a table as CSV |
