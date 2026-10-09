#!/bin/sh
# Run the tests, then copy the plugin and the NickelMenu entry to a mounted Kobo.
set -e
cd "$(dirname "$0")/.."
VOL="${1:-/Volumes/KOBOeReader}"
[ -d "$VOL/.adds/koreader/plugins" ] || { echo "No KOReader on $VOL (is the Kobo mounted?)" >&2; exit 1; }
[ -d "$VOL/.adds/nm" ] || { echo "No NickelMenu on $VOL" >&2; exit 1; }

for t in tools/test_*.lua; do luajit "$t" >/dev/null || { echo "$t failed" >&2; exit 1; }; done

rsync -a --delete --exclude '._*' --exclude '.DS_Store' \
    coloursketch.koplugin/ "$VOL/.adds/koreader/plugins/coloursketch.koplugin/"
cp nickelmenu/coloursketch "$VOL/.adds/nm/coloursketch"
dot_clean -m "$VOL"
echo "Installed to $VOL. Eject the Kobo; the NickelMenu entry appears after it reloads."
