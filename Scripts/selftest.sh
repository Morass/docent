#!/usr/bin/env bash
# Drive the built app's own end-to-end checks against a docset made for the occasion.
# These cover what `swift test` cannot reach: the window's model, the real web view, and
# the promise that a page cannot reach the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Docent.app/Contents/MacOS/Docent"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$ROOT/Scripts/make-fixture-docset.sh" "$WORK" >/dev/null

for mode in browse page network; do
    HOME="$WORK" DOCENT_DOCSETS="$WORK" DOCENT_SELFTEST="$mode" "$APP"
done

# The negative control: with the block removed, the beacon must fire. Without this, the
# network check could be passing because nothing loads at all.
if HOME="$WORK" DOCENT_DOCSETS="$WORK" DOCENT_SELFTEST=network DOCENT_SELFTEST_NO_BLOCK=1 "$APP" >/dev/null 2>&1; then
    echo "selftest network: the negative control passed, so the network test proves nothing" >&2
    exit 1
fi
echo "selftest network: negative control fired as expected"
