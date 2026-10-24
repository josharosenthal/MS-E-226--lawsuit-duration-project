#!/usr/bin/env python3
"""
flatten_scales.py — read the SCALES cross-sectional archive (one JSON file per
case, packed in a .tar.gz) WITHOUT unpacking it to disk, and write five flat
tables, one row per:

    cases            case
    parties          party in a case
    counsel          lawyer listed for a party in a case
    docket_entries   line on a case's docket sheet
    criminal_counts  criminal count against a defendant (criminal cases only)

Each table is written as compressed JSON-lines (flat/<table>.jsonl.gz). The
script also writes flat/convert_to_parquet.sql, which DuckDB then runs to make
the Parquet files, and flat/keys_report.csv, which lists every field name that
actually appears in the files (the SCALES schema docs may be out of date).

Uses only Python's standard library, so there is nothing to install.
Field names follow https://docs.scales-okn.org/parser/#json-schema

Usage:  python3 flatten_scales.py ARCHIVE FLAT_DIR PARQUET_DIR [--keep-contact-info]
"""
import argparse
import collections
import csv
import datetime as dt
import gzip
import io
import json
import os
import sys
import tarfile
import time

# ---------------------------------------------------------------------------
# Table definitions: column name -> DuckDB type. Everything not listed is
# ignored (but still counted in keys_report.csv so you can see it exists).
# "json" in a name means a list stored as JSON text, e.g. '["a","b"]'.
# ---------------------------------------------------------------------------
CASES = {
    "ucid": "VARCHAR", "court": "VARCHAR", "case_id": "VARCHAR", "case_type": "VARCHAR",
    "year_dir": "VARCHAR", "court_dir": "VARCHAR", "archive_path": "VARCHAR",
    "header_case_id": "VARCHAR", "case_status": "VARCHAR", "case_name": "VARCHAR",
    "filing_date_raw": "VARCHAR", "filing_date": "DATE",
    "terminating_date_raw": "VARCHAR", "terminating_date": "DATE",
    "city": "VARCHAR", "lead_case_id": "VARCHAR", "lead_case_pacer_id": "VARCHAR",
    "mdl_code": "BIGINT", "mdl_id_source": "VARCHAR", "is_mdl": "BOOLEAN", "is_multi": "BOOLEAN",
    "member_case_key": "VARCHAR",
    "judge": "VARCHAR", "referred_judges_json": "VARCHAR", "appeals_case_ids_json": "VARCHAR",
    "nature_suit": "VARCHAR", "jury_demand": "VARCHAR", "cause": "VARCHAR",
    "jurisdiction": "VARCHAR", "monetary_demand": "VARCHAR",
    "filed_in_error_text": "VARCHAR", "case_flags_json": "VARCHAR",
    "related_cases_json": "VARCHAR", "other_courts_json": "VARCHAR",
    "magistrate_case_ids_json": "VARCHAR",
    "docket_available": "BOOLEAN", "n_docket_entries": "INTEGER",
    "n_parties": "INTEGER", "n_counsel": "INTEGER",
    "billable_pages": "INTEGER", "cost": "DOUBLE", "download_timestamp": "VARCHAR",
    "n_docket_reports": "INTEGER", "case_pacer_id": "BIGINT", "scraper_labels_json": "VARCHAR",
    "is_stub": "BOOLEAN", "is_private": "BOOLEAN", "source": "VARCHAR", "recap_id": "BIGINT",
    "summary_date_filed": "VARCHAR", "summary_date_terminated": "VARCHAR",
    "summary_date_of_last_filing": "VARCHAR", "summary_presiding": "VARCHAR",
    "summary_referral": "VARCHAR",
}
PARTIES = {
    "ucid": "VARCHAR", "party_index": "INTEGER", "name": "VARCHAR", "pacer_id": "BIGINT",
    "role": "VARCHAR", "party_type": "VARCHAR",
    "terminating_date_raw": "VARCHAR", "terminating_date": "DATE",
    "raw_info": "VARCHAR", "office_name": "VARCHAR", "n_counsel": "INTEGER",
    # criminal-only, per defendant
    "judge": "VARCHAR", "referred_judges_json": "VARCHAR", "appeals_case_ids_json": "VARCHAR",
    "complaints_text": "VARCHAR", "complaints_disposition": "VARCHAR",
    "highest_offense_level_opening": "VARCHAR", "highest_offense_level_terminated": "VARCHAR",
    # contact details (only filled when --keep-contact-info is used)
    "address": "VARCHAR", "phone": "VARCHAR", "fax": "VARCHAR", "email": "VARCHAR",
}
COUNSEL = {
    "ucid": "VARCHAR", "party_index": "INTEGER", "counsel_index": "INTEGER", "name": "VARCHAR",
    "is_pro_se": "BOOLEAN", "is_lead_attorney": "BOOLEAN", "is_notice_attorney": "BOOLEAN",
    "is_pro_hac_vice": "BOOLEAN", "designation": "VARCHAR", "bar_status": "VARCHAR",
    "trial_bar_status": "VARCHAR", "has_see_above": "BOOLEAN", "office_name": "VARCHAR",
    "address": "VARCHAR", "phone": "VARCHAR", "fax": "VARCHAR", "email": "VARCHAR",
}
DOCKET = {
    "ucid": "VARCHAR", "entry_index": "INTEGER", "date_filed_raw": "VARCHAR", "date_filed": "DATE",
    "ind": "VARCHAR", "docket_text": "VARCHAR", "n_documents": "INTEGER", "n_edges": "INTEGER",
}
COUNTS = {
    "ucid": "VARCHAR", "party_index": "INTEGER", "status": "VARCHAR", "pacer_id": "BIGINT",
    "counts": "VARCHAR", "disposition": "VARCHAR",
}
TABLES = {"cases": CASES, "parties": PARTIES, "counsel": COUNSEL,
          "docket_entries": DOCKET, "criminal_counts": COUNTS}
