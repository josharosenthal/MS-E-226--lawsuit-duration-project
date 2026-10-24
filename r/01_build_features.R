# =============================================================================
# 01_build_features.R — build the case-level covariates Josh chose in
# covariates.xlsx, ONCE, and save them to
#     ~/scales_project/parquet/case_features.parquet   (one row per case)
# 00_sample.R joins this file automatically when it exists.
#
# Covers every 2016-17 civil case (the base sample plus the excluded habeas and
# 1983pr cases), so the features are the same whatever population is chosen.
# None of these use the dependent variable or the holdout split. (The two
# features that depend on the TRAINING data - judge_group and cause_group -
# are made in 00_sample.R instead.)
#
# Run it again if the case tables, the FJC link or the reference files change.
# Takes several minutes: it reads ~23 million docket entries.
#
# Features (see covariates.xlsx and CHANGES.md):
#   case_number_parity       odd / even: last digit of the case sequence number
#   any_referral             TRUE if referred to a magistrate judge (leaks; Josh's choice)
#   has_related_case         TRUE if related cases are listed
#   is_consolidated          has a lead case: consolidation_role is lead or member
#   consolidation_role       lead / member / not consolidated (from lead_case_id)
#   mdl_any                  MDL member per SCALES is_mdl OR FJC ORIGIN 6 / 13
#   circuit                  federal circuit (from the FJC file)
#   diversity_residence      plaintiff+defendant citizenship code (diversity cases),
#                            "not diversity", or "diversity, not recorded"
#   county_area_class        urban / suburban / rural / US territory / out of state / non-US,
#                            from the first plaintiff's county (FJC) and NCHS 2013
#   senior_judge_at_filing   senior / active / appointed after filing / magistrate /
#                            unassigned / territorial court / not matched
#   judge_visiting           TRUE if the judge sits by designation from another court
#   n_plaintiffs, n_defendants
#   first_plaintiff_type, first_defendant_type   entity type guessed from the name:
#                            federal government / state or local government /
#                            business / other organization / individual
#   plaintiff_firm_cases     4 levels: firm of the first plaintiff's lead attorney,
#                            by how many cases that firm appears in (1-10, 11-20,
#                            21-50, over 50), or pro se / no counsel, no firm listed
#   defendant_firm_rank      first defendant's lead attorney's firm, by BCG
#                            headcount rank bucket (1-20, 21-40, ...), not in list,
#                            or no counsel listed
#   plaintiff_org_attorney   TRUE if any plaintiff-side attorney has a .org email
#   tro_pi_motion_60d        TRUE if a TRO or preliminary-injunction motion was
#                            filed within 60 days of filing
#   amicus                   TRUE if an amicus appears (docket text or party role);
#                            leaks duration (Josh's choice)
# Plus a report, ~/scales_project/checks/features_report_*.csv, with coverage,
# match rates and examples to check by hand.
# =============================================================================

r_dir <- path.expand(Sys.getenv("SCALES_R_DIR", "~/scales_setup/r"))
population <- "all"
source(file.path(r_dir, "00_sample.R"))
ref_dir    <- file.path(dirname(r_dir), "reference")
checks_dir <- file.path(project_dir, "checks"); dir.create(checks_dir, showWarnings = FALSE)
for (f in c("fjc_district_judges.csv", "nchs_urban_rural_2013.csv", "large_firms_bcg_2026.csv"))
  if (!file.exists(file.path(ref_dir, f))) stop("Missing reference file ", file.path(ref_dir, f),
                                                 " - copy the reference/ folder to FarmShare.")
rq <- function(f) file.path(ref_dir, f)
step <- function(msg) cat(format(Sys.time(), "%H:%M:%S"), msg, "\n")

# Firm-name cleaning (SQL). firm_match: lower case, no accents or punctuation,
# and the words "&" / "and" removed ("Kirkland & Ellis LLP" -> "kirkland ellis llp");
# used to match the large-firm list, whose prefixes are cleaned the same way.
# firm_key: firm_match without legal-entity endings (LLP, P.C., PLLC, ...), so
# "Mid Firm P.C." and "Mid Firm PC" count as one firm; used to count cases.
clean_sql <- function(x) sprintf(
  "trim(regexp_replace(regexp_replace(regexp_replace(' ' || trim(regexp_replace(regexp_replace(
     replace(replace(lower(strip_accents(coalesce(CAST(%s AS VARCHAR), ''))), '+', ' & '), '&', ' & '),
     '[^a-z0-9& ]+', ' ', 'g'), ' +', ' ', 'g')) || ' ', ' (& )+', ' ', 'g'), ' (and )+', ' ', 'g'), ' +', ' ', 'g'))", x)
