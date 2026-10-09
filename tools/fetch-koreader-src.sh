#!/bin/sh
# Copy KOReader's Lua sources off the Kobo into .koreader-src/, so the tests
# run against the exact version on the device. Run with the Kobo mounted.
set -e
cd "$(dirname "$0")/.."
SRC="${1:-/Volumes/KOBOeReader/.adds/koreader}"
[ -d "$SRC/ffi" ] || { echo "No KOReader at $SRC (is the Kobo mounted?)" >&2; exit 1; }
mkdir -p .koreader-src
rsync -a --delete --exclude '._*' "$SRC/ffi" "$SRC/frontend" .koreader-src/
cp "$SRC/git-rev" .koreader-src/
echo "KOReader $(cat .koreader-src/git-rev) sources in .koreader-src/"
