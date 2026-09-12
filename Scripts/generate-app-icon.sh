#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT_DIR}/Artwork/AppIcon.png"
OUTPUT="${ROOT_DIR}/Sources/Quartz/Resources/AppIcon.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quartz-app-icon.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
ICONSET="${WORK_DIR}/AppIcon.iconset"

mkdir -p "${ICONSET}" "$(dirname "${OUTPUT}")"
for size in 16 32 128 256 512; do
    sips --resampleHeightWidth "${size}" "${size}" "${SOURCE}" \
        --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips --resampleHeightWidth "$((size * 2))" "$((size * 2))" "${SOURCE}" \
        --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "${OUTPUT}" "${ICONSET}"
echo "Generated ${OUTPUT}"
