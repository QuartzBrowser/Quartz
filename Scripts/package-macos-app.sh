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
read -r -a APP_ARCHS <<< "${QUARTZ_APP_ARCHS:-arm64 x86_64}"
if [[ "${#APP_ARCHS[@]}" == 0 || "${#APP_ARCHS[@]}" -gt 2 || ( "${#APP_ARCHS[@]}" == 2 && "${APP_ARCHS[0]}" == "${APP_ARCHS[1]}" ) ]]; then
    echo "error: QUARTZ_APP_ARCHS must contain arm64, x86_64, or both" >&2
    exit 1
fi
ENGINE_ARCH_ARGS=()
LAUNCHER_ARCH_ARGS=()
for architecture in "${APP_ARCHS[@]}"; do
    case "${architecture}" in
        arm64|x86_64)
            ENGINE_ARCH_ARGS+=(--arch "${architecture}")
            LAUNCHER_ARCH_ARGS+=(-arch "${architecture}") ;;
        *) echo "error: unsupported Quartz architecture: ${architecture}" >&2; exit 1 ;;
    esac
done

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

USE_FORK_WEBKIT=1
MINIMUM_SYSTEM_VERSION=14.0
if [[ "${QUARTZ_USE_SYSTEM_WEBKIT:-0}" == 1 ]]; then
    USE_FORK_WEBKIT=0
    unset QUARTZ_WEBKIT_PRODUCTS_DIR
else
    export QUARTZ_WEBKIT_PRODUCTS_DIR="${QUARTZ_WEBKIT_PRODUCTS_DIR:-${ROOT_DIR}/.build/quartz-webkit/products/Release}"
    python3 "${ROOT_DIR}/Scripts/webkit-bundle.py" verify "${QUARTZ_WEBKIT_PRODUCTS_DIR}" "${ENGINE_ARCH_ARGS[@]}" > /dev/null
fi

if [[ ! -f "${APP_ICON}" ]]; then
    echo "error: app icon not found at ${APP_ICON}" >&2
    exit 1
fi

BUILD_ARGS=(-c "${CONFIGURATION}" "${ENGINE_ARCH_ARGS[@]}" --product "${PRODUCT_NAME}")
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build --show-bin-path "${BUILD_ARGS[@]}")"
EXECUTABLE="${BIN_DIR}/${PRODUCT_NAME}"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "error: expected executable at ${EXECUTABLE}" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks"

RUNTIME_EXECUTABLE_NAME="${PRODUCT_NAME}"
if [[ "${USE_FORK_WEBKIT}" == 1 ]]; then
    RUNTIME_EXECUTABLE_NAME=QuartzRuntime
fi
cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${RUNTIME_EXECUTABLE_NAME}"
chmod 755 "${APP_DIR}/Contents/MacOS/${RUNTIME_EXECUTABLE_NAME}"
cp "${APP_ICON}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
    echo "error: Sparkle framework not found at ${SPARKLE_FRAMEWORK}" >&2
    exit 1
fi
# ditto preserves the framework's symlinks and helper executable permissions.
ditto "${SPARKLE_FRAMEWORK}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
cp "${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/LICENSE" "${APP_DIR}/Contents/Resources/Sparkle-LICENSE.txt"

if [[ "${USE_FORK_WEBKIT}" == 1 ]]; then
    MINIMUM_SYSTEM_VERSION="$(python3 "${ROOT_DIR}/Scripts/webkit-bundle.py" embed \
        --products-dir "${QUARTZ_WEBKIT_PRODUCTS_DIR}" --app-dir "${APP_DIR}" \
        --executable "${RUNTIME_EXECUTABLE_NAME}" "${ENGINE_ARCH_ARGS[@]}")"
    # Sparkle displays release notes with WebKit. Its downloaded binary points
    # at the system engine, so redirect only our app's copy before signing.
    python3 "${ROOT_DIR}/Scripts/webkit-bundle.py" prepare-sparkle \
        --source-framework "${SPARKLE_FRAMEWORK}" \
        --output-dir "${APP_DIR}/Contents/Frameworks" \
        --products-dir "${APP_DIR}/Contents/Frameworks" \
        --manifest "${APP_DIR}/Contents/Resources/QuartzWebKit.json"
    # A small libc-only launcher supplies bundle-relative framework overrides
    # before dyld starts Swift/AppKit. This also redirects absolute engine links
    # in macOS integrations such as Quick Look after the browser has launched.
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
        "${LAUNCHER_ARCH_ARGS[@]}" -mmacosx-version-min="${MINIMUM_SYSTEM_VERSION}" \
        "${ROOT_DIR}/Scripts/QuartzLauncher.c" \
        -o "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
fi

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
    <string>${MINIMUM_SYSTEM_VERSION}</string>
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
if [[ "${USE_FORK_WEBKIT}" == 1 ]]; then
    # The engine includes multiple frameworks and sibling XPC services with
    # distinct sandbox/JIT entitlements. Sign from the inside out.
    python3 "${ROOT_DIR}/Scripts/webkit-bundle.py" sign "${APP_DIR}/Contents/Frameworks" \
        --identity "${SIGN_IDENTITY}" --manifest "${APP_DIR}/Contents/Resources/QuartzWebKit.json"
fi
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
codesign "${CODESIGN_ARGS[@]}" --preserve-metadata=entitlements "${EMBEDDED_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/Autoupdate"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}/Versions/B/Updater.app"
codesign "${CODESIGN_ARGS[@]}" "${EMBEDDED_FRAMEWORK}"
if [[ "${USE_FORK_WEBKIT}" == 1 ]]; then
    # Only the inner runtime accepts the launcher's dyld environment. The outer
    # launcher has no such exception and never disables library validation.
    codesign "${CODESIGN_ARGS[@]}" --identifier "${BUNDLE_ID}" \
        --entitlements "${ROOT_DIR}/Scripts/QuartzRuntime.entitlements" \
        "${APP_DIR}/Contents/MacOS/${RUNTIME_EXECUTABLE_NAME}"
fi
if [[ "${USE_FORK_WEBKIT}" == 1 && "${SIGN_IDENTITY}" == "-" ]]; then
    # The libc-only outer launcher can reject incoming dyld injection even for
    # an ad-hoc development package; it loads no unsigned third-party libraries.
    codesign "${CODESIGN_ARGS[@]}" --options runtime "${APP_DIR}"
else
    codesign "${CODESIGN_ARGS[@]}" "${APP_DIR}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
xcrun lipo "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}" -verify_arch "${APP_ARCHS[@]}"
xcrun lipo "${APP_DIR}/Contents/MacOS/${RUNTIME_EXECUTABLE_NAME}" -verify_arch "${APP_ARCHS[@]}"
xcrun lipo "${EMBEDDED_FRAMEWORK}/Versions/B/Sparkle" -verify_arch "${APP_ARCHS[@]}"

# This reads the loaded WKWebView class location before creating a browser or
# opening the user's profile. A copied-but-unused engine must fail packaging.
"${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}" --quartz-webkit-info
python3 "${ROOT_DIR}/Scripts/test-webkit-runtime.py" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"

if [[ "${ZIP_APP:-0}" == "1" ]]; then
    ditto -c -k --norsrc --keepParent "${APP_DIR}" "${DIST_DIR}/${PRODUCT_NAME}.zip"
fi

echo "Built ${APP_DIR}"
