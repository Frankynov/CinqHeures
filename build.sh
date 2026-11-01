#!/bin/bash
# Builds 5heures and assembles a double-clickable .app bundle.
# No Xcode required — just the Swift toolchain from the Command Line Tools.
#
#   ./build.sh            release, this Mac's architecture
#   ./build.sh universal  release, Apple silicon + Intel in one binary
#   ./build.sh debug      debug, much faster to build
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-release}
APP="build/5heures.app"
APP_VERSION="1.3"
DEPLOYMENT=14.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$MODE" = universal ]; then
  # A build folder per architecture: SwiftPM puts every triple's product at the same path, so the
  # second build would overwrite the first.
  SLICES=()
  for arch in arm64 x86_64; do
    echo "▸ Compiling (release, $arch)…"
    FOLDER=".build/universal-$arch"
    swift build -c release --product CinqHeures --triple "$arch-apple-macosx$DEPLOYMENT" --scratch-path "$FOLDER"
    SLICES+=("$(swift build -c release --triple "$arch-apple-macosx$DEPLOYMENT" --scratch-path "$FOLDER" --show-bin-path)/CinqHeures")
  done
  echo "▸ Joining into a universal binary…"
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/CinqHeures"
else
  echo "▸ Compiling ($MODE)…"
  swift build -c "$MODE" --product CinqHeures
  cp "$(swift build -c "$MODE" --show-bin-path)/CinqHeures" "$APP/Contents/MacOS/CinqHeures"
fi
# Drop the debug map: it lists every source folder by its path on this Mac.
[ "$MODE" = debug ] || strip -S "$APP/Contents/MacOS/CinqHeures"

# The icon. With Xcode installed, actool turns the layered Icon Composer document into the
# Liquid Glass icon (light, dark and tinted looks). Without it, the pre-composed .icns is used.
ICON_NAME_KEY=""
if xcrun --find actool >/dev/null 2>&1 && [ -d Resources/Icon/AppIcon.icon ]; then
  if xcrun actool Resources/Icon/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
       --minimum-deployment-target 26.0 --app-icon AppIcon --include-all-app-icons \
       --output-partial-info-plist /dev/null >/dev/null 2>&1; then
    ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
    echo "▸ Icon: compiled from AppIcon.icon"
  else
    echo "  (actool could not build AppIcon.icon, using AppIcon.icns)"
  fi
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>5heures</string>
  <key>CFBundleDisplayName</key><string>5heures</string>
  <key>CFBundleExecutable</key><string>CinqHeures</string>
  <key>CFBundleIdentifier</key><string>be.cinqheures.player</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICON_NAME_KEY
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
echo "▸ Done: $APP"
lipo -archs "$APP/Contents/MacOS/CinqHeures" | sed 's/^/  architectures: /'
