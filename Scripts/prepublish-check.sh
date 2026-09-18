#!/bin/bash
# Fails when publishing this repository would expose personal data: commit
# identities, agent instruction files, absolute home paths, IP addresses,
# token-shaped literals or e-mail addresses. Names and hosts specific to one
# machine belong in .git/info/private-patterns (one extended regex per line),
# which stays outside the repository.
set -u
cd "$(dirname "$0")/.."
fail=0
hit() { echo "✗ $1"; fail=1; }
self=':!scripts/prepublish-check.sh'

while read -r e; do
	case "$e" in
	*@users.noreply.github.com | "") ;;
	*) hit "a commit author/committer e-mail would be published: $e" ;;
	esac
done < <(git log --all --format='%ae%n%ce' | sort -u)

# Files that belong to the toolchain that built this repository, not to the
# repository: a template copied in during setup and never deleted.
templates='(^|/)(screenshots-harness\.sh|README-skeleton\.md|review-claim\.md|private-patterns\.example|TEMPLATE\.md)$'
tmpl=$(git ls-files | grep -E "$templates")
[ -n "$tmpl" ] && { echo "$tmpl"; hit "build-process templates are tracked"; }
tmplpast=$(git log --all --name-only --format= | sort -u | grep -E "$templates")
[ -n "$tmplpast" ] && { echo "$tmplpast"; hit "build-process templates exist in history"; }

agentfiles='(^|/)(AGENTS(\.override)?\.md|CLAUDE\.md|GEMINI\.md|\.cursorrules|copilot-instructions\.md)$|(^|/)\.(claude|cursor|agents)/'
tracked=$(git ls-files | grep -E "$agentfiles")
[ -n "$tracked" ] && { echo "$tracked"; hit "agent instruction files are tracked"; }
past=$(git log --all --name-only --format= | sort -u | grep -E "$agentfiles")
[ -n "$past" ] && { echo "$past"; hit "agent instruction files exist in history"; }

paths=$(git grep -nIE '/Users/[A-Za-z][A-Za-z0-9_-]+/|/home/[a-z][a-z0-9_-]+/|(^|[^0-9.v])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)' -- "$self" ':!go.sum' |
	grep -vE '/Users/(you|u|alice|bob|recorded|nonexistent)/|/home/(u|bob|linuxbrew|secret)/|0\.0\.0\.0|127\.0\.0\.1|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.')
[ -n "$paths" ] && { echo "$paths"; hit "home paths or IP addresses above"; }

tokens=$(git grep -nIE 'gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|npm_[A-Za-z0-9]{36}|-----BEGIN [A-Z ]*PRIVATE KEY-----' -- "$self")
[ -n "$tokens" ] && { echo "$tokens"; hit "token-shaped literals above (build test fixtures at run time)"; }

mails=$(git grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' -- "$self" ':!go.sum' |
	grep -vE 'example\.(com|org)|users\.noreply\.github\.com|git@github\.com')
[ -n "$mails" ] && { echo "$mails"; hit "e-mail addresses above"; }

if [ -s .git/info/private-patterns ]; then
	pp=$(grep -v '^[[:space:]]*$' .git/info/private-patterns | paste -sd'|' -)
	if [ -n "$pp" ]; then
		files=$(git grep -nIiE "$pp" -- "$self")
		[ -n "$files" ] && { echo "$files"; hit "private patterns found in files"; }
		msgs=$(git log --all --format='%h %s%n%b' | grep -iE "$pp")
		[ -n "$msgs" ] && { echo "$msgs"; hit "private patterns found in commit messages"; }
		# History the owner has decided to leave alone can be listed, one
		# extended regex per line, in .git/info/private-exceptions (local,
		# never committed). Only past diffs can be excused this way: the
		# working tree and commit messages are always checked in full.
		past=$(git log --all -p -- . "$self" | grep -iE "$pp")
		if [ -s .git/info/private-exceptions ]; then
			ex=$(grep -v '^[[:space:]]*\(#\|$\)' .git/info/private-exceptions | paste -sd'|' -)
			[ -n "$ex" ] && past=$(printf '%s\n' "$past" | grep -ivE "$ex")
		fi
		n=$(printf '%s' "$past" | grep -c . )
		[ "$n" != 0 ] && hit "private patterns found in $n line(s) of past diffs"
	fi
fi

[ "$fail" = 0 ] && echo "✓ nothing personal or private found"
exit "$fail"
