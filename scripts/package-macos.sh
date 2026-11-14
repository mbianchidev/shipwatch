#!/bin/bash
# Builds dist/Shipwatch.dmg: a universal (Apple Silicon + Intel), ad-hoc signed menu bar app
# in a drag-to-Applications installer window laid out by dmgbuild (needs Python 3.10+).
# With SHIPWATCH_UPDATE_SIGNING_KEY set, also signs it for the self-updater as dist/Shipwatch.dmg.sig.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${SHIPWATCH_VERSION:-dev}"
CLIENT_ID="${SHIPWATCH_CLIENT_ID:-}"
APP_SLUG="${SHIPWATCH_APP_SLUG:-}"

die() { echo "Packaging failed: $1" >&2; exit 1; }
# shellcheck source=scripts/dmgbuild-env.sh
. "$ROOT/scripts/dmgbuild-env.sh"

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
# Keep the update signing key out of the environment of every build step; only the release tool gets it.
UPDATE_SIGNING_KEY="${SHIPWATCH_UPDATE_SIGNING_KEY:-}"
unset SHIPWATCH_UPDATE_SIGNING_KEY
if [ -n "$UPDATE_SIGNING_KEY" ] && [ "$VERSION" = "dev" ]; then
  die "a dev build must not be signed as an update. Set SHIPWATCH_VERSION or unset SHIPWATCH_UPDATE_SIGNING_KEY."
fi

mkdir -p "$ROOT/.build" "$DIST"
rm -f "$DIST/Shipwatch.dmg.sig"
STAGE="$(mktemp -d "$ROOT/.build/macos-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/image/Shipwatch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BUILD_ARGS=(--package-path "$ROOT" -c release --jobs "$(sysctl -n hw.logicalcpu)")
PRODUCTS=(Shipwatch ShipwatchUpdateHelper)
if [ "$UNIVERSAL_BUILD" -eq 1 ]; then
  BUILD_ARGS+=(--build-system swiftbuild --arch arm64 --arch x86_64)
  for PRODUCT in "${PRODUCTS[@]}"; do
    echo "Building universal $PRODUCT..."
    swift build "${BUILD_ARGS[@]}" --product "$PRODUCT"
    cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT" "$STAGE/$PRODUCT"
  done
else
  for PRODUCT in "${PRODUCTS[@]}"; do
    BINARIES=()
    for ARCH in arm64 x86_64; do
      echo "Building $PRODUCT for $ARCH..."
      swift build "${BUILD_ARGS[@]}" --product "$PRODUCT" --arch "$ARCH"
      cp "$(swift build "${BUILD_ARGS[@]}" --arch "$ARCH" --show-bin-path)/$PRODUCT" "$STAGE/$PRODUCT-$ARCH"
      lipo "$STAGE/$PRODUCT-$ARCH" -verify_arch "$ARCH"
      BINARIES+=("$STAGE/$PRODUCT-$ARCH")
    done
    lipo -create "${BINARIES[@]}" -output "$STAGE/$PRODUCT"
  done
fi
for PRODUCT in "${PRODUCTS[@]}"; do
  for ARCH in arm64 x86_64; do
    lipo "$STAGE/$PRODUCT" -verify_arch "$ARCH"
  done
done
cp "$STAGE/Shipwatch" "$APP/Contents/MacOS/Shipwatch"
mkdir -p "$APP/Contents/Helpers"
cp "$STAGE/ShipwatchUpdateHelper" "$APP/Contents/Helpers/ShipwatchUpdateHelper"

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

# Nested code is signed first; the app signature then seals the signed helper.
codesign --force --sign - --identifier dev.mbianchi.shipwatch.update-helper "$APP/Contents/Helpers/ShipwatchUpdateHelper"
codesign --force --sign - --identifier dev.mbianchi.shipwatch "$APP"
codesign --verify --deep --strict "$APP"

echo "Building the installer disk image..."
cp "$ROOT/packaging/macos/Install.txt" "$STAGE/image/Install.txt"
swift run --package-path "$ROOT" ShipwatchSnapshots --dmg-background "$STAGE/image/background"
DMG_PYTHON="$(dmgbuild_python "$ROOT")" || die "dmgbuild is unavailable."
"$DMG_PYTHON" "$ROOT/scripts/dmg-layout.py" build "$STAGE/image" "$STAGE/Shipwatch.dmg" \
  || die "dmgbuild could not create the disk image."
shasum -a 256 "$STAGE/Shipwatch.dmg" | awk '{print $1}' > "$STAGE/Shipwatch.dmg.sha256"

for ASSET in Shipwatch.dmg Shipwatch.dmg.sha256; do
  [ ! -d "$DIST/$ASSET" ] || die "Refusing to overwrite directory $DIST/$ASSET."
  mv -f "$STAGE/$ASSET" "$DIST/$ASSET"
done
[ -n "$CLIENT_ID" ] || echo "Note: no SHIPWATCH_CLIENT_ID baked in; set the GitHub App in Settings > Account or use the gh fallback."
echo "Packaged $DIST/Shipwatch.dmg ($VERSION, Apple Silicon and Intel)."

if [ -n "$UPDATE_SIGNING_KEY" ]; then
  echo "Signing the update..."
  swift build --package-path "$ROOT" --product ShipwatchReleaseTool
  SHIPWATCH_UPDATE_SIGNING_KEY="$UPDATE_SIGNING_KEY" \
    "$(swift build --package-path "$ROOT" --show-bin-path)/ShipwatchReleaseTool" \
    sign "$DIST/Shipwatch.dmg" --version "$BUNDLE_VERSION"
else
  echo "Note: SHIPWATCH_UPDATE_SIGNING_KEY is not set, so the DMG is unsigned for updates and installed copies won't accept it."
fi
