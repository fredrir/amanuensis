#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/Amanuensis.app" >&2
  exit 64
fi

app_path=$1

if [[ ! -d "$app_path" ]]; then
  echo "error: app bundle not found at $app_path" >&2
  exit 66
fi

info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  echo "error: missing Info.plist at $info_plist" >&2
  exit 66
fi

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
codesign_output=$(codesign -d --verbose=4 "$app_path" 2>&1)

codesign_identifier=$(printf '%s\n' "$codesign_output" | awk -F= '/^Identifier=/{print $2}')
signature_kind=$(printf '%s\n' "$codesign_output" | awk -F= '/^Signature=/{print $2}')

errors=()

if [[ -z "$codesign_identifier" ]]; then
  errors+=("codesign output did not include an Identifier")
elif [[ "$codesign_identifier" != "$bundle_identifier" ]]; then
  errors+=("codesign identifier '$codesign_identifier' does not match CFBundleIdentifier '$bundle_identifier'")
fi

if [[ "$signature_kind" == "adhoc" ]]; then
  errors+=("app is ad-hoc signed; release builds must use a stable signing identity")
fi

if (( ${#errors[@]} > 0 )); then
  echo "release signing verification failed for $app_path" >&2
  for error in "${errors[@]}"; do
    echo "- $error" >&2
  done
  exit 1
fi

echo "release signing verification passed for $app_path"
