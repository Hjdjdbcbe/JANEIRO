#!/usr/bin/env bash
# Refresh the self-hosted webfonts in frontend/assets/fonts/.
#
# The @font-face block lives at the top of frontend/index.html's <style>;
# if a unicode-range changes upstream it has to be updated there too. Only
# the arabic and latin subsets are shipped. Cairo is a variable font: the
# css2 API returns the same binary for every static weight, so one file per
# subset is kept and declared as `font-weight: 400 700`.
set -euo pipefail
cd "$(dirname "$0")/.."
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
API=https://fonts.googleapis.com/css2

get() { curl -sfS -A "$UA" "$API?$1&display=swap"; }
css=$( { get 'family=Lalezar'; get 'family=Cairo:wght@400;700'; get 'family=IBM+Plex+Mono:wght@400;500;600'; } )

echo "$css" | grep -B1 -A6 '@font-face' > /dev/null || { echo "no @font-face returned"; exit 1; }
echo "Fetched CSS. Font files currently on disk:"
ls -la frontend/assets/fonts/
echo
echo "Compare the unicode-range values above against the @font-face block"
echo "in frontend/index.html before replacing any .woff2 file."
