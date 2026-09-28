#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/xcode/Build/Products/Debug/Amanuensis.app"
binary="$app/Contents/MacOS/Amanuensis"
log="build/dev-app.log"

cleanup() {
  pkill -x Amanuensis 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "        🔨 Building Amanuensis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./scripts/build-debug.sh

pkill -x Amanuensis 2>/dev/null || true
for _ in {1..50}; do
  if ! pgrep -x Amanuensis >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

mkdir -p build
: >"$log"

INJECTION_DIRECTORIES="$PWD/Amanuensis/Sources,$PWD/build/xcode/Logs/Build" \
  NSUnbufferedIO=YES \
  nohup "$binary" --restore-settings >>"$log" 2>&1 &

cat <<'EOF'

Stop:                                 Ctrl-C
EOF

tail -n +1 -f "$log"
