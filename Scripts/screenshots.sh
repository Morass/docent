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

scene() {  # scene <name> <command…>            — with the fixture library
    scene_with "DOCENT_DOCSETS='$WORK'" "$@"
}

scene_home() {  # scene_home <name> <command…>     — with only the sandbox HOME, so a
    scene_with "" "$@"                             # command that installs shows ~/Library
}

scene_with() {  # scene_with <env> <name> <command…>
    local extra="$1"; shift
    local name="$1"; shift
    "$TMUX_BIN" -S "$SOCKET" -f /dev/null new-session -d -s shot -x 96 -y 22 \
        "PS1='\[\e[1;32m\]\$\[\e[0m\] ' bash --noprofile --norc"
    "$TMUX_BIN" -S "$SOCKET" set -g status off
    "$TMUX_BIN" -S "$SOCKET" send-keys -t shot \
        "export HOME='$DEMO_HOME' $extra PATH='$ROOT/build:/usr/bin:/bin' TERM=xterm-256color; clear" Enter
    nap 0.5
    "$TMUX_BIN" -S "$SOCKET" send-keys -t shot "$*" Enter
    nap 1.2
    # The sandbox HOME is a temporary directory; nobody needs to read its name.
    "$TMUX_BIN" -S "$SOCKET" capture-pane -p -e -t shot | sed "s#$DEMO_HOME#~#g" > "$WORK/$name.ansi"
    "$TMUX_BIN" -S "$SOCKET" kill-session -t shot
    "$WORK/term-to-svg" < "$WORK/$name.ansi" > "$OUT/$name.svg"
    echo "wrote $OUT/$name.svg"
}

scene find "docent find Print"
scene show "docent show PrintLine"

# A project to photograph the window with. A checkout of daub (a public repo of the same
# author) if it is here, exported clean so nothing untracked can appear in a picture;
# otherwise a small invented one, so this script runs anywhere.
PROJECT="$DEMO_HOME/code/project"
mkdir -p "$PROJECT"
SOURCE="${DOCENT_SHOT_PROJECT:-$HOME/programs/daub}"
if [ -d "$SOURCE/.git" ]; then
    PROJECT_NAME=$(basename "$SOURCE")
    rm -rf "$PROJECT" && mkdir -p "$DEMO_HOME/code/$PROJECT_NAME"
    PROJECT="$DEMO_HOME/code/$PROJECT_NAME"
    git -C "$SOURCE" archive HEAD | tar -x -C "$PROJECT"
else
    mkdir -p "$PROJECT/Sources"
    printf '# Sample\n\nA small project.\n\n## Install\n\nRun make.\n' > "$PROJECT/README.md"
    printf '/// Somewhere to draw.\npublic struct Canvas {\n    /// Draws a line.\n    public func draw() {}\n}\n' \
        > "$PROJECT/Sources/Canvas.swift"
    PROJECT_NAME=Sample
fi
TITLE=$(printf '%s' "$PROJECT_NAME" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
KEYWORD=$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')
# Indexed the way a reader would do it, in the sandbox, and photographed as it happens.
scene_home index "docent index ~/code/$PROJECT_NAME --name $TITLE --keyword $KEYWORD"
cp -R "$DEMO_HOME/Library/Application Support/Docent/DocSets/$TITLE.docset" "$WORK/" 2>/dev/null || \
    HOME="$DEMO_HOME" "$ROOT/build/docent" index "$PROJECT" --name "$TITLE" --keyword "$KEYWORD" \
        --out "$WORK/$TITLE.docset" >/dev/null

app() {  # app NAME [env…]
    local name="$1"; shift
    HOME="$DEMO_HOME" DOCENT_DOCSETS="$WORK" DOCENT_SCREENSHOT="$OUT/$name.png" \
        "$@" "$ROOT/build/Docent.app/Contents/MacOS/Docent" >/dev/null 2>&1
    echo "wrote $OUT/$name.png"
}

# The three pictures the README needs: the project as a tree beside its overview, a
# declaration with its documentation, and a search across the library.
app app env DOCENT_SCREENSHOT_DOCSET="$KEYWORD"
app app-page env DOCENT_SCREENSHOT_DOCSET="$KEYWORD" DOCENT_SCREENSHOT_QUERY="${DOCENT_SHOT_SYMBOL:-Bitmap}"
app app-search env DOCENT_SCREENSHOT_QUERY=Print
