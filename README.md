# Docent

**Read offline documentation sets on a Mac — in a window, or straight from the terminal.**

<p align="center"><img src="docs/images/app.png" alt="The Docent window: docsets on the left, search results in the middle, the page on the right" width="900"></p>

Docsets are the offline documentation format used by Dash and Zeal: a folder with an index
and a tree of HTML pages. Docent opens the ones you already have — no account, no
subscription, nothing downloaded behind your back — and gives you one search across all of
them, in an app and in a command you can pipe.

- **Search** every docset at once, exactly or loosely: `NSPast` finds `NSPasteboard`.
- **Read** a symbol's page in the window, or print it as text with `docent show`.
- **Keep it offline.** Docent never opens a network connection, and pages you read cannot
  either.

One Swift binary and one app bundle, no runtime dependencies, macOS 14 or later.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Getting docsets](#getting-docsets)
- [A tour](#a-tour)
- [Keyboard](#keyboard)
- [Getting help](#getting-help)
- [Command reference](#command-reference)
- [What it touches](#what-it-touches)
- [Limits](#limits)
- [License](#license)

## Install

From a checkout, with the Xcode command line tools installed:

```sh
make install
```

That builds `Docent.app` into `/Applications` and the `docent` command into
`/usr/local/bin`. Both destinations can be moved:

```sh
DOCENT_APP_DIR=~/Applications DOCENT_BIN_DIR=~/.local/bin make install
```

`make` alone builds both into `./build` without installing anything.

## Quick start

```sh
docent add ~/Downloads/Go.tgz     # put a docset in your library
docent list                       # what is installed
docent find Println               # search every docset
docent show go:Println            # print the documentation as text
open -a Docent                    # the same library, in a window
```

## Getting docsets

Docent reads docsets; it does not host or sell them. Three ways to get one:

- **You already have them.** If Dash or Zeal is installed, Docent reads their docset
  folders as they are — nothing to copy.
- **Download one** from the docset feeds those apps use, then add the archive:
  `docent add ~/Downloads/Python_3.tgz`.
- **Build one from any documentation** with [doc2dash](https://github.com/hynek/doc2dash),
  which turns Sphinx, MkDocs and similar output into a docset:
  `doc2dash -n MyLib docs/_build/html && docent add MyLib.docset`.

## A tour

### 1. Find something

`docent find` searches every installed docset and puts the best answer first: an exact
name, then names that start with what you typed, then names that merely contain it, then a
loose letters-in-order match for when you only half-remember it.

<p align="center"><img src="docs/images/find.svg" alt="docent find Print listing three matching functions" width="820"></p>

Narrow it to one docset with its keyword — `docent find go:Println` — or with
`--docset go`.

### 2. Read it without leaving the terminal

`docent show` prints the documentation as text. When a docset points at one symbol on a
long page, you get that section rather than the whole file; `--all` gives you the page.

<p align="center"><img src="docs/images/show.svg" alt="docent show PrintLine printing a function's signature and description" width="820"></p>

`docent find --json` prints the same results as JSON, and `docent path` prints the file a
symbol lives in, so you can hand it to something else.

### 3. Or in a window

The app opens on the search field. Type, move through the results with the arrow keys
without leaving the field, and the page appears beside them. The docsets on the left narrow
the search to one at a time.

## Keyboard

| Key | What it does |
|---|---|
| ⌘F | back to the search field |
| ↑ / ↓ | move through the results while you keep typing |
| ⌘[ / ⌘] | back and forward through what you have read |
| ⌘R | look for docsets again after adding one |

## Getting help

```sh
docent --help            # the commands, with examples
docent help find         # one command in full
docent find --help       # the same thing
```

## Command reference

| Command | What it does |
|---|---|
| `docent list` | the docsets Docent can see, with their keywords and sizes |
| `docent find <query>` | search every docset; `--limit`, `--docset`, `--json` |
| `docent show <query>` | print a symbol's documentation as text; `--all`, `--index N` |
| `docent path <query>` | print the file (and anchor) a symbol lives in |
| `docent add <path>` | install a `.docset` folder or a `.tgz` archive; `--replace` |

## What it touches

Docent installs docsets into `~/Library/Application Support/Docent/DocSets`, and that is
the only place it writes. It reads:

- that folder,
- `~/Library/Application Support/Dash/DocSets` and `~/.local/share/Zeal/Zeal/docsets`, so
  docsets you already have just appear,
- whatever `DOCENT_DOCSETS` names, if you set it (a colon-separated list of folders, which
  replaces all three).

It never writes to a docset, never deletes one you did not ask it to replace, and never
opens a network connection. Pages you read cannot either: JavaScript is off, remote images,
stylesheets and fonts are blocked, and a link to the web opens in your own browser instead
of loading inside Docent. A docset that points at a file outside itself is refused rather
than followed.

## Limits

- macOS 14 or later, and docsets in the Dash format. Other documentation formats need
  converting first (see [doc2dash](https://github.com/hynek/doc2dash)).
- No docset catalogue or downloader: you bring the docsets.
- `docent show` renders a page as plain text. Tables come out as rows, diagrams and images
  do not come out at all — read those in the window.
- Search is over symbol names, not the text of the pages.

## License

[MIT](LICENSE): use it, change it, share it, sell it. Keep the copyright notice.
