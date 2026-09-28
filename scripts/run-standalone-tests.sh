#!/bin/zsh

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/screenscribe-standalone-tests.XXXXXX")

cleanup() {
  rm -rf "$tmpdir"
}

trap cleanup EXIT

run_swift_test() {
  local binary_name=$1
  shift

  echo "Running $binary_name"
  xcrun swiftc "$@" -o "$tmpdir/$binary_name"
  "$tmpdir/$binary_name"
}

cd "$repo_root"

run_swift_test \
  ProviderStoreTests \
  Tests/ProviderStoreTests.swift \
  ScreenScribe/Sources/Services/ProviderStore.swift \
  ScreenScribe/Sources/Models/AIProvider.swift \
  ScreenScribe/Sources/Config.swift

run_swift_test \
  ProviderRoutingTests \
  Tests/ProviderRoutingTests.swift \
  ScreenScribe/Sources/Services/AIProviderClient.swift \
  ScreenScribe/Sources/Models/AIProvider.swift \
  ScreenScribe/Sources/Config.swift

run_swift_test \
  ScreenCaptureCLIArgumentsTests \
  Tests/ScreenCaptureCLIArgumentsTests.swift \
  ScreenScribe/Sources/Services/ScreenCaptureBackend.swift \
  ScreenScribe/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenCaptureStrategyTests \
  Tests/ScreenCaptureStrategyTests.swift \
  ScreenScribe/Sources/Services/ScreenCaptureBackend.swift \
  ScreenScribe/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenRegionSelectionTeardownTests \
  Tests/ScreenRegionSelectionTeardownTests.swift \
  ScreenScribe/Sources/Services/ScreenCaptureBackend.swift \
  ScreenScribe/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenCapturePermissionManagerTests \
  Tests/ScreenCapturePermissionManagerTests.swift \
  ScreenScribe/Sources/Services/ScreenCapturePermissionManager.swift \
  ScreenScribe/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  KeyboardShortcutTests \
  Tests/KeyboardShortcutTests.swift \
  ScreenScribe/Sources/Settings/ShortcutMonitor.swift \
  ScreenScribe/Sources/Settings/SettingsManager.swift \
  ScreenScribe/Sources/Config.swift \
  -framework AppKit \
  -framework Carbon
