#!/bin/bash
# Build the pinned QuartzBrowser/WebKit sources, then prepare relocatable products.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/WebKit.lock.json"

usage() {
    cat <<'EOF'
Usage: Scripts/build-webkit.sh [--check]

Build the revision in WebKit.lock.json with the public macOS SDK.
--check validates the local prerequisites without fetching or building WebKit.

Environment:
  WEBKIT_CACHE_DIR     Engine cache (default: ~/Library/Caches/Quartz/WebKit/REVISION)
  WEBKIT_SOURCE_DIR    Source checkout (default: WEBKIT_CACHE_DIR/source)
  WEBKIT_BUILD_DIR     Raw build root (default: WEBKIT_CACHE_DIR/build)
  WEBKIT_PRODUCTS_DIR  Prepared products (default: .build/quartz-webkit/products/Release)
  WEBKIT_ARCHS         Space-separated architectures (default: arm64 x86_64)
  WEBKIT_JOBS          Concurrent build jobs (default: 2)
  DEVELOPER_DIR        Optional full Xcode developer directory

Use WEBKIT_ARCHS=arm64 for a local Apple Silicon build. Existing source checkouts
must be clean, use the locked remote, and already be at the locked revision.
EOF
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

CHECK_ONLY=NO
case "${1:-}" in
    --check) CHECK_ONLY=YES; shift ;;
    --help|-h) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || fail 'Building the Cocoa WebKit port requires macOS.'
for tool in git python3 perl xcodebuild xcrun codesign; do
    command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"
done

LOCK_FIELDS="$(python3 - "$LOCK_FILE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    lock = json.load(stream)
if lock.get("schemaVersion") != 1:
    raise SystemExit("Unsupported WebKit lock schema")
repository = lock.get("repository", "")
revision = lock.get("revision", "")
minimum = lock.get("minimumXcode", "")
deployment = lock.get("macOSDeploymentTarget", "")
if repository != "https://github.com/QuartzBrowser/WebKit.git":
    raise SystemExit("WebKit lock must name the QuartzBrowser/WebKit fork")
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("WebKit lock revision must be a full lowercase commit SHA")
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", minimum):
    raise SystemExit("WebKit lock minimumXcode must be a version number")
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", deployment):
    raise SystemExit("WebKit lock macOSDeploymentTarget must be a version number")
print(repository, revision, minimum, deployment, sep="\t")
PY
)"
IFS=$'\t' read -r REPOSITORY REVISION MINIMUM_XCODE DEPLOYMENT_TARGET <<< "$LOCK_FIELDS"

XCODE_VERSION="$(xcodebuild -version)"
python3 - "$MINIMUM_XCODE" "$XCODE_VERSION" <<'PY'
import re
import sys

match = re.search(r"^Xcode ([0-9.]+)$", sys.argv[2], re.MULTILINE)
if not match:
    raise SystemExit("Select a full Xcode installation with xcode-select or DEVELOPER_DIR")
def version(value):
    return tuple(int(part) for part in value.split(".")) + (0,) * (4 - len(value.split(".")))
if version(match[1]) < version(sys.argv[1]):
    raise SystemExit(f"Pinned WebKit requires Xcode {sys.argv[1]} or newer; selected {match[1]}")
print(f"Using Xcode {match[1]} (WebKit requires {sys.argv[1]} or newer)")
PY
xcrun --sdk macosx --show-sdk-path >/dev/null
xcrun --sdk macosx metal --version >/dev/null 2>&1 || \
    fail 'The Metal toolchain is unavailable. Install it with: xcodebuild -downloadComponent MetalToolchain'

CACHE_DIR="${WEBKIT_CACHE_DIR:-$HOME/Library/Caches/Quartz/WebKit/$REVISION}"
SOURCE_DIR="${WEBKIT_SOURCE_DIR:-$CACHE_DIR/source}"
BUILD_DIR="${WEBKIT_BUILD_DIR:-$CACHE_DIR/build}"
PRODUCTS_DIR="${WEBKIT_PRODUCTS_DIR:-$ROOT_DIR/.build/quartz-webkit/products/Release}"
ARCHS="${WEBKIT_ARCHS:-arm64 x86_64}"
JOBS="${WEBKIT_JOBS:-2}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'WEBKIT_JOBS must be a positive integer.'
PATH_FIELDS="$(python3 - "$SOURCE_DIR" "$BUILD_DIR" "$PRODUCTS_DIR" "$ARCHS" <<'PY'
from pathlib import Path
import sys

paths = [Path(value).expanduser().resolve() for value in sys.argv[1:4]]
if any(any(character.isspace() for character in str(path)) for path in paths[:2]):
    raise SystemExit("WebKit's upstream Makefiles require source and raw build paths without whitespace. Set WEBKIT_CACHE_DIR to a cache path without spaces; Quartz and prepared products can remain in their current directory.")
for path in paths:
    if any(character in str(path) for character in "\n\r\t"):
        raise SystemExit("WebKit paths cannot contain tabs or newlines")
for index, path in enumerate(paths):
    for other in paths[index + 1:]:
        if path == other or path in other.parents or other in path.parents:
            raise SystemExit("Source, raw build, and prepared products paths must not overlap")
