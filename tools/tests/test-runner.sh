#!/usr/bin/env bash
# Tests for the test filter, the parallel runner and the edge suite's short timeouts (issue #126):
#   - tools/tests/lib/filter.sh and TEST_FILTER in every suite under tools/tests/ (#126-AC1),
#   - tools/tests/run-all.sh against fixture suites in tools/tests/filter-fixtures/ (#126-AC2),
#   - the edge timeouts include, its test override and the edge suite's use of them (#126-AC3, static only).
# Nothing here reaches GitHub or Docker: the fixture suites are plain scripts, and the real suites are run only with a
# filter that matches one case or none (the Docker suites stop on a filter that no case of theirs names, before any
# container). Every file this test writes lives under one fresh temporary directory.
# Each check names the criterion or edge case it covers (#126-AC<n>, #126-AC<n>.<m>).
# Run from anywhere: tools/tests/test-runner.sh (VERBOSE=1 also shows the output of passing cases; TEST_FILTER=<text> runs
# only the cases whose name contains it)
set -uo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cd "$tools/.." && pwd)"
tests="$tools/tests"
fx="$tests/filter-fixtures"
runner="$tests/run-all.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0

case "$work" in
    "${TMPDIR:-/tmp}"/*) ;;
    *) echo "Refusing to run: the work directory $work is not a fresh temporary directory" >&2; exit 1 ;;
esac

# shellcheck source=lib/filter.sh
[ -f "$tests/lib/filter.sh" ] && source "$tests/lib/filter.sh"
if ! declare -F filter_gate >/dev/null; then
    # the library is not there yet: no filter, every case runs (and fails on its assertion)
    filter_gate() { :; }
    filter_report() { :; }
fi

check() { # <name> <command...>: passes when the command succeeds
    local name="$1"
    shift
    filter_gate "$name" || return 0
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
        [ -z "${VERBOSE:-}" ] || echo "ok    $name"
    else
        failed=$((failed + 1))
        echo "FAIL  $name"
        printf '      rc=%s\n      out: %s\n' "${rc:-?}" "${out//$'\n'/ | }"
    fi
}
rc=0
out=""
# run <env assignment>... -- <command...>: sets $out (stdout and stderr) and $rc; the real TEST_FILTER and CI of this run
# never leak into the cases
run() {
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    out="$(env -u TEST_FILTER -u CI -u RUN_ALL_DIR -u RUN_ALL_TIMEOUT "${envs[@]}" "$@" 2>&1)"
    rc=$?
}
# run_suite <env assignment>... -- <suite file>: run only a suite that has the filter library; one that has not would run in
# full, and the Docker suites would start containers
run_suite() {
    local suite="${*: -1}"
    if grep -q 'lib/filter.sh' "$suite" 2>/dev/null; then
        run "$@"
    else
        rc=99
        out="$(basename "$suite") does not take TEST_FILTER yet: not run"
    fi
}
rc_is() { [ "$rc" -eq "$1" ]; }
says() { grep -qF -- "$1" <<<"$out"; }
silent_on() { ! grep -qF -- "$1" <<<"$out"; }
matches() { grep -qE -- "$1" <<<"$out"; }
# a fixture directory of suites: dir <name> <suite>... copies the fixture suites into a fresh directory, sets $d
dirs=0
dir() {
    local s
    dirs=$((dirs + 1))
    d="$work/d$dirs"
    mkdir -p "$d"
    for s in "$@"; do cp "$fx/suites/$s.sh" "$d/$s.sh"; done
}
line_no() { grep -nF -- "$1" <<<"$out" | head -1 | cut -d: -f1; }

# ---- #126-AC1: TEST_FILTER ------------------------------------------------------------------------------------------

test_ac1_fixture() {
    run -- "$fx/cases.sh"
    check "#126-AC1 no filter: every case runs, the failing one fails the suite" bash -c '[ '"$rc"' -eq 1 ] && grep -q "3 passed, 1 failed" <<<"$1"' _ "$out"
    check "#126-AC1 no filter: no filter line is printed (behaviour unchanged)" silent_on "filter '"
    run TEST_FILTER= -- "$fx/cases.sh"
    check "#126-AC1.1 an empty value is the same as unset: all four cases run" says "3 passed, 1 failed"
    check "#126-AC1.1 an empty value prints no filter line" silent_on "filter '"
    run TEST_FILTER='#900-AC1.1' -- "$fx/cases.sh"
    check "#126-AC1.1 a spec id runs only the case with that id: exit 0" rc_is 0
    check "#126-AC1.1 a spec id: one ran" says "1 passed, 0 failed"
    check "#126-AC1.10 the summary line names the filter and counts ran and filtered out" says "filter '#900-AC1.1': 1 ran, 3 filtered out"
    run TEST_FILTER='#900-AC1' -- "$fx/cases.sh"
    check "#126-AC1.1 an id also selects the cases below it (#900-AC1 and #900-AC1.1)" says "filter '#900-AC1': 2 ran, 2 filtered out"
    run TEST_FILTER='gamma' -- "$fx/cases.sh"
    check "#126-AC1.1 a plain word selects by name" says "filter 'gamma': 1 ran, 3 filtered out"
    run TEST_FILTER='[x] (literal) * ?' -- "$fx/cases.sh"
    check "#126-AC1.1 regex metacharacters are matched literally: the one case that has them runs" says "filter '[x] (literal) * ?': 1 ran, 3 filtered out"
    check "#126-AC1.1 metacharacters: exit 0" rc_is 0
    run TEST_FILTER='.*' -- "$fx/cases.sh"
    check "#126-AC1.1 .* is not a wildcard: it matches no name, so exit 1" rc_is 1
    run TEST_FILTER='alpha (one|two)' -- "$fx/cases.sh"
    check "#126-AC1.1 an alternation is not an alternation: exit 1" rc_is 1
    run TEST_FILTER='alpha' -- "$fx/cases.sh"
    check "#126-AC1.2 matching several cases (all of the alpha ones)" says "filter 'alpha': 2 ran, 2 filtered out"
    run TEST_FILTER='#900' -- "$fx/cases.sh"
    check "#126-AC1.2 matching all cases runs them all (filter line says 4 ran, 0 filtered out)" says "filter '#900': 4 ran, 0 filtered out"
    run TEST_FILTER='zz-no-such-case' -- "$fx/cases.sh"
    check "#126-AC1.2 matching none: exit 1, so a mistyped filter never looks like a pass" rc_is 1
    check "#126-AC1.2 matching none: the summary says 0 ran and the filter" says "filter 'zz-no-such-case': 0 ran, 4 filtered out"
    check "#126-AC1.2 matching none: says why" says "no case matches"
    run TEST_FILTER='gamma fails' -- "$fx/cases.sh"
    check "#126-AC1.6 a filtered run with one failing case exits 1" rc_is 1
    check "#126-AC1.6 and names the failing case" says "FAIL  #900-AC3 gamma fails"
    run TEST_FILTER='alpha one' -- "$fx/cases.sh"
    check "#126-AC1.6 a filter that leaves the failing case out passes (exit 0)" rc_is 0
    check "#126-AC1.7 the same filter gives the same cases twice" bash -c '[ "$1" = "$(TEST_FILTER="alpha one" "$2" 2>&1)" ]' _ "$out" "$fx/cases.sh"
    run CI=true TEST_FILTER='alpha' -- "$fx/cases.sh"
    check "#126-AC1.9 CI never sets a filter: with CI set, a filter is refused (exit 1)" rc_is 1
    check "#126-AC1.9 and the message says why" says "TEST_FILTER must not be set in CI"
    run CI=true -- "$fx/cases.sh"
    check "#126-AC1.9 CI without a filter runs as before" says "3 passed, 1 failed"
}

# a literal that exactly one case of the suite names, the number of its ran case(s), per suite
suite_cases=(
    "check-compose-images|an uppercase name fails|1"
    "ci-tools|ci-gate.sh knows every job of build.yml|1"
    "env-check|Silo user of 2 characters|1"
    "file-storage-entrypoint|star and question mark|1"
    "pr-tools|#71-AC1 line 5 is the tip comparison|1"
    "ticket-tools|#70-AC6.7 the docs say a re-run is safe|1"
    "wt-tools|#72-AC4 workflow.md names tools/wt.sh add|1"
    "repo-settings|#82-AC1.8 without a ref the lines are unchanged|1"
    "release-tools|a malformed digest fails|1"
)
docker_suites=(compose-smoke edge proxy-resolve)

test_ac1_every_suite() {
    local entry suite text n s
    for entry in "${suite_cases[@]}"; do
        IFS='|' read -r suite text n <<<"$entry"
        run_suite TEST_FILTER="$text" -- "$tests/$suite.sh"
        check "#126-AC1 $suite: a filter naming one case runs it and exits 0" rc_is 0
        check "#126-AC1.10 $suite: the summary line names the filter and says $n ran" says "filter '$text': $n ran"
        check "#126-AC1.10 $suite: the summary says how many were filtered out" matches "filter '.*': $n ran, [1-9][0-9]* filtered out"
        run_suite TEST_FILTER='zz-no-such-case-zz' -- "$tests/$suite.sh"
        check "#126-AC1.2 $suite: a filter that matches nothing exits 1" rc_is 1
        check "#126-AC1.2 $suite: and says 0 ran with the filter named" says "filter 'zz-no-such-case-zz': 0 ran"
    done
    for s in "${docker_suites[@]}"; do
        # no container: a filter no case names is refused before any Docker call
        run_suite TEST_FILTER='zz-no-such-case-zz' PATH=/usr/bin:/bin -- "$tests/$s.sh"
        check "#126-AC1.2 $s: a filter that matches nothing exits 1 before Docker is touched" rc_is 1
        check "#126-AC1.2 $s: and says 0 ran with the filter named" says "filter 'zz-no-such-case-zz': 0 ran"
        check "#126-AC1 $s: sources the shared filter library" grep -q 'lib/filter.sh' "$tests/$s.sh"
    done
}

test_ac1_regex_in_a_real_suite() {
    run_suite TEST_FILTER='@ / # % ?' -- "$tests/file-storage-entrypoint.sh"
    check "#126-AC1.1 a real suite: a case name with regex metacharacters is matched literally" says "filter '@ / # % ?': 1 ran"
    run_suite TEST_FILTER='.*' -- "$tests/file-storage-entrypoint.sh"
    check "#126-AC1.1 a real suite: .* matches nothing, exit 1" rc_is 1
    run_suite TEST_FILTER= -- "$tests/file-storage-entrypoint.sh"
    check "#126-AC1.1 a real suite: an empty filter runs everything" says "9 passed, 0 failed"
    check "#126-AC1.1 a real suite: an empty filter prints no filter line" silent_on "filter '"
}

test_ac1_suites_are_covered() {
    local f base listed
    for f in "$tests"/*.sh; do
        base="$(basename "$f" .sh)"
        [ "$base" = run-all ] && continue
        check "#126-AC1 $base takes TEST_FILTER (it sources the filter library)" grep -q 'lib/filter.sh' "$f"
        listed=0
        for entry in "${suite_cases[@]}"; do [[ "$entry" == "$base|"* ]] && listed=1; done
        for s in "${docker_suites[@]}" test-runner; do [ "$s" = "$base" ] && listed=1; done
        check "#126-AC1 $base is covered by this test's table of suites" test "$listed" -eq 1
    done
}

# ---- #126-AC2: run-all.sh -------------------------------------------------------------------------------------------

test_ac2_results() {
    dir pass fail
    run RUN_ALL_DIR="$d" -- "$runner"
    check "#126-AC2 a failing suite makes the runner exit non-zero" test "$rc" -ne 0
    check "#126-AC2 and the runner names that suite" says "FAILED: fail"
    check "#126-AC2.6 the passing suite's output is shown too" says "pass suite: all good"
    check "#126-AC2.6 the failing suite's output is shown" says "fail suite: this case failed"
    check "#126-AC2.10 the summary table lists the passing suite with its result and time" matches '^ *pass +ok +[0-9]+\.[0-9]s$'
    check "#126-AC2.10 the summary table lists the failing suite with its result and time" matches '^ *fail +FAILED +[0-9]+\.[0-9]s$'
    check "#126-AC2 the total wall time is printed" matches 'total wall time: [0-9]+\.[0-9]s'
    dir pass
    cp "$fx/suites/pass.sh" "$d/pass-two.sh"
    run RUN_ALL_DIR="$d" -- "$runner"
    check "#126-AC2.2 all suites passing: exit 0" rc_is 0
    check "#126-AC2.2 every suite of the directory ran (no arguments)" bash -c 'grep -q "^ *pass  *ok" <<<"$1" && grep -q "^ *pass-two  *ok" <<<"$1"' _ "$out"
}

test_ac2_arguments() {
    dir pass fail
    run RUN_ALL_DIR="$d" -- "$runner" pass
    check "#126-AC2.2 one suite by name: only it runs, exit 0" rc_is 0
    check "#126-AC2.2 one suite: the other did not run" silent_on "fail suite"
    run RUN_ALL_DIR="$d" -- "$runner" pass.sh
    check "#126-AC2.1 a suite name with .sh is accepted" rc_is 0
    run RUN_ALL_DIR="$d" -- "$runner" pass no-such-suite
    check "#126-AC2.1 an unknown suite name fails the run (exit 2, a usage error)" rc_is 2
    check "#126-AC2.1 and names it" says "no-such-suite"
    check "#126-AC2.1 and nothing runs for it: the known suite did not run either" silent_on "pass suite: all good"
    run RUN_ALL_DIR="$d" -- "$runner" '../pass'
    check "#126-AC2.1 a name with a path in it is refused" rc_is 2
}

test_ac2_parallel_and_grouping() {
    local start end
    dir par-a par-b par-c
    export RUN_ALL_MARKS="$work/marks-par"
    start="$(date +%s)"
    run RUN_ALL_DIR="$d" RUN_ALL_MARKS="$RUN_ALL_MARKS" -- "$runner"
    end="$(date +%s)"
    check "#126-AC2.2 three 2-second suites pass" rc_is 0
    check "#126-AC2 they run in parallel: the wall time is under 5 s, not 6 s" test $((end - start)) -lt 5
    dir lines-a lines-b
    run RUN_ALL_DIR="$d" -- "$runner"
    check "#126-AC2 a suite's output stays together: all of a's lines are adjacent" bash -c '
        n="$(grep -n "^a-line" <<<"$1" | cut -d: -f1 | tr "\n" " ")"; [ "$n" = "$(seq "$(echo $n | cut -d" " -f1)" "$(( $(echo $n | cut -d" " -f1) + 7 ))" | tr "\n" " ")" ]' _ "$out"
    check "#126-AC2 and so are b's" bash -c '
        n="$(grep -n "^b-line" <<<"$1" | cut -d: -f1 | tr "\n" " ")"; [ "$n" = "$(seq "$(echo $n | cut -d" " -f1)" "$(( $(echo $n | cut -d" " -f1) + 7 ))" | tr "\n" " ")" ]' _ "$out"
}

test_ac2_4_time() {
    local start end
    dir pass hang
    start="$(date +%s)"
    run RUN_ALL_DIR="$d" RUN_ALL_TIMEOUT=2 -- "$runner"
    end="$(date +%s)"
    check "#126-AC2.4 a suite that hangs past the timeout makes the run fail" test "$rc" -ne 0
    check "#126-AC2.4 it is killed and reported as failed, with the timeout" matches '^ *hang +FAILED \(timeout after 2s\) +[0-9]+\.[0-9]s$'
    check "#126-AC2.4 the run does not wait for it: under 10 s" test $((end - start)) -lt 10
    check "#126-AC2.4 the killed suite's process is gone" bash -c '! pgrep -f "sleep 61.77" >/dev/null'
    check "#126-AC2.4 the other suite still reported ok" matches '^ *pass +ok '
    run RUN_ALL_DIR="$d" RUN_ALL_TIMEOUT=abc -- "$runner" pass
    check "#126-AC2.4 a timeout that is not a number is refused (exit 2)" rc_is 2
    check "#126-AC2.4 the default timeout is 10 minutes" grep -q 'RUN_ALL_TIMEOUT:-600' "$runner"
}

test_ac2_5_edge_alone() {
    local pe ps maxend
    dir par-a par-b edge
    export RUN_ALL_MARKS="$work/marks-edge"
    run RUN_ALL_DIR="$d" RUN_ALL_MARKS="$RUN_ALL_MARKS" -- "$runner"
    check "#126-AC2.5 the edge suite runs with the others in the set: exit 0" rc_is 0
    ps="$(head -1 "$RUN_ALL_MARKS.edge" 2>/dev/null | cut -d' ' -f1)"
    maxend="$(cat "$RUN_ALL_MARKS".par-a "$RUN_ALL_MARKS".par-b 2>/dev/null | grep ' end' | cut -d' ' -f1 | sort -n | tail -1)"
    check "#126-AC2.5 the edge suite starts only after every parallel suite has ended" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -ge "$2" ]' _ "$ps" "$maxend"
    pe="$(grep ' end' "$RUN_ALL_MARKS.edge" 2>/dev/null | cut -d' ' -f1)"
    check "#126-AC2.5 and it ends (nothing runs next to it)" test -n "$pe"
    rm -f "$RUN_ALL_MARKS".*
    run RUN_ALL_DIR="$d" RUN_ALL_MARKS="$RUN_ALL_MARKS" -- "$runner" --no-edge
    check "#126-AC2.5 --no-edge leaves the edge suite out (a Markdown-only change)" test ! -e "$RUN_ALL_MARKS.edge"
    check "#126-AC2.5 --no-edge still runs the others" says "par-a done"
    run RUN_ALL_DIR="$d" RUN_ALL_MARKS="$RUN_ALL_MARKS" -- "$runner" edge par-a
    check "#126-AC2.5 named together, the edge suite still runs alone, after par-a" test -e "$RUN_ALL_MARKS.edge"
    check "#126-AC2.5 the real suites: edge is the only one that runs alone" bash -c 'grep -qE "^alone=\(edge\)$" "$1"' _ "$runner"
}

test_ac2_every_suite_is_classified() {
    local f base
    for f in "$tests"/*.sh; do
        base="$(basename "$f" .sh)"
        [ "$base" = run-all ] && continue
        check "#126-AC2.1 $base is listed in run-all.sh (parallel, alone or manual)" grep -qE "^(parallel|alone|manual)=\(.*(^|[ (])$base([ )]|$)" "$runner"
    done
}

test_ac2_filter_through_runner() {
    dir matches nomatch
    run RUN_ALL_DIR="$d" TEST_FILTER=zz -- "$runner" matches
    check "#126-AC2 the filter is passed to the suites: a matching suite is ok" rc_is 0
    run RUN_ALL_DIR="$d" TEST_FILTER=zz -- "$runner"
    check "#126-AC2 a suite where the filter matches nothing is 'no match', not a failure, when another suite matched" rc_is 0
    check "#126-AC2.10 and the table says no match for it" matches '^ *nomatch +no match +[0-9]+\.[0-9]s$'
    run RUN_ALL_DIR="$d" TEST_FILTER=zz -- "$runner" nomatch
    check "#126-AC2 when no suite matches the filter the runner exits 1" rc_is 1
    run RUN_ALL_DIR="$d" CI=true TEST_FILTER=zz -- "$runner"
    check "#126-AC1.9 the runner refuses a filter in CI" rc_is 1
    check "#126-AC1.9 and says so" says "TEST_FILTER must not be set in CI"
}

test_ac2_workflow() {
    local wf="$root/.github/workflows/build.yml" gate
    gate="$(awk '/^  gate:/{g=1;next} g&&/^  [a-z][a-z-]*:$/{exit} g' "$wf")"
    check "#126-AC2 the gate job runs tools/tests/run-all.sh" grep -q 'tools/tests/run-all.sh' <<<"$gate"
    check "#126-AC2 the gate job no longer has a step per suite" bash -c '! grep -qE "run: tools/tests/(ci-tools|env-check|file-storage-entrypoint|ticket-tools|pr-tools|wt-tools|check-compose-images|edge)\.sh" <<<"$1"' _ "$gate"
    check "#126-AC2 a Markdown-only change skips the edge suite (--no-edge when changes.code is not true)" bash -c 'grep -q "no-edge" <<<"$1" && grep -q "needs.changes.outputs.code" <<<"$1"' _ "$gate"
    check "#126-AC1.9 the gate job fails when TEST_FILTER is set" bash -c 'grep -q "TEST_FILTER" <<<"$1"' _ "$gate"
    check "#126-AC2 the gate job keeps its key" grep -qE '^  gate:$' "$wf"
    check "#126-AC2 permissions stay denied by default" grep -qE '^permissions: \{\}$' "$wf"
    check "#126-AC2 the pin, permission and cross checks pass" bash -c 'cd "$1" && tools/check-action-pins.sh >/dev/null && tools/check-workflow-permissions.sh >/dev/null && tools/check-workflow-crosscheck.sh >/dev/null' _ "$root"
    check "#126-AC2.9 run-all.sh works under bash 4 and later (no bash 5 only features)" bash -c '! grep -qE "EPOCHREALTIME|wait -p|\$\{[a-z_]+@[ULul]\}" "$1"' _ "$runner"
}

# ---- #126-AC3: the edge timeouts --------------------------------------------------------------------------------------

test_ac3_static() {
    local inc="$root/Edge/timeouts.conf" ov="$tests/edge/timeouts-short.conf" conf="$root/Edge/nginx.conf"
    local d
    check "#126-AC3 the shipped timeouts live in one include, Edge/timeouts.conf" test -f "$inc"
    for d in "proxy_connect_timeout 3s" "proxy_read_timeout 30s" "proxy_send_timeout 30s" "client_header_timeout 10s" "client_body_timeout 10s"; do
        check "#126-AC3 the shipped include has the #75 value: $d" grep -qE "^ *$d;" "$inc"
        check "#126-AC3 nginx.conf no longer sets it itself: $d" bash -c '! grep -qE "^ *$1;" "$2"' _ "$d" "$conf"
    done
    check "#126-AC3 nginx.conf includes the timeouts file" grep -qE '^ *include /etc/nginx/edge-timeouts\.conf;' "$conf"
    check "#126-AC3 the edge's compose file mounts the include read-only" grep -qE 'timeouts\.conf:/etc/nginx/edge-timeouts\.conf:ro' "$root/Edge/docker-compose.yml"
    check "#126-AC3 the test override sets a 3 s read timeout" grep -qE '^ *proxy_read_timeout 3s;' "$ov"
    check "#126-AC3 the test override sets a 1 s connect timeout" grep -qE '^ *proxy_connect_timeout 1s;' "$ov"
    check "#126-AC3.3 the shipped config never loads the test override (nothing under Edge/ or in Prince names it)" bash -c '! grep -rIl "timeouts-short" "$1/Edge" "$1/Prince" "$1/docker-compose.prod.yml" 2>/dev/null | grep .' _ "$root"
    check "#126-AC3.3 the override lives under tools/tests only" bash -c 'git -C "$1" ls-files | grep -F timeouts-short | grep -qv "^tools/tests/"; [ $? -ne 0 ]' _ "$root"
}

test_ac3_edge_suite() {
    local e="$tests/edge.sh"
    check "#126-AC3 the edge suite mounts the test override over the include" grep -q 'timeouts-short.conf' "$e"
    check "#126-AC3 the edge suite no longer waits for 30 s (no 28000 ms lower bound)" bash -c '! grep -q "28000" "$1"' _ "$e"
    check "#126-AC3.2 the 504 is expected at 3 s plus or minus 1 s (2000 to 4000 ms)" grep -qE '\-ge 2000 \] && \[ "\$ms" -le 4000' "$e"
    check "#126-AC3 the 502 timing scales with the 1 s connect timeout (answers within 2 s)" grep -qE 'took" -le 2000' "$e"
    check "#126-AC3 a separate static case checks the shipped include still has the #75 values" grep -q '#126-AC3.*shipped include' "$e"
    check "#126-AC3 the static case reads Edge/timeouts.conf" grep -q 'timeouts.conf' "$e"
    check "#126-AC3.3 the static case checks the shipped files never load the override" grep -q '#126-AC3.3' "$e"
    check "#126-AC3.4 the header says about how long the suite takes now (no 30 s wait)" bash -c '! grep -q "one 30 s wait" "$1"' _ "$e"
}

for fn in test_ac1_fixture test_ac1_every_suite test_ac1_regex_in_a_real_suite test_ac1_suites_are_covered test_ac2_results \
    test_ac2_arguments test_ac2_parallel_and_grouping test_ac2_4_time test_ac2_5_edge_alone test_ac2_every_suite_is_classified \
    test_ac2_filter_through_runner test_ac2_workflow test_ac3_static test_ac3_edge_suite; do
    echo "== $fn"
    "$fn"
done

echo
echo "$pass passed, $failed failed"
filter_report "$pass" "$failed" || exit 1
[ "$failed" -eq 0 ]
