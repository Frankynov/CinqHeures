#!/bin/bash
# CI health check for the Mac app (see .github/workflows/apple.yml): a first launch with nothing
# saved, then a second launch with the catalogue already downloaded. Records CPU and memory every
# two seconds and takes screenshots, when the runner allows screen capture.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=health/mac
mkdir -p "$OUT"
APP="$PWD/build/5heures.app"
BINARY="$APP/Contents/MacOS/CinqHeures"

# A real first launch: nothing left from an earlier run.
rm -rf "$HOME/Library/Application Support/CinqHeures" "$HOME/Library/Caches/CinqHeures" \
       "$HOME/Library/Caches/be.cinqheures.player"
defaults delete be.cinqheures.player >/dev/null 2>&1 || true

launch() {   # label, seconds, phases, screenshot times, stack sample times
  open "$APP"
  local pid=""
  for _ in $(seq 1 100); do
    pid=$(pgrep -n -f "$BINARY" || true)
    [ -n "$pid" ] && break
    sleep 0.2
  done
  if [ -z "$pid" ]; then echo "The app didn't start"; return 1; fi
  python3 Tools/ci/sample.py --pid "$pid" --seconds "$2" --label "$1" --out "$OUT" \
    --phases "$3" --shot-at "$4" --shot 'screencapture -x {path}' --stacks-at "$5" --binary CinqHeures
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
}

launch mac-first-launch 150 "0-30,30-90,90-150" "25,70,145" "15,100"
launch mac-second-launch 90 "0-20,20-60,60-90" "30,85" "8,50"
du -sh "$HOME/Library/Application Support/CinqHeures" "$HOME/Library/Caches/CinqHeures" 2>/dev/null || true
