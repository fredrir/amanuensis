#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_app="${1:-build/xcode/Build/Products/Release/Amanuensis.app}"
smoke_app="build/BackendSmoke.app"
mkdir -p "${smoke_app}/Contents/MacOS" "${smoke_app}/Contents/Resources"
rm -rf "${smoke_app}/Contents/Resources/Backend"
ditto "${source_app}/Contents/Resources/Backend" "${smoke_app}/Contents/Resources/Backend"
cat > "${smoke_app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.amanuensis.backend-smoke</string>
<key>CFBundleExecutable</key><string>BackendSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# Cloud extraction must work from the slim bundle alone. The staged runtime is used
# because the bundled python3 only runs as a child of a sandboxed app.
PYTHONPATH=build/backend/src:build/backend/site-packages build/backend/python/bin/python3 -s -c '
import sys
from amanuensis_backend.extraction import parse_markdown, render_document
assert "42" in render_document(parse_markdown("# Answer\n\n**42**"), "latex")
assert "torch" not in sys.modules and "mlx" not in sys.modules
print("Slim backend parses cloud output")'

# Install a locally built Granite pack through the app's installer, signed like the app's runtime.
pack_dir="$(uv run --quiet --project backend --locked python scripts/prepare-backend.py --granite)"
identity="$(codesign -dvv "${source_app}/Contents/Resources/Backend/python/bin/python3" 2>&1 | awk -F= '/^Authority=/ && !found { print $2; found = 1 }')"
backend/.venv/bin/python3 scripts/sign-backend.py "${pack_dir}" "${identity:--}"
archive="$(pwd)/${smoke_app}/Contents/Resources/granite.zip"
rm -f "${archive}"
ditto -c -k --keepParent "${pack_dir}" "${archive}"
cat >"${smoke_app}/Contents/Resources/Backend/granite-pack.json" <<JSON
{
  "id": "$(basename "${pack_dir}")",
  "url": "file://${archive}",
  "sha256": "$(shasum -a 256 "${archive}" | awk '{ print $1 }')",
  "size": $(stat -f %z "${archive}"),
  "installedSize": 0
}
JSON

uv run --project backend python - <<'PY'
import plistlib
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
image = Image.new('RGB', (700, 220), 'white')
draw = ImageDraw.Draw(image)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 32)
draw.text((30, 35), 'Amanuensis local extraction', fill='black', font=font)
draw.text((30, 100), 'The answer is 42.', fill='black', font=font)
image.save('build/BackendSmoke.app/Contents/Resources/capture.png')
# Enforce offline operation, including native libraries, with App Sandbox.
Path('build/BackendSmoke.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
PY
xcrun swiftc Tests/BackendSmokeTests.swift \
    Amanuensis/Sources/Services/AIProviderClient.swift \
    Amanuensis/Sources/Services/GraniteInstaller.swift \
    Amanuensis/Sources/Models/AIProvider.swift \
    Amanuensis/Sources/Config.swift \
    -o "${smoke_app}/Contents/MacOS/BackendSmoke"
codesign --force --sign - --options runtime --entitlements build/BackendSmoke.entitlements "${smoke_app}"
"${smoke_app}/Contents/MacOS/BackendSmoke"