CONTACT = ("address", "phone", "fax", "email")


# ---------------------------------------------------------------------------
# Small helpers that turn messy values into clean ones (or None = missing).
# ---------------------------------------------------------------------------
DATE_FORMATS = ("%m/%d/%Y", "%Y-%m-%d", "%m/%d/%y", "%Y/%m/%d")

def to_iso_date(value):
    """'03/15/2016' -> '2016-03-15'. Returns None if it can't be read."""
    if not value or not isinstance(value, str):
        return None
    s = value.strip()[:10]
    for fmt in DATE_FORMATS:
        try:
            d = dt.datetime.strptime(s, fmt).date()
            return d.isoformat() if 1900 <= d.year <= 2100 else None
        except ValueError:
            continue
    return None

def clean(value, duck_type):
    """Coerce a value to fit a DuckDB column type; anything unreadable -> None."""
    if value is None or value == "":
        return None
    try:
        if duck_type in ("INTEGER", "BIGINT"):
            return int(value)
        if duck_type == "DOUBLE":
            return float(value)
        if duck_type == "BOOLEAN":
            if isinstance(value, bool):
                return value
            return str(value).strip().lower() in ("true", "t", "1", "yes")
        if duck_type == "DATE":
            return to_iso_date(value) if isinstance(value, str) else None
    except (ValueError, TypeError):
        return None
    if isinstance(value, (list, dict)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)

def as_json_list(value):
    if value in (None, "", []):
        return None
    return json.dumps(value, ensure_ascii=False)

def as_list(value):
    """Parties sometimes come as a list, sometimes as a dict; always return a list."""
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        out = []
        for v in value.values():
            out.extend(v if isinstance(v, list) else [v])
        return out
    return []


