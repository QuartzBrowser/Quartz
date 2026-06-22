#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="${PRODUCT_NAME:-Quartz}"
BUNDLE_ID="${BUNDLE_ID:-org.quartzbrowser.Quartz}"
VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"
APP_DIR="${DIST_DIR}/${PRODUCT_NAME}.app"

cd "${ROOT_DIR}"

BIN_DIR="$(swift build --show-bin-path -c "${CONFIGURATION}" --arch arm64 --arch x86_64)"
EXECUTABLE="${BIN_DIR}/${PRODUCT_NAME}"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "error: expected executable at ${EXECUTABLE}" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
chmod 755 "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CODESIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${CODESIGN_ARGS[@]}" "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

if [[ "${ZIP_APP:-0}" == "1" ]]; then
    ditto -c -k --keepParent "${APP_DIR}" "${DIST_DIR}/${PRODUCT_NAME}.zip"
fi

echo "Built ${APP_DIR}"