key_sql <- function(x) sprintf(
  "trim(regexp_replace(%s, '( (llp|llc|pllc|pc|p c|lp|l p|ltd|chartered|chtd|pa|p a|plc|sc|s c|apc|a p c|professional corporation|a professional corporation|a professional law corporation))+$', ''))", x)

# ---- Base: every 2016-17 civil case, with its best FJC record -----------------
step("cases")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_cases AS
  SELECT c.ucid, c.court, CAST(c.case_id AS VARCHAR) AS case_id, c.filing_date,
         CAST(c.judge AS VARCHAR) AS judge, CAST(c.lead_case_id AS VARCHAR) AS lead_case_id, c.is_mdl,
         CAST(c.referred_judges_json AS VARCHAR) AS referred_judges_json,
         CAST(c.related_cases_json AS VARCHAR) AS related_cases_json,
         l.fjc_row, l.JURIS, l.ORIGIN
  FROM civil_cases c
  LEFT JOIN (SELECT * FROM '%s/scales_fjc_link.parquet' WHERE fjc_rank = 1) l USING (ucid)", pq))

# ---- Simple case-level features --------------------------------------------------
step("case-level features")
# Consolidation, from SCALES lead_case_id only (not is_multi, which turned out to
# flag ANY docket that refers to another case number - removal and transfer
# origins too; see CHANGES.md change 31):
#   member            lead_case_id names a different case
#   lead              another case in the same court names this one as its lead
#                     (or lead_case_id names itself)
#   not consolidated  neither
dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_cases AS
  WITH k AS (
    SELECT *,
      regexp_extract(case_id, '([0-9]{2})-[a-z]{2}-', 1) || '-' || ltrim(regexp_extract(case_id, '-[a-z]{2}-([0-9]+)', 1), '0') AS own_key,
      CASE WHEN nullif(trim(lead_case_id), '') IS NOT NULL
           THEN regexp_extract(lead_case_id, '([0-9]{2})-[a-z]{2}-', 1) || '-' || ltrim(regexp_extract(lead_case_id, '-[a-z]{2}-([0-9]+)', 1), '0') END AS lead_key
    FROM f_cases),
  leads AS (SELECT DISTINCT court, lead_key FROM k WHERE lead_key IS NOT NULL AND lead_key <> own_key)
  SELECT k.* EXCLUDE (own_key, lead_key),
    CASE WHEN k.lead_key = k.own_key OR l.lead_key IS NOT NULL THEN 'lead'
         WHEN k.lead_key IS NOT NULL                          THEN 'member'
         ELSE 'not consolidated' END AS consolidation_role
  FROM k LEFT JOIN leads l ON l.court = k.court AND l.lead_key = k.own_key")

dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_simple AS
  SELECT ucid,
    CASE WHEN regexp_matches(case_id, '-cv-[0-9]+')
         THEN CASE WHEN TRY_CAST(right(regexp_extract(case_id, '-cv-([0-9]+)', 1), 1) AS INTEGER) % 2 = 0
                   THEN 'even' ELSE 'odd' END END AS case_number_parity,
    coalesce(trim(CAST(referred_judges_json AS VARCHAR)) NOT IN ('', '[]'), false) AS any_referral,
    coalesce(trim(CAST(related_cases_json AS VARCHAR)) NOT IN ('', '[]'), false)  AS has_related_case,
    coalesce(is_mdl, false) OR coalesce(trim(ORIGIN) IN ('6', '13'), false) AS mdl_any,
    consolidation_role,
    consolidation_role <> 'not consolidated' AS is_consolidated
  FROM f_cases")

