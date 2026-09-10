#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="QuartzBrowser/Quartz"
KEY_ACCOUNT="org.quartzbrowser.Quartz"
cd "${ROOT_DIR}"
command -v gh >/dev/null || { echo "error: install GitHub CLI and sign in with gh auth login" >&2; exit 1; }
gh auth status --active >/dev/null

# Never rotate an existing trust key accidentally: older Quartz installations
# only accept releases signed by the key that was embedded when they shipped.
SETUP_DIR="$(mktemp -d)"
trap 'rm -rf "${SETUP_DIR}"' EXIT
chmod 700 "${SETUP_DIR}"
gh variable list --repo "${REPOSITORY}" --json name,value > "${SETUP_DIR}/variables.json"
gh secret list --repo "${REPOSITORY}" --json name > "${SETUP_DIR}/secrets.json"
EXISTING_PUBLIC_KEY="$(python3 - "${SETUP_DIR}/variables.json" "${SETUP_DIR}/secrets.json" <<'PY'
import json, sys
variables = {item['name']: item['value'] for item in json.load(open(sys.argv[1]))}
secrets = {item['name'] for item in json.load(open(sys.argv[2]))}
public_key = variables.get('SPARKLE_PUBLIC_KEY', '')
if 'SPARKLE_PRIVATE_KEY' in secrets and not public_key:
    sys.exit('error: an update signing secret already exists without a public key; recover its public key before continuing')
print(public_key)
PY
)"
swift package resolve
KEY_TOOL="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ -n "${EXISTING_PUBLIC_KEY}" ]]; then
    LOCAL_PUBLIC_KEY="$("${KEY_TOOL}" --account "${KEY_ACCOUNT}" -p)"
    if [[ "${LOCAL_PUBLIC_KEY}" != "${EXISTING_PUBLIC_KEY}" ]]; then
        echo "error: this Mac does not have the repository's update signing key; restore the original Keychain key instead of generating a replacement" >&2
        exit 1
    fi
else
    "${KEY_TOOL}" --account "${KEY_ACCOUNT}"
    LOCAL_PUBLIC_KEY="$("${KEY_TOOL}" --account "${KEY_ACCOUNT}" -p)"
fi
umask 077
"${KEY_TOOL}" --account "${KEY_ACCOUNT}" -x "${SETUP_DIR}/private-key"

# Secret bytes travel over standard input, never command arguments or logs.
# Set the public key first so an interrupted setup can safely be retried.
gh variable set SPARKLE_PUBLIC_KEY --repo "${REPOSITORY}" --body "${LOCAL_PUBLIC_KEY}"
gh secret set SPARKLE_PRIVATE_KEY --repo "${REPOSITORY}" < "${SETUP_DIR}/private-key"
echo "Configured free update signing for ${REPOSITORY}. The private key remains in this Mac's Keychain (${KEY_ACCOUNT})."
