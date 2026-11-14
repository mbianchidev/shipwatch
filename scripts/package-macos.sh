#!/bin/bash
# Builds dist/Shipwatch.dmg: a universal (Apple Silicon + Intel), ad-hoc signed menu bar app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${SHIPWATCH_VERSION:-dev}"
CLIENT_ID="${SHIPWATCH_CLIENT_ID:-}"
APP_SLUG="${SHIPWATCH_APP_SLUG:-}"

die() { echo "Packaging failed: $1" >&2; exit 1; }

UNIVERSAL_BUILD=0
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = "--universal-build" ] \
    || die "Usage: bash scripts/package-macos.sh [--universal-build]"
  UNIVERSAL_BUILD=1
fi

[ "$(uname -s)" = "Darwin" ] || die "macOS is required."
if [ "$VERSION" = "dev" ]; then
  BUNDLE_VERSION="0.0.0"
elif [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  BUNDLE_VERSION="${VERSION#v}"
else
  die "SHIPWATCH_VERSION must be 'dev' or a version such as v1.2.3."
fi
[[ "$CLIENT_ID" =~ ^[A-Za-z0-9._-]*$ ]] || die "SHIPWATCH_CLIENT_ID may only contain letters, digits, '.', '_' and '-'."
[[ "$APP_SLUG" =~ ^[A-Za-z0-9-]*$ ]] || die "SHIPWATCH_APP_SLUG may only contain letters, digits and '-'."

mkdir -p "$ROOT/.build" "$DIST"
STAGE="$(mktemp -d "$ROOT/.build/macos-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/image/Shipwatch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BUILD_ARGS=(--package-path "$ROOT" -c release --jobs "$(sysctl -n hw.logicalcpu)")
if [ "$UNIVERSAL_BUILD" -eq 1 ]; then
  echo "Building universal Shipwatch..."
  BUILD_ARGS+=(--build-system swiftbuild --arch arm64 --arch x86_64)
  swift build "${BUILD_ARGS[@]}" --product Shipwatch
  cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Shipwatch" "$STAGE/Shipwatch"
else
  BINARIES=()
  for ARCH in arm64 x86_64; do
    echo "Building Shipwatch for $ARCH..."
    swift build "${BUILD_ARGS[@]}" --product Shipwatch --arch "$ARCH"
    cp "$(swift build "${BUILD_ARGS[@]}" --arch "$ARCH" --show-bin-path)/Shipwatch" "$STAGE/Shipwatch-$ARCH"
    lipo "$STAGE/Shipwatch-$ARCH" -verify_arch "$ARCH"
    BINARIES+=("$STAGE/Shipwatch-$ARCH")
  done
  lipo -create "${BINARIES[@]}" -output "$STAGE/Shipwatch"
fi
for ARCH in arm64 x86_64; do
  lipo "$STAGE/Shipwatch" -verify_arch "$ARCH"
done
cp "$STAGE/Shipwatch" "$APP/Contents/MacOS/Shipwatch"

PLIST="$APP/Contents/Info.plist"
cp "$ROOT/packaging/macos/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :ShipwatchClientID $CLIENT_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :ShipwatchAppSlug $APP_SLUG" "$PLIST"
plutil -lint "$PLIST" > /dev/null || die "Info.plist is invalid."

echo "Rendering app icon..."
swift run --package-path "$ROOT" ShipwatchSnapshots --iconset "$STAGE/AppIcon.iconset"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"

codesign --force --sign - --identifier dev.mbianchi.shipwatch "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$STAGE/image/Applications"
cp "$ROOT/packaging/macos/Install.txt" "$STAGE/image/Install.txt"
hdiutil create -quiet -volname Shipwatch -srcfolder "$STAGE/image" \
  -fs HFS+ -format UDZO "$STAGE/Shipwatch.dmg"
shasum -a 256 "$STAGE/Shipwatch.dmg" | awk '{print $1}' > "$STAGE/Shipwatch.dmg.sha256"

for ASSET in Shipwatch.dmg Shipwatch.dmg.sha256; do
  [ ! -d "$DIST/$ASSET" ] || die "Refusing to overwrite directory $DIST/$ASSET."
  mv -f "$STAGE/$ASSET" "$DIST/$ASSET"
done
[ -n "$CLIENT_ID" ] || echo "Note: no SHIPWATCH_CLIENT_ID baked in; set the GitHub App in Settings > Account or use the gh fallback."
echo "Packaged $DIST/Shipwatch.dmg ($VERSION, Apple Silicon and Intel)."
