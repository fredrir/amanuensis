#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv
cd "${REPO_ROOT}"

OUTPUT_DIR="${REPO_ROOT}/dist"
INSTALL=true
PACKAGE=true
ADHOC=false
SIGNING_IDENTITY="${AMANUENSIS_SIGNING_IDENTITY:-${APPLE_DEVELOPER_ID_APPLICATION:-}}"

usage() {
  cat <<EOF
Usage: scripts/build.sh [--no-install] [--no-package] [--signing-identity IDENTITY] [--adhoc]

Builds, signs, packages, and installs ${APP_NAME}.app.

Options:
  --no-install                  Leave ${APP_NAME}.app in build/xcode
  --no-package                  Skip the .dmg in dist/
  --signing-identity IDENTITY   Use this codesigning identity instead of auto-detecting
  --adhoc                       Use an unstable ad-hoc signature (Screen Recording permission resets)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-install)
    INSTALL=false
    shift
    ;;
  --no-package)
    PACKAGE=false
    shift
    ;;
  --signing-identity)
    [[ $# -ge 2 ]] || usage_error "--signing-identity requires a value"
    SIGNING_IDENTITY="$2"
    shift 2
    ;;
  --adhoc)
    ADHOC=true
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

if [[ "${ADHOC}" == true && -n "${SIGNING_IDENTITY}" ]]; then
  usage_error "--adhoc cannot be combined with a signing identity"
fi

if [[ "${ADHOC}" == true ]]; then
  SIGNING_IDENTITY="-"
elif [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(find_signing_identity any)"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  die "no Developer ID Application or Apple Development codesigning identity was found"
fi

require_commands xcodebuild xcbeautify codesign ditto hdiutil plutil

log "Building (release)"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  warn "ad-hoc signatures change identity after every rebuild"
else
  note "identity: ${SIGNING_IDENTITY}"
fi
xcodebuild_release "${SIGNING_IDENTITY}" "--timestamp=none"
codesign --verify --deep --strict "${RELEASE_APP}"

if [[ "${PACKAGE}" == true ]]; then
  VERSION="$(app_version "${RELEASE_APP}")"
  DMG_NAME="${APP_NAME}-${VERSION}-dev.dmg"
  log "Packaging ${DMG_NAME}"
  mkdir -p "${OUTPUT_DIR}"
  make_dmg "${RELEASE_APP}" "${OUTPUT_DIR}/${DMG_NAME}"
  if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
    codesign --force --sign "${SIGNING_IDENTITY}" --timestamp=none "${OUTPUT_DIR}/${DMG_NAME}"
  fi
  note "${OUTPUT_DIR}/${DMG_NAME}"
fi

if [[ "${INSTALL}" != true ]]; then
  log "Built ${RELEASE_APP} (not installed)"
  exit 0
fi

install_app "${RELEASE_APP}"
