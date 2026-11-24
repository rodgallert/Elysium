#!/bin/sh
# Checks what the repository's workflows pull in and run on (#83, Docs/workflow.md, "Pinned actions, default permissions
# and runners"):
#   - every `uses:` in .github/workflows/*.yml and .github/actions/**/action.yml is either a local path starting with ./
#     or <owner>/<repo>[/<path>]@<40 lowercase hex characters> followed by a version comment (`# v1.2.3`, the release
#     tag the commit came from). Tags, branches, short or uppercase SHAs, docker:// references, quoted values, block
#     values and a missing comment all fail;
#   - every `runs-on:` in .github/workflows is exactly ubuntu-24.04 (no -latest, no other image, no list, no expression).
# Usage: tools/check-action-pins.sh [repository root]   (default: the repository this script is in)
# Output: one line per offender, "<file>:<line>: <ref>" (the `uses` value, or the `runs-on` value), nothing else, so
# no other text of a workflow reaches the log. Exit 0 when nothing is wrong, 1 on offenders, 2 on a bad argument.
#
# Offline on purpose: it reads files and never uses the network. So it cannot see a commit that was deleted upstream
# (GitHub fails that job when it downloads the action) or tell a tag that is named like a 40-character hex from a
# commit; the repository setting "Require actions to be pinned to a full-length commit SHA" refuses the latter at run time.
# Plain POSIX sh (CI runs it under dash) and awk without GNU extensions.
set -eu

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$root" ]; then
    echo "check-action-pins.sh: $root is not a directory" >&2
    exit 2
fi
cd "$root"

files="$({
    find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true
    find .github/actions -type f \( -name action.yml -o -name action.yaml \) 2>/dev/null || true
} | LC_ALL=C sort)"
[ -n "$files" ] || exit 0

# Every file name is a plain path; word splitting on newlines only, no globbing
IFS='
'
set -f
# shellcheck disable=SC2086
exec awk '
function offender(ref) {
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
{
    line = $0
    sub(/\r$/, "", line)
}
match(line, /^[[:space:]]*(-[[:space:]]+)?uses:/) {
    split_value(substr(line, RLENGTH + 1))
    if (val == "") {
        offender("<empty>")
    } else if (substr(val, 1, 2) == "./") {
        # a local action or workflow: nothing to pin
    } else if (!pinned(val) || cmt !~ /^#[[:space:]]*v[0-9]+[.][0-9]+[.][0-9]+([-+[:space:]].*)?$/) {
        offender(val)
    }
    next
}
index(FILENAME, ".github/workflows/") == 1 && match(line, /^[[:space:]]*runs-on:/) {
    split_value(substr(line, RLENGTH + 1))
    if (val == "") val = "<empty>"
    if (val != "ubuntu-24.04") offender(val)
}
END { exit bad ? 1 : 0 }
' $files
