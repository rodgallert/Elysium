#!/usr/bin/env bash
# Tests for tools/pr.sh (issue #71), against the stub gh in tools/tests/ticket-stubs/gh (the harness of tools/ticket.sh's
# tests): a fake of the GitHub calls with its state in files, so no case reaches GitHub. Every case runs in a fresh "world"
# (a state directory) under one temporary directory. Each test function and comment cites the criterion or edge case it
# covers (#71-AC<n>, #71-AC<n>.<m>).
# Run from anywhere: tools/tests/pr-tools.sh (VERBOSE=1 also shows the output of passing cases)
# shellcheck disable=SC2016 # the cases pass strings with literal $( ) and backticks on purpose
set -uo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$tools/pr.sh"
stubs="$tools/tests/ticket-stubs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0

# Guard: every file this test writes lives under the fresh temporary directory, and git never looks above it
case "$work" in
    "${TMPDIR:-/tmp}"/*) ;;
    *) echo "Refusing to run: the work directory $work is not a fresh temporary directory" >&2; exit 1 ;;
esac
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work"
mkdir -p "$work/home" "$work/shim"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"$STUB_DIR/sleeps"\n' >"$work/sleep"
chmod +x "$work/sleep"
# a git that only records what it is asked (pr.sh may run git only with a checked ref or a 40-hex SHA)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$STUB_DIR/git.log"\nexit 1\n' >"$work/shim/git"
chmod +x "$work/shim/git"

owner_token=gho_stubOwnerToken0001
other_token=gho_stubOtherUser00003
repo=rodgallert/Elysium
sha_a=$(printf 'a%.0s' {1..40})
sha_b=$(printf 'b%.0s' {1..40})
sha_c=$(printf 'c%.0s' {1..40})

# ---- worlds and fixtures ----------------------------------------------------------------------------------------

world=0
XENV=()
TT=5
new_world() {
    world=$((world + 1))
    STUB_DIR="$work/w$world"
    mkdir -p "$STUB_DIR/pr" "$STUB_DIR/checks" "$STUB_DIR/behind" "$STUB_DIR/reviews" "$STUB_DIR/locks" "$STUB_DIR/issue" "$STUB_DIR/comments"
    : >"$STUB_DIR/tips"
    XENV=()
    TT=5
}
# put_pr <n> [key=value]...: keys state, merged, base, ref, sha, repo (head repository), body, user
put_pr() {
    local n="$1" state=open merged=false base=main ref=feat/x sha="$sha_a" hrepo="$repo" body=$'Closes #5\n\nWhat changed.' user=alice kv
    shift
    for kv in "$@"; do
        case "$kv" in
            state=*) state="${kv#state=}" ;;
            merged=*) merged="${kv#merged=}" ;;
            base=*) base="${kv#base=}" ;;
            ref=*) ref="${kv#ref=}" ;;
            sha=*) sha="${kv#sha=}" ;;
            repo=*) hrepo="${kv#repo=}" ;;
            body=*) body="${kv#body=}" ;;
            user=*) user="${kv#user=}" ;;
        esac
    done
    printf '%s' "$body" >"$STUB_DIR/body.tmp"
    jq -nc --argjson n "$n" --arg s "$state" --argjson m "$merged" --arg base "$base" --arg ref "$ref" --arg sha "$sha" --arg hr "$hrepo" \
        --rawfile b "$STUB_DIR/body.tmp" --arg u "$user" \
        '{number:$n, state:$s, merged:$m, body:$b, user:{login:$u}, html_url:("https://github.com/rodgallert/Elysium/pull/" + ($n|tostring)),
          base:{ref:$base}, head:{ref:$ref, sha:$sha, repo:{full_name:$hr}}}' >"$STUB_DIR/pr/$n.json"
}
tip() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$STUB_DIR/tips"; } # <repo> <branch> <sha>
behind() { echo "$2" >"$STUB_DIR/behind/$1"; }               # <sha> <count>
# put_checks <sha> <json array of runs>
put_checks() { echo "$2" >"$STUB_DIR/checks/$1.json"; }
gate_run() { # <sha> <status> <conclusion|null> [head_sha]: one gate run on <sha>
    jq -nc --arg h "${4:-$1}" --arg s "$2" --arg c "$3" '[{id:1, name:"gate", status:$s, conclusion:(if $c == "null" then null else $c end), head_sha:$h}]'
}
# ready_pr <n> [key=value]...: an open PR with everything in order (tip equal, up to date, gate success, Closes)
ready_pr() {
    local n="$1" ref=feat/x sha="$sha_a" kv
    for kv in "${@:2}"; do
        case "$kv" in
            ref=*) ref="${kv#ref=}" ;;
            sha=*) sha="${kv#sha=}" ;;
        esac
    done
    put_pr "$@"
    tip "$repo" "$ref" "$sha"
    behind "$sha" 0
    put_checks "$sha" "$(gate_run "$sha" completed success)"
}
fault() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$STUB_DIR/faults"; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null | wc -l; }
calls_like() { cat "$STUB_DIR/calls.log" 2>/dev/null | grep -c -- "$1" || true; }
writes() { cat "$STUB_DIR/writes.log" 2>/dev/null | grep -c "^$1\$" || true; }
nreviews() { jq length "$STUB_DIR/reviews/$1.json" 2>/dev/null || echo 0; }
review_body() { jq -j ".[$2].body" "$STUB_DIR/reviews/$1.json"; }
sleeps() { tr '\n' ' ' <"$STUB_DIR/sleeps" 2>/dev/null; }

# p <args...>: runs pr.sh in the current world; sets $out, $err and $rc
p() {
    local o="$work/out.tmp" e="$work/err.tmp"
    env -i PATH="$stubs:$work/shim:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" \
        TICKET_TIMEOUT="$TT" TICKET_LOCK_DIR="$STUB_DIR/locks" "${XENV[@]}" bash "$script" "$@" >"$o" 2>"$e" </dev/null
    rc=$?
    out=$(<"$o")
    err=$(<"$e")
}
# v <pr> <verdict> <body file> [sha]: pr.sh verdict with the body file and the head SHA
v() { p verdict "$1" "$2" --body-file "$3" --sha "${4:-$sha_a}"; }
body_file() { printf '%s\n' "${2-$'Looks right.\n\nDetails below.'}" >"$work/$1"; echo "$work/$1"; }

check() { # <name> <command...>: passes when the command succeeds
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
        [ -z "${VERBOSE:-}" ] || echo "ok    $name"
    else
        failed=$((failed + 1))
        echo "FAIL  $name"
        printf '      rc=%s\n      out: %s\n      err: %s\n' "${rc:-?}" "${out//$'\n'/ | }" "${err//$'\n'/ | }"
    fi
}
rc_is() { [ "$rc" -eq "$1" ]; }
says() { grep -qF -- "$1" <<<"$out
$err"; }
silent_on() { ! grep -qF -- "$1" <<<"$out
$err"; }
eq() { [ "$1" = "$2" ]; }
line_is() { [ "$(sed -n "${1}p" <<<"$out")" = "$2" ]; } # <n> <text>: line n of stdout
no_secret() { ! grep -qE "gho_|ghp_|github_pat_" <<<"$out
$err"; }
usage_exit() { [ "$rc" -eq 2 ] && grep -q "Usage:" <<<"$err" && [ "$(calls)" -eq 0 ]; }

# ---- #71-AC1: status ---------------------------------------------------------------------------------------------

test_ac1_facts() {
    new_world
    ready_pr 7
    p status 7
    check "#71-AC1 a ready PR: exit 0" rc_is 0
    check "#71-AC1 line 1 is the state" line_is 1 "state: open"
    check "#71-AC1 line 2 is the base branch" line_is 2 "base: main"
    check "#71-AC1 line 3 is the head branch" line_is 3 "head: feat/x"
    check "#71-AC1 line 4 is the head SHA" line_is 4 "sha: $sha_a"
    check "#71-AC1 line 5 is the tip comparison" line_is 5 "tip: equal"
    check "#71-AC1 line 6 is the up-to-date fact" line_is 6 "up-to-date: yes"
    check "#71-AC1 line 7 is the gate conclusion" line_is 7 "gate: success"
    check "#71-AC1 line 8 is the Closes fact" line_is 8 "closes: yes"
    check "#71-AC1 line 9 says ready, and nothing follows" bash -c '[ "$(sed -n 9p <<<"$1")" = ready ] && [ "$(wc -l <<<"$1")" -eq 9 ]' _ "$out"

    # each failing fact exits 1 and is named
    new_world
    ready_pr 7
    tip "$repo" feat/x "$sha_b"
    p status 7
    check "#71-AC1 tip differs: exit 1 and named" bash -c '[ '"$rc"' -eq 1 ] && grep -q "tip: differs" <<<"$1" && grep -q "^not ready: .*tip" <<<"$1"' _ "$out"
    new_world
    ready_pr 7
    : >"$STUB_DIR/tips"
    p status 7
    check "#71-AC1 branch gone from the remote: tip missing, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "tip: missing" <<<"$1"' _ "$out"
    new_world
    ready_pr 7
    behind "$sha_a" 3
    p status 7
    check "#71-AC1 behind its base: exit 1, named" bash -c '[ '"$rc"' -eq 1 ] && grep -q "up-to-date: no (behind 3)" <<<"$1" && grep -q "^not ready: .*behind" <<<"$1"' _ "$out"
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(gate_run "$sha_a" completed failure)"
    p status 7
    check "#71-AC1 gate failure: exit 1, named" bash -c '[ '"$rc"' -eq 1 ] && grep -q "gate: failure" <<<"$1" && grep -q "^not ready: gate" <<<"$1"' _ "$out"
    new_world
    ready_pr 7 'body=No closing line here.'
    p status 7
    check "#71-AC1 no Closes line: exit 1, named" bash -c '[ '"$rc"' -eq 1 ] && grep -q "closes: no" <<<"$1" && grep -q "^not ready: .*Closes" <<<"$1"' _ "$out"
    new_world
    ready_pr 7 $'body=Intro first\n\nCloses #5'
    p status 7
    check "#71-AC1 Closes must start the body (not a later line)" bash -c '[ '"$rc"' -eq 1 ] && grep -q "closes: no" <<<"$1"' _ "$out"
    new_world
    ready_pr 7 $'body=Closes #5\r\n\r\nWindows line ends.'
    p status 7
    check "#71-AC1 a CRLF body still starts with Closes" rc_is 0

    # several failures: the first in the fixed order is the one named
    new_world
    ready_pr 7 'body=none'
    behind "$sha_a" 2
    put_checks "$sha_a" "$(gate_run "$sha_a" completed failure)"
    p status 7
    check "#71-AC1 several failures: the first failing fact (up to date) is named" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^not ready: .*behind" <<<"$1"' _ "$out"
}

test_ac1_1_inputs() {
    local bad
    for bad in 0 -1 007 12abc "" https://github.com/rodgallert/Elysium/pull/7 "1 2" 12345678; do
        new_world
        ready_pr 7
        p status "$bad"
        check "#71-AC1.1 status '$bad': exit 2, usage line, gh never called" usage_exit
    done
    new_world
    p status
    check "#71-AC1.1 status without a PR: exit 2" usage_exit
    p
    check "#71-AC1.1 no command: exit 2, usage line" usage_exit
    p frobnicate 7
    check "#71-AC1.1 unknown command: exit 2" usage_exit
    p status 7 extra
    check "#71-AC1.1 an extra argument: exit 2" usage_exit

    # a branch name in the PR data that is not a safe refname is refused before any ref lookup
    local ref
    for ref in 'feat/a b' 'feat/x..y' '-x' 'feat//x' 'feat/$(id)' 'x/refs/heads/y' 'refs/heads/x' 'feat/x.lock' 'feat/x/'; do
        new_world
        ready_pr 7 "ref=$ref"
        p status 7
        check "#71-AC1.1 PR data with head branch '$ref': refused (exit 1), no ref or git lookup" bash -c '[ '"$rc"' -eq 1 ] && [ "$(grep -c "git/ref" "'"$STUB_DIR"'/calls.log")" -eq 0 ] && [ ! -e "'"$STUB_DIR"'/git.log" ]'
    done
    new_world
    ready_pr 7 'base=-x'
    p status 7
    check "#71-AC1.1 PR data with a base branch '-x': refused (exit 1)" rc_is 1
}

test_ac1_2_boundaries() {
    new_world
    ready_pr 7
    put_checks "$sha_a" '[]'
    p status 7
    check "#71-AC1.2 an empty check list: gate: none, exit 1 (never ok)" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: none" <<<"$1" && ! grep -qx ready <<<"$1"' _ "$out"

    new_world
    ready_pr 7
    put_checks "$sha_a" '[{"id":2,"name":"changes","status":"completed","conclusion":"success","head_sha":"'"$sha_a"'"}]'
    p status 7
    check "#71-AC1.2 checks without a gate: gate: none, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: none" <<<"$1"' _ "$out"

    # 150 checks over two pages, the gate on the second page: read to the end
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(jq -nc --arg h "$sha_a" '[range(0; 140) | {id: (. + 10), name: ("check-" + tostring), status: "completed", conclusion: "success", head_sha: $h}]
        + [{id: 1000, name: "gate", status: "completed", conclusion: "success", head_sha: $h}]
        + [range(0; 9) | {id: (. + 2000), name: ("late-" + tostring), status: "completed", conclusion: "success", head_sha: $h}]')"
    p status 7
    check "#71-AC1.2 150 checks, gate on the second page: found, exit 0" rc_is 0
    check "#71-AC1.2 the check list was read with pagination" bash -c 'grep -q "check-runs.*--paginate" "'"$STUB_DIR"'/calls.log"'
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(jq -nc --arg h "$sha_a" '[range(0; 140) | {id: (. + 10), name: ("check-" + tostring), status: "completed", conclusion: "success", head_sha: $h}]')"
    p status 7
    check "#71-AC1.2 100+ checks without a gate: none, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: none" <<<"$1"' _ "$out"
    # two runs of the gate (a re-run): the newest counts
    new_world
    ready_pr 7
    put_checks "$sha_a" '[{"id":5,"name":"gate","status":"completed","conclusion":"failure","head_sha":"'"$sha_a"'"},{"id":9,"name":"gate","status":"completed","conclusion":"success","head_sha":"'"$sha_a"'"}]'
    p status 7
    check "#71-AC1.2 a re-run gate: the newest run counts" rc_is 0
    new_world
    ready_pr 7
    put_checks "$sha_a" '[{"id":5,"name":"gate","status":"completed","conclusion":"success","head_sha":"'"$sha_a"'"},{"id":9,"name":"gate","status":"in_progress","conclusion":null,"head_sha":"'"$sha_a"'"}]'
    p status 7
    check "#71-AC1.2 a newer gate run still going: pending, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: pending" <<<"$1"' _ "$out"
}

test_ac1_3_state() {
    new_world
    ready_pr 7 state=closed merged=true
    p status 7
    check "#71-AC1.3 a merged PR: exit 1 with its state" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^state: merged" <<<"$1" && grep -q "^not ready: .*merged" <<<"$1"' _ "$out"
    new_world
    ready_pr 7 state=closed merged=false
    p status 7
    check "#71-AC1.3 a closed PR: exit 1 with its state" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^state: closed" <<<"$1" && grep -q "^not ready: .*closed" <<<"$1"' _ "$out"

    # the gate ran on an older SHA only
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(gate_run "$sha_a" completed success "$sha_b")"
    p status 7
    check "#71-AC1.3 a gate that ran on an older SHA: gate not run on head, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: not run on head" <<<"$1" && grep -q "gate not run on head" <<<"$1"' _ "$out"
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(gate_run "$sha_a" in_progress null)"
    p status 7
    check "#71-AC1.4 a gate still running: pending, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: pending" <<<"$1"' _ "$out"
    new_world
    ready_pr 7
    put_checks "$sha_a" "$(gate_run "$sha_a" queued null)"
    p status 7
    check "#71-AC1.4 a gate still queued: pending, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^gate: pending" <<<"$1"' _ "$out"

    # a fork's PR with the same branch name as a branch here: matched by head repository and SHA
    new_world
    put_pr 7 repo=evil/Elysium "sha=$sha_a"
    tip "$repo" feat/x "$sha_a"
    behind "$sha_a" 0
    put_checks "$sha_a" "$(gate_run "$sha_a" completed success)"
    p status 7
    check "#71-AC1.3 a fork PR whose branch exists here with the same SHA: tip is read in the fork, which lacks it: missing, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^tip: missing" <<<"$1"' _ "$out"
    check "#71-AC1.3 the fork PR's tip was asked of the fork, not of this repository" bash -c 'grep -q "repos/evil/Elysium/git/ref" "'"$STUB_DIR"'/calls.log" && ! grep -q "repos/'"$repo"'/git/ref" "'"$STUB_DIR"'/calls.log"'
    new_world
    put_pr 7 repo=evil/Elysium "sha=$sha_a"
    tip "$repo" feat/x "$sha_b"
    tip evil/Elysium feat/x "$sha_a"
    behind "$sha_a" 0
    put_checks "$sha_a" "$(gate_run "$sha_a" completed success)"
    p status 7
    check "#71-AC1.3 a fork PR is judged by the fork's own branch tip (this repository's same-named branch differs, and does not matter)" bash -c 'grep -q "^tip: equal" <<<"$1"' _ "$out"
    new_world
    put_pr 7 repo=evil/Elysium "sha=$sha_a"
    tip "$repo" feat/x "$sha_a"
    tip evil/Elysium feat/x "$sha_b"
    behind "$sha_a" 0
    put_checks "$sha_a" "$(gate_run "$sha_a" completed success)"
    p status 7
    check "#71-AC1.3 a fork PR whose fork branch moved: tip differs even though this repository's branch has the SHA" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^tip: differs" <<<"$1"' _ "$out"
}

test_ac1_5_concurrency() {
    new_world
    ready_pr 7
    echo "$sha_b" >"$STUB_DIR/pr/7.sha2"
    p status 7
    check "#71-AC1.5 a push between reading the head and the checks: exit 1, head moved" bash -c '[ '"$rc"' -eq 1 ] && grep -q "head moved" <<<"$1"' _ "$out$err"
    check "#71-AC1.5 no ready and no partial facts are printed when the head moved" bash -c '! grep -qx ready <<<"$1" && [ -z "$1" ]' _ "$out"
}

test_ac1_6_partial() {
    local step
    for step in "pulls/7" compare check-runs git/ref/heads; do
        new_world
        ready_pr 7
        fault "*$step*" 10 502
        p status 7
        check "#71-AC1.6 gh failing at '$step' after retries: non-zero, names the step, prints nothing on stdout" bash -c '[ '"$rc"' -ne 0 ] && [ -z "$1" ] && [ -n "$2" ]' _ "$out" "$err"
    done
    new_world
    ready_pr 7
    fault "*check-runs*" 10 502
    p status 7
    check "#71-AC1.6 the failure line names the step (the check list)" says "check"
    check "#71-AC1.6 a failed check read never prints a ready line" silent_on ready
    new_world
    ready_pr 7
    fault "*compare*" 2 502
    p status 7
    check "#71-AC1.6 a 5xx is retried (2 s, 4 s) and the run succeeds" bash -c '[ '"$rc"' -eq 0 ] && [ "$(cat "'"$STUB_DIR"'/sleeps")" = "$(printf "2\n4")" ]'
    new_world
    ready_pr 7
    fault "*pulls/7*" 1 404
    p status 7
    check "#71-AC1.6 a PR that does not exist: exit 1, not found" bash -c '[ '"$rc"' -eq 1 ] && grep -qi "not found" <<<"$1"' _ "$err"
}

test_ac1_7_idempotence() {
    new_world
    ready_pr 7
    p status 7
    local first="$out"
    p status 7
    check "#71-AC1.7 two runs print the same output" eq "$first" "$out"
    check "#71-AC1.7 status never writes" bash -c '[ ! -s "'"$STUB_DIR"'/writes.log" ]'
    new_world
    ready_pr 7
    tip "$repo" feat/x "$sha_b"
    p status 7
    first="$out"
    p status 7
    check "#71-AC1.7 two runs print the same output when not ready" eq "$first" "$out"
}

test_account() {
    new_world
    ready_pr 7
    XENV=(GH_TOKEN="$other_token")
    p status 7
    check "#71-AC1.8 a GH_TOKEN of another login: exit 1, nothing read" bash -c '[ '"$rc"' -eq 1 ] && [ "$(grep -c "pulls" "'"$STUB_DIR"'/calls.log")" -eq 0 ]'
    new_world
    ready_pr 7
    XENV=(STUB_NO_OWNER=1)
    p status 7
    check "#71-AC1.8 no login for the owner: exit 1, says to log in, never uses the active account" bash -c '[ '"$rc"' -eq 1 ] && ! grep -q "gho_stubActiveToken9999" "'"$STUB_DIR"'/calls.log"'
    new_world
    ready_pr 7
    p status 7
    check "#71-AC1.8 every gh call carries the owner's token and gh auth switch is never called" bash -c '! grep -q "auth.switch" "'"$STUB_DIR"'/calls.log" && ! grep -v "^'"$owner_token"'" "'"$STUB_DIR"'/calls.log" | grep -qv "^$"'
    new_world
    ready_pr 7
    XENV=(GH_TOKEN="$owner_token")
    p status 7
    check "#71-AC1.8 a GH_TOKEN of the owner is accepted" rc_is 0
    new_world
    put_pr 7
    echo "$sha_b" >"$STUB_DIR/pr/7.sha2"
    p verdict 7 comment --body-file "$(body_file b1)" --sha "$sha_a"
    check "#71-AC3.8 verdict uses the owner's token only and never gh auth switch" bash -c '! grep -q "auth.switch" "'"$STUB_DIR"'/calls.log" && ! grep -q "gho_stubActiveToken9999" "'"$STUB_DIR"'/calls.log"'
    new_world
    put_pr 7
    XENV=(GH_TOKEN="$other_token")
    p verdict 7 comment --body-file "$(body_file b1)" --sha "$sha_a"
    check "#71-AC3.8 verdict with another login's GH_TOKEN: exit 1, no review" bash -c '[ '"$rc"' -eq 1 ] && [ "$(ls "'"$STUB_DIR"'/reviews" | wc -l)" -eq 0 ]'
    new_world
    XENV=(GH_TOKEN="$other_token")
    p status --branch x
    check "#71-AC2.8 status --branch with another login's GH_TOKEN: exit 1" rc_is 1
}

test_ac1_9_environment() {
    new_world
    ready_pr 7
    XENV=(STUB_GH_VERSION=2.39.9)
    p status 7
    check "#71-AC1.9 gh below the minimum (2.40.0): exit 1, says to upgrade" bash -c '[ '"$rc"' -eq 1 ] && grep -q "2.40.0" <<<"$1"' _ "$err"
    new_world
    ready_pr 7
    XENV=(STUB_GH_VERSION=2.40.0)
    p status 7
    check "#71-AC1.9 gh at exactly the minimum: works" rc_is 0
    check "#71-AC1.9 the minimum version is stated in the header of ticket.sh's library" grep -q "Minimum gh version: 2.40.0" "$tools/gh-lib.sh"
}

test_ac1_10_observability() {
    new_world
    ready_pr 7
    p status 7
    check "#71-AC1.10 ready run: no token in the output" no_secret
    new_world
    ready_pr 7
    fault "*compare*" 10 502
    p status 7
    check "#71-AC1.10 failing run: no token in the output" no_secret
    new_world
    ready_pr 7
    XENV=(SHELLOPTS=xtrace)
    p status 7
    check "#71-AC1.10 a caller's xtrace never prints the token" no_secret
    new_world
    ready_pr 7
    XENV=(GH_TOKEN="$other_token")
    p status 7
    check "#71-AC1.10 a rejected token is not echoed" no_secret
    new_world
    p verdict 7 comment --body-file "$(body_file b1)" --sha "$sha_a"
    check "#71-AC1.10 verdict on an unknown PR: no token in the output" no_secret
}

# ---- #71-AC2: finding a PR by branch ---------------------------------------------------------------------------------

# a world with PRs for 120-x (5), a decoy x/refs/heads/20-x (6) and, if asked, 20-x itself (4)
branch_world() {
    new_world
    ready_pr 5 ref=120-x
    ready_pr 6 ref=x/refs/heads/20-x "sha=$sha_b"
    [ "${1:-}" = with ] && ready_pr 4 ref=20-x "sha=$sha_c"
    return 0
}

test_ac2_exact() {
    branch_world
    p status --branch 20-x
    check "#71-AC2 20-x does not match 120-x or the decoy x/refs/heads/20-x: no PR for 20-x, exit 1" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "no PR for 20-x" <<<"$1"' _ "$out$err"
    check "#71-AC2 no PR found: nothing was read for any other PR" bash -c '! grep -q "check-runs" "'"$STUB_DIR"'/calls.log"'
    branch_world with
    p status --branch 20-x
    check "#71-AC2 with the exact branch present, its PR (4) is the one reported" bash -c '[ '"$rc"' -eq 0 ] && grep -q "^pr: 4" <<<"$1" && grep -q "^sha: '"$sha_c"'" <<<"$1"' _ "$out"
    check "#71-AC2 --branch output carries the same facts after the pr line" bash -c 'grep -q "^state: open" <<<"$1" && grep -q "^head: 20-x" <<<"$1" && grep -q "^gate: success" <<<"$1"' _ "$out"
    p status --branch 120-x
    check "#71-AC2 120-x finds PR 5, not 20-x's" bash -c 'grep -q "^pr: 5" <<<"$1"' _ "$out"
    p status --branch x/refs/heads/20-x
    check "#71-AC2.1 the decoy name itself is refused as input (exit 2)" bash -c '[ '"$rc"' -eq 2 ]'
    check "#71-AC2 git, if run at all, got only refs/remotes/origin/<name> or a 40-hex SHA" bash -c '! [ -e "'"$STUB_DIR"'/git.log" ] || ! grep -qvE "^(rev-parse )?(--verify )?(--quiet )?(refs/remotes/origin/[A-Za-z0-9._/-]+|[0-9a-f]{40})(\^\{commit\})?$" "'"$STUB_DIR"'/git.log"'
}

test_ac2_1_inputs() {
    local bad
    for bad in 'a..b' 'a b' '-x' '' 'refs/heads/x' 'x/refs/heads/y' 'a//b' 'a/' 'x.lock' $'a\nb' 'a~1' 'a^b' 'a:b' 'a?b' 'a*b' 'a[b' 'a\b' '$(id)'; do
        new_world
        p status --branch "$bad"
        check "#71-AC2.1 --branch '${bad//$'\n'/\\n}': exit 2, gh never called" usage_exit
    done
    new_world
    p status --branch
    check "#71-AC2.1 --branch without a value: exit 2" usage_exit
    p status --branch a b
    check "#71-AC2.1 --branch with two values: exit 2" usage_exit
    p status 7 --branch a
    check "#71-AC2.1 a number together with --branch: exit 2" usage_exit
}

test_ac2_2_boundaries() {
    local one long255 long256
    one=x
    long255=$(printf 'a%.0s' $(seq 1 255))
    long256=$(printf 'a%.0s' $(seq 1 256))
    new_world
    p status --branch "$one"
    check "#71-AC2.2 a 1-character branch name is accepted (no PR for it, exit 1)" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "no PR for x" <<<"$1"' _ "$out$err"
    new_world
    ready_pr 8 "ref=$long255"
    p status --branch "$long255"
    check "#71-AC2.2 a 255-character branch name is accepted and its PR found" bash -c '[ '"$rc"' -eq 0 ] && grep -q "^pr: 8" <<<"$1"' _ "$out"
    new_world
    p status --branch "$long256"
    check "#71-AC2.2 a 256-character branch name is refused (exit 2)" usage_exit
}

test_ac2_3_state() {
    new_world
    ready_pr 3 ref=feat/x state=closed
    ready_pr 9 ref=feat/x "sha=$sha_b"
    p status --branch feat/x
    check "#71-AC2.3 one closed and one open PR for the name: the open one (9) is returned" bash -c 'grep -q "^pr: 9" <<<"$1" && grep -q "^state: open" <<<"$1"' _ "$out"
    new_world
    ready_pr 3 ref=feat/x state=closed
    p status --branch feat/x
    check "#71-AC2.3 only a closed PR: it is reported with its state (exit 1)" bash -c '[ '"$rc"' -eq 1 ] && grep -q "^pr: 3" <<<"$1" && grep -q "^state: closed" <<<"$1"' _ "$out"
    new_world
    ready_pr 3 ref=feat/x state=closed
    ready_pr 4 ref=feat/x state=closed
    p status --branch feat/x
    check "#71-AC2.3 two closed PRs: the newest (4) is reported" bash -c 'grep -q "^pr: 4" <<<"$1"' _ "$out"
    new_world
    ready_pr 3 ref=feat/x
    put_pr 12 repo=evil/Elysium ref=feat/x "sha=$sha_b"
    p status --branch feat/x
    check "#71-AC2.3 two open PRs for one name (one from a fork): exit 1 naming both numbers" bash -c '[ '"$rc"' -eq 1 ] && grep -q "#3" <<<"$1" && grep -q "#12" <<<"$1"' _ "$out$err"
    new_world
    put_pr 12 repo=evil/Elysium ref=feat/x
    p status --branch feat/x
    check "#71-AC2.3 only a fork has a PR with this name: no PR for it here (exit 1)" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "no PR for feat/x" <<<"$1"' _ "$out$err"
}

test_ac2_6_partial() {
    branch_world
    fault "*pulls*" 10 502
    p status --branch 20-x
    check "#71-AC2.6 a gh failure while listing is not 'no PR': non-zero, names the step" bash -c '[ '"$rc"' -ne 0 ] && ! grep -qF "no PR for" <<<"$1" && grep -qi "list" <<<"$1"' _ "$out$err"
    branch_world
    p status --branch 20-x
    check "#71-AC2.10 the no-PR line names the branch and the reason" bash -c 'grep -qF "no PR for 20-x" <<<"$1" && grep -qE "open|head" <<<"$1"' _ "$err"
    branch_world with
    p status --branch 20-x
    local first="$out"
    p status --branch 20-x
    check "#71-AC2.7 --branch is read-only: the same output twice, no writes" bash -c '[ "$1" = "$2" ] && [ ! -s "'"$STUB_DIR"'/writes.log" ]' _ "$first" "$out"
}

# ---- #71-AC3: verdict --------------------------------------------------------------------------------------------------

test_ac3_flags() {
    local pair verdict flag
    for pair in approve:--approve changes:--request-changes comment:--comment; do
        verdict="${pair%%:*}"
        flag="${pair#*:}"
        new_world
        put_pr 7
        v 7 "$verdict" "$(body_file b1)"
        check "#71-AC3 $verdict posts one review with $flag" bash -c '[ '"$rc"' -eq 0 ] && [ "$(grep -c "^pr.review" "'"$STUB_DIR"'/calls.log")" -eq 0 ] && [ "$(grep -cP "\tpr\treview\t" "'"$STUB_DIR"'/calls.log")" -eq 1 ] && grep -P "\tpr\treview\t" "'"$STUB_DIR"'/calls.log" | grep -qF -e "'"$flag"'" && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 1 ]'
        check "#71-AC3 $verdict: the body is passed as --body-file, never as an argument" bash -c 'grep -P "\tpr\treview\t" "'"$STUB_DIR"'/calls.log" | grep -q -e "--body-file" && ! grep -q "Looks right" "'"$STUB_DIR"'/calls.log"'
        check "#71-AC3.10 $verdict prints the review URL" bash -c 'grep -q "https://github.com/rodgallert/Elysium/pull/7#pullrequestreview-" <<<"$1"' _ "$out"
    done
    new_world
    put_pr 7
    v 7 comment "$(body_file b1 'SECRETBODYTEXT')"
    check "#71-AC3.10 the output never contains the body" silent_on SECRETBODYTEXT
    check "#71-AC3.10 the output has no token" no_secret
}

test_ac3_1_inputs() {
    local f
    new_world
    put_pr 7
    f="$(body_file b1)"
    v 7 merge "$f"
    check "#71-AC3.1 an unknown verdict: exit 2, gh never called" usage_exit
    v 7 APPROVE "$f"
    check "#71-AC3.1 a verdict in the wrong case: exit 2" usage_exit
    p verdict 7 comment --body-file "$work/does-not-exist" --sha "$sha_a"
    check "#71-AC3.1 a missing body file: exit 2, gh never called" usage_exit
    : >"$work/empty"
    v 7 comment "$work/empty"
    check "#71-AC3.1 an empty body file: exit 2, gh never called" usage_exit
    printf '\n\n  \n' >"$work/blank"
    v 7 comment "$work/blank"
    check "#71-AC3.1 a body of only blank lines: exit 2" usage_exit
    p verdict 7 comment --body-file "$work" --sha "$sha_a"
    check "#71-AC3.1 a directory as the body file: exit 2" usage_exit
    p verdict 7 comment --sha "$sha_a"
    check "#71-AC3.1 no --body-file: exit 2" usage_exit
    p verdict 7 comment --body-file "$f"
    check "#71-AC3.1 no --sha: exit 2" usage_exit
    local bad
    for bad in "" abc "${sha_a:0:39}" "${sha_a}a" "${sha_a:0:39}g" "$(tr a-f A-F <<<"$sha_a")" "main" "$sha_a $sha_b"; do
        p verdict 7 comment --body-file "$f" --sha "$bad"
        check "#71-AC3.1 --sha '$bad' is not 40 hex: exit 2, gh never called" usage_exit
    done
    for bad in 0 007 12abc ""; do
        v "$bad" comment "$f"
        check "#71-AC3.1 verdict PR '$bad': exit 2" usage_exit
    done
    p verdict 7 comment --body-file "$f" --sha "$sha_a" --extra
    check "#71-AC3.1 an unknown option: exit 2" usage_exit

    # a hostile body reaches the review verbatim, through the file
    new_world
    put_pr 7
    printf '%s\n' '$(id) `id` ${HOME}' 'second line' '' "'quoted' \"double\" \\ backslash" >"$work/hostile"
    v 7 comment "$work/hostile"
    check "#71-AC3.1 \$(id), backticks and newlines are posted verbatim (the stub's recorded body)" bash -c '[ '"$rc"' -eq 0 ] && [ "$(jq -j ".[0].body" "'"$STUB_DIR"'/reviews/7.json")" = "$(cat "'"$work"'/hostile")" ]'
    check "#71-AC3.1 none of it appears in a gh argument" bash -c '! grep -qF "\$(id)" "'"$STUB_DIR"'/calls.log" && ! grep -qF "second line" "'"$STUB_DIR"'/calls.log"'
}

test_ac3_2_boundaries() {
    new_world
    put_pr 7
    printf 'a%.0s' $(seq 1 65536) >"$work/max"
    v 7 comment "$work/max"
    check "#71-AC3.2 a body of 65536 characters is accepted" bash -c '[ '"$rc"' -eq 0 ] && [ "$(jq -r ".[0].body | length" "'"$STUB_DIR"'/reviews/7.json")" -eq 65536 ]'
    new_world
    put_pr 7
    printf 'a%.0s' $(seq 1 65537) >"$work/over"
    v 7 comment "$work/over"
    check "#71-AC3.2 a body of 65537 characters is refused before any call" bash -c '[ '"$rc"' -ne 0 ] && [ "$(calls)" -eq 0 ]'
    check "#71-AC3.2 the refusal says why" says "65536"
    new_world
    put_pr 7
    head -c 65536 /dev/zero | tr '\0' a | sed 's/a/é/g' >"$work/multi"
    v 7 comment "$work/multi"
    check "#71-AC3.2 the limit counts characters, not bytes (65536 two-byte characters pass)" rc_is 0
    new_world
    put_pr 7
    printf 'x' >"$work/one"
    v 7 comment "$work/one"
    check "#71-AC3.2 a 1-character body is accepted" rc_is 0
}

test_ac3_attribution() {
    local text
    for text in $'Fine.\n\nGenerated with a tool' $'Fine.\n\nCo-Authored-By: Someone <a@b.c>' $'Fine.\n\n🤖 Generated with Tool' $'fine\nco-authored-by: x' $'Fine\n  Generated with x'; do
        new_world
        put_pr 7
        v 7 comment "$(body_file att "$text")"
        check "#71-AC3 a body with a tool-attribution line is refused (exit 1, nothing posted): ${text//$'\n'/ | }" bash -c '[ '"$rc"' -eq 1 ] && [ "$(calls)" -eq 0 ] && grep -qi "attribution" <<<"$1"' _ "$err"
    done
    new_world
    put_pr 7
    v 7 comment "$(body_file att $'A review that says the commit message was generated with care.')"
    check "#71-AC3 the words in the middle of a sentence are not an attribution line" rc_is 0
}

test_ac3_3_state() {
    new_world
    put_pr 7 state=closed merged=true
    v 7 comment "$(body_file b1)"
    check "#71-AC3.3 a verdict on a merged PR: exit 1, says merged, nothing posted" bash -c '[ '"$rc"' -eq 1 ] && grep -q merged <<<"$1" && [ "$(grep -c "review" "'"$STUB_DIR"'/writes.log" 2>/dev/null)" -eq 0 ]' _ "$err"
    new_world
    put_pr 7 state=closed
    v 7 comment "$(body_file b1)"
    check "#71-AC3.3 a verdict on a closed PR: exit 1, says closed" bash -c '[ '"$rc"' -eq 1 ] && grep -q closed <<<"$1"' _ "$err"
    new_world
    put_pr 7 user=rodgallert
    v 7 approve "$(body_file b1)"
    check "#71-AC3.3 approve on the account's own PR: exit 1 with GitHub's reason, reported as such" bash -c '[ '"$rc"' -eq 1 ] && grep -qi "own pull request" <<<"$1" && grep -qi "refused" <<<"$1"' _ "$err"
    check "#71-AC3.3 the refusal is not retried and posts nothing" bash -c '[ "$(grep -cP "\tpr\treview\t" "'"$STUB_DIR"'/calls.log")" -eq 1 ] && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json" 2>/dev/null || echo 0)" -eq 0 ] && [ ! -s "'"$STUB_DIR"'/sleeps" ]'
    new_world
    put_pr 7 user=rodgallert
    v 7 comment "$(body_file b1)"
    check "#71-AC3.3 a comment verdict on the account's own PR is posted" rc_is 0
    new_world
    v 7 comment "$(body_file b1)"
    check "#71-AC3.3 a PR that does not exist: exit 1, not found, nothing posted" bash -c '[ '"$rc"' -eq 1 ] && grep -qi "not found" <<<"$1"' _ "$err"
}

test_ac3_5_concurrency() {
    new_world
    put_pr 7 "sha=$sha_b"
    v 7 comment "$(body_file b1)" "$sha_a"
    check "#71-AC3.5 --sha that is not the PR head: exit 1 (head moved), nothing posted" bash -c '[ '"$rc"' -eq 1 ] && grep -q "head moved" <<<"$1" && [ "$(grep -cP "\tpr\treview\t" "'"$STUB_DIR"'/calls.log")" -eq 0 ]' _ "$err"
    new_world
    put_pr 7
    echo "$sha_b" >"$STUB_DIR/pr/7.sha2"
    v 7 comment "$(body_file b1)" "$sha_a"
    check "#71-AC3.5 a head that moves between the first read and the call: exit 1, nothing posted" bash -c '[ '"$rc"' -eq 1 ] && grep -q "head moved" <<<"$1" && [ "$(grep -cP "\tpr\treview\t" "'"$STUB_DIR"'/calls.log")" -eq 0 ]' _ "$err"
    new_world
    put_pr 7
    ( v 7 comment "$(body_file b1)" >/dev/null; ) &
    wait
    p verdict 7 comment --body-file "$(body_file b1)" --sha "$sha_a"
    check "#71-AC3.5 two runs of one verdict in sequence post one review" bash -c '[ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 1 ]'
}

test_ac3_6_partial() {
    new_world
    put_pr 7
    fault "*pr review*" 2 502
    v 7 comment "$(body_file b1)"
    check "#71-AC3.6 a 5xx on the call is retried (2 s, 4 s) and one review is posted" bash -c '[ '"$rc"' -eq 0 ] && [ "$(sleeps)" = "2 4 " ] && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 1 ]'
    new_world
    put_pr 7
    fault "*pr review*" 10 502
    v 7 comment "$(body_file b1 'SECRETBODYTEXT first line')"
    check "#71-AC3.6 after the retries the exit is non-zero and says no review with this body exists" bash -c '[ '"$rc"' -ne 0 ] && grep -qi "no review" <<<"$1" && grep -qi "post" <<<"$1"' _ "$err"
    check "#71-AC3.6 the failure line does not show the body" silent_on SECRETBODYTEXT
    check "#71-AC3.6 the reviews were listed before saying it failed" bash -c 'grep -q "pulls/7/reviews" "'"$STUB_DIR"'/calls.log"'
    new_world
    put_pr 7
    fault "*pr review*" 10 502 after
    v 7 comment "$(body_file b1)"
    check "#71-AC3.6 a call whose answer was lost but whose review exists: exit 0, one review (not two)" bash -c '[ '"$rc"' -eq 0 ] && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 1 ] && grep -q "pullrequestreview" <<<"$1"' _ "$out"
    new_world
    put_pr 7
    fault "*pulls/7/reviews*" 10 502
    v 7 comment "$(body_file b1)"
    check "#71-AC3.6 listing the reviews failing (before the post): non-zero, nothing posted, names the step" bash -c '[ '"$rc"' -ne 0 ] && [ "$(grep -cP "\tpr\treview\t" "'"$STUB_DIR"'/calls.log")" -eq 0 ] && grep -qi "review" <<<"$1"' _ "$err"
}

test_ac3_7_idempotence() {
    new_world
    put_pr 7
    local f
    f="$(body_file b1)"
    v 7 comment "$f"
    local first="$out"
    v 7 comment "$f"
    check "#71-AC3.7 the same verdict and body twice posts one review" bash -c '[ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 1 ]'
    check "#71-AC3.7 the second run prints already posted, exit 0, with the URL" bash -c '[ '"$rc"' -eq 0 ] && grep -q "already posted" <<<"$1" && grep -q "pullrequestreview-" <<<"$1"' _ "$out"
    check "#71-AC3.7 the first run did not say already posted" bash -c '! grep -q "already posted" <<<"$1"' _ "$first"
    v 7 changes "$f"
    check "#71-AC3.7 another verdict with the same body is a new review" bash -c '[ '"$rc"' -eq 0 ] && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 2 ]'
    v 7 comment "$(body_file b2 $'A different first line.\nmore')"
    check "#71-AC3.7 the same verdict with another first line is a new review" bash -c '[ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 3 ]'
    # the same words on a new head are a new review (the earlier one was of another commit)
    new_world
    put_pr 7
    v 7 comment "$f"
    put_pr 7 "sha=$sha_b"
    tip "$repo" feat/x "$sha_b"
    p verdict 7 comment --body-file "$f" --sha "$sha_b"
    check "#71-AC3.7 the same words after a push (new head) post a new review" bash -c '[ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 2 ]'
    # a review by someone else with the same first line is not ours
    new_world
    put_pr 7
    jq -nc --arg c "$sha_a" '[{id:1, user:{login:"someone-else"}, state:"COMMENTED", body:"Looks right.", commit_id:$c, html_url:"https://example.invalid/r/1"}]' >"$STUB_DIR/reviews/7.json"
    v 7 comment "$f"
    check "#71-AC3.7 another person's review with the same first line does not count" bash -c '[ '"$rc"' -eq 0 ] && [ "$(jq length "'"$STUB_DIR"'/reviews/7.json")" -eq 2 ]'
}

test_ac3_9_docs_and_lint() {
    check "#71-AC3 the script's usage line shows the verdict form" bash -c 'bash "'"$script"'" 2>&1 | grep -q "verdict <pr> <approve|changes|comment> --body-file <file> --sha <sha>"'
}

# ---- #71-AC4: documentation, CI and lint --------------------------------------------------------------------------------

test_ac4_docs() {
    local ticket_flow="$tools/../.claude/skills/ticket-flow/SKILL.md" pr_review="$tools/../.claude/skills/pr-review/SKILL.md" usage
    usage=$(bash "$script" 2>&1)
    check "#71-AC4 the usage line shows status <pr>" grep -qF "status <pr>" <<<"$usage"
    check "#71-AC4 the usage line shows status --branch <name>" grep -qF "status --branch <name>" <<<"$usage"
    check "#71-AC4 ticket-flow calls tools/pr.sh status <pr> for the head and CI checks" grep -qF 'tools/pr.sh status <pr>' "$ticket_flow"
    check "#71-AC4 pr-review calls tools/pr.sh status <pr>" grep -qF 'tools/pr.sh status <pr>' "$pr_review"
    check "#71-AC4 pr-review documents status --branch <name> (as in the usage line)" grep -qF 'tools/pr.sh status --branch <name>' "$pr_review"
    check "#71-AC4 ticket-flow step 4 no longer lists the raw checks as a manual sequence" bash -c '! grep -q "that the PR.s head on GitHub equals the branch tip, that CI ran on that commit" "'"$ticket_flow"'"'
    check "#71-AC4 tools/tests/pr-tools.sh is listed in the gate job" grep -qF "tools/tests/pr-tools.sh" "$tools/../.github/workflows/build.yml"
    check "#71-AC4 tools/tests/pr-tools.sh is listed in workflow.md" grep -qF "tools/tests/pr-tools.sh" "$tools/../Docs/workflow.md"
}

test_lint() {
    if command -v shellcheck >/dev/null; then
        check "#71-AC4 shellcheck: script, library, test file and stub" shellcheck -x "$script" "$tools/gh-lib.sh" "$tools/tests/pr-tools.sh" "$stubs/gh"
    else
        echo "note: shellcheck is not installed here; run it on the script, library, test file and stub (CI image has it)"
    fi
}

for fn in test_ac1_facts test_ac1_1_inputs test_ac1_2_boundaries test_ac1_3_state test_ac1_5_concurrency test_ac1_6_partial \
    test_ac1_7_idempotence test_account test_ac1_9_environment test_ac1_10_observability test_ac2_exact test_ac2_1_inputs \
    test_ac2_2_boundaries test_ac2_3_state test_ac2_6_partial test_ac3_flags test_ac3_1_inputs test_ac3_2_boundaries \
    test_ac3_attribution test_ac3_3_state test_ac3_5_concurrency test_ac3_6_partial test_ac3_7_idempotence \
    test_ac3_9_docs_and_lint test_ac4_docs test_lint; do
    echo "== $fn"
    "$fn"
done

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
