#!/bin/bash
# Downloads every episode of every series from 5heures.be into one folder of JSON pages,
# the same requests the app makes (named client, polite pace). Usage: crawl.sh <folder>
set -euo pipefail
OUT=${1:?folder}
UA="CinqHeures/1.0 (personal podcast player)"
mkdir -p "$OUT"
CONFIG=$(curl -s -A "$UA" https://5heures.be/api/config)
python3 -I -c '
import json,sys
for kind, years in json.loads(sys.argv[1])["config"]["years_for_kinds"].items():
    for y in years: print(kind, y)
' "$CONFIG" | while read -r kind year; do
  page=1
  while :; do
    f="$OUT/$kind-$year-$page.json"
    curl -s -A "$UA" "https://5heures.be/api/podcasts?per_page=100&year=$year&kind=$kind&page=$page" -o "$f"
    total=$(python3 -I -c "import json;print(json.load(open('$f'))['pagination']['total_pages'])")
    [ "$page" -ge "$total" ] && break
    page=$((page+1))
  done
  sleep 0.2
done
