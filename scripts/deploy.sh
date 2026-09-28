#!/bin/bash
# Publish the Granite pack if needed, then build, sign, notarize, package, and install a Developer ID release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv

OUTPUT_DIR="${REPO_ROOT}/dist"
INSTALL=true
SIGNING_IDENTITY="${APPLE_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--identity IDENTITY] [options]

Options:
  --identity IDENTITY       Developer ID Application identity (default: auto-detected from Keychain)
  --notary-profile PROFILE  notarytool Keychain profile
  --output DIR              Output directory (default: ./dist)
  --no-install              Skip installing into ~/Applications
  -h, --help                Show this help

Environment equivalents:
  APPLE_DEVELOPER_ID_APPLICATION  Signing identity
  APPLE_NOTARY_PROFILE            notarytool Keychain profile
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
  --output)
    [[ $# -ge 2 ]] || usage_error "--output requires a value"
    OUTPUT_DIR="$2"
    shift 2
    ;;
  --no-install)
    INSTALL=false
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

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(find_signing_identity developer-id)"
  if [[ -n "${SIGNING_IDENTITY}" ]]; then
    log "Using auto-detected Developer ID identity: ${SIGNING_IDENTITY}"
  fi
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  usage_error "provide a Developer ID Application identity with --identity or APPLE_DEVELOPER_ID_APPLICATION, or install your Developer ID certificate in Keychain"
fi

if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  usage_error "deploys require a 'Developer ID Application:' identity (got: ${SIGNING_IDENTITY})"
fi

if [[ -z "${NOTARY_PROFILE}" ]]; then
  usage_error "provide a notarytool profile with --notary-profile or APPLE_NOTARY_PROFILE"
fi

require_commands xcodebuild xcbeautify codesign ditto hdiutil lipo plutil security xcrun
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool is unavailable in the selected Xcode toolchain"
assert_signing_identity_available "${SIGNING_IDENTITY}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}/.deploy.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"

"${SCRIPTS_DIR}/granite-pack.sh" --identity "${SIGNING_IDENTITY}" --notary-profile "${NOTARY_PROFILE}"

log "Building Apple Silicon release"
note "identity: ${SIGNING_IDENTITY}"
xcodebuild_release "${SIGNING_IDENTITY}" "--timestamp"
ditto "${RELEASE_APP}" "${APP_BUNDLE}"
[[ "$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}")" == "arm64" ]] ||
  die "release binary must be arm64 only"
[[ -f "${APP_BUNDLE}/Contents/Resources/Backend/granite-pack.json" ]] ||
  die "release is missing the Granite pack manifest"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign --display --verbose=2 --entitlements - --xml "${APP_BUNDLE}"
printf '\n'
"${SCRIPTS_DIR}/verify-release-signing.sh" "${APP_BUNDLE}"

VERSION="$(app_version "${APP_BUNDLE}")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGED_DMG="${STAGING_DIR}/${DMG_NAME}"

log "Packaging ${DMG_NAME}"
make_dmg "${APP_BUNDLE}" "${STAGED_DMG}"
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${STAGED_DMG}"

log "Submitting for notarization"
notarize "${STAGED_DMG}" "${NOTARY_PROFILE}" "${STAGING_DIR}/notary-log.json"

log "Stapling and validating notarization ticket"
xcrun stapler staple -q "${STAGED_DMG}"
xcrun stapler validate -q "${STAGED_DMG}"
xcrun stapler staple -q "${APP_BUNDLE}"
xcrun stapler validate -q "${APP_BUNDLE}"

if command -v syspolicy_check >/dev/null 2>&1; then
  syspolicy_check distribution "${APP_BUNDLE}"
else
  spctl --assess --type execute --verbose=4 "${APP_BUNDLE}"
fi

FINAL_DMG="${OUTPUT_DIR}/${DMG_NAME}"
rm -f "${FINAL_DMG}"
mv "${STAGED_DMG}" "${FINAL_DMG}"

log "Deploy artifacts"
note "${FINAL_DMG}"

if [[ "${INSTALL}" == true ]]; then
  install_app "${APP_BUNDLE}"
fi
