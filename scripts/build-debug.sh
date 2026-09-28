#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcbeautify >/dev/null 2>&1; then
    echo "error: xcbeautify is not installed. Install it with: brew install xcbeautify" >&2
    exit 1
fi

mode="${1:-pretty}"  # pretty | quiet

xcodebuild_flags=(
    -project Amanuensis.xcodeproj
    -scheme Amanuensis
    -configuration Debug
    -destination 'platform=macOS'
    -derivedDataPath build/xcode
)

beautify_flags=(--disable-logging)

if [[ "$mode" == "quiet" ]]; then
    # Only show warnings/errors; the caller prints its own success/failure banner.
    xcodebuild_flags+=(-quiet)
    beautify_flags+=(-q)
fi

xcodebuild "${xcodebuild_flags[@]}" build 2>&1 | xcbeautify "${beautify_flags[@]}"