# ---- FJC-based: circuit, diversity residence, county area class -------------------
step("FJC fields: circuit, residence, county")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_fjc AS
  WITH circ AS (
    SELECT x.scales_court AS court, mode(trim(fj.CIRCUIT)) AS circuit
    FROM '%s/fjc_idb_civil.parquet' fj
    JOIN read_csv('%s', all_varchar = true) x ON x.fjc_district = lpad(upper(trim(fj.DISTRICT)), 2, '0')
    GROUP BY 1),
  nchs AS (SELECT * FROM read_csv('%s', all_varchar = true)),
  rec AS (
    SELECT c.ucid, c.court, c.JURIS, trim(fj.RESIDENC) AS residenc,
           -- 12025 is Dade County's FIPS code before 1997; it is now Miami-Dade, 12086
           CASE lpad(trim(fj.COUNTY), 5, '0') WHEN '12025' THEN '12086' ELSE lpad(trim(fj.COUNTY), 5, '0') END AS county
    FROM f_cases c LEFT JOIN '%s/fjc_idb_civil.parquet' fj ON fj.fjc_row = c.fjc_row)
  SELECT r.ucid,
    ci.circuit,
    CASE WHEN r.JURIS IS NULL                 THEN NULL
         WHEN trim(r.JURIS) <> '4'            THEN 'not diversity'
         WHEN regexp_matches(r.residenc, '^[1-6]{2}$') THEN r.residenc
         ELSE 'diversity, not recorded' END AS diversity_residence,
    CASE WHEN r.county IS NULL OR r.county IN ('00000', '000-8', '   -8') THEN NULL
         WHEN r.county = '88888'              THEN 'out of state'
         WHEN r.county = '99999'              THEN 'non-US'
         WHEN n.area_class IS NOT NULL        THEN n.area_class
         -- territories aren't in the NCHS scheme: Puerto Rico 72, Guam 66, Virgin
         -- Islands 78, American Samoa 60, Northern Mariana Islands 69
         WHEN left(r.county, 2) IN ('72', '66', '78', '60', '69') THEN 'US territory'
         ELSE 'unmatched county code' END AS county_area_class,
    r.county AS fjc_county_code
  FROM rec r LEFT JOIN circ ci USING (court) LEFT JOIN nchs n ON n.fips = r.county",
  pq, file.path(dirname(r_dir), "fjc_district_crosswalk.csv"), rq("nchs_urban_rural_2013.csv"), pq))

# ---- Judge at filing: senior / active / ... (FJC Biographical Directory) -------------
# SCALES's judge field is the judge when SCALES COLLECTED the case (2020-21), not
# necessarily the judge at filing. Each (court, judge name) is classified as:
#   unassigned            the field says Unassigned / Not Assigned (see 00_sample.R)
#   magistrate            "Magistrate" in the name, OR the surname is one of this
#                         court's magistrate judges, learned from SCALES's referral
#                         lists (referred_judges_json) and "Magistrate Judge ..." names
#   matched               an Article III judge of THIS court in the FJC directory
#   visiting              not in this court, but exactly one match in another court
#                         (judges sitting by designation, e.g. a D. Hawaii judge in W.D. Tex.)
#   territorial court     Guam, Virgin Islands, Northern Mariana Islands (not Article III)
#   not matched           none of the above
# For matched / visiting judges, per case:
#   appointed after filing   commissioned after the case was filed, so the case was
#                            REASSIGNED during its life (partly reflects duration - leaks);
#                            unless the judge was this court's magistrate then ("magistrate")
#   senior / active          senior status taken before / after the filing date
# Surnames must equal the last 1-3 words of the SCALES name; ties are broken by
# first name or initial. Names are converted from UTF-8 explicitly, so accents
# work even when R runs with a plain-ASCII locale (e.g. Sanchez / Sánchez).
step("judge at filing")
norm_words <- function(x) {
  x <- iconv(enc2utf8(as.character(x)), from = "UTF-8", to = "ASCII//TRANSLIT", sub = "")
  x <- tolower(gsub("['`^~\"]", "", x))           # some systems transliterate á as 'a
  x <- gsub("[^a-z ]", " ", x)
  w <- strsplit(trimws(gsub(" +", " ", x)), " ")[[1]]
  setdiff(w, c("judge", "honorable", "hon", "chief", "senior", "district", "us", "u", "s", "the",
               "presiding", "jr", "sr", "ii", "iii", "iv", "united", "states", "court", "of",
               "magistrate", "mag"))
}
jdir <- read.csv(rq("fjc_district_judges.csv"), colClasses = "character", encoding = "UTF-8")
jdir$last_key  <- vapply(jdir$last_name,  function(x) paste(norm_words(x), collapse = ""), "")
jdir$first_key <- vapply(jdir$first_name, function(x) paste(norm_words(x), collapse = ""), "")
territorial <- c("gud", "vid", "nmid")

