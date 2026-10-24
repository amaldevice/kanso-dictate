#!/usr/bin/env bash
set -euo pipefail

# Builds the .app (via build-app.sh, honoring KANSO_CODESIGN_IDENTITY), then
# packs a drag-to-Applications DMG: Finder window layout via AppleScript over
# a read-write image, converted to compressed UDZO. The Finder step needs
# Automation permission once; if unavailable the DMG still builds with a
# default layout.

CONFIGURATION="${1:-release}"
APP_NAME="Kanso Dictate"
VOLNAME="Kanso Dictate"
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/KansoDictate/Resources/Info.plist)"
DMG_PATH=".build/bin/Kanso-Dictate-v${VERSION}-macos-arm64.dmg"
RW_DMG=".build/bin/Kanso-Dictate-rw.dmg"
STAGING=".build/dmg-staging"
IDENTITY="${KANSO_CODESIGN_IDENTITY:-}"

echo "==> Building app (${CONFIGURATION})..."
./scripts/build-app.sh "${CONFIGURATION}"

echo "==> Staging DMG contents..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}/.background"
cp -R ".build/bin/${APP_NAME}.app" "${STAGING}/"
ln -sf /Applications "${STAGING}/Applications"
cp docs/assets/dmg-background.png "${STAGING}/.background/dmg-background.png"

echo "==> Creating read-write DMG..."
rm -f "${RW_DMG}"
hdiutil create -srcfolder "${STAGING}" -volname "${VOLNAME}" -fs HFS+ -format UDRW -ov -quiet "${RW_DMG}"

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}" | grep 'Apple_HFS' | awk '{print $1}' | head -1)"
cleanup() { hdiutil detach "${DEVICE}" -quiet >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Applying Finder window layout..."
sleep 1
OSA_SCRIPT="$(mktemp -t kansodmg).applescript"
cat > "${OSA_SCRIPT}" <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Kanso Dictate"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {0, 0, 660, 400}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:dmg-background.png"
        set position of item "Kanso Dictate" of container window to {180, 160}
        set position of item "Applications" of container window to {480, 160}
        update without registering applications
        delay 2
        close
        delay 1
    end tell
end tell
APPLESCRIPT
if ! osascript "${OSA_SCRIPT}" >/dev/null 2>&1; then
    echo "==> WARNING: Finder layout failed (Automation permission denied?); DMG ships with default layout." >&2
fi
rm -f "${OSA_SCRIPT}"
# Give Finder time to flush the .DS_Store before the volume is detached.
sleep 3

echo "==> Converting to compressed DMG..."
hdiutil detach "${DEVICE}" -quiet
DEVICE=""
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "${DMG_PATH}"
rm -f "${RW_DMG}"

if [[ -n "${IDENTITY}" ]]; then
    echo "==> Codesigning DMG with '${IDENTITY}'..."
    codesign --sign "${IDENTITY}" "${DMG_PATH}"
fi

hdiutil verify "${DMG_PATH}" -quiet
echo "==> Successfully packaged ${DMG_PATH}"
