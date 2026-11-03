#!/bin/zsh
# Refreshes the catalogue shipped inside the apps (Resources/Snapshot) from this Mac's own copy, so a
# first launch starts with every episode and every film already matched on TMDB instead of
# downloading them. Run it before a release, after letting the app refresh and finish its lookups.
set -e
cd "${0:A:h}/.."
FROM="$HOME/Library/Application Support/CinqHeures"
TO=Resources/Snapshot
mkdir -p $TO
python3 -I - "$FROM" "$TO" <<'PY'
import json, sys, os
src, dst = sys.argv[1], sys.argv[2]
catalogue = json.load(open(os.path.join(src, "catalogue.json")))
films = json.load(open(os.path.join(src, "films.json")))
schema = int(open("Sources/CinqHeuresCore/Catalogue.swift").read().split("currentSchema = ")[1].split()[0])
if catalogue.get("schema") != schema:
    sys.exit(f"The saved catalogue is schema {catalogue.get('schema')}, the app expects {schema}: launch the app first.")
for name, data in (("snapshot-catalogue.json", catalogue), ("snapshot-films.json", films)):
    with open(os.path.join(dst, name), "w") as out:
        json.dump(data, out, ensure_ascii=False, separators=(",", ":"))
print(f"{len(catalogue['episodes'])} episodes, {len(films['entries'])} films → {dst}")
PY
ls -lh $TO
