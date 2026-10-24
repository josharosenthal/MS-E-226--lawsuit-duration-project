# Brief for Claude Code: load the SCALES federal-court data on FarmShare

## Context
I'm Josh, a student in MS&E 226 (Fundamentals of Data Science, Stanford, Autumn 2026). I'm not an experienced programmer, so please explain your changes in plain language. Right now I only want to **get the data onto FarmShare in queryable form and understand its shape**. I haven't chosen a sample or an outcome yet, and my later analysis will be in R/RStudio.

## The data (already downloaded and copied to `~/scales_project/raw/`)
- **Cross-Sectional Data (JSONs):** one ~2.2 GB `.gz` file from the SCALES OKN file server, described as case data from all 94 federal districts for 2016–2017, 676,809 cases. I expect it to be a tarball of one JSON file per case, laid out as `scales_json_cross_sectional/<year>/<court>/<case>.json`. The fields are documented at https://docs.scales-okn.org/parser/#json-schema, though the docs may be out of date.
- **Event log:** one ~2 GB CSV, one row per case event. It's described at https://docs.scales-okn.org/eventlog/, but its exact columns are not documented.

## What the scripts do
| Step | File | Action |
|---|---|---|
| 00 | `00_setup.sh` | Makes the folders, checks tools, installs the DuckDB command-line tool in `~/bin`, checks disk space and that the input files exist |
| 01 | `01_check_files.sh` | Runs `gzip -t`, checks whether the archive is a tarball, shows the event-log header, writes a manifest with checksums |
| 02 | `02_flatten_cases.sh` → `flatten_scales.py` | `flatten_scales.py` uses only the Python standard library. It streams through the tarball (`tarfile` mode `r\|gz`), writes five gzip JSON-lines tables plus `keys_report.csv` and `convert_to_parquet.sql`, and DuckDB then writes the Parquet files |
| 03 | `03_convert_eventlog.sh` | DuckDB `read_csv` with type detection on the full file (`sample_size=-1`) and `store_rejects`, written to Parquet |
| 04 | `04_profile.sh` | Column summaries (`SUMMARIZE`), samples, coverage and structure breakdowns, and the link between the event log and the cases |

`run_all.sh` runs steps 00 to 04 in order. `submit_farmshare.sbatch` runs it as a Slurm batch job.

## Rules
1. **Keep everything.** Don't filter or drop cases, rows or columns, or sample the data (other than the 10,000-row profile samples), unless I approve.
2. **Never unpack the archive into individual files.** That would mean 676,809 files and could hit FarmShare's limit on the number of files. Always stream it.
3. **Keep contact details out.** Party and counsel addresses, phone numbers, emails and fax numbers stay out unless I set `KEEP_CONTACT_INFO="yes"`. Don't print raw case records containing personal details in your summaries to me. Column names, types, counts and short snippets are fine.
4. **No analysis.** Don't model the data or look for relationships between variables. I'll set aside a holdout before any analysis. Profiling structure (types, missingness, ranges, coverage, how the tables link) is fine.
5. **Ask before changing what the scripts produce**, such as adding or removing columns or tables.

## Environment
- FarmShare: Linux (Ubuntu 24.04), no root access, Slurm scheduler. Run long steps through `sbatch`, not on the login node. Check partition names and limits in the FarmShare docs (https://docs.farmshare.stanford.edu/) and adjust the `#SBATCH` lines if needed.
- Check `df -h ~`, `df -i ~` and my quota first. If home is too small, point `PROJECT_DIR` at `/scratch` and tell me what you changed.
- The scripts were tested only in a sandbox, on a small fake archive and event log built to match the documented format, using the DuckDB Python package (v1.5) in place of the command-line tool. They have **never run on the real files or on FarmShare**.

## Please check these on the real data
- **Archive layout.** Is it really a tarball, and are paths really `…/<year>/<court>/<file>.json`? The code takes `year_dir` and `court_dir` from the last two folder names in the path. If it's actually JSON-lines, the script falls back to reading one case per line. Confirm which happened.
- **Schema differences.** Look at `keys_report.csv` for fields that differ from what `flatten_scales.py` expects: renamed fields, `parties` stored as a dict instead of a list, date formats not covered by `to_iso_date`. Propose fixes, but ask before adding new columns.
- **Error counts.** `parse_errors.csv` should be zero or tiny. Also check the event log's `rejected_lines`.
- **Event-log columns and link.** Check which column holds the case ID (the profile guesses the first column name matching `ucid|case_?id|case id`), whether it matches `cases.ucid`, and if not, how the ID formats differ.
- **Case count.** Total cases should be 676,809. Explain how they split across `year_dir`, `source` and filing year, given SCALES's published counts of 247,416 for 2016 and 319,718 for 2017.
- **Run time and memory.** `SUMMARIZE` on `docket_entries`, which holds the full docket text, may be slow or memory-hungry. If it fails, propose a lighter alternative before changing anything.

## What to give me at the end
1. A short plain-language summary: what ran, how long each step took, row and column counts per table, and disk usage.
2. A `CHANGES.md` file listing every edit you made and why. I need this for the project's AI-use disclosure.
3. The path to the log file.
4. Anything you weren't sure about.
