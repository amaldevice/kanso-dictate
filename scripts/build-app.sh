#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
APP_NAME="Kanso Dictate"
BUNDLE_DIR=".build/bin/${APP_NAME}.app"

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

echo "==> Applying ad-hoc codesign with entitlements..."
codesign --force --sign - \
    --entitlements "Sources/KansoDictate/Resources/KansoDictate.entitlements" \
    "${BUNDLE_DIR}"

echo "==> Successfully packaged ${BUNDLE_DIR}"
