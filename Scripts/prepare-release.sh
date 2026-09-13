#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: prepare-release.sh VERSION}"
if [[ "${QUARTZ_USE_SYSTEM_WEBKIT:-0}" == 1 && "${QUARTZ_TEST_SYSTEM_RELEASE:-0}" != 1 ]]; then
    echo "error: public releases require the pinned Quartz WebKit fork; see docs/WEBKIT.md" >&2
    exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: release version must be a numeric major.minor.patch" >&2
    exit 1
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" || -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    echo "error: releases require SPARKLE_PRIVATE_KEY and SPARKLE_PUBLIC_KEY; see docs/UPDATES.md" >&2
    exit 1
fi
# Do not pass the private update key to compilers or other child processes.
UPDATE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY}"
unset SPARKLE_PRIVATE_KEY
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
mkdir -p "${DIST_DIR}"
DIST_DIR="$(cd "${DIST_DIR}" && pwd)"
RELEASE_DIR="${DIST_DIR}/release"
BUNDLE_DIR="${DIST_DIR}/release-bundle"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin}"
FEED_URL="https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml"
DOWNLOAD_PREFIX="https://github.com/QuartzBrowser/Quartz/releases/download/v${VERSION}/"
ARCHIVE_NAME="Quartz-v${VERSION}-macos-universal.zip"
umask 022
cd "${ROOT_DIR}"
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
VERSION="${VERSION}" BUILD_NUMBER="${VERSION}" DIST_DIR="${BUNDLE_DIR}" ZIP_APP=0 \
    QUARTZ_APP_ARCHS="arm64 x86_64" \
    SPARKLE_FEED_URL="${FEED_URL}" SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY}" \
    SIGN_IDENTITY="-" \
    "${ROOT_DIR}/Scripts/package-macos-app.sh"

for tool in generate_appcast sign_update; do
    if [[ ! -x "${SPARKLE_TOOLS_DIR}/${tool}" ]]; then
        echo "error: missing Sparkle tool ${SPARKLE_TOOLS_DIR}/${tool}" >&2
        exit 1
    fi
done
APP="${BUNDLE_DIR}/Quartz.app"
# Freeze the archive only after all application signatures are complete.
codesign --verify --deep --strict "${APP}"
ditto -c -k --norsrc --keepParent "${APP}" "${RELEASE_DIR}/${ARCHIVE_NAME}"
unzip -tq "${RELEASE_DIR}/${ARCHIVE_NAME}"

# Retain older compatible releases (for example when the minimum macOS version
# changes). A missing feed is permitted only for the first updater release.
if [[ -n "${PREVIOUS_APPCAST_FILE:-}" ]]; then
    cp "${PREVIOUS_APPCAST_FILE}" "${RELEASE_DIR}/appcast.xml"
else
    HTTP_STATUS="$(curl --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 120 \
        --output "${RELEASE_DIR}/appcast.xml" --write-out '%{http_code}' "${FEED_URL}")"
    case "${HTTP_STATUS}" in
        200) ;;
        404) rm "${RELEASE_DIR}/appcast.xml" ;;
        *) echo "error: could not retrieve the previous appcast (HTTP ${HTTP_STATUS})" >&2; exit 1 ;;
    esac
fi
if [[ -f "${RELEASE_DIR}/appcast.xml" ]]; then
    printf '%s' "${UPDATE_PRIVATE_KEY}" | "${SPARKLE_TOOLS_DIR}/sign_update" --verify --ed-key-file - "${RELEASE_DIR}/appcast.xml"
fi
printf '%s' "${UPDATE_PRIVATE_KEY}" | "${SPARKLE_TOOLS_DIR}/generate_appcast" --ed-key-file - \
    --download-url-prefix "${DOWNLOAD_PREFIX}" --maximum-deltas 0 --maximum-versions 3 \
    --link "https://github.com/QuartzBrowser/Quartz/releases/tag/v${VERSION}" \
    "${RELEASE_DIR}"
printf '%s' "${UPDATE_PRIVATE_KEY}" | "${SPARKLE_TOOLS_DIR}/sign_update" --verify --ed-key-file - "${RELEASE_DIR}/appcast.xml"
unset UPDATE_PRIVATE_KEY
swift "${ROOT_DIR}/Scripts/verify-update.swift" "${APP}" "${RELEASE_DIR}/${ARCHIVE_NAME}" \
    "${RELEASE_DIR}/appcast.xml" "${VERSION}" "${DOWNLOAD_PREFIX}${ARCHIVE_NAME}"
(
    cd "${RELEASE_DIR}"
    shasum -a 256 "${ARCHIVE_NAME}" appcast.xml > SHA256SUMS
)
test -s "${RELEASE_DIR}/${ARCHIVE_NAME}"
test -s "${RELEASE_DIR}/appcast.xml"
test -s "${RELEASE_DIR}/SHA256SUMS"
echo "Prepared verified release assets in ${RELEASE_DIR}"
