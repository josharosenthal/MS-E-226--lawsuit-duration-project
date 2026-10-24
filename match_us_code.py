#!/usr/bin/env python3
"""
match_us_code.py — look up the US Code section heading for each cause-of-action
(title, section) pair, using the CourtGPT/us-code JSON files
(https://github.com/CourtGPT/us-code, a mirror of uscode.house.gov).

Usage:  python3 match_us_code.py TITLES_DIR INPUT_CSV OUTPUT_CSV

  TITLES_DIR  folder holding the downloaded data/titles/title-*.json files
  INPUT_CSV   columns cause_title, cause_section, n_cases
  OUTPUT_CSV  the same rows plus the matched heading and how it was matched

How a section is matched (the first rule that works is used):
  1. exact            the section as written, e.g. 28 + 1332
  2. exact (ignoring case and dashes)  e.g. 1605a -> 1605A, 1973gg6 -> 1973gg–6
  3. dropped suffix   trailing characters removed one at a time, never cutting
                      into the leading digits: 1983pr -> 1983, 2000e2o -> 2000e2
                      (= § 2000e-2). A letter followed by a digit is read as a
                      subsection, so 227b3 -> 227, not 227b. These need a human
                      check: a suffix can be a PACER tag (pr = prisoner) or a
                      subsection (405g = 405(g)).
  4. within range     the section falls inside a grouped entry such as
                      "§§ 1 to 1j" (usually repealed or omitted sections)
Hyphens and dashes are ignored when comparing (2000e–2 = 2000e2).

The repository sometimes lists the same number more than once in a title,
because sections of acts quoted in the editorial notes are picked up too.
Those extra entries have ALL-CAPS headings ("SHORT TITLE."), so an entry
with a normal heading is preferred.

The repository is the current US Code (release point in its metadata.json),
not the 2016-17 version, so sections that have since moved or been repealed
are flagged in the `status` column rather than guessed.
"""
import csv
import glob
import json
import os
import re
import sys

STATUS_WORDS = ("Repealed", "Transferred", "Omitted", "Renumbered", "Reserved", "Vacant")


def norm(s):
    """Lower-case and drop hyphens, dashes and spaces: '2000e–2' -> '2000e2'."""
    return re.sub(r"[\s\-‐-―]", "", s).lower()


def sort_key(s):
    """'1983pr' -> (1983, 'pr') so that range ends can be compared."""
    m = re.match(r"(\d+)(.*)", norm(s))
    return (int(m.group(1)), m.group(2)) if m else None


def quality(entry):
    """Higher is better: a normal heading beats an ALL-CAPS note heading."""
    name = (entry.get("sectionName") or "").strip()
    if not name or re.fullmatch(r"Section \S+", name):
        return 0
    letters = [c for c in name if c.isalpha()]
    return 1 if letters and all(c.isupper() for c in letters) else 2


def load_titles(titles_dir):
    """title number -> {'name', 'exact', 'lower', 'ranges'}"""
    out = {}
    for path in glob.glob(os.path.join(titles_dir, "title-*.json")):
        m = re.match(r"title-0*(\d+)-", os.path.basename(path))
        if not m:                      # skip appendices such as title-05a, title-28a
            continue
        j = json.load(open(path, encoding="utf-8"))
        t = {"name": j.get("titleName"), "exact": {}, "lower": {}, "ranges": []}
        for e in j["sections"]:
            sec = e["section"]
            if "..." in sec:
                lo, hi = sec.split("...", 1)
                if sort_key(lo) and sort_key(hi):
                    t["ranges"].append((sort_key(lo), sort_key(hi), e))
                continue
            for index, key in ((t["exact"], sec), (t["lower"], norm(sec))):
                if key not in index or quality(e) > quality(index[key]):
                    index[key] = e
        out[int(m.group(1))] = t
    return out


def candidates(section):
    """'1983pr' -> ['1983pr', '1983p', '1983']; never cuts into the leading digits."""
    m = re.match(r"\d+", section)
    if not m:
        return []
    return [section[:i] for i in range(len(section), m.end() - 1, -1)]


def match(titles, title, section):
    """Return (entry, method) or (None, reason)."""
    if not title.isdigit():
        return None, "no title number"
    t = titles.get(int(title))
    if t is None:
        return None, "not a US Code title (e.g. a PACER placeholder code)"
    if section in t["exact"]:
        return t["exact"][section], "exact"
    if norm(section) in t["lower"]:
        return t["lower"][norm(section)], "exact (ignoring case and dashes)"
    for c in candidates(section)[1:]:
        # '227b3' means 227(b)(3): don't stop at '227b' when what follows the letter is a digit
        if c[-1].isalpha() and section[len(c)].isdigit():
            continue
        if norm(c) in t["lower"]:
            return t["lower"][norm(c)], f"dropped suffix '{section[len(c):]}'"
    k = sort_key(section) if re.match(r"\d", section) else None
    if k:
        for lo, hi, e in t["ranges"]:
            if lo <= k <= hi:
                return e, f"within range {e['section'].replace('...', ' to ')}"
    if not re.match(r"\d", section):
        return None, "section is not a number"
    return None, "no matching section in the current US Code"


def status_of(entry):
    """'Repealed', 'Transferred', ... if the heading says so near its start."""
    start = (entry.get("sectionName") or "")[:40]
    for w in STATUS_WORDS:
        if w.lower() in start.lower():
            return w
    return "note-level heading only; check" if quality(entry) < 2 else ""


def main():
    titles_dir, in_csv, out_csv = sys.argv[1:4]
    titles = load_titles(titles_dir)
    rows = list(csv.DictReader(open(in_csv, encoding="utf-8")))
    fields = ["cause_title", "cause_section", "n_cases", "usc_title_name", "matched_section",
              "section_heading", "match_method", "status", "source_url"]
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            title, section = r["cause_title"].strip(), r["cause_section"].strip()
            entry, method = match(titles, title, section)
            t = titles.get(int(title)) if title.isdigit() else None
            w.writerow({
                "cause_title": title, "cause_section": section, "n_cases": r["n_cases"],
                "usc_title_name": t["name"] if t and entry else "",
                "matched_section": entry["section"].replace("...", " to ") if entry else "",
                "section_heading": (entry.get("sectionName") or "").strip() if entry else "",
                "match_method": method,
                "status": status_of(entry) if entry else "",
                "source_url": entry.get("sourceUrl", "") if entry else "",
            })
    print(f"wrote {len(rows):,} rows to {out_csv}")


if __name__ == "__main__":
    main()
