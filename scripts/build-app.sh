#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
APP_NAME="Kanso Dictate"
BUNDLE_DIR=".build/bin/${APP_NAME}.app"

# macOS TCC ties privacy grants (Accessibility, Input Monitoring, Microphone)
# to the app's code-signing identity. Ad-hoc signing yields a fresh cdhash on
# every build, so each rebuild+reinstall silently orphans existing grants while
# System Settings still shows the toggles ON. Set KANSO_CODESIGN_IDENTITY to a
# stable certificate name (self-signed code-signing cert or Developer ID) so
# grants survive rebuilds. Optionally point KANSO_CODESIGN_KEYCHAIN at the
# keychain holding it.
IDENTITY="${KANSO_CODESIGN_IDENTITY:-}"

echo "==> Building ${APP_NAME} (${CONFIGURATION})..."
swift build -c "${CONFIGURATION}"

BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)/KansoDictate"

echo "==> Packaging into ${BUNDLE_DIR}..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${BUNDLE_DIR}/Contents/MacOS/KansoDictate"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/KansoDictate"
ln -sf "KansoDictate" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
cp "Sources/KansoDictate/Resources/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
cp "Sources/KansoDictate/Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

KEYCHAIN_ARGS=()
if [[ -n "${KANSO_CODESIGN_KEYCHAIN:-}" ]]; then
    KEYCHAIN_ARGS=(--keychain "${KANSO_CODESIGN_KEYCHAIN}")
fi

SIGNER="-"
if [[ -n "${IDENTITY}" ]]; then
    SIGNER="${IDENTITY}"
    echo "==> Codesigning with stable identity '${IDENTITY}' (TCC grants survive rebuilds)..."
else
    echo "==> WARNING: KANSO_CODESIGN_IDENTITY not set; falling back to ad-hoc signing." >&2
    echo "==>          macOS will silently revoke Accessibility / Input Monitoring /" >&2
    echo "==>          Microphone after every rebuild: the System Settings toggle stays" >&2
    echo "==>          ON but the app reports Not Granted. See README 'Stable Signing'." >&2
fi

codesign --force --sign "${SIGNER}" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    --entitlements "Sources/KansoDictate/Resources/KansoDictate.entitlements" \
    "${BUNDLE_DIR}"

echo "==> Successfully packaged ${BUNDLE_DIR}"
