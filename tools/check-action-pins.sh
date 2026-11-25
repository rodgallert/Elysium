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
# The files are the ones git tracks (`git ls-files -s`; a new file must be `git add`ed to be checked): the workflows
# .github/workflows/*.yml and every action.yml / action.yaml in the repository, wherever it lives (a local action can:
# `uses: ./tools/x`), with no directory skipped. A tracked symlink among them is an offender "<symlink>", and a local
# reference passes only when it resolves to a scanned regular action.yml / action.yaml or a workflow file.
# Usage: tools/check-action-pins.sh [--list] [repository root]   (default: the repository this script is in)
# Output: one line per offender, "<file>:<line>: <ref>" (the `uses` value, or the `runs-on` value), nothing else, so
# no other text of a workflow reaches the log. Exit 0 when nothing is wrong, 1 on offenders, 2 on a bad argument.
# --list prints "<file>: uses <value>" and "<file>: runs-on <value>" for every key it reads, in line order, and exits 0;
# --files prints the scanned files. tools/check-workflow-crosscheck.sh compares that with what yq finds.
#
# The guarantee that nothing hides is the action-pins job's: this script, tools/check-workflow-permissions.sh and the yq
# cross-check together. This script alone refuses the forms listed above; it still passes some valid YAML that only the
# cross-check catches: an explicit `? uses` key, a double-quoted key written with an escape (`"us\u0065s"`) and a file
# with lone CR line breaks (yq splits lines on CR, awk does not). Do not use it alone as the check.
#
# Offline on purpose: it reads files and never uses the network. So it cannot see a commit that was deleted upstream
# (GitHub fails that job when it downloads the action) or tell a tag that is named like a 40-character hex from a
# commit; the repository setting "Require actions to be pinned to a full-length commit SHA" refuses the latter at run time.
# Plain POSIX sh (CI runs it under dash) and awk without GNU extensions.
set -eu

mode=check
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--files" ]; then
    mode="${1#--}"
    shift
fi
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$(cd "$here/.." && pwd)}"
if [ ! -d "$root" ]; then
    echo "check-action-pins.sh: $root is not a directory" >&2
    exit 2
fi
if [ ! -e "$root/.git" ]; then
    echo "check-action-pins.sh: $root is not a git repository" >&2
    exit 2
fi
cd "$root"

# The tracked files (tools/tracked-ci-files.sh): F to scan, S symlink, G not a regular file, U an unsafe name
if ! records="$(sh "$here/tracked-ci-files.sh" "$root")"; then
    echo "check-action-pins.sh: git cannot list the files of $root" >&2
    exit 2
fi
files="$(printf '%s\n' "$records" | awk '$1 == "F" { sub(/^. /, ""); print }')"
extra=""
if [ "$mode" = check ]; then
    extra="$(printf '%s\n' "$records" | awk 'NF && $1 != "F" {
        k = $1
        sub(/^. /, "")
        printf "%s:1: <%s>\n", $0, (k == "S" ? "symlink" : (k == "G" ? "not a regular file" : "unsafe file name"))
    }')"
fi
if [ "$mode" = files ]; then
    [ -z "$files" ] || printf '%s\n' "$files"
    exit 0
fi

# Every file name is a plain path; word splitting on newlines only, no globbing
IFS='
'
set -f
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rc=0
: >"$work/awk"
if [ -n "$files" ]; then
    # shellcheck disable=SC2086
    SCANNED="$files" awk -v mode="$mode" '
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
# ./<dir> with a scanned regular <dir>/action.yml or .yaml, or ./.github/workflows/<name>.yml that is scanned. The path is
# plain characters only, with no ., .. or empty segment; a symlink is never in the scanned set
function local_ok(ref,    path, n, parts, i) {
    if (ref !~ "^[A-Za-z0-9_./-]+$") return 0
    path = substr(ref, 3)
    sub(/\/$/, "", path)
    if (path == "") return ("action.yml" in scanned) || ("action.yaml" in scanned)
    n = split(path, parts, "/")
    for (i = 1; i <= n; i++) if (parts[i] == "" || parts[i] == "." || parts[i] == "..") return 0
    if (path ~ /^[.]github\/workflows\/[^\/]+[.]ya?ml$/) return (path in scanned)
    return ((path "/action.yml") in scanned) || ((path "/action.yaml") in scanned)
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
    n = split(ENVIRON["SCANNED"], scanned_list, "\n")
    for (i = 1; i <= n; i++) scanned[scanned_list[i]] = 1
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
        # a local action or workflow: nothing to pin, but it must be a scanned action.yml / action.yaml or a workflow
        if (!local_ok(val)) offender(val)
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
END { exit bad ? 1 : 0 }' $files >"$work/awk" 2>/dev/null || rc=$?
fi
# 1 only means "offenders found"; anything above is awk failing (an unreadable file), which must not look like a pass
if [ "$rc" -gt 1 ]; then
    echo "check-action-pins.sh: awk failed (status $rc) reading the files" >&2
    exit 2
fi
out="$({
    [ -z "$extra" ] || printf '%s\n' "$extra"
    cat "$work/awk"
} | LC_ALL=C sort -s -t: -k1,1)"
[ -z "$out" ] || printf '%s\n' "$out"
[ "$mode" = list ] || [ -z "$out" ] || exit 1
exit 0
