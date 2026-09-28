#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_app="${1:-build/xcode/Build/Products/Release/ScreenScribe.app}"
smoke_app="build/BackendSmoke.app"
mkdir -p "${smoke_app}/Contents/MacOS" "${smoke_app}/Contents/Resources"
rm -rf "${smoke_app}/Contents/Resources/Backend"
ditto "${source_app}/Contents/Resources/Backend" "${smoke_app}/Contents/Resources/Backend"
cat > "${smoke_app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.screenscribe.backend-smoke</string>
<key>CFBundleExecutable</key><string>BackendSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
uv run --project backend python - <<'PY'
import plistlib
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
image = Image.new('RGB', (700, 220), 'white')
draw = ImageDraw.Draw(image)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 32)
draw.text((30, 35), 'ScreenScribe local extraction', fill='black', font=font)
draw.text((30, 100), 'The answer is 42.', fill='black', font=font)
image.save('build/BackendSmoke.app/Contents/Resources/capture.png')
# Enforce offline operation, including native libraries, with App Sandbox.
Path('build/BackendSmoke.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
PY
xcrun swiftc Tests/BackendSmokeTests.swift \
    ScreenScribe/Sources/Services/AIProviderClient.swift \
    ScreenScribe/Sources/Models/AIProvider.swift \
    ScreenScribe/Sources/Config.swift \
    -o "${smoke_app}/Contents/MacOS/BackendSmoke"
codesign --force --sign - --options runtime --entitlements build/BackendSmoke.entitlements "${smoke_app}"
"${smoke_app}/Contents/MacOS/BackendSmoke"
