#!/bin/sh
# Checks what the repository's workflows pull in and run on (#83, Docs/workflow.md, "Pinned actions, default permissions
# and runners"):
#   - every `uses:` in .github/workflows/*.yml and .github/actions/**/action.yml is either a local path starting with ./
#     or <owner>/<repo>[/<path>]@<40 lowercase hex characters> followed by a version comment (`# v1.2.3`, the release
#     tag the commit came from). Tags, branches, short or uppercase SHAs, docker:// references, quoted values, block
#     values and a missing comment all fail;
#   - every `runs-on:` in .github/workflows is exactly ubuntu-24.04 (no -latest, no other image, no list, no expression);
#   - it fails on any form it does not read: a `uses` or `runs-on` key that is quoted, has a space before the colon or
#     sits inside a `{ ... }` or `[ ... ]` (a flow mapping), is an offender "<unrecognised: uses>" or "<unrecognised:
#     runs-on>", so quoting a key never hides a line.
# A local reference (`uses: ./<path>`) needs an action.yml / action.yaml in that directory, or to be a workflow file.
# The files are .github/workflows/*.yml and every action.yml / action.yaml in the repository (a local action can live
# anywhere: `uses: ./tools/x`), except under node_modules, .git and .claude.
# Usage: tools/check-action-pins.sh [--list] [repository root]   (default: the repository this script is in)
# Output: one line per offender, "<file>:<line>: <ref>" (the `uses` value, or the `runs-on` value), nothing else, so
# no other text of a workflow reaches the log. Exit 0 when nothing is wrong, 1 on offenders, 2 on a bad argument.
# --list prints "<file>: uses <value>" and "<file>: runs-on <value>" for every key it reads, in line order, and exits 0;
# tools/check-workflow-crosscheck.sh compares that with what yq finds.
#
# Offline on purpose: it reads files and never uses the network. So it cannot see a commit that was deleted upstream
# (GitHub fails that job when it downloads the action) or tell a tag that is named like a 40-character hex from a
# commit; the repository setting "Require actions to be pinned to a full-length commit SHA" refuses the latter at run time.
# Plain POSIX sh (CI runs it under dash) and awk without GNU extensions.
set -eu

mode=check
if [ "${1:-}" = "--list" ]; then
    mode=list
    shift
fi
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$root" ]; then
    echo "check-action-pins.sh: $root is not a directory" >&2
    exit 2
fi
cd "$root"

files="$({
    find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true
    find . \( -name node_modules -o -name .git -o -name .claude \) -prune -o -type f \
        \( -name action.yml -o -name action.yaml \) -print 2>/dev/null | sed 's|^\./||' || true
} | LC_ALL=C sort -u)"
[ -n "$files" ] || exit 0

# Every file name is a plain path; word splitting on newlines only, no globbing
IFS='
'
set -f
# shellcheck disable=SC2086
exec awk -v mode="$mode" '
function offender(ref) {
    if (mode == "list") return
    printf "%s:%d: %s\n", FILENAME, FNR, ref
    bad = 1
}
# <owner>/<repo>[/<path>]@<40 lowercase hex>, no spaces
function pinned(val,    n, parts) {
    n = split(val, parts, "@")
    if (n != 2) return 0
    if (parts[1] !~ "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?$") return 0
    if (length(parts[2]) != 40) return 0
    return parts[2] ~ "^[0-9a-f]+$"
}
# The value of a key and the comment after it: sets val (comment stripped, trimmed) and cmt
function split_value(rest) {
    sub(/^[[:space:]]+/, "", rest)
    if (rest ~ /^#/) {
        val = ""
        cmt = rest
    } else {
        val = rest
        sub(/[[:space:]]+#.*$/, "", val)
        sub(/[[:space:]]+$/, "", val)
        cmt = substr(rest, length(val) + 1)
        sub(/^[[:space:]]+/, "", cmt)
    }
}
BEGIN {
    q = "\047"
    uses_key = "(^|[^A-Za-z0-9_.-])[\"" q "]?uses[\"" q "]?[[:space:]]*:"
    runs_key = "(^|[^A-Za-z0-9_.-])[\"" q "]?runs-on[\"" q "]?[[:space:]]*:"
}
{
    line = $0
    sub(/\r$/, "", line)
}
line ~ /^[[:space:]]*#/ { next }
match(line, /^[[:space:]]*(-[[:space:]]+)?uses:/) {
    split_value(substr(line, RLENGTH + 1))
    if (mode == "list") {
        if (val != "") printf "%s: uses %s\n", FILENAME, val
    } else if (val == "") {
        offender("<empty>")
    } else if (substr(val, 1, 2) == "./") {
        # a local action or workflow: nothing to pin, but it must exist (its action.yml is scanned like the rest).
        # The path comes from a file, so only plain path characters ever reach the shell
        if (val !~ "^[A-Za-z0-9_./-]+$") offender(val)
        else if (system("[ -f \"" val "\" ] || [ -f \"" val "/action.yml\" ] || [ -f \"" val "/action.yaml\" ]") != 0) offender(val)
    } else if (!pinned(val) || cmt !~ /^#[[:space:]]*v[0-9]+[.][0-9]+[.][0-9]+([-+[:space:]].*)?$/) {
        offender(val)
    }
    next
}
index(FILENAME, ".github/workflows/") == 1 && match(line, /^[[:space:]]*runs-on:/) {
    split_value(substr(line, RLENGTH + 1))
    if (mode == "list") {
        printf "%s: runs-on %s\n", FILENAME, (val == "" ? "<empty>" : val)
    } else {
        if (val == "") val = "<empty>"
        if (val != "ubuntu-24.04") offender(val)
    }
    next
}
{
    # anything else that has a uses or runs-on key in it is a form this check does not read: refuse it
    code = line
    sub(/[[:space:]]+#.*$/, "", code)
    if (code ~ uses_key) offender("<unrecognised: uses>")
    if (index(FILENAME, ".github/workflows/") == 1 && code ~ runs_key) offender("<unrecognised: runs-on>")
}
END { exit bad ? 1 : 0 }
' $files
