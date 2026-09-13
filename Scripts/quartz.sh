#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
case "${COMMAND}" in
    build|test|run) ;;
    *) echo "usage: Scripts/quartz.sh build|test [SwiftPM arguments], or run [Quartz arguments]" >&2; exit 2 ;;
esac
cd "${ROOT_DIR}"
ENGINE_MODE=fork
if [[ "${QUARTZ_USE_SYSTEM_WEBKIT:-0}" == 1 ]]; then
    # Keep explicit system development consistent at compile time and runtime.
    unset QUARTZ_WEBKIT_PRODUCTS_DIR
    ENGINE_MODE=system
else
    export QUARTZ_WEBKIT_PRODUCTS_DIR="${QUARTZ_WEBKIT_PRODUCTS_DIR:-${ROOT_DIR}/.build/quartz-webkit/products/Release}"
    if [[ ! -f "${QUARTZ_WEBKIT_PRODUCTS_DIR}/QuartzWebKit.json" ]]; then
        echo "error: missing fork build; run Scripts/build-webkit.sh first (see docs/WEBKIT.md)" >&2
        exit 1
    fi
    export QUARTZ_WEBKIT_PRODUCTS_DIR="$(cd "${QUARTZ_WEBKIT_PRODUCTS_DIR}" && pwd -P)"
    python3 Scripts/webkit-bundle.py verify "${QUARTZ_WEBKIT_PRODUCTS_DIR}" --arch "$(uname -m)" > /dev/null
fi

ORIGINAL_ARGS=("$@")
BUILD_ARGS=()
SKIP_BUILD=0
case "${COMMAND}" in
    run) BUILD_ARGS=(--product Quartz) ;;
    build) BUILD_ARGS=("$@") ;;
    test)
        # Build tests without starting discovery or executing a test binary:
        # Sparkle must first stop linking the system engine. Keep runner options
        # intact for the later `swift test --skip-build` invocation.
        BUILD_ARGS=(--build-tests)
        while [[ $# -gt 0 ]]; do
            case "${1%%=*}" in
                --skip-build) SKIP_BUILD=1 ;;
                --filter|--skip|--specifier|-s|--num-workers|--xunit-output|--attachments-path|--test-product|--configuration-path|--event-stream-output-path|--event-stream-version|--experimental-maximum-parallelization-width|--test-output)
                    if [[ "$1" != *=* ]]; then
                        [[ $# -gt 1 ]] || { echo "error: missing value for $1" >&2; exit 2; }
                        shift
                    fi ;;
                --parallel|--no-parallel|--list-tests|-l|--experimental-xunit-message-failure|--enable-testable-imports|list) ;;
                --disable-testable-imports)
                    echo "error: Quartz's fork test build requires testable imports; remove --disable-testable-imports" >&2
                    exit 2 ;;
                -Xcc|-Xswiftc|-Xlinker|-Xcxx|-Xxcbuild|-Xbuild-tools-swiftc|-Xmanifest|--package-path|--scratch-path|--build-path|--cache-path|--config-path|--security-path|--swift-sdks-path|--toolset|--pkg-config-path|--manifest-cache|--netrc-file|--resolver-fingerprint-checking|--resolver-signing-entity-checking|--default-registry-url|-c|--configuration|--triple|--sdk|--toolchain|--swift-sdk|--sanitize|-j|--jobs|--explicit-target-dependency-import-check|--build-system|-debug-info-format|--traits|--arch|--destination|--experimental-swift-sdk|--experimental-test-entry-point-path|--experimental-lto-mode)
                    BUILD_ARGS+=("$1")
                    if [[ "$1" != *=* ]]; then
                        [[ $# -gt 1 ]] || { echo "error: missing value for $1" >&2; exit 2; }
                        shift
                        BUILD_ARGS+=("$1")
                    fi ;;
                *) BUILD_ARGS+=("$1") ;;
            esac
            shift
        done ;;
esac

# Informational SwiftPM commands do not execute Quartz or require staging.
if [[ "${COMMAND}" != run ]]; then
    for argument in ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}; do
        case "$argument" in
            --help|--help-hidden|-help|-h|--version|--show-bin-path|--print-manifest-job-graph|--print-pif-manifest-graph|--show-codecov-path|--show-code-coverage-path|--show-coverage-path|last)
                exec swift "${COMMAND}" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"} ;;
        esac
    done
fi

if [[ "${SKIP_BUILD}" != 1 ]]; then
    swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
fi
BIN_DIR="$(swift build --show-bin-path ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"})"
SOURCE_FRAMEWORK="$(python3 - "${BIN_DIR}" <<'PY'
from pathlib import Path
import sys

# SwiftPM places the downloaded artifact beneath its scratch directory. Looking
# up from the selected bin path also handles --scratch-path and Xcode layouts.
for parent in Path(sys.argv[1]).resolve().parents:
    source = parent / "artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if source.is_dir():
        print(source)
        break
else:
    sys.exit("error: could not locate SwiftPM's original Sparkle artifact")
PY
)"
if [[ "${ENGINE_MODE}" == system ]]; then
    # Incremental SwiftPM builds can retain a previously relocated fork copy.
    python3 Scripts/webkit-bundle.py prepare-sparkle --system \
        --source-framework "${SOURCE_FRAMEWORK}" --output-dir "${BIN_DIR}"
else
    python3 Scripts/webkit-bundle.py prepare-sparkle \
        --source-framework "${SOURCE_FRAMEWORK}" --output-dir "${BIN_DIR}" \
        --products-dir "${QUARTZ_WEBKIT_PRODUCTS_DIR}"
fi

# System frameworks can open WebKit dependencies by absolute system paths later
# in the process. Scope the selected framework override to runtime only, including
# WebKit's XPC services, and discard inherited loader settings in either mode.
RUNTIME_ENV=(env)
while IFS= read -r variable; do
    case "${variable}" in
        DYLD_*|__XPC_DYLD_*) RUNTIME_ENV+=(-u "${variable}") ;;
    esac
done < <(compgen -e)
if [[ "${ENGINE_MODE}" == fork ]]; then
    RUNTIME_ENV+=("DYLD_FRAMEWORK_PATH=${QUARTZ_WEBKIT_PRODUCTS_DIR}"
                 "__XPC_DYLD_FRAMEWORK_PATH=${QUARTZ_WEBKIT_PRODUCTS_DIR}")
fi

case "${COMMAND}" in
    run) exec "${RUNTIME_ENV[@]}" "${BIN_DIR}/Quartz" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"} ;;
    test)
        SWIFT_RUNTIME="$(command -v swift)"
        # The system Swift shim can strip DYLD variables before launching the
        # selected toolchain. Resolve it before setting the runtime environment.
        if [[ "${SWIFT_RUNTIME}" == /usr/bin/swift ]]; then
            SWIFT_RUNTIME="$(xcrun --find swift)"
        fi
        exec "${RUNTIME_ENV[@]}" "${SWIFT_RUNTIME}" test ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"} --skip-build ;;
esac