# Each court's magistrate surnames, from referral lists and "Magistrate Judge ..." names
mag_names <- dbGetQuery(con, "
  SELECT court, unnest(regexp_extract_all(referred_judges_json, '\"([^\"]+)\"', 1)) AS name
  FROM f_cases WHERE referred_judges_json IS NOT NULL
  UNION ALL
  SELECT court, judge FROM f_cases WHERE regexp_matches(lower(coalesce(judge, '')), 'magistrate')")
mag_names <- mag_names[nchar(mag_names$name) > 3 & !grepl("^(name|judge|role|type)$", tolower(mag_names$name)), ]
mag_keys <- unique(do.call(rbind, lapply(seq_len(nrow(mag_names)), function(i) {
  w <- norm_words(mag_names$name[i]); if (!length(w)) return(NULL)
  data.frame(court = mag_names$court[i], key = c(tail(w, 1), paste(tail(w, 2), collapse = "")))
})))
in_mag_set <- function(court, w) {
  if (is.null(mag_keys) || !length(w)) return(FALSE)
  any(paste(court, c(tail(w, 1), paste(tail(w, 2), collapse = ""))) %in% paste(mag_keys$court, mag_keys$key))
}

pairs <- dbGetQuery(con, "SELECT court, judge, count(*) AS n FROM f_cases WHERE judge IS NOT NULL AND trim(judge) <> '' GROUP BY 1, 2")
find_judge <- function(cand, w) {                  # one FJC judge whose surname ends the name
  for (k in 1:min(3, length(w))) {
    hit <- cand[cand$last_key == paste(tail(w, k), collapse = ""), ]
    if (length(unique(hit$fjc_judge_id)) > 1) {
      f <- w[1]
      h2 <- hit[hit$first_key == f, ]; if (!nrow(h2)) h2 <- hit[substr(hit$first_key, 1, 1) == substr(f, 1, 1), ]
      hit <- h2
    }
    if (nrow(hit) >= 1 && length(unique(hit$fjc_judge_id)) == 1)
      return(hit[order(hit$commission_date, decreasing = TRUE), ][1, ])
  }
  NULL
}
none <- list(kind = "not matched", id = NA_character_, service_court = NA_character_, mag = FALSE)
match_one <- function(court, judge) {
  if (grepl(unassigned_pattern, tolower(judge))) return(modifyList(none, list(kind = "unassigned")))
  if (grepl("magistrate", judge, ignore.case = TRUE)) return(modifyList(none, list(kind = "magistrate")))
  w <- norm_words(judge); if (!length(w)) return(none)
  mag <- in_mag_set(court, w)
  hit <- find_judge(jdir[jdir$scales_court == court, ], w)
  if (!is.null(hit)) return(list(kind = "matched", id = hit$fjc_judge_id, service_court = hit$scales_court, mag = mag))
  if (mag) return(modifyList(none, list(kind = "magistrate")))
  if (court %in% territorial) return(modifyList(none, list(kind = "territorial court")))
  hit <- find_judge(jdir, w)
  if (!is.null(hit)) return(list(kind = "visiting", id = hit$fjc_judge_id, service_court = hit$scales_court, mag = FALSE))
  none
}
m <- mapply(match_one, pairs$court, pairs$judge, SIMPLIFY = FALSE)
pairs$match_kind    <- vapply(m, function(x) x$kind, "")
pairs$fjc_judge_id  <- vapply(m, function(x) as.character(x$id), "")
pairs$service_court <- vapply(m, function(x) as.character(x$service_court), "")
pairs$in_magistrate_set <- vapply(m, function(x) isTRUE(x$mag), TRUE)
dbWriteTable(con, "f_judge_pairs", pairs, temporary = TRUE, overwrite = TRUE)
dbWriteTable(con, "f_jdir", jdir, temporary = TRUE, overwrite = TRUE)
dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_senior AS
  SELECT c.ucid,
    CASE WHEN c.judge IS NULL OR trim(c.judge) = ''           THEN NULL
         WHEN p.match_kind IN ('unassigned', 'magistrate', 'territorial court') THEN p.match_kind
         WHEN p.match_kind NOT IN ('matched', 'visiting') OR s.fjc_judge_id IS NULL THEN 'not matched'
         WHEN c.filing_date IS NULL                            THEN NULL
         WHEN TRY_CAST(s.commission_date AS DATE) > c.filing_date
              THEN CASE WHEN p.in_magistrate_set THEN 'magistrate' ELSE 'appointed after filing' END
         WHEN nullif(trim(s.senior_status_date), '') IS NOT NULL
              AND TRY_CAST(s.senior_status_date AS DATE) <= c.filing_date THEN 'senior'
         ELSE 'active' END AS senior_judge_at_filing,
    p.match_kind = 'visiting' AS judge_visiting
  FROM f_cases c
  LEFT JOIN f_judge_pairs p ON p.court = c.court AND p.judge = c.judge
  LEFT JOIN (SELECT DISTINCT ON (fjc_judge_id, scales_court) * FROM f_jdir ORDER BY fjc_judge_id, scales_court, commission_date DESC) s
         ON s.fjc_judge_id = p.fjc_judge_id AND s.scales_court = p.service_court")

# ---- Parties: counts, entity type of the first plaintiff / defendant, amicus -------
step("parties")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_parties AS
  SELECT p.ucid, p.party_index, p.name, lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))) AS role_l,
    CASE WHEN regexp_matches(lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))), '^(plaintiff|petitioner)') THEN 'P'
         WHEN regexp_matches(lower(trim(coalesce(CAST(p.role AS VARCHAR), ''))), '^(defendant|respondent)') THEN 'D'
         WHEN lower(coalesce(CAST(p.party_type AS VARCHAR), '')) LIKE 'plaintiff%%' THEN 'P'
         WHEN lower(coalesce(CAST(p.party_type AS VARCHAR), '')) LIKE 'defendant%%' THEN 'D' END AS side
  FROM '%s/parties.parquet' p WHERE p.ucid IN (SELECT ucid FROM f_cases)", pq))
