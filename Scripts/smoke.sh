#!/usr/bin/env bash
# A real terminal: tmux, real keystrokes, and a look at what actually appeared on screen.
# Model tests and piped end-to-end tests both miss what a TTY changes — colour, width,
# and how a long page lands on a small screen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/docent"
[ -x "$BIN" ] || { echo "smoke: build first (make build)" >&2; exit 1; }

# A Unix socket path caps at about 104 characters, so keep the working directory short.
WORK="$(mktemp -d /tmp/docent-smoke.XXXXXX)"
SOCKET="$WORK/s"
SESSION=smoke
trap 'tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

"$ROOT/Scripts/make-fixture-docset.sh" "$WORK" >/dev/null

fail=0
check() {
    local label="$1" pattern="$2"
    if tmux -S "$SOCKET" capture-pane -p -t "$SESSION" | grep -q -- "$pattern"; then
        echo "  ok   $label"
    else
        echo "  FAIL $label (expected to see: $pattern)" >&2
        tmux -S "$SOCKET" capture-pane -p -t "$SESSION" | sed 's/^/       | /' >&2
        fail=1
    fi
}

run() {
    tmux -S "$SOCKET" send-keys -t "$SESSION" "clear; $1" Enter
    sleep 1
}

tmux -S "$SOCKET" new-session -d -s "$SESSION" -x 100 -y 30
tmux -S "$SOCKET" set-environment -t "$SESSION" DOCENT_DOCSETS "$WORK"
tmux -S "$SOCKET" send-keys -t "$SESSION" "export DOCENT_DOCSETS='$WORK' PATH='$ROOT/build:$PATH'" Enter
sleep 0.5

echo "smoke: a real terminal"

run "docent list"
check "list names the docset" "Sparrow"
check "list shows the keyword" "sparrow:"

run "docent find Print"
check "find lists the exact match first" " 1. Print "
check "find lists the others" "PrintTable"

run "docent show Print"
check "show prints the signature" "func Print(value: Any)"
check "show stops at the next symbol" "characters written"
if tmux -S "$SOCKET" capture-pane -p -t "$SESSION" | grep -q "Writes value followed by a newline"; then
    echo "  FAIL show leaked the next section into this one" >&2
    fail=1
else
    echo "  ok   show did not leak the next section"
fi

# A terminal gets colour; a pipe does not. Both paths matter and only one is visible here.
run "docent find Print | cat -v"
if tmux -S "$SOCKET" capture-pane -p -t "$SESSION" | grep -q '\^\[\['; then
    echo "  FAIL colour escapes survived a pipe" >&2
    fail=1
else
    echo "  ok   a pipe gets plain text"
fi

run "docent find Print"
if tmux -S "$SOCKET" capture-pane -p -e -t "$SESSION" | grep -q $'\033\['; then
    echo "  ok   a terminal gets colour"
else
    echo "  FAIL a terminal got no colour" >&2
    fail=1
fi

run "docent show Nothing-Like-This; echo exit=\$?"
check "a miss explains itself" "nothing is called"
check "a miss exits non-zero" "exit=1"

if [ "$fail" -eq 0 ]; then
    echo "smoke: all good"
else
    echo "smoke: failures above" >&2
    exit 1
fi
