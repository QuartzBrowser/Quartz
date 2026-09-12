#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="${PRODUCT_NAME:-Quartz}"
BUNDLE_ID="${BUNDLE_ID:-org.quartzbrowser.Quartz}"
VERSION_FILE="${ROOT_DIR}/version.txt"
DEFAULT_VERSION="0.0.0"
if [[ -f "${VERSION_FILE}" ]]; then
    DEFAULT_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
fi
if [[ -z "${DEFAULT_VERSION}" ]]; then
    DEFAULT_VERSION="0.0.0"
fi
VERSION="${VERSION:-${DEFAULT_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-${VERSION}}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"
APP_DIR="${DIST_DIR}/${PRODUCT_NAME}.app"
APP_ICON="${ROOT_DIR}/Sources/Quartz/Resources/AppIcon.icns"
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK:-${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "${BUILD_NUMBER}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: VERSION and BUILD_NUMBER must be numeric release versions" >&2
    exit 1
fi
if [[ "${SPARKLE_FEED_URL}" != https://* && "${ALLOW_INSECURE_TEST_FEED:-0}" != "1" ]]; then
    echo "error: the update feed must use HTTPS" >&2
    exit 1
fi
if [[ -n "${SPARKLE_PUBLIC_KEY}" ]]; then
    python3 - "${SPARKLE_PUBLIC_KEY}" <<'PY'
import base64, sys
try:
    valid = len(base64.b64decode(sys.argv[1], validate=True)) == 32
except ValueError:
    valid = False
if not valid:
    sys.exit("error: SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key")
PY
fi

cd "${ROOT_DIR}"

if [[ ! -f "${APP_ICON}" ]]; then
    echo "error: app icon not found at ${APP_ICON}" >&2
    exit 1
fi

BUILD_ARGS=(-c "${CONFIGURATION}" --arch arm64 --arch x86_64 --product "${PRODUCT_NAME}")
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build --show-bin-path "${BUILD_ARGS[@]}")"
EXECUTABLE="${BIN_DIR}/${PRODUCT_NAME}"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "error: expected executable at ${EXECUTABLE}" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
chmod 755 "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
cp "${APP_ICON}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
    echo "error: Sparkle framework not found at ${SPARKLE_FRAMEWORK}" >&2
    exit 1
fi
# ditto preserves the framework's symlinks and helper executable permissions.
ditto "${SPARKLE_FRAMEWORK}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
cp "${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/LICENSE" "${APP_DIR}/Contents/Resources/Sparkle-LICENSE.txt"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
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

# plistlib safely escapes URLs and other configuration values.
python3 - "${APP_DIR}/Contents/Info.plist" "${SPARKLE_FEED_URL}" "${SPARKLE_PUBLIC_KEY}" <<'PY'
import plistlib, sys
path, feed, key = sys.argv[1:]
with open(path, "rb") as source:
    info = plistlib.load(source)
info.update(SUFeedURL=feed, SUEnableAutomaticChecks=True,
            SUScheduledCheckInterval=3600, SUAutomaticallyUpdate=False,
            SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
            SURequireSignedFeed=True)
if key:
    info["SUPublicEDKey"] = key
with open(path, "wb") as target:
    plistlib.dump(info, target)
PY

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CODESIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi

# Sign nested code first. Do not use --deep for signing: helpers have distinct
# entitlements, and the Downloader must retain its own entitlements.
EMBEDDED_FRAMEWORK="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
xattr -cr "${APP_DIR}"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
codesign "${CODESIGN_ARGS[@]}" --preserve-metadata=entitlements "${EMBEDDED_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/Autoupdate"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/Updater.app"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}"
codesign "${CODESIGN_ARGS[@]}" "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
xcrun lipo "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}" -verify_arch arm64 x86_64
xcrun lipo "${EMBEDDED_FRAMEWORK}/Versions/B/Sparkle" -verify_arch arm64 x86_64

if [[ "${ZIP_APP:-0}" == "1" ]]; then
    ditto -c -k --norsrc --keepParent "${APP_DIR}" "${DIST_DIR}/${PRODUCT_NAME}.zip"
fi

echo "Built ${APP_DIR}"
