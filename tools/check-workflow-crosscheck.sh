#!/bin/sh
# Cross-checks the awk checks against a real YAML parser (#83). yq reads every workflow and every action.yml / action.yaml
# (the files tools/check-action-pins.sh --files lists: what git tracks) and lists each `uses` value, each job's `runs-on` and each job's
# permissions; tools/check-action-pins.sh --list and tools/check-workflow-permissions.sh --list list the same things as
# they read them. The two lists must be equal. A line the awk checks cannot read (a flow mapping, a quoted key, a job id
# in quotes) is in yq's list and not theirs, and is printed as "only in yq: <file>: <what>".
# Usage: tools/check-workflow-crosscheck.sh [repository root]   (default: the repository this script is in)
# Output: only the differences, "only in yq: ..." and "only in scripts: ...". Exit 0 when the lists are equal, 1 when they
# are not or yq cannot parse a file, 2 on a bad argument or when neither yq nor docker (mikefarah/yq) is there.
# The environment variables PINS and PERMS name the two scripts (the tests point them at stubs). POSIX sh.
set -eu

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$root" ]; then
    echo "check-workflow-crosscheck.sh: $root is not a directory" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
pins="${PINS:-$here/check-action-pins.sh}"
perms="${PERMS:-$here/check-workflow-permissions.sh}"

if command -v yq >/dev/null 2>&1; then
    yaml_json() { yq -o=json . "$1"; }
elif command -v docker >/dev/null 2>&1; then
    yaml_json() { docker run --rm -i mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2 -o=json . <"$1"; }
else
    echo "check-workflow-crosscheck.sh: needs yq (or docker for mikefarah/yq)" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$root"

files="$(sh "$pins" --files "$root")"

: >"$work/yq"
status=0
IFS='
'
set -f
for f in $files; do
    if ! yaml_json "./$f" >"$work/json" 2>"$work/err"; then
        echo "$f: yq cannot parse it"
        status=1
        continue
    fi
    jq -r --arg f "$f" '
        [.. | objects | select(has("uses")) | $f + ": uses " + (.uses | tostring)][]' "$work/json" >>"$work/yq"
    case "$f" in
        .github/workflows/*)
            jq -r --arg f "$f" '
                (.jobs // {} | if type == "object" then . else {} end | to_entries[]) as $j
                | ($j.value | if type == "object" and has("runs-on") then
                      $f + ": runs-on " + (.["runs-on"] | if type == "string" then . else tojson end)
                  else empty end),
                  ($f + ": job " + $j.key + ": "
                   + ($j.value | if type != "object" or (has("permissions") | not) then "(no permissions block)"
                     else .permissions
                       | if type == "string" then .
                         elif . == null then "none"
                         elif type == "object" then (to_entries | map("\(.key):\(.value)") | sort | if length == 0 then "none" else join(" ") end)
                         else tojson end
                     end))' "$work/json" >>"$work/yq"
            ;;
    esac
done

{
    sh "$pins" --list "$root"
    sh "$perms" --list "$root"
} >"$work/scripts"

LC_ALL=C sort "$work/yq" >"$work/yq.sorted"
LC_ALL=C sort "$work/scripts" >"$work/scripts.sorted"
LC_ALL=C comm -23 "$work/yq.sorted" "$work/scripts.sorted" | sed 's/^/only in yq: /' >"$work/diff"
LC_ALL=C comm -13 "$work/yq.sorted" "$work/scripts.sorted" | sed 's/^/only in scripts: /' >>"$work/diff"
if [ -s "$work/diff" ]; then
    cat "$work/diff"
    status=1
fi
exit "$status"
