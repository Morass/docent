#!/usr/bin/env bash
# Assemble Docent.app and the docent command from the SwiftPM build. No Xcode project:
# an .app is a directory with a plist, and keeping it that way keeps the repo readable.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product DocentApp
swift build -c "$CONFIG" --product docent
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Docent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build"
cp "$BIN_DIR/DocentApp" "$APP/Contents/MacOS/Docent"
cp "$ROOT/Sources/DocentApp/Support/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN_DIR/docent" "$ROOT/build/docent"

# Ad-hoc signature: without it macOS refuses a bundle with no signature on first run.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
echo "built: $ROOT/build/docent"
