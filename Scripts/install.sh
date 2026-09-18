#!/usr/bin/env bash
# Install Docent.app and the docent command. Both locations can be overridden:
#   DOCENT_APP_DIR=~/Applications DOCENT_BIN_DIR=~/bin ./Scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${DOCENT_APP_DIR:-/Applications}"
BIN_DIR="${DOCENT_BIN_DIR:-/usr/local/bin}"

"$ROOT/Scripts/build-app.sh" release

mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Docent.app"
cp -R "$ROOT/build/Docent.app" "$APP_DIR/Docent.app"
echo "installed: $APP_DIR/Docent.app"

if mkdir -p "$BIN_DIR" 2>/dev/null && [ -w "$BIN_DIR" ]; then
    install -m 755 "$ROOT/build/docent" "$BIN_DIR/docent"
    echo "installed: $BIN_DIR/docent"
else
    echo "note: $BIN_DIR is not writable — copy build/docent somewhere on your PATH yourself,"
    echo "      or run: DOCENT_BIN_DIR=~/.local/bin ./Scripts/install.sh"
fi