entity_sql <- "CASE
  WHEN regexp_matches(n, '(^|[^a-z])(united states|usa|u s a|commissioner of social security|social security administration|internal revenue service|secretary of (homeland|labor|state|health|veterans|the army|the navy|the air force|defense|agriculture|education|transportation|the treasury|treasury|commerce|energy|the interior|interior|housing)|federal bureau|federal (deposit|trade|communications|election)|u s (department|dept|attorney|citizenship|immigration|customs|marshal)|department of homeland security|department of justice|department of labor|department of veterans affairs|equal employment opportunity commission|eeoc|securities and exchange commission|drug enforcement|bureau of prisons|immigration and customs)([^a-z]|$)') THEN 'federal government'
  WHEN regexp_matches(n, '(^|[^a-z])(state of|commonwealth of|people of the state|county|city of|village of|town of|township|borough|parish|municipal|police department|sheriff|board of education|school district|department of corrections|department of (public|human|children|revenue|transportation|motor)|state police|department of state police|authority|board of (regents|trustees|commissioners))([^a-z]|$)') THEN 'state or local government'
  WHEN regexp_matches(n, '(^|[^a-z])(inc|incorporated|llc|l l c|corp|corporation|company|co|ltd|limited|lp|l p|llp|pllc|plc|n a|bank|bancorp|holdings|group|insurance|assurance|services|enterprises|partners|associates|industries|technologies|systems|motors|financial|capital|properties|realty|gmbh|ag|s a|sa|bv|trust company)([^a-z]|$)') THEN 'business'
  WHEN regexp_matches(n, '(^|[^a-z])(association|union|foundation|church|society|council|committee|club|institute|university|college|hospital|center|centre|trust|fund|organization|alliance|coalition|league|federation|ministries|diocese|academy|school)([^a-z]|$)') THEN 'other organization'
  WHEN n = '' THEN NULL
  ELSE 'individual' END"
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_party_feats AS
  WITH typed AS (
    SELECT *, %s AS entity_type
    FROM (SELECT *, trim(regexp_replace(lower(strip_accents(coalesce(name, ''))), '[^a-z]+', ' ', 'g')) AS n
          FROM f_parties)),
  firstp AS (SELECT DISTINCT ON (ucid, side) ucid, side, party_index, entity_type
             FROM typed WHERE side IS NOT NULL ORDER BY ucid, side, party_index)
  SELECT c.ucid,
    count(t.ucid) FILTER (WHERE t.side = 'P') AS n_plaintiffs,
    count(t.ucid) FILTER (WHERE t.side = 'D') AS n_defendants,
    any_value(fp.entity_type) AS first_plaintiff_type,
    any_value(fd.entity_type) AS first_defendant_type,
    coalesce(bool_or(t.role_l LIKE '%%amicus%%'), false) AS amicus_party
  FROM f_cases c
  LEFT JOIN typed t USING (ucid)
  LEFT JOIN (SELECT * FROM firstp WHERE side = 'P') fp USING (ucid)
  LEFT JOIN (SELECT * FROM firstp WHERE side = 'D') fd USING (ucid)
  GROUP BY 1", entity_sql))

