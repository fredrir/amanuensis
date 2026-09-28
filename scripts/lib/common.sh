#!/bin/bash

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${COMMON_SH_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

APP_NAME="Amanuensis"
PROJECT="${REPO_ROOT}/${APP_NAME}.xcodeproj"
DERIVED_DATA="${REPO_ROOT}/build/xcode"
RELEASE_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"

log() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

load_dotenv() {
  local env_file="${REPO_ROOT}/.env"
  [[ -f "${env_file}" ]] || return 0
  set -a
  source "${env_file}"
  set +a
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "${command}" >/dev/null 2>&1 || die "required command not found: ${command}"
  done
}

list_signing_identities() {
  security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' 'NF > 1 { print $2 }'
}

find_signing_identity() {
  local required_kind="${1:-any}"
  local identities
  identities="$(list_signing_identities)"

  local prefixes=("Developer ID Application:")
  [[ "${required_kind}" == "developer-id" ]] || prefixes+=("Apple Development:")

  local prefix identity
  for prefix in "${prefixes[@]}"; do
    if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
      while IFS= read -r identity; do
        if [[ "${identity}" == "${prefix}"*"(${APPLE_TEAM_ID})" ]]; then
          printf '%s\n' "${identity}"
          return 0
        fi
      done <<<"${identities}"
    fi
    while IFS= read -r identity; do
      if [[ "${identity}" == "${prefix}"* ]]; then
        printf '%s\n' "${identity}"
        return 0
      fi
    done <<<"${identities}"
  done
}

assert_signing_identity_available() {
  local identity="$1"
  security find-identity -v -p codesigning 2>/dev/null |
    grep -Fq -- "\"${identity}\"" ||
    die "signing identity is not available in the login Keychain: ${identity}"
}

# Usage: xcodebuild_release IDENTITY TIMESTAMP_FLAG
xcodebuild_release() {
  local identity="$1"
  local timestamp_flag="$2"

  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${identity}" \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="${timestamp_flag}" \
    build 2>&1 | xcbeautify --disable-logging --quiet
}

app_version() {
  local version
  version="$(plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist")"
  if [[ -z "${version}" || "${version}" == *[!A-Za-z0-9._-]* ]]; then
    die "CFBundleShortVersionString is not safe for an artifact name: ${version}"
  fi
  printf '%s\n' "${version}"
}

# Usage: make_dmg APP OUTPUT_DMG
make_dmg() {
  local app="$1"
  local output="$2"
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-dmg.XXXXXX")"

  ditto "${app}" "${root}/${APP_NAME}.app"
  ln -s /Applications "${root}/Applications"
  rm -f "${output}"
  hdiutil create \
    -quiet \
    -volname "${APP_NAME}" \
    -srcfolder "${root}" \
    -format UDZO \
    -ov \
    "${output}"
  rm -rf "${root}"
}

install_app() {
  local app="$1"
  local bundle_name="${APP_NAME}.app"
  local installed_path="${INSTALL_DIR}/${bundle_name}"

  log "Installing to ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  if pgrep -x "${APP_NAME}" >/dev/null; then
    note "stopping running instance"
    pkill -x "${APP_NAME}" || true
    sleep 1
  fi
  rm -rf "${installed_path:?}"
  ditto "${app}" "${installed_path}"

  local stale_copy="/Applications/${bundle_name}"
  if [[ -e "${stale_copy}" ]]; then
    warn "removing stale copy: ${stale_copy}"
    rm -rf -- "${stale_copy}"
  fi

  log "Done"
  open "${installed_path}"
}
