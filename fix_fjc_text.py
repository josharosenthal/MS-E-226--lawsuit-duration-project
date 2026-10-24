#!/usr/bin/env python3
"""
fix_fjc_text.py — repair the few malformed lines in the FJC civil text file so
that DuckDB can read every row. Reads the file on standard input, writes a clean
UTF-8, tab-separated copy and a list of the lines it changed.

Usage:  unzip -p cv88on.zip cv88on.txt | python3 fix_fjc_text.py CLEAN.txt REPAIRED.csv

What it fixes (found in the real file, release of 30 June 2026):
  * Tabs inside a party name. Some rows have more than 46 fields because a tab
    sits inside the plaintiff or defendant name. Fields 1-21 (CIRCUIT ... MDLDOCK)
    and the last 23 (TRANSDAT ... TAPEYEAR) are fixed, so whatever is in between
    is PLT and DEF: PLT gets the first piece, DEF the rest joined with spaces.
  * Text that isn't UTF-8. Such lines are read as Latin-1 (e.g. accented names).
  * Stray carriage returns inside a line, which DuckDB would treat as a line
    break. They are replaced with a space.
  * Rows with fewer than 46 fields are padded with blanks (none expected).
Only line numbers and reasons go in REPAIRED.csv, never the line's contents.
Uses only Python's standard library.
"""
import collections
import csv
import sys

N_FIELDS = 46     # columns in the FJC civil file
N_HEAD = 21       # CIRCUIT ... MDLDOCK, before PLT
N_TAIL = 23       # TRANSDAT ... TAPEYEAR, after DEF


def main():
    clean_path, report_path = sys.argv[1:3]
    counts = collections.Counter()
    with open(clean_path, "w", encoding="utf-8", newline="\n") as out, \
         open(report_path, "w", newline="") as rf:
        report = csv.writer(rf)
        report.writerow(["line", "problem", "n_fields_before"])
        for line_no, raw in enumerate(sys.stdin.buffer, start=1):
            raw = raw.rstrip(b"\n")
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            problems = []
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = raw.decode("latin-1")
                problems.append("not UTF-8; read as Latin-1")
            if "\r" in text:
                text = text.replace("\r", " ")
                problems.append("stray carriage return replaced with a space")
            fields = text.split("\t")
            n = len(fields)
            if line_no == 1:
                if n != N_FIELDS:
                    sys.exit(f"STOP: the header has {n} columns, expected {N_FIELDS}. "
                             "The FJC file layout has changed; check the codebook.")
            elif n > N_FIELDS:
                middle = fields[N_HEAD:n - N_TAIL]
                fields = fields[:N_HEAD] + [middle[0], " ".join(middle[1:])] + fields[n - N_TAIL:]
                problems.append("tab inside plaintiff/defendant name; pieces rejoined")
            elif n < N_FIELDS:
                fields += [""] * (N_FIELDS - n)
                problems.append("too few fields; padded with blanks")
            for p in problems:
                report.writerow([line_no, p, n])
                counts[p] += 1
            out.write("\t".join(fields) + "\n")
    print(f"   read {line_no:,} lines (including the header)")
    for p, c in counts.most_common():
        print(f"   repaired: {p}: {c:,} lines")
    if not counts:
        print("   no lines needed repair")


if __name__ == "__main__":
    main()
