#!/usr/bin/env bash
# Build a small, entirely invented docset in a folder, for tests, the self-test and the
# screenshots. Nothing here describes a real library, and no real machine is read.
set -euo pipefail

DEST="${1:?usage: make-fixture-docset.sh <folder>}"
BUNDLE="$DEST/Sparrow.docset"
DOCS="$BUNDLE/Contents/Resources/Documents"
mkdir -p "$DOCS"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>sparrow</string>
	<key>CFBundleName</key><string>Sparrow</string>
	<key>DocSetPlatformFamily</key><string>sparrow</string>
	<key>isDashDocset</key><true/>
</dict>
</plist>
PLIST

cat > "$DOCS/printing.html" <<'HTML'
<html><head><title>Printing — Sparrow</title>
<style>body{font:15px/1.6 -apple-system,sans-serif;margin:2.5rem;max-width:44rem}
code,pre{font-family:ui-monospace,Menlo,monospace}pre{background:#f4f4f6;padding:.8rem;border-radius:6px}</style>
</head><body>
<h1>Printing</h1>
<p>Sparrow writes to the console through one family of functions.</p>
<a name="Print"></a><h2>Print(value)</h2>
<pre>func Print(value: Any) -> Int</pre>
<p>Writes <code>value</code> to the console and returns the number of characters written.
A trailing newline is not added; use <code>PrintLine</code> for that.</p>
<ul><li>Returns the count of characters written.</li>
<li>Raises <code>ConsoleClosed</code> if the console has been closed.</li></ul>
<a name="PrintLine"></a><h2>PrintLine(value)</h2>
<pre>func PrintLine(value: Any) -> Int</pre>
<p>Writes <code>value</code> followed by a newline.</p>
<a name="PrintTable"></a><h2>PrintTable(rows)</h2>
<pre>func PrintTable(rows: [[Any]]) -> Int</pre>
<p>Writes rows as an aligned table.</p>
</body></html>
HTML

cat > "$DOCS/sparrow.html" <<'HTML'
<html><head><title>Sparrow</title></head><body>
<h1>Sparrow</h1><p>A small pretend library, invented for this project's tests and pictures.</p>
<a name="Sparrow"></a><h2>class Sparrow</h2><p>The entry point.</p>
</body></html>
HTML

/usr/bin/sqlite3 "$BUNDLE/Contents/Resources/docSet.dsidx" <<'SQL'
CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
INSERT INTO searchIndex(name,type,path) VALUES
 ('Sparrow','Class','sparrow.html#Sparrow'),
 ('Print','Function','printing.html#Print'),
 ('PrintLine','Function','printing.html#PrintLine'),
 ('PrintTable','Function','printing.html#PrintTable');
SQL

echo "$DEST"
