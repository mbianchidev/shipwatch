#!/bin/bash
# Verifies dist/Shipwatch.dmg without launching the app or Finder: checksum, installer layout,
# bundle metadata, icon, signatures, update helper and architectures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
die() { echo "Package check failed: $1" >&2; exit 1; }
# shellcheck source=scripts/dmgbuild-env.sh
. "$ROOT/scripts/dmgbuild-env.sh"
DMG_PYTHON="$(dmgbuild_python "$ROOT")" || die "dmgbuild is unavailable."

mkdir -p "$ROOT/.build"
STAGE="$(mktemp -d "$ROOT/.build/macos-package-checks.XXXXXX")"
MOUNT="$STAGE/mount"
MOUNTED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$MOUNTED" -eq 1 ] && ! hdiutil detach -quiet "$MOUNT"; then
    echo "Could not unmount $MOUNT. Temporary files were left in $STAGE." >&2
    exit 1
  fi
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT

DMG="$DIST/Shipwatch.dmg"
[ -f "$DMG" ] || die "Missing $DMG. Run scripts/package-macos.sh first."
printf '%s  %s\n' "$(cat "$DMG.sha256")" "$DMG" | shasum -a 256 -c - > /dev/null || die "Checksum mismatch for $DMG."
hdiutil verify -quiet "$DMG"
mkdir -p "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
MOUNTED=1

APP="$MOUNT/Shipwatch.app"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plutil -lint "$PLIST" > /dev/null || die "Info.plist is invalid."
[ "$(plist CFBundleIdentifier)" = "dev.mbianchi.shipwatch" ] || die "Incorrect bundle identifier."
[ "$(plist CFBundleExecutable)" = "Shipwatch" ] || die "Incorrect executable name."
[ "$(plist CFBundleIconFile)" = "AppIcon" ] || die "Incorrect icon resource."
[ "$(plist LSMinimumSystemVersion)" = "14.0" ] || die "Incorrect minimum macOS version."
[ "$(plist LSUIElement)" = "true" ] || die "Shipwatch must be a menu bar (LSUIElement) app."
[ "$(plist CFBundleShortVersionString)" = "$(plist CFBundleVersion)" ] || die "Bundle versions disagree."
plist ShipwatchClientID > /dev/null || die "Missing ShipwatchClientID key."
plist ShipwatchAppSlug > /dev/null || die "Missing ShipwatchAppSlug key."

[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  || die "Missing drag-to-Applications shortcut."
grep -Fq 'Open Anyway for Shipwatch' "$MOUNT/Install.txt" || die "Missing Open Anyway instructions in Install.txt."
! grep -Fq 'xattr' "$MOUNT/Install.txt" || die "Install.txt must not suggest removing quarantine."
"$DMG_PYTHON" "$ROOT/scripts/dmg-layout.py" verify "$MOUNT" || die "Installer window layout is incorrect."

iconutil --convert iconset --output "$STAGE/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
for POINTS in 16 32 128 256 512; do
  for SCALE in 1 2; do
    ICON="$STAGE/AppIcon.iconset/icon_${POINTS}x${POINTS}.png"
    [ "$SCALE" -eq 1 ] || ICON="$STAGE/AppIcon.iconset/icon_${POINTS}x${POINTS}@2x.png"
    [ -f "$ICON" ] || die "Missing app icon size: $ICON."
    PIXELS=$((POINTS * SCALE))
    DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$ICON" | awk '/pixelWidth|pixelHeight/ {print $2}')"
    [ "$DIMENSIONS" = "$(printf '%s\n%s' "$PIXELS" "$PIXELS")" ] || die "Incorrect app icon dimensions: $ICON."
    [ "$(sips -g hasAlpha "$ICON" | awk '/hasAlpha/ {print $2}')" = "yes" ] || die "App icon needs an alpha channel: $ICON."
  done
done

codesign --verify --deep --strict "$APP"
for ARCH in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/Shipwatch" -verify_arch "$ARCH" || die "Executable lacks $ARCH."
done
HELPER="$APP/Contents/Helpers/ShipwatchUpdateHelper"
[ -f "$HELPER" ] && [ -x "$HELPER" ] || die "Missing executable update helper."
for ARCH in arm64 x86_64; do
  lipo "$HELPER" -verify_arch "$ARCH" || die "Update helper lacks $ARCH."
done
codesign --verify --strict -R='identifier "dev.mbianchi.shipwatch.update-helper"' "$HELPER" \
  || die "Update helper signature or identifier is invalid."
INSTALLED_APP="$STAGE/Mock Applications/Shipwatch.app"
ditto "$APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

if [ -e "$DMG.sig" ]; then
  swift run --package-path "$ROOT" ShipwatchReleaseTool verify "$DMG" "$DMG.sig" \
    --version "$(plist CFBundleShortVersionString)" || die "Update signature verification failed."
else
  echo "Note: no $DMG.sig, so the update signature was not checked."
fi
echo "macOS package checks passed."