# ---- Counsel: plaintiff firm experience, defendant firm rank, .org attorney -------
step("counsel and firms")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_counsel AS
  SELECT k.ucid, k.party_index, k.counsel_index, coalesce(k.is_lead_attorney, false) AS is_lead,
         coalesce(k.is_pro_se, false) AS is_pro_se, %s AS firm_match,
         lower(trim(coalesce(CAST(k.email AS VARCHAR), ''))) AS email_l
  FROM '%s/counsel.parquet' k WHERE k.ucid IN (SELECT ucid FROM f_cases)", clean_sql("k.office_name"), pq))
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_counsel AS SELECT *, %s AS firm FROM f_counsel", key_sql("firm_match")))
# how many cases each cleaned firm name appears in (any side, all 2016-17 civil cases)
dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_firm_counts AS
  SELECT firm, count(DISTINCT ucid) AS n_cases FROM f_counsel WHERE firm <> '' GROUP BY 1")
firms <- read.csv(rq("large_firms_bcg_2026.csv"), colClasses = "character")
drop_and <- function(x) trimws(gsub(" +", " ", gsub(" (& |and )+", " ", paste0(" ", x, " "))))
fp <- do.call(rbind, lapply(seq_len(nrow(firms)), function(i)
  data.frame(prefix = drop_and(trimws(strsplit(firms$match_prefixes[i], "|", fixed = TRUE)[[1]])),
             bcg_firm = firms$firm[i], rank_bucket = firms$rank_bucket[i])))
fp <- fp[!duplicated(fp$prefix), ]
dbWriteTable(con, "f_big_firms", fp, temporary = TRUE, overwrite = TRUE)
dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_firm_feats AS
  WITH first_party AS (
    SELECT DISTINCT ON (ucid, side) ucid, side, party_index FROM f_parties
    WHERE side IS NOT NULL ORDER BY ucid, side, party_index),
  lead AS (                      -- the first party's lead attorney (or first-listed one)
    SELECT DISTINCT ON (fp.ucid, fp.side) fp.ucid, fp.side, k.firm, k.firm_match, k.is_pro_se, k.counsel_index
    FROM first_party fp LEFT JOIN f_counsel k ON k.ucid = fp.ucid AND k.party_index = fp.party_index
    ORDER BY fp.ucid, fp.side, k.is_lead DESC, k.counsel_index NULLS LAST),
  big AS (                       -- longest matching large-firm prefix
    SELECT DISTINCT ON (l.ucid) l.ucid, b.bcg_firm, b.rank_bucket
    FROM lead l JOIN f_big_firms b
      ON l.side = 'D' AND (l.firm_match = b.prefix OR starts_with(l.firm_match, b.prefix || ' '))
    ORDER BY l.ucid, length(b.prefix) DESC)
  SELECT c.ucid,
    CASE WHEN p.ucid IS NULL                          THEN NULL
         WHEN p.counsel_index IS NULL OR p.is_pro_se  THEN 'pro se / no counsel'
         WHEN coalesce(p.firm, '') = ''               THEN 'no firm listed'
         WHEN fc.n_cases <= 10 THEN '1-10 cases'  WHEN fc.n_cases <= 20 THEN '11-20 cases'
         WHEN fc.n_cases <= 50 THEN '21-50 cases' ELSE 'over 50 cases' END AS plaintiff_firm_cases,
    CASE WHEN d.ucid IS NULL                          THEN NULL
         WHEN d.counsel_index IS NULL OR d.is_pro_se  THEN 'no counsel listed'
         WHEN big.rank_bucket LIKE 'listed%'           THEN 'large-firm list, headcount not given'
         WHEN big.rank_bucket IS NOT NULL             THEN 'rank ' || big.rank_bucket
         ELSE 'not in list' END AS defendant_firm_rank,
    big.bcg_firm AS defendant_bcg_firm,
    p.firm AS plaintiff_firm_clean, d.firm_match AS defendant_firm_clean
  FROM f_cases c
  LEFT JOIN (SELECT * FROM lead WHERE side = 'P') p USING (ucid)
  LEFT JOIN (SELECT * FROM lead WHERE side = 'D') d USING (ucid)
  LEFT JOIN f_firm_counts fc ON fc.firm = p.firm
  LEFT JOIN big USING (ucid)")
