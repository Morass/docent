#!/usr/bin/env bash
# Re-take the pictures in the README.
#
# Everything here runs against an invented docset in a throwaway HOME, so no picture can
# show a real library, a real path or a real machine. The terminal shots are captured from
# a real tmux session and rendered to SVG; the app photographs its own window.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/images"
mkdir -p "$OUT"

WORK="$(mktemp -d /tmp/docent-shots.XXXXXX)"
DEMO_HOME="$WORK/home"
SOCKET="$WORK/s"
TMUX_BIN="$(command -v tmux)"
trap '"$TMUX_BIN" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

mkdir -p "$DEMO_HOME"
"$ROOT/Scripts/make-fixture-docset.sh" "$WORK" >/dev/null
[ -x "$ROOT/build/docent" ] || "$ROOT/Scripts/build-app.sh" release >/dev/null

swiftc -O "$ROOT/Scripts/term-to-svg.swift" -o "$WORK/term-to-svg"

nap() { perl -e "select(undef,undef,undef,$1)"; }

scene() {  # scene <name> <command…>
    local name="$1"; shift
    "$TMUX_BIN" -S "$SOCKET" -f /dev/null new-session -d -s shot -x 96 -y 22 \
        "PS1='\[\e[1;32m\]\$\[\e[0m\] ' bash --noprofile --norc"
    "$TMUX_BIN" -S "$SOCKET" set -g status off
    "$TMUX_BIN" -S "$SOCKET" send-keys -t shot \
        "export HOME='$DEMO_HOME' DOCENT_DOCSETS='$WORK' PATH='$ROOT/build:/usr/bin:/bin' TERM=xterm-256color; clear" Enter
    nap 0.5
    "$TMUX_BIN" -S "$SOCKET" send-keys -t shot "$*" Enter
    nap 1.2
    "$TMUX_BIN" -S "$SOCKET" capture-pane -p -e -t shot > "$WORK/$name.ansi"
    "$TMUX_BIN" -S "$SOCKET" kill-session -t shot
    "$WORK/term-to-svg" < "$WORK/$name.ansi" > "$OUT/$name.svg"
    echo "wrote $OUT/$name.svg"
}

scene find "docent find Print"
scene show "docent show PrintLine"

HOME="$DEMO_HOME" DOCENT_DOCSETS="$WORK" DOCENT_SCREENSHOT="$OUT/app.png" \
    DOCENT_SCREENSHOT_QUERY=Print "$ROOT/build/Docent.app/Contents/MacOS/Docent"
echo "wrote $OUT/app.png"
