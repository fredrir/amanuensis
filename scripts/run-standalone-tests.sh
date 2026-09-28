#!/bin/zsh

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/amanuensis-standalone-tests.XXXXXX")

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
  Amanuensis/Sources/Services/ProviderStore.swift \
  Amanuensis/Sources/Models/AIProvider.swift \
  Amanuensis/Sources/Config.swift

run_swift_test \
  ProviderRoutingTests \
  Tests/ProviderRoutingTests.swift \
  Amanuensis/Sources/Services/AIProviderClient.swift \
  Amanuensis/Sources/Services/GraniteInstaller.swift \
  Amanuensis/Sources/Models/AIProvider.swift \
  Amanuensis/Sources/Config.swift

run_swift_test \
  GraniteInstallerTests \
  Tests/GraniteInstallerTests.swift \
  Amanuensis/Sources/Services/GraniteInstaller.swift \
  Amanuensis/Sources/Services/AIProviderClient.swift \
  Amanuensis/Sources/Models/AIProvider.swift \
  Amanuensis/Sources/Config.swift

run_swift_test \
  ScreenCaptureCLIArgumentsTests \
  Tests/ScreenCaptureCLIArgumentsTests.swift \
  Amanuensis/Sources/Services/ScreenCaptureBackend.swift \
  Amanuensis/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenCaptureStrategyTests \
  Tests/ScreenCaptureStrategyTests.swift \
  Amanuensis/Sources/Services/ScreenCaptureBackend.swift \
  Amanuensis/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenRegionSelectionTeardownTests \
  Tests/ScreenRegionSelectionTeardownTests.swift \
  Amanuensis/Sources/Services/ScreenCaptureBackend.swift \
  Amanuensis/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  ScreenCapturePermissionManagerTests \
  Tests/ScreenCapturePermissionManagerTests.swift \
  Amanuensis/Sources/Services/ScreenCapturePermissionManager.swift \
  Amanuensis/Sources/Logger.swift \
  -framework AppKit \
  -framework ScreenCaptureKit

run_swift_test \
  KeyboardShortcutTests \
  Tests/KeyboardShortcutTests.swift \
  Amanuensis/Sources/Settings/ShortcutMonitor.swift \
  Amanuensis/Sources/Settings/SettingsManager.swift \
  Amanuensis/Sources/Config.swift \
  -framework AppKit \
  -framework Carbon

run_swift_test \
  StatusItemIconStateTests \
  Tests/StatusItemIconStateTests.swift \
  Amanuensis/Sources/StatusItemIconState.swift