dbExecute(con, "CREATE OR REPLACE TEMP TABLE f_org AS
  SELECT c.ucid, coalesce(bool_or(k.email_l LIKE '%.org'), false) AS plaintiff_org_attorney
  FROM f_cases c
  LEFT JOIN f_parties p ON p.ucid = c.ucid AND p.side = 'P'
  LEFT JOIN f_counsel k ON k.ucid = p.ucid AND k.party_index = p.party_index
  GROUP BY 1")

# ---- Docket: TRO / preliminary injunction within 60 days; amicus ----------------
step("docket entries (the slow part)")
dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE f_docket AS
  SELECT d.ucid,
    bool_or(regexp_matches(lower(d.docket_text),
              '(motion|application|petition|request)[^.;]{0,80}(temporary restraining order|preliminary injunction|(^|[^a-z])tro([^a-z]|$))')
            AND d.date_filed IS NOT NULL AND c.filing_date IS NOT NULL
            AND date_diff('day', c.filing_date, d.date_filed) BETWEEN 0 AND 60) AS tro_pi_motion_60d,
    bool_or(regexp_matches(lower(d.docket_text), '(^|[^a-z])amic(us|i)([^a-z]|$)')) AS amicus_docket
  FROM '%s/docket_entries.parquet' d JOIN f_cases c USING (ucid)
  GROUP BY 1", pq))

# ---- Put it together and save ---------------------------------------------------
step("saving case_features.parquet")
dbExecute(con, sprintf("COPY (
  -- Missing values get explicit labels (Josh, 24 Oct 2026) so no case is dropped
  -- and a model can learn whether being missing matters.
  SELECT c.ucid,
         coalesce(s.case_number_parity, 'not recorded') AS case_number_parity,
         s.any_referral, s.has_related_case, s.is_consolidated,
         s.consolidation_role, s.mdl_any,
         coalesce(j.circuit, CASE WHEN c.fjc_row IS NULL THEN 'no FJC record' ELSE 'not recorded' END) AS circuit,
         CASE WHEN c.fjc_row IS NULL THEN 'no FJC record'
              ELSE coalesce(j.diversity_residence, 'not recorded') END AS diversity_residence,
         CASE WHEN c.fjc_row IS NULL THEN 'no FJC record'
              ELSE coalesce(j.county_area_class, 'county not recorded') END AS county_area_class,
         CASE WHEN sj.senior_judge_at_filing IS NOT NULL THEN sj.senior_judge_at_filing
              WHEN nullif(trim(c.judge), '') IS NULL   THEN 'no judge listed'
              ELSE 'filing date missing' END AS senior_judge_at_filing,
         coalesce(sj.judge_visiting, false) AS judge_visiting,
         coalesce(pf.n_plaintiffs, 0) AS n_plaintiffs, coalesce(pf.n_defendants, 0) AS n_defendants,
         CASE WHEN coalesce(pf.n_plaintiffs, 0) = 0 THEN 'no plaintiff listed'
              ELSE coalesce(pf.first_plaintiff_type, 'name not recorded') END AS first_plaintiff_type,
         CASE WHEN coalesce(pf.n_defendants, 0) = 0 THEN 'no defendant listed'
              ELSE coalesce(pf.first_defendant_type, 'name not recorded') END AS first_defendant_type,
         coalesce(ff.plaintiff_firm_cases, 'no plaintiff listed') AS plaintiff_firm_cases,
         coalesce(ff.defendant_firm_rank, 'no defendant listed') AS defendant_firm_rank,
         coalesce(o.plaintiff_org_attorney, false) AS plaintiff_org_attorney,
         coalesce(dk.tro_pi_motion_60d, false) AS tro_pi_motion_60d,
         coalesce(dk.amicus_docket, false) OR coalesce(pf.amicus_party, false) AS amicus
  FROM f_cases c
  LEFT JOIN f_simple s USING (ucid)   LEFT JOIN f_fjc j USING (ucid)
  LEFT JOIN f_senior sj USING (ucid)  LEFT JOIN f_party_feats pf USING (ucid)
  LEFT JOIN f_firm_feats ff USING (ucid) LEFT JOIN f_org o USING (ucid)
  LEFT JOIN f_docket dk USING (ucid)
  ORDER BY c.ucid) TO '%s/case_features.parquet' (FORMAT parquet, COMPRESSION zstd)", pq))

# ---- Report: coverage and things to check by hand ---------------------------------
step("report")
feat <- sprintf("'%s/case_features.parquet'", pq)
cols <- c("case_number_parity", "any_referral", "has_related_case", "is_consolidated", "consolidation_role", "mdl_any",
          "circuit", "diversity_residence", "county_area_class", "senior_judge_at_filing",
          "first_plaintiff_type", "first_defendant_type", "plaintiff_firm_cases", "defendant_firm_rank",
          "plaintiff_org_attorney", "tro_pi_motion_60d", "amicus")
coverage <- do.call(rbind, lapply(cols, function(cl) dbGetQuery(con, sprintf(
  "SELECT '%s' AS feature, coalesce(CAST(%s AS VARCHAR), '(missing)') AS value, count(*) AS n_cases,
          round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
   FROM %s GROUP BY 2 ORDER BY 3 DESC", cl, cl, feat))))
counts <- dbGetQuery(con, sprintf("SELECT 'n_plaintiffs' AS feature, quantile_cont(n_plaintiffs, [0.1,0.5,0.9,0.99])::VARCHAR AS p10_p50_p90_p99 FROM %s
  UNION ALL SELECT 'n_defendants', quantile_cont(n_defendants, [0.1,0.5,0.9,0.99])::VARCHAR FROM %s", feat, feat))
judge_check <- dbGetQuery(con, "SELECT match_kind, count(*) AS n_judge_names, sum(n) AS n_cases
                                FROM f_judge_pairs GROUP BY 1 ORDER BY 3 DESC")
judge_unmatched <- dbGetQuery(con, "SELECT court, judge, n AS n_cases FROM f_judge_pairs
                                    WHERE match_kind = 'not matched' ORDER BY n DESC LIMIT 40")
county_unmatched <- dbGetQuery(con, "SELECT fjc_county_code, count(*) AS n_cases FROM f_fjc
                                     WHERE county_area_class = 'unmatched county code' GROUP BY 1 ORDER BY 2 DESC LIMIT 40")
big_firm_matches <- dbGetQuery(con, "SELECT defendant_bcg_firm, defendant_firm_clean, count(*) AS n_cases
                                     FROM f_firm_feats WHERE defendant_bcg_firm IS NOT NULL
                                     GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 200")
top_plaintiff_firms <- dbGetQuery(con, "SELECT f.plaintiff_firm_clean, any_value(fc.n_cases) AS cases_in_data, count(*) AS as_first_plaintiff_lead
                                        FROM f_firm_feats f JOIN f_firm_counts fc ON fc.firm = f.plaintiff_firm_clean
                                        GROUP BY 1 ORDER BY 2 DESC LIMIT 50")
write.csv(coverage,            file.path(checks_dir, "features_report_coverage.csv"), row.names = FALSE)
write.csv(counts,              file.path(checks_dir, "features_report_party_counts.csv"), row.names = FALSE)
write.csv(judge_check,         file.path(checks_dir, "features_report_judge_match.csv"), row.names = FALSE)
write.csv(judge_unmatched,     file.path(checks_dir, "features_report_judges_not_matched.csv"), row.names = FALSE)
write.csv(county_unmatched,    file.path(checks_dir, "features_report_counties_not_matched.csv"), row.names = FALSE)
write.csv(big_firm_matches,    file.path(checks_dir, "features_report_defendant_big_firm_matches.csv"), row.names = FALSE)
write.csv(top_plaintiff_firms, file.path(checks_dir, "features_report_top_plaintiff_firms.csv"), row.names = FALSE)
print(judge_check)
# Record what the features were built from, so 00_sample.R can warn when they go stale.
write.csv(features_inputs(), features_manifest, row.names = FALSE)
cat("Saved", file.path(pq, "case_features.parquet"), "and features_report_*.csv in", checks_dir, "\n")
cat("Next: source 00_sample.R (it joins the features), and look at the reports.\n")