architectures = sys.argv[4].split()
if not architectures or len(set(architectures)) != len(architectures):
    raise SystemExit("WEBKIT_ARCHS must contain one or more unique architectures")
if not set(architectures) <= {"arm64", "x86_64"}:
    raise SystemExit("WEBKIT_ARCHS supports arm64 and x86_64 only")
print(*paths, " ".join(architectures), sep="\t")
PY
)"
IFS=$'\t' read -r SOURCE_DIR BUILD_DIR PRODUCTS_DIR ARCHS <<< "$PATH_FIELDS"

printf 'WebKit revision: %s\nArchitectures: %s; jobs: %s\n' "$REVISION" "$ARCHS" "$JOBS"
printf 'macOS deployment target: %s\n' "$DEPLOYMENT_TARGET"
printf 'Source: %s\nRaw build: %s\nPrepared products: %s\n' "$SOURCE_DIR" "$BUILD_DIR" "$PRODUCTS_DIR"
if [[ "$CHECK_ONLY" == YES ]]; then
    printf 'WebKit build prerequisites are available.\n'
    exit 0
fi

python3 "$ROOT_DIR/Scripts/webkit-bundle.py" check-output "$PRODUCTS_DIR"

mkdir -p "$(dirname "$BUILD_DIR")"
BUILD_LOCK="${BUILD_DIR}.quartz-build-lock"
mkdir "$BUILD_LOCK" 2>/dev/null || fail "Another WebKit build may be running: $BUILD_LOCK"
trap 'rmdir "$BUILD_LOCK"' EXIT

if [[ -e "$SOURCE_DIR" ]]; then
    [[ -d "$SOURCE_DIR/.git" ]] || fail "Source directory already exists and is not a standalone Git checkout: $SOURCE_DIR"
    ACTUAL_REMOTE="$(git -C "$SOURCE_DIR" remote get-url origin)"
    [[ "$ACTUAL_REMOTE" == "$REPOSITORY" ]] || fail "WebKit origin does not match the lock: $ACTUAL_REMOTE"
    [[ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]] || \
        fail "WebKit source has local changes; preserve or move them before building: $SOURCE_DIR"
    ACTUAL_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    [[ "$ACTUAL_REVISION" == "$REVISION" ]] || \
        fail "WebKit checkout is at $ACTUAL_REVISION, expected $REVISION. Use a new WEBKIT_SOURCE_DIR for the new pin."
else
    mkdir -p "$(dirname "$SOURCE_DIR")"
    git init "$SOURCE_DIR"
    git -C "$SOURCE_DIR" remote add origin "$REPOSITORY"
    git -C "$SOURCE_DIR" config core.autocrlf false
    git -C "$SOURCE_DIR" sparse-checkout init --cone
    git -C "$SOURCE_DIR" sparse-checkout set Source Tools Configurations WebKitLibraries WebKit.xcworkspace resources
    git -C "$SOURCE_DIR" fetch --depth=1 --filter=blob:none origin "$REVISION"
    git -C "$SOURCE_DIR" checkout --detach "$REVISION"
fi

[[ -f "$SOURCE_DIR/Tools/Scripts/build-webkit" ]] || fail 'WebKit checkout is missing Tools/Scripts/build-webkit.'
[[ -f "$SOURCE_DIR/WebKit.xcworkspace/xcshareddata/xcschemes/Everything up to WebKit.xcscheme" ]] || \
    fail 'WebKit checkout is missing the expected build scheme.'
printf 'WebKit is a large build. Available storage on the build volume:\n'
df -h "$(dirname "$BUILD_DIR")"

# Public Release builds provide the development XPC services without requiring
# Apple-internal SDKs or restricted entitlements. Pin the deployment target
# explicitly, as upstream's Sequoia builders do, instead of inheriting this
# machine's OS version. Preparation derives the real minimum OS from Mach-O.
(
    cd "$SOURCE_DIR"
    unset BUILD_WEBKIT_ARGS
    export WEBKIT_OUTPUTDIR="$BUILD_DIR"
    perl Tools/Scripts/build-webkit \
        --xcode --release --sdk=macosx --architecture="$ARCHS" \
        --only='Everything up to WebKit' \
        -jobs "$JOBS" \
        ONLY_ACTIVE_ARCH=NO \
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        DEBUG_INFORMATION_FORMAT= \
        GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
        CLANG_ENABLE_MODULE_DEBUGGING=NO \
        COMPILER_INDEX_STORE_ENABLE=NO \
        SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
        WK_RELOCATABLE_FRAMEWORKS=YES \
        WK_USE_RESTRICTED_ENTITLEMENTS=NO
)

python3 "$ROOT_DIR/Scripts/webkit-bundle.py" prepare \
    --build-dir "$BUILD_DIR/Release" \
    --output-dir "$PRODUCTS_DIR" \
    --source-dir "$SOURCE_DIR" \
    --lock-file "$LOCK_FILE"
printf 'Prepared Quartz WebKit products: %s\n' "$PRODUCTS_DIR"
