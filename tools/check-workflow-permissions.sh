#!/bin/sh
# Checks that no workflow gets a token it did not ask for (#83, Docs/workflow.md, "Pinned actions, default permissions
# and runners"): in every .github/workflows/*.yml
#   - the top-level `permissions:` is exactly `{}` (not write-all, read-all, a block or missing), so a new job starts with
#     no token at all;
#   - every job has its own `permissions:` key, with only the grants it uses (`permissions: {}` is a valid block);
#     `write-all` and `read-all` are not accepted at job level either.
# Usage: tools/check-workflow-permissions.sh [--list] [repository root]   (default: the repository this script is in)
# Output: one line per offender, "<file>: top level: <problem>" or "<file>: job <name>: <problem>"; exit 0 when there
# are none, 1 on offenders, 2 on a bad argument. With --list it prints each job's grants instead, one line per job,
# "<file>: job <name>: <key:value ...>" sorted (or "none"), and exits 0: the PR description's table and the test that no
# job gained a permission read it.
# Reads files only, plain POSIX sh (CI runs it under dash) and awk without GNU extensions. It understands the layout
# the workflows use (block mappings, `permissions: {}` and one-line `{ key: value }` forms), not all of YAML.
set -eu

mode=check
if [ "${1:-}" = "--list" ]; then
    mode=list
    shift
fi
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$root" ]; then
    echo "check-workflow-permissions.sh: $root is not a directory" >&2
    exit 2
fi
cd "$root"

files="$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | LC_ALL=C sort || true)"
[ -n "$files" ] || exit 0

IFS='
'
set -f
# shellcheck disable=SC2086
exec awk -v mode="$mode" '
function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}
# the value of "key: value" without its comment
function value_of(s) {
    sub(/^[^:]*:/, "", s)
    sub(/(^|[[:space:]])#.*$/, "", s)
    return trim(s)
}
function key_of(s) {
    s = trim(s)
    sub(/:.*$/, "", s)
    return s
}
function add_grant(k, v) {
    ngrant++
    grant[ngrant] = k ":" v
}
# "{ a: b, c: d }" or "{}"
function parse_flow(v,    n, i, parts, kv) {
    sub(/^\{/, "", v)
    sub(/\}$/, "", v)
    v = trim(v)
    if (v == "") return
    n = split(v, parts, ",")
    for (i = 1; i <= n; i++) {
        kv = trim(parts[i])
        add_grant(trim(substr(kv, 1, index(kv, ":") - 1)), trim(substr(kv, index(kv, ":") + 1)))
    }
}
function sorted_grants(    i, j, t, out) {
    for (i = 2; i <= ngrant; i++) {
        t = grant[i]
        for (j = i - 1; j >= 1 && grant[j] > t; j--) grant[j + 1] = grant[j]
        grant[j + 1] = t
    }
    out = ""
    for (i = 1; i <= ngrant; i++) out = out (i > 1 ? " " : "") grant[i]
    return out == "" ? "none" : out
}
function finish_job() {
    if (job == "") return
    jobs[++njobs] = job
    if (!has_perm) {
        problem[njobs] = "no permissions block"
        listing[njobs] = "(no permissions block)"
    } else if (scalar != "") {
        problem[njobs] = "permissions: " scalar " is not allowed"
        listing[njobs] = scalar
    } else if (is_block && ngrant == 0) {
        problem[njobs] = "permissions block is empty (write {} to grant nothing)"
        listing[njobs] = "none"
    } else {
        listing[njobs] = sorted_grants()
    }
    job = ""
}
function reset_job() {
    has_perm = 0
    scalar = ""
    is_block = 0
    in_block = 0
    ngrant = 0
    child = 0
}
function end_file(    i, topproblem) {
    finish_job()
    if (!top_seen) topproblem = "no permissions key"
    else if (top_val != "{}") topproblem = (top_val == "" ? "a block" : top_val)
    if (mode == "check" && topproblem != "") {
        printf "%s: top level: permissions must be {} (found: %s)\n", cur_file, topproblem
        bad = 1
    }
    for (i = 1; i <= njobs; i++) {
        if (mode == "list") printf "%s: job %s: %s\n", cur_file, jobs[i], listing[i]
        else if (problem[i] != "") {
            printf "%s: job %s: %s\n", cur_file, jobs[i], problem[i]
            bad = 1
        }
    }
    for (i = 1; i <= njobs; i++) {
        delete jobs[i]
        delete problem[i]
        delete listing[i]
    }
    njobs = 0
}
function start_file() {
    cur_file = FILENAME
    top_seen = 0
    top_val = ""
    in_jobs = 0
    job_indent = 0
    in_top_block = 0
    reset_job()
    job = ""
}
FNR == 1 {
    if (NR > 1) end_file()
    start_file()
}
{
    line = $0
    sub(/\r$/, "", line)
}
line ~ /^[[:space:]]*(#|$)/ { next }
{
    match(line, /^ */)
    indent = RLENGTH
}
indent == 0 {
    in_jobs = 0
    in_top_block = 0
    finish_job()
    k = key_of(line)
    if (k == "permissions") {
        top_seen = 1
        top_val = value_of(line)
    } else if (k == "jobs") {
        in_jobs = 1
        job_indent = 0
    }
    next
}
!in_jobs { next }
{
    if (job_indent == 0) job_indent = indent
    if (indent == job_indent && line ~ /^ *[A-Za-z_][A-Za-z0-9_-]*:/) {
        finish_job()
        job = key_of(line)
        reset_job()
        next
    }
    if (job == "") next
    if (child == 0) child = indent
    if (in_block && indent > child) {
        # one grant per line
        add_grant(key_of(line), value_of(line))
        next
    }
    in_block = 0
    if (indent == child && key_of(line) == "permissions") {
        has_perm = 1
        v = value_of(line)
        if (v == "") {
            is_block = 1
            in_block = 1
        } else if (substr(v, 1, 1) == "{") {
            parse_flow(v)
        } else {
            scalar = v
        }
    }
}
END {
    if (NR > 0) end_file()
    exit bad ? 1 : 0
}
' $files
