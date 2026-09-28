#!/bin/bash
# Build, sign, notarize, and publish the downloadable Docling Granite pack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv
cd "${REPO_ROOT}"

SIGNING_IDENTITY="${APPLE_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"
REPOSITORY="${AMANUENSIS_GRANITE_REPOSITORY:-}"
MANIFEST="${REPO_ROOT}/backend/granite-pack.json"
FORCE=false

usage() {
  cat <<'EOF'
Usage: scripts/granite-pack.sh [--identity IDENTITY] [options]

Publishes the Granite pack for the locked dependencies as a GitHub release asset
and records it in backend/granite-pack.json. Does nothing if that pack is already published.

Options:
  --identity IDENTITY       Developer ID Application identity (default: auto-detected from Keychain)
  --notary-profile PROFILE  notarytool Keychain profile
  --repository OWNER/NAME   GitHub repository for the release (default: this checkout's repository)
  --force                   Rebuild and upload even if the manifest is current
  -h, --help                Show this help

Environment equivalents:
  APPLE_DEVELOPER_ID_APPLICATION  Signing identity
  APPLE_NOTARY_PROFILE            notarytool Keychain profile
  AMANUENSIS_GRANITE_REPOSITORY   GitHub repository
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --identity)
    [[ $# -ge 2 ]] || usage_error "--identity requires a value"
    SIGNING_IDENTITY="$2"
    shift 2
    ;;
  --notary-profile)
    [[ $# -ge 2 ]] || usage_error "--notary-profile requires a value"
    NOTARY_PROFILE="$2"
    shift 2
    ;;
  --repository)
    [[ $# -ge 2 ]] || usage_error "--repository requires a value"
    REPOSITORY="$2"
    shift 2
    ;;
  --force)
    FORCE=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage_error "unknown option: $1"
    ;;
  esac
done

require_commands uv codesign ditto gh plutil shasum xcrun

PACK_ID="$(uv run --quiet --project backend --locked python scripts/prepare-backend.py --granite-id)"
if [[ "${FORCE}" != true && -f "${MANIFEST}" && "$(plutil -extract id raw "${MANIFEST}")" == "${PACK_ID}" ]]; then
  log "Granite pack ${PACK_ID} is already published"
  exit 0
fi

[[ -n "${SIGNING_IDENTITY}" ]] || SIGNING_IDENTITY="$(find_signing_identity developer-id)"
[[ "${SIGNING_IDENTITY}" == "Developer ID Application:"* ]] ||
  usage_error "the Granite pack requires a 'Developer ID Application:' identity (got: ${SIGNING_IDENTITY:-none})"
[[ -n "${NOTARY_PROFILE}" ]] ||
  usage_error "provide a notarytool profile with --notary-profile or APPLE_NOTARY_PROFILE"
assert_signing_identity_available "${SIGNING_IDENTITY}"
[[ -n "${REPOSITORY}" ]] || REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

log "Staging Granite pack ${PACK_ID}"
PACK_DIR="$(uv run --quiet --project backend --locked python scripts/prepare-backend.py --granite)"
[[ "$(basename "${PACK_DIR}")" == "${PACK_ID}" ]] || die "staged pack ${PACK_DIR} does not match ${PACK_ID}"

log "Signing Granite pack"
note "identity: ${SIGNING_IDENTITY}"
backend/.venv/bin/python3 scripts/sign-backend.py "${PACK_DIR}" "${SIGNING_IDENTITY}"

ARCHIVE_NAME="${APP_NAME}-Granite-${PACK_ID}.zip"
ARCHIVE="${REPO_ROOT}/dist/${ARCHIVE_NAME}"
log "Packaging ${ARCHIVE_NAME}"
mkdir -p "$(dirname "${ARCHIVE}")"
rm -f "${ARCHIVE}"
ditto -c -k --keepParent "${PACK_DIR}" "${ARCHIVE}"
SIZE="$(stat -f %z "${ARCHIVE}")"
((SIZE < 2147483648)) || die "GitHub release assets must be under 2 GiB (${ARCHIVE_NAME} is ${SIZE} bytes)"
note "$((SIZE / 1048576)) MB"

log "Submitting Granite pack for notarization"
notarize "${ARCHIVE}" "${NOTARY_PROFILE}" "${REPO_ROOT}/build/granite-notary-log.json"

TAG="granite-${PACK_ID}"
log "Publishing ${TAG} to ${REPOSITORY}"
if gh release view "${TAG}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
  gh release upload "${TAG}" "${ARCHIVE}" --repo "${REPOSITORY}" --clobber
else
  gh release create "${TAG}" "${ARCHIVE}" \
    --repo "${REPOSITORY}" \
    --title "Docling Granite pack ${PACK_ID}" \
    --notes "Local inference runtime and Granite Docling 258M weights, downloaded by ${APP_NAME} from Settings." \
    --latest=false
fi

cat >"${MANIFEST}" <<EOF
{
  "id": "${PACK_ID}",
  "url": "https://github.com/${REPOSITORY}/releases/download/${TAG}/${ARCHIVE_NAME}",
  "sha256": "$(shasum -a 256 "${ARCHIVE}" | awk '{ print $1 }')",
  "size": ${SIZE},
  "installedSize": $(($(du -sk "${PACK_DIR}" | awk '{ print $1 }') * 1024))
}
EOF
log "Recorded ${MANIFEST#"${REPO_ROOT}/"}; commit it with this release"