# ---------------------------------------------------------------------------
# Writers: one gzip JSON-lines file per table.
# Rows for a case are held back until the whole case has been read, then
# written together (commit). If a case fails partway, its rows are thrown
# away (discard), so no table ends up with rows for a case that isn't in
# the cases table.
# ---------------------------------------------------------------------------
class Writers:
    def __init__(self, out_dir):
        self.files = {t: gzip.open(os.path.join(out_dir, f"{t}.jsonl.gz"), "wb",
                                   compresslevel=3) for t in TABLES}
        self.rows = collections.Counter()
        self.pending = []

    def write(self, table, row):
        schema = TABLES[table]
        clean_row = {c: clean(row.get(c), schema[c]) for c in schema}
        # Encoding here (not at commit) means bad text fails while the case can still be discarded.
        line = (json.dumps(clean_row, ensure_ascii=False) + "\n").encode("utf-8")
        self.pending.append((table, line))

    def commit(self):
        for table, line in self.pending:
            self.files[table].write(line)
            self.rows[table] += 1
        self.pending = []

    def discard(self):
        self.pending = []

    def close(self):
        for f in self.files.values():
            f.close()


# ---------------------------------------------------------------------------
# Turn ONE case (a parsed JSON object) into rows for each table.
# ---------------------------------------------------------------------------
def flatten_case(case, path, w, keys, keep_contact):
    parts = path.strip("/").split("/")
    # The real archive is cross_sectional/<court>/<yy>/<case>.json. Of the two
    # folders above the file, the all-digit one is the year and the other is
    # the court, so either order works.
    dirs = parts[-3:-1]
    year_dir = next((d for d in dirs if d.isdigit()), None)
    court_dir = next((d for d in reversed(dirs) if not d.isdigit()), None)
    stem = os.path.splitext(parts[-1])[0]

    for k, v in case.items():
        keys[("case", k, type(v).__name__)] += 1

    court = case.get("court") or court_dir
    ucid = case.get("ucid") or (f"{court};;{case.get('case_id') or stem}")
    parties = as_list(case.get("parties"))
    docket = case.get("docket") if isinstance(case.get("docket"), list) else []
    summary = case.get("summary") if isinstance(case.get("summary"), dict) else {}
    for k in summary:
        keys[("summary", k, type(summary[k]).__name__)] += 1

    n_counsel_total = 0
    for p_i, p in enumerate(parties):
        if not isinstance(p, dict):
            continue
        for k, v in p.items():
            keys[("party", k, type(v).__name__)] += 1
        info = p.get("entity_info") if isinstance(p.get("entity_info"), dict) else {}
        counsel = p.get("counsel") if isinstance(p.get("counsel"), list) else []
        n_counsel_total += len(counsel)
        prow = {
            "ucid": ucid, "party_index": p_i, "name": p.get("name"), "pacer_id": p.get("pacer_id"),
            "role": p.get("role"), "party_type": p.get("party_type"),
            "terminating_date_raw": p.get("terminating_date"),
            "terminating_date": to_iso_date(p.get("terminating_date")),
            "raw_info": info.get("raw_info"), "office_name": info.get("office_name"),
            "n_counsel": len(counsel),
            "judge": p.get("judge"), "referred_judges_json": as_json_list(p.get("referred_judges")),
            "appeals_case_ids_json": as_json_list(p.get("appeals_case_ids")),
            "complaints_text": p.get("complaints_text"),
            "complaints_disposition": p.get("complaints_disposition"),
            "highest_offense_level_opening": p.get("highest_offense_level_opening"),
            "highest_offense_level_terminated": p.get("highest_offense_level_terminated"),
        }
        if keep_contact:
            prow.update({c: info.get(c) for c in CONTACT})
        w.write("parties", prow)

        for c_i, c in enumerate(counsel):
            if not isinstance(c, dict):
                continue
            for k, v in c.items():
                keys[("counsel", k, type(v).__name__)] += 1
            cinfo = c.get("entity_info") if isinstance(c.get("entity_info"), dict) else {}
            crow = {"ucid": ucid, "party_index": p_i, "counsel_index": c_i, "name": c.get("name"),
                    "office_name": cinfo.get("office_name")}
            for f in ("is_pro_se", "is_lead_attorney", "is_notice_attorney", "is_pro_hac_vice",
                      "designation", "bar_status", "trial_bar_status", "has_see_above"):
                crow[f] = c.get(f)
            if keep_contact:
                crow.update({k: cinfo.get(k) for k in CONTACT})
            w.write("counsel", crow)

        for status in ("pending_counts", "terminated_counts"):
            for cnt in (p.get(status) or []):
                if isinstance(cnt, dict):
                    w.write("criminal_counts", {
                        "ucid": ucid, "party_index": p_i, "status": status.replace("_counts", ""),
                        "pacer_id": cnt.get("pacer_id"), "counts": cnt.get("counts"),
                        "disposition": cnt.get("disposition")})

    for e_i, e in enumerate(docket):
        if not isinstance(e, dict):
            continue
        for k, v in e.items():
            keys[("docket_entry", k, type(v).__name__)] += 1
        docs = e.get("documents")
        w.write("docket_entries", {
            "ucid": ucid, "entry_index": e_i, "date_filed_raw": e.get("date_filed"),
            "date_filed": to_iso_date(e.get("date_filed")), "ind": e.get("ind"),
            "docket_text": e.get("docket_text"),
            "n_documents": len(docs) if isinstance(docs, (dict, list)) else 0,
            "n_edges": len(e.get("edges") or []) if isinstance(e.get("edges"), list) else None})

    row = {k: case.get(k) for k in CASES if k in case}
    row.update({
        "ucid": ucid, "court": court, "case_id": case.get("case_id") or stem,
        "year_dir": year_dir, "court_dir": court_dir, "archive_path": path,
        "filing_date_raw": case.get("filing_date"), "filing_date": to_iso_date(case.get("filing_date")),
        "terminating_date_raw": case.get("terminating_date"),
        "terminating_date": to_iso_date(case.get("terminating_date")),
        "referred_judges_json": as_json_list(case.get("referred_judges")),
        "appeals_case_ids_json": as_json_list(case.get("appeals_case_ids")),
        "case_flags_json": as_json_list(case.get("case_flags")),
        "related_cases_json": as_json_list(case.get("related_cases")),
        "other_courts_json": as_json_list(case.get("other_courts")),
        "magistrate_case_ids_json": as_json_list(case.get("magistrate_case_ids")),
        "scraper_labels_json": as_json_list(case.get("scraper_labels")),
        "n_docket_entries": len(docket), "n_parties": len(parties), "n_counsel": n_counsel_total,
        "summary_date_filed": summary.get("date_filed"),
        "summary_date_terminated": summary.get("date_terminated"),
        "summary_date_of_last_filing": summary.get("date_of_last_filing"),
        "summary_presiding": summary.get("presiding"), "summary_referral": summary.get("referral"),
    })
    w.write("cases", row)


