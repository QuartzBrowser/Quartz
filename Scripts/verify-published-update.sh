#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: verify-published-update.sh VERSION}"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: invalid release version" >&2
    exit 1
fi
LOCAL_RELEASE="${DIST_DIR:-${ROOT_DIR}/dist}/release"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "${VERIFY_DIR}"' EXIT
ARCHIVE_NAME="Quartz-v${VERSION}-macos-universal.zip"
DOWNLOAD_PREFIX="https://github.com/QuartzBrowser/Quartz/releases/download/v${VERSION}/"
for asset in "${ARCHIVE_NAME}" appcast.xml SHA256SUMS; do
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
        --connect-timeout 20 --max-time 180 "${DOWNLOAD_PREFIX}${asset}" --output "${VERIFY_DIR}/${asset}"
    cmp "${LOCAL_RELEASE}/${asset}" "${VERIFY_DIR}/${asset}"
done
(
    cd "${VERIFY_DIR}"
    shasum -a 256 --check SHA256SUMS
)
"${ROOT_DIR}/Scripts/wait-for-published-feed.sh" "${VERIFY_DIR}/appcast.xml" "${VERIFY_DIR}/latest.xml"
ditto -x -k "${VERIFY_DIR}/${ARCHIVE_NAME}" "${VERIFY_DIR}/unpacked"
codesign --verify --deep --strict "${VERIFY_DIR}/unpacked/Quartz.app"
swift "${ROOT_DIR}/Scripts/verify-update.swift" "${VERIFY_DIR}/unpacked/Quartz.app" \
    "${VERIFY_DIR}/${ARCHIVE_NAME}" "${VERIFY_DIR}/appcast.xml" "${VERSION}" "${DOWNLOAD_PREFIX}${ARCHIVE_NAME}"
echo "Verified public archive, signed feed, checksums, and latest-feed URL."
