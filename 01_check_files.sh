#!/usr/bin/env bash
# =============================================================================
# 01_check_files.sh — confirm the case archive is complete and see what kind
# of file it is, before spending an hour processing it.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

echo "== 1. Case archive: $CASES_ARCHIVE"
echo "   testing that the .gz is not corrupted (a few minutes)..."
if gzip -t "$CASES_ARCHIVE"; then echo "   OK: archive is intact"
else echo "   STOP: the archive is corrupted or incomplete. Re-download it."; exit 1; fi
echo "   first 15 entries (if it is a .tar.gz, these are file paths):"
entries=$(tar -tzf "$CASES_ARCHIVE" 2>/dev/null | head -n 15 || true)
echo "$entries" | sed 's/^/      /'
if [ -n "$entries" ]; then
  echo "   -> looks like a TAR archive of many files (expected)."
else
  echo "   -> NOT a tar archive. First 300 characters of its contents:"
  gzip -cd "$CASES_ARCHIVE" | head -c 300 || true; echo
fi

echo
echo "== 2. Writing a manifest (size + checksum) for the code upload, handout section 9"
manifest="$RAW_DIR/download_manifest.txt"
{
  echo "SCALES OKN file-server download, checked $(date -u '+%Y-%m-%d %H:%M UTC')"
  ls -l "$CASES_ARCHIVE"
  sha256sum "$CASES_ARCHIVE"
} > "$manifest"
cat "$manifest"