# ---------------------------------------------------------------------------
# Read the archive one case at a time.
# ---------------------------------------------------------------------------
def iter_cases(archive, errors, skipped):
    """Yield (path, case_dict). Handles .tar.gz (expected) or a .gz of JSON lines.
    Files in the tarball that don't end in .json are counted in `skipped`
    (extension -> count) so they can't go missing without anyone noticing."""
    try:
        with tarfile.open(archive, mode="r|gz") as tar:      # 'r|' = stream, no seeking
            for m in tar:
                if not m.isfile():
                    continue
                if os.path.basename(m.name).startswith("._"):     # hidden Mac metadata, not a case
                    if not skipped["._ (Mac metadata)"]:
                        print(f"   skipping hidden Mac file, e.g. {m.name}", flush=True)
                    skipped["._ (Mac metadata)"] += 1
                    continue
                if not m.name.endswith(".json"):
                    ext = os.path.splitext(m.name)[1] or "(no extension)"
                    if not skipped[ext]:
                        print(f"   skipping non-.json file, e.g. {m.name}", flush=True)
                    skipped[ext] += 1
                    continue
                try:
                    yield m.name, json.load(tar.extractfile(m))
                except Exception as e:                        # bad JSON in one file
                    errors.writerow([m.name, type(e).__name__, str(e)[:200]])
        return
    except tarfile.ReadError:
        print("   (not a tar archive — trying one-JSON-object-per-line instead)", flush=True)
    with gzip.open(archive, "rt", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            try:
                case = json.loads(line)
                yield case.get("ucid") or f"line_{i}", case
            except Exception as e:
                errors.writerow([f"line_{i}", type(e).__name__, str(e)[:200]])


def write_convert_sql(out_dir, parquet_dir):
    lines = []
    for t, schema in TABLES.items():
        cols = ", ".join(f"'{c}': '{ty}'" for c, ty in schema.items())
        lines.append(
            f"COPY (SELECT * FROM read_json('{out_dir}/{t}.jsonl.gz', format = 'newline_delimited', "
            f"columns = {{{cols}}})) TO '{parquet_dir}/{t}.parquet' (FORMAT parquet, COMPRESSION zstd);")
    with open(os.path.join(out_dir, "convert_to_parquet.sql"), "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive"); ap.add_argument("out_dir"); ap.add_argument("parquet_dir")
    ap.add_argument("--keep-contact-info", action="store_true")
    ap.add_argument("--expected-cases", type=int, default=None,
                    help="warn if the number of cases read differs from this")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    w = Writers(a.out_dir)
    keys = collections.Counter()
    err_f = open(os.path.join(a.out_dir, "parse_errors.csv"), "w", newline="")
    errors = csv.writer(err_f); errors.writerow(["path", "error_type", "message"])
    skipped = collections.Counter()
    start, n, n_failed = time.time(), 0, 0
    for path, case in iter_cases(a.archive, errors, skipped):
        if not isinstance(case, dict):
            errors.writerow([path, "not_an_object", type(case).__name__]); n_failed += 1; continue
        try:
            flatten_case(case, path, w, keys, a.keep_contact_info)
        except Exception as e:
            w.discard()
            errors.writerow([path, type(e).__name__, str(e)[:200]])
            n_failed += 1
            continue
        w.commit()
        n += 1
        if n % 20000 == 0:
            print(f"   {n:,} cases  ({n / (time.time() - start):,.0f}/sec)", flush=True)
    w.close(); err_f.close()

    with open(os.path.join(a.out_dir, "keys_report.csv"), "w", newline="") as f:
        kw = csv.writer(f); kw.writerow(["level", "field", "python_type", "n_occurrences"])
        for (level, field, ty), cnt in sorted(keys.items()):
            kw.writerow([level, field, ty, cnt])
    write_convert_sql(a.out_dir, a.parquet_dir)

    print(f"== Read {n:,} cases in {(time.time() - start) / 60:.1f} minutes"
          f" ({n_failed:,} more could not be read; see parse_errors.csv)")
    for t in TABLES:
        print(f"   {t:16s} {w.rows[t]:>12,} rows")
    if skipped:
        print("   Files skipped (hidden Mac files, or not ending in .json): "
              + ", ".join(f"{ext}: {c:,}" for ext, c in skipped.most_common()))

    if n == 0:
        sys.exit("STOP: no cases were read. Check the archive layout (01_check_files.sh shows "
                 "the first file names) and the skipped-files line above.")
    if a.expected_cases and n != a.expected_cases:
        print(f"   WARNING: expected {a.expected_cases:,} cases but read {n:,} "
              f"({n - a.expected_cases:+,}). Check parse_errors.csv and the skipped files above.")


if __name__ == "__main__":
    main()
