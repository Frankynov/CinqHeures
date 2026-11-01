#!/bin/bash
# CI health check for the iPhone and iPad app (see .github/workflows/apple.yml): a first launch on an
# iPhone simulator, then a launch on an iPad simulator with the catalogue already there (copied from
# the iPhone, so 5heures.be is asked only once). Records CPU and memory, with light and dark screenshots.
#
#   Tools/ci/measure-ios.sh path/to/5heures.app          IOS_DEVICES="ipad" for the iPad alone
set -uo pipefail
cd "$(dirname "$0")/../.."
APP_PATH=$1
OUT=health/ios
mkdir -p "$OUT"
BUNDLE=be.cinqheures.player
IPHONE=$(python3 Tools/ci/simulator.py iPhone)
IPAD=$(python3 Tools/ci/simulator.py iPad)
SAVED=$(mktemp -d)

run() {   # device, label, seconds, phases, screenshot times, stack sample times
  local device=$1 label=$2 data pid
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 2>/dev/null || true
  xcrun simctl ui "$device" appearance light
  xcrun simctl install "$device" "$APP_PATH"
  if [ -d "$SAVED/CinqHeures" ]; then
    data=$(xcrun simctl get_app_container "$device" "$BUNDLE" data)
    mkdir -p "$data/Library/Application Support"
    cp -R "$SAVED/CinqHeures" "$data/Library/Application Support/"
    ls -l "$data/Library/Application Support/CinqHeures"
  fi
  echo "$label: launching at $(date +%T)"
  pid=$(xcrun simctl launch "$device" "$BUNDLE" | awk '{print $NF}')
  python3 Tools/ci/sample.py --pid "$pid" --seconds "$3" --label "$label" --out "$OUT" \
    --phases "$4" --shot-at "$5" --shot "xcrun simctl io $device screenshot {path}" \
    --stacks-at "$6" --binary 5heures
  xcrun simctl ui "$device" appearance dark
  sleep 4
  xcrun simctl io "$device" screenshot "$OUT/$label-dark.png"
  if [ ! -d "$SAVED/CinqHeures" ]; then
    data=$(xcrun simctl get_app_container "$device" "$BUNDLE" data)
    cp -R "$data/Library/Application Support/CinqHeures" "$SAVED/" 2>/dev/null || true
  fi
  xcrun simctl terminate "$device" "$BUNDLE" 2>/dev/null || true
  xcrun simctl shutdown "$device" 2>/dev/null || true
}

for device in ${IOS_DEVICES:-iphone ipad}; do
  case $device in
    iphone) run "$IPHONE" iphone-first-launch 120 "0-30,30-80,80-120" "20,60,115" "15,90" ;;
    ipad)
      if [ -d "$SAVED/CinqHeures" ]; then label=ipad-second-launch; else label=ipad-first-launch; fi
      run "$IPAD" "$label" 120 "0-20,20-60,60-120" "30,115" "10,50,100" ;;
  esac
done
