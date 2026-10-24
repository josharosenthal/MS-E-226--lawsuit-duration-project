"""
build_reference.py - build the lookup tables in this folder.
Usage: python3 build_reference.py BCG_JSON JUDGES_CSV NCHS_XLSX CROSSWALK_CSV OUT_DIR
Give "-" for any of the first three sources to skip rebuilding that table.
  BCG_JSON    firm names + headcounts read from the BCG page  -> large_firms_bcg_2026.csv
  JUDGES_CSV  FJC Biographical Directory judges.csv           -> fjc_district_judges.csv
              (district judgeships active at any time 2016-2021: the cases were filed
              2016-17 and collected by SCALES in 2020-21, so the judge field can name a
              judge appointed after filing)
  NCHS_XLSX   NCHSURCodes2013.xlsx                             -> nchs_urban_rural_2013.csv
"""
import json, re, csv, sys, unicodedata, openpyxl
bcg_path, judges_path, nchs_path, xwalk_path, out = sys.argv[1:6]


def build_firms():
    raw = json.load(open(bcg_path))
    def headcount(s):
        m = re.match(r"([\d,]+)'", s)
        return int(m.group(1).replace(",", "")) if m else None
    firms = [(name, headcount(h)) for name, h in raw]
    ranked = sorted([f for f in firms if f[1] is not None], key=lambda f: -f[1])
    rank = {name: i + 1 for i, (name, _) in enumerate(ranked)}
    def clean(s):
        s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
        s = re.sub(r"\(.*?\)", " ", s).replace("+", " & ").replace("&", " & ")
        s = re.sub(r"[^a-z0-9& ]+", " ", s)
        return re.sub(r"\s+", " ", s).strip()
    STOP = {"&", "and", "llp", "pc", "p", "c", "llc", "pllc", "the", "law", "firm", "lp"}
    ALIASES = {
     "A&O Shearman": ["allen & overy", "shearman & sterling", "shearman and sterling", "a & o shearman"],
     "Troutman Pepper Locke": ["troutman", "pepper hamilton", "locke lord"],
     "Faegre Drinker Biddle & Reath": ["faegre", "drinker biddle"],
     "McDermott Will & Schulte (fka McDermott Will & Emery)": ["mcdermott will"],
     "Hunton Andrews Kurth": ["hunton", "andrews kurth"],
     "Arnold & Porter Kaye Scholer": ["arnold & porter", "arnold and porter", "kaye scholer"],
     "Bryan Cave Leighton Paisner (BCLP)": ["bryan cave"],
     "ArentFox Schiff": ["arent fox", "arentfox"],
     "Womble Bond Dickinson": ["womble"],
     "Eversheds Sutherland": ["eversheds", "sutherland asbill"],
     "Lathrop GPM": ["lathrop", "gray plant mooty"],
     "WilmerHale (Wilmer Cutler Pickering Hale and Dorr)": ["wilmer cutler", "wilmerhale", "wilmer hale"],
     "Harris Beach Murtha": ["harris beach", "murtha cullina"],
     "Milberg Coleman Bryson Phillips Grossman": ["milberg"],
     "Taft Stettinius & Hollister": ["taft stettinius"],
     "BakerHostetler": ["baker hostetler", "bakerhostetler", "baker & hostetler", "baker and hostetler"],
     "McGuireWoods": ["mcguirewoods", "mcguire woods"],
     "GrayRobinson": ["grayrobinson", "gray robinson"],
     "Steptoe LLP": ["steptoe & johnson llp", "steptoe and johnson llp"],
     "Stinson LLP": ["stinson leonard street", "stinson llp", "stinson morrison"],
     "Mintz, Levin, Cohn, Ferris, Glovsky and Popeo": ["mintz levin", "mintz"],
     "Dykema Gossett": ["dykema"],
     "Cooley": ["cooley llp", "cooley godward"],
     "Skadden, Arps, Slate, Meagher & Flom": ["skadden"],
     "Ogletree Deakins": ["ogletree"],
     "Littler Mendelson": ["littler"],
     "K&L Gates": ["k & l gates", "kl gates"],
    }
    rows = []
    for name, hc in firms:
        toks = [t for t in clean(name).split() if t not in STOP]
        pats = [clean(a) for a in ALIASES.get(name, [])] or [" ".join(toks[:2]) if len(toks) >= 2 else toks[0]]
        pats = list(dict.fromkeys(pats))
        r = rank.get(name)
        bucket = f"{20*((r-1)//20)+1}-{20*((r-1)//20)+20}" if r else "listed, headcount not given"
        rows.append({"firm": name, "attorneys": hc or "", "headcount_rank": r or "", "rank_bucket": bucket,
                     "match_prefixes": " | ".join(pats)})
    seen = {}
    for r_ in rows:
        for p in r_["match_prefixes"].split(" | "):
            assert p not in seen, (p, seen.get(p), r_["firm"]); seen[p] = r_["firm"]
    # a prefix that is the start of another firm's prefix would match both
    allp = sorted(seen)
    clash = [(a, b) for a in allp for b in allp if a != b and (b + " ").startswith(a + " ")]
    print("prefix clashes (shorter prefix would also match the longer firm):", clash)
    with open(f"{out}/large_firms_bcg_2026.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader()
        w.writerows(sorted(rows, key=lambda r: (r["headcount_rank"] == "", r["headcount_rank"] or 0)))
    print("firms:", len(rows), "| ranked by headcount:", len(ranked), "| buckets:", sorted({r["rank_bucket"] for r in rows}, key=lambda b: (len(b), b)))

def build_judges():
    xw = {r["district_name"]: r["scales_court"] for r in csv.DictReader(open(xwalk_path))}
    def fjc_court_to_name(ct):
        m = re.match(r"U\.S\. District Court for the (Northern|Southern|Eastern|Western|Middle|Central) District of (.+)$", ct)
        if m: return f"{m.group(2)} - {m.group(1)}"
        m = re.match(r"U\.S\. District Court for the District of (.+)$", ct)
        if not m: return None
        return "District of Columbia" if m.group(1) == "Columbia" else m.group(1)
    jr = list(csv.DictReader(open(judges_path, encoding="utf-8-sig")))
    out_rows, unmapped = [], set()
    for r in jr:
        for k in range(1, 7):
            ct = r.get(f"Court Name ({k})", "")
            # Appeals and international-trade judges are kept too, so judges sitting
            # by designation in a district court can be matched as visiting judges.
            other = ct.startswith("U.S. Court of Appeals") or ct.startswith("U.S. Court of International Trade")
            if not (ct.startswith("U.S. District Court") or other): continue
            comm, term = r.get(f"Commission Date ({k})", ""), r.get(f"Termination Date ({k})", "")
            if not comm or comm > "2021-12-31" or (term and term < "2016-01-01"): continue
            if other:
                court = "appeals" if "Appeals" in ct else "intl_trade"
            else:
                nm = fjc_court_to_name(ct); court = xw.get(nm) if nm else None
                if not court: unmapped.add(ct); continue
            out_rows.append({"scales_court": court, "last_name": r["Last Name"], "first_name": r["First Name"],
                             "middle_name": r["Middle Name"], "suffix": r.get("Suffix", ""), "commission_date": comm,
                             "senior_status_date": r.get(f"Senior Status Date ({k})", ""), "termination_date": term,
                             "fjc_judge_id": r.get("nid", "")})
    with open(f"{out}/fjc_district_judges.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out_rows[0])); w.writeheader(); w.writerows(out_rows)
    print("judge services:", len(out_rows), "| district courts covered:", len({r['scales_court'] for r in out_rows} - {"appeals", "intl_trade"}),
          "| appeals / trade services:", sum(r["scales_court"] in ("appeals", "intl_trade") for r in out_rows), "| unmapped FJC courts:", sorted(unmapped))
    print("columns present in FJC file:", "Suffix" in jr[0], "nid" in jr[0])

def build_counties():
    ws = openpyxl.load_workbook(nchs_path, read_only=True).active
    LABEL = {1: "large central metro", 2: "large fringe metro", 3: "medium metro", 4: "small metro", 5: "micropolitan", 6: "noncore"}
    JOSH = {1: "urban", 2: "suburban", 3: "rural", 4: "rural", 5: "rural", 6: "rural"}
    n = 0
    with open(f"{out}/nchs_urban_rural_2013.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["fips", "state", "county", "nchs_2013_code", "nchs_2013_label", "area_class"])
        for row in list(ws.iter_rows(values_only=True))[1:]:
            if row[0] is None: continue
            code = int(row[6]); w.writerow([f"{int(row[0]):05d}", row[1], row[2], code, LABEL[code], JOSH[code]]); n += 1
    print("counties:", n)

if bcg_path != "-": build_firms()
if judges_path != "-": build_judges()
if nchs_path != "-": build_counties()
