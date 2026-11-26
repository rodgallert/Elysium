#!/usr/bin/env bash
# Runs the tool suites under tools/tests/ (issue #126): the parallel set side by side, each suite's output kept together
# (printed in one piece when the suite ends), then the suites that need the machine to themselves, one at a time. Locally and
# in the `gate` job of the Build workflow.
#
# Usage: tools/tests/run-all.sh [--no-edge] [<suite>...]
#   no suites     every suite of the default set (below)
#   <suite>...    only these, by name (`pr-tools` or `pr-tools.sh`); an unknown name fails with exit 2 and nothing runs
#   --no-edge     leaves the edge suite out (the gate job passes it for a change that touches only Markdown)
#
# Environment:
#   TEST_FILTER         passed on to the suites (tools/tests/lib/filter.sh); a suite where it matches no case is reported
#                       as `no match` and is no failure, unless it matches in no suite at all (exit 1). Refused when CI is set.
#   RUN_ALL_TIMEOUT     seconds a suite may run before it is killed and counted as failed (default 600)
#   RUN_ALL_DIR         a directory of suites to run instead of this one (the fixtures of tools/tests/test-runner.sh): every
#                       *.sh in it is in the parallel set, except edge.sh, which runs alone
#
# Exit: 0 when every suite passed (or had no case for the filter), 1 when one failed or was killed, 2 for a usage error.
#
# The sets (every file of tools/tests/ is in exactly one list; test-runner.sh checks that):
#   parallel  no suite here shares a temporary directory, port, network or container with another: each makes its own
#             mktemp -d, and none starts Docker containers
#   alone     uses fixed names on the machine: the edge suite binds port 80 on loopback and creates the network elysium-edge
#   manual    not in the default set: compose-smoke and proxy-resolve build real stacks (minutes), and release-tools runs in
#             the release-checks job of the Build workflow; each can still be named on the command line (then it runs alone)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/filter.sh
source "$here/lib/filter.sh"

parallel=(check-compose-images ci-tools env-check file-storage-entrypoint pr-tools repo-settings test-runner ticket-tools wt-tools)
alone=(edge)
manual=(compose-smoke proxy-resolve release-tools)

timeout_s="${RUN_ALL_TIMEOUT:-600}"
dir="${RUN_ALL_DIR:-$here}"
usage() { echo "usage: tools/tests/run-all.sh [--no-edge] [<suite>...]" >&2; exit 2; }
case "$timeout_s" in
    '' | *[!0-9]* | 0) echo "run-all: RUN_ALL_TIMEOUT must be a number of seconds (got '$timeout_s')" >&2; exit 2 ;;
esac

no_edge=0
requested=()
for arg in "$@"; do
    case "$arg" in
        --no-edge) no_edge=1 ;;
        -*) usage ;;
        *) requested+=("${arg%.sh}") ;;
    esac
done

# the suites of the default set, or the named ones sorted into the parallel and the alone group
known=() par=() solo=()
if [ -n "${RUN_ALL_DIR:-}" ]; then
    for f in "$dir"/*.sh; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .sh)"
        known+=("$n")
        if [ "$n" = edge ]; then solo+=("$n"); else par+=("$n"); fi
    done
else
    known=("${parallel[@]}" "${alone[@]}" "${manual[@]}")
    par=("${parallel[@]}")
    solo=("${alone[@]}")
fi
if [ "${#requested[@]}" -gt 0 ]; then
    for n in "${requested[@]}"; do
        case "$n" in
            *[!A-Za-z0-9_-]* | '') echo "run-all: unknown suite '$n'" >&2; exit 2 ;;
        esac
        listed=0
        for k in "${known[@]}"; do [ "$k" = "$n" ] && listed=1; done
        if [ "$listed" -eq 0 ] || [ ! -f "$dir/$n.sh" ]; then
            echo "run-all: unknown suite '$n'" >&2
            exit 2
        fi
    done
    sel_par=() sel_solo=()
    for n in "${requested[@]}"; do
        in_par=0
        for k in "${par[@]}"; do [ "$k" = "$n" ] && in_par=1; done
        if [ "$in_par" -eq 1 ]; then sel_par+=("$n"); else sel_solo+=("$n"); fi
    done
    par=("${sel_par[@]}")
    solo=("${sel_solo[@]}")
fi
if [ "$no_edge" -eq 1 ]; then
    keep=()
    for n in "${solo[@]}"; do [ "$n" = edge ] || keep+=("$n"); done
    solo=("${keep[@]}")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/lock"

now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }

# run_suite <name>: runs the suite under the timeout, then prints its whole output in one piece
run_suite() {
    local n="$1" started rc result took log="$tmp/$1.log"
    started="$(now)"
    timeout --kill-after=5 "$timeout_s" bash "$dir/$n.sh" >"$log" 2>&1 </dev/null
    rc=$?
    took="$(since "$started")"
    if [ "$rc" -eq 0 ]; then
        result=ok
        grep -q '^SKIP: all of' "$log" && result="ok (skipped)"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        result="FAILED (timeout after ${timeout_s}s)"
    elif [ -n "${TEST_FILTER:-}" ] && [ "$rc" -eq 1 ] && grep -q "^filter '.*': 0 ran" "$log"; then
        result="no match"
    else
        result=FAILED
    fi
    printf '%s\n%s\n' "$result" "$took" >"$tmp/$n.result"
    {
        flock 9
        printf '===== %s (%s, %ss) =====\n' "$n" "$result" "$took"
        cat "$log"
        echo
    } 9>>"$tmp/lock"
}

start_all="$(now)"
for n in "${par[@]}"; do run_suite "$n" & done
wait
for n in "${solo[@]}"; do run_suite "$n"; done

echo "===== summary ====="
failed=() matched=0 total=0
for n in "${par[@]}" "${solo[@]}"; do
    [ -f "$tmp/$n.result" ] || continue
    { read -r result; read -r took; } <"$tmp/$n.result"
    printf '  %-26s %-30s %6ss\n' "$n" "$result" "$took"
    total=$((total + 1))
    case "$result" in
        FAILED*) failed+=("$n") ;;
        "no match") ;;
        *) matched=$((matched + 1)) ;;
    esac
done
echo "total wall time: $(since "$start_all")s"
if [ "${#failed[@]}" -gt 0 ]; then
    echo "run-all: FAILED: $(printf '%s, ' "${failed[@]}" | sed 's/, $//')"
    exit 1
fi
if [ -n "${TEST_FILTER:-}" ] && [ "$matched" -eq 0 ]; then
    echo "run-all: filter '$TEST_FILTER' matches no case in any suite"
    exit 1
fi
if [ "$total" -eq 0 ]; then
    echo "run-all: no suite to run"
    exit 1
fi
echo "run-all: every suite passed"
