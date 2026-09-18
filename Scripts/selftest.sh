#!/usr/bin/env bash
# Drive the built app's own end-to-end checks against a docset made for the occasion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$ROOT/Scripts/make-fixture-docset.sh" "$WORK" >/dev/null
DOCENT_DOCSETS="$WORK" DOCENT_SELFTEST=browse "$ROOT/build/Docent.app/Contents/MacOS/Docent"
