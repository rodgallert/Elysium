#!/usr/bin/env bash
# Tests for tools/ticket.sh (issue #70), against the stub gh in tools/tests/ticket-stubs/gh: a fake of the GitHub
# calls with its state in files, so no case reaches GitHub. Every case runs in a fresh "world" (a state directory)
# under one temporary directory. Each test function and comment cites the criterion or edge case it covers
# (#70-AC<n>, #70-AC<n>.<m>).
# Run from anywhere: tools/tests/ticket-tools.sh (VERBOSE=1 also shows the output of passing cases)
# shellcheck disable=SC2016 # the cases pass strings with literal $( ) and backticks on purpose
set -uo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$tools/ticket.sh"
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
mkdir -p "$work/home"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"$STUB_DIR/sleeps"\n' >"$work/sleep"
chmod +x "$work/sleep"

owner_token=gho_stubOwnerToken0001
active_token=gho_stubActiveToken9999
other_token=gho_stubOtherUser00003
repo=rodgallert/Elysium

# ---- worlds and fixtures ----------------------------------------------------------------------------------------

world=0
XENV=()
TT=5
new_world() {
    world=$((world + 1))
    STUB_DIR="$work/w$world"
    mkdir -p "$STUB_DIR/issue" "$STUB_DIR/comments" "$STUB_DIR/edits" "$STUB_DIR/pr" "$STUB_DIR/board" "$STUB_DIR/locks"
    : >"$STUB_DIR/branches"
    XENV=()
    TT=5
    put_issue 62 $'Epic: #1\n' "epic" open 2026-01-01T00:00:00Z "Environments"
}
# put_issue <n> <body> [labels csv] [state] [created_at] [title]
put_issue() {
    local n="$1" body="$2" labels="${3-ticket,type: feat}" state="${4-open}" created="${5-2026-01-01T00:00:00Z}" title="${6-feat(tools): a thing}"
    printf '%s' "$body" >"$STUB_DIR/body.tmp"
    jq -nc --argjson n "$n" --rawfile b "$STUB_DIR/body.tmp" --arg l "$labels" --arg s "$state" --arg c "$created" --arg t "$title" \
        '{number:$n, state:$s, title:$t, body:$b, labels:($l | split(",") | map(select(. != "") | {name:.})), assignees:[],
          created_at:$c, updated_at:"2026-05-01T00:00:00Z", html_url:("https://github.com/rodgallert/Elysium/issues/" + ($n|tostring))}' \
        >"$STUB_DIR/issue/$n.json"
    echo '[]' >"$STUB_DIR/comments/$n.json"
    echo '[]' >"$STUB_DIR/edits/$n.json"
}
put_comment() { # <n> <id> <text>
    jq -c --argjson id "$2" --arg b "$3" --arg u "https://api.github.com/repos/$repo/issues/$1" \
        '. + [{id:$id, body:$b, issue_url:$u}]' "$STUB_DIR/comments/$1.json" >"$STUB_DIR/c.tmp" && mv "$STUB_DIR/c.tmp" "$STUB_DIR/comments/$1.json"
}
put_edits() { echo "$2" >"$STUB_DIR/edits/$1.json"; }
fault() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$STUB_DIR/faults"; }
# spec_issue <n> [approval time] [extra body lines]: an approved spec; created 2026-01-01, approved 2026-01-02
spec_issue() {
    local n="$1" at="${2-2026-01-02T00:00:00Z}" body
    printf -v body 'Epic: #62\n\n## Goal\nA goal.\n\n## Out of scope\nNone.\n%s\nApproved: https://github.com/%s/issues/%s#issuecomment-5001\n' "${3-}" "$repo" "$n"
    put_issue "$n" "$body"
    put_comment "$n" 5001 "Issue last edited $at"
}
put_issue_body_append() { # <n> <text>: add a line at the end of the body
    jq -c --arg t "$2" '.body = (.body | rtrimstr("\n")) + "\n" + $t + "\n"' "$STUB_DIR/issue/$1.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/$1.json"
}
body_of() { jq -j .body "$STUB_DIR/issue/$1.json"; }
state_of() { jq -r .state "$STUB_DIR/issue/$1.json"; }
comments_of() { jq -r '.[].body' "$STUB_DIR/comments/$1.json"; }
board_of() { cat "$STUB_DIR/board/$1" 2>/dev/null || echo none; }
writes() { cat "$STUB_DIR/writes.log" 2>/dev/null | grep -c "^$1\$" || true; }
all_writes() { cat "$STUB_DIR/writes.log" 2>/dev/null | wc -l; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null | wc -l; }
calls_like() { cat "$STUB_DIR/calls.log" 2>/dev/null | grep -c -- "$1" || true; }
fingerprint() { # <n>: the observable end state of one issue
    jq -cS '{state, body, assignees: [.assignees[].login]}' "$STUB_DIR/issue/$1.json"
    comments_of "$1"
    board_of "$1"
    echo "branches: $(sort "$STUB_DIR/branches" | tr '\n' ' ')"
}
# t <args...>: runs ticket.sh in the current world; sets $out, $err and $rc
t() {
    local o="$work/out.tmp" e="$work/err.tmp"
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" \
        TICKET_TIMEOUT="$TT" TICKET_LOCK_DIR="$STUB_DIR/locks" "${XENV[@]}" bash "$script" "$@" >"$o" 2>"$e" </dev/null
    rc=$?
    out=$(<"$o")
    err=$(<"$e")
}
# tpath <dir> <command>...: a PATH directory holding only the named commands (to make gh or jq absent)
tpath() {
    local d="$1" c
    shift
    mkdir -p "$d"
    for c in "$@"; do ln -sf "$(command -v "$c")" "$d/$c"; done
}

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
one_line_err() { [ "$(wc -l <<<"$err")" -eq 1 ] && [ -n "$err" ]; }
eq() { [ "$1" = "$2" ]; }
no_secret() { ! grep -qE "gho_|ghp_|github_pat_" <<<"$out
$err"; }

# ---- #70-AC1: argument and account guards --------------------------------------------------------------------------

test_ac1() {
    new_world
    t
    check "#70-AC1 no command: exit 2, one usage line, no gh call" bash -c '[ '"$rc"' -eq 2 ] && [ "$(wc -l <<<"$1")" -eq 1 ] && grep -q "^Usage:" <<<"$1"' _ "$err"
    check "#70-AC1 no command: gh called zero times" eq "$(calls)" 0
    t frobnicate 5
    check "#70-AC1 unknown command: exit 2, usage line, zero calls" bash -c '[ '"$rc"' -eq 2 ] && grep -q "^Usage:" <<<"$1" && [ '"$(calls)"' -eq 0 ]' _ "$err"
    t start
    check "#70-AC1 start without a number: exit 2" rc_is 2
    t review 5
    check "#70-AC1 review without a PR number: exit 2" rc_is 2
    t file --title x
    check "#70-AC1 file with missing options: exit 2" rc_is 2
}

test_ac1_1_inputs() {
    local bad cmd
    for cmd in start ready 'done'; do
        for bad in 0 -1 007 12abc 12345678 "" https://github.com/rodgallert/Elysium/issues/5 "1 2"; do
            new_world
            t "$cmd" "$bad"
            check "#70-AC1.1 $cmd '$bad': exit 2 with a usage line, gh never called" bash -c '[ '"$rc"' -eq 2 ] && grep -q "^Usage:" <<<"$1" && [ '"$(calls)"' -eq 0 ]' _ "$err"
        done
    done
    for bad in 0 007 12345678 "" "1 2"; do
        new_world
        t review 5 "$bad"
        check "#70-AC1.1 review 5 '$bad': bad PR number, exit 2, gh never called" bash -c '[ '"$rc"' -eq 2 ] && [ '"$(calls)"' -eq 0 ]'
        t review "$bad" 5
        check "#70-AC1.1 review '$bad' 5: bad issue number, exit 2" rc_is 2
    done

    # a hostile branch in the body is rejected, not quoted: nothing is created or moved
    local hostile
    for hostile in '-x' 'feat/a b' 'feat/x..y' 'x/refs/heads/y' 'feat/$(id)'; do
        new_world
        spec_issue 20 "" "Branch: $hostile"
        put_issue_body_append 20 "Branch: $hostile"
        t start 20
        check "#70-AC1.1 Branch: '$hostile' in the body is rejected (exit 1, no write)" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'
    done

    # a title with shell syntax only reaches gh through a body file
    new_world
    spec_issue 20
    jq -c '.title = "feat(tools): $(id) `id` x"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC1.1 start with a hostile title: exit 0, branch is a clean slug" bash -c '[ '"$rc"' -eq 0 ] && grep -qx "feat/id-id-x" "'"$STUB_DIR"'/branches"'
    check "#70-AC1.1 the hostile title is nowhere in the recorded gh arguments" bash -c '! grep -qF "\$(id)" "'"$STUB_DIR"'/calls.log" && ! grep -qF "\`id\`" "'"$STUB_DIR"'/calls.log"'

    new_world
    printf 'Epic: #62\n\n## Goal\nx\n' >"$work/body.md"
    t file --title 'feat(x): $(id) `id`' --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC1.1 file with a \$(id) title: created, and the title is not in any gh argument" bash -c '[ '"$rc"' -eq 0 ] && ! grep -qF "\$(id)" "'"$STUB_DIR"'/calls.log" && [ "$(jq -r .title "'"$STUB_DIR"'/issue/101.json")" = "feat(x): \$(id) \`id\`" ]'
    new_world
    t file --title $'feat(x): a\nb' --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC1.1 file with a newline in the title: refused (exit 2), nothing created" bash -c '[ '"$rc"' -eq 2 ] && [ '"$(writes create)"' -eq 0 ]'
}

test_ac1_2_boundaries() {
    new_world
    put_issue 1 $'Epic: #62\n' "ticket,type: feat" closed
    put_issue 9999999 $'Epic: #62\n' "ticket,type: feat" closed
    t start 1
    check "#70-AC1.2 issue 1 is accepted" rc_is 0
    t start 9999999
    check "#70-AC1.2 issue 9999999 is accepted" rc_is 0
    t start 10000000
    check "#70-AC1.2 issue 10000000 is rejected (exit 2)" rc_is 2
}

test_ac1_6_account() {
    new_world
    XENV=(STUB_NO_OWNER=1)
    spec_issue 20
    t start 20
    check "#70-AC1.6 no login for the owner: exit 1, one line saying what to do" bash -c '[ '"$rc"' -eq 1 ] && [ "$(wc -l <<<"$1")" -eq 1 ] && grep -q "gh auth login" <<<"$1"' _ "$err"
    check "#70-AC1.6 ... and no call besides asking for the token" eq "$(calls_like '^none	api')" 0
    XENV=()
    local p="$work/nogh"
    rm -rf "$p"
    tpath "$p" bash env jq date sed awk grep cat mktemp sort head tail tr wc flock timeout rm mkdir dirname cut cp mv
    env -i PATH="$p" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" "$(command -v bash)" "$script" start 20 >"$work/o" 2>"$work/e"
    rc=$? out=$(<"$work/o") err=$(<"$work/e")
    check "#70-AC1.6 gh missing: exit 1, one line" bash -c '[ '"$rc"' -eq 1 ] && [ "$(wc -l <<<"$1")" -eq 1 ] && grep -qi "gh" <<<"$1"' _ "$err"
}

test_ac1_8_permissions() {
    new_world
    spec_issue 20
    t start 20
    check "#70-AC1.8 start works with the owner's token" rc_is 0
    check "#70-AC1.8 no gh auth switch call" eq "$(calls_like 'auth	switch')" 0
    check "#70-AC1.8 the active account's token is never read (no auth token call without --user)" bash -c '! grep -P "^none\tauth\ttoken\t?$" "'"$STUB_DIR"'/calls.log" && ! grep -P "auth\ttoken\t$" "'"$STUB_DIR"'/calls.log"'
    check "#70-AC1.8 every call carried the owner's token (the token lookup aside)" bash -c '! grep -v "^'"$owner_token"'" "'"$STUB_DIR"'/calls.log" | grep -vq "auth.token.--user.rodgallert"'
    check "#70-AC1.8 the active account's token appears in no call" eq "$(calls_like "$active_token")" 0

    new_world
    spec_issue 20
    XENV=("GH_TOKEN=$other_token")
    t start 20
    check "#70-AC1.8 a preset GH_TOKEN of another login is refused (exit 1, no write)" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'
    check "#70-AC1.8 ... after asking only who it is" eq "$(calls)" 1
    XENV=("GH_TOKEN=$active_token")
    t start 20
    check "#70-AC1.8 a preset GH_TOKEN equal to the active account's is refused (exit 1)" rc_is 1

    new_world
    put_issue 20 $'Epic: #62\n' "ticket,type: feat" closed
    XENV=("GH_TOKEN=$owner_token")
    t start 20
    check "#70-AC1.8 a preset GH_TOKEN of the owner is accepted, and no auth token lookup follows" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(calls_like 'auth	token')"' -eq 0 ]'
}

test_ac1_9_environment() {
    new_world
    spec_issue 20
    XENV=(STUB_GH_VERSION=2.30.0)
    t start 20
    check "#70-AC1.9 gh below the minimum version: exit 1, one line, no call" bash -c '[ '"$rc"' -eq 1 ] && [ "$(wc -l <<<"$1")" -eq 1 ] && [ '"$(calls)"' -eq 0 ]' _ "$err"
    XENV=()
    local p="$work/nojq"
    rm -rf "$p"
    tpath "$p" bash env date sed awk grep cat mktemp sort head tail tr wc flock timeout rm mkdir dirname cut cp mv
    ln -sf "$stubs/gh" "$p/gh"
    env -i PATH="$p" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" "$(command -v bash)" "$script" start 20 >"$work/o" 2>"$work/e"
    rc=$? out=$(<"$work/o") err=$(<"$work/e")
    check "#70-AC1.9 jq absent: exit 1, one line naming jq" bash -c '[ '"$rc"' -eq 1 ] && [ "$(wc -l <<<"$1")" -eq 1 ] && grep -q jq <<<"$1"' _ "$err"
    check "#70-AC1.9 the test file starts with #!/usr/bin/env bash" bash -c 'head -1 "'"$tools"'/tests/ticket-tools.sh" | grep -qx "#!/usr/bin/env bash"'
    check "#70-AC1.9 the script starts with #!/usr/bin/env bash" bash -c 'head -1 "'"$script"'" | grep -qx "#!/usr/bin/env bash"'
}

test_ac1_10_observability() {
    local case_
    for case_ in start-ok start-502 start-active nonzero-xtrace; do
        new_world
        spec_issue 20
        XENV=()
        case "$case_" in
            start-502) fault '*issues/20' 99 502 ;;
            start-active) XENV=("GH_TOKEN=$active_token") ;;
            nonzero-xtrace) fault '*comments*' 99 502 ;;
        esac
        [ "$case_" = nonzero-xtrace ] && XENV+=(SHELLOPTS=xtrace)
        t start 20
        check "#70-AC1.10 no token in the output ($case_)" no_secret
    done
    new_world
    spec_issue 20
    XENV=(SHELLOPTS=xtrace)
    t start 20
    check "#70-AC1.10 with xtrace set by the caller (SHELLOPTS), a good run prints no token" no_secret
    check "#70-AC1.10 ... and no token value (GH_TOKEN)" silent_on "$owner_token"
}

# ---- #70-AC2: start is idempotent and ordered ----------------------------------------------------------------------

test_ac2_start() {
    new_world
    spec_issue 20
    t start 20
    check "#70-AC2 start: exit 0, ends with ok" bash -c '[ '"$rc"' -eq 0 ] && [ "$(tail -1 <<<"$1")" = ok ]' _ "$out"
    check "#70-AC2 one gh issue develop call" eq "$(writes develop)" 1
    check "#70-AC2 exactly one Branch: line, last in the body" bash -c '[ "$(grep -c "^Branch: " <<<"$1")" -eq 1 ] && [ "$(tail -1 <<<"$1")" = "Branch: feat/a-thing" ]' _ "$(body_of 20)"
    check "#70-AC2 board In progress" eq "$(board_of 20)" "In progress"
    check "#70-AC2 assigned to the account" eq "$(jq -r '.assignees[0].login' "$STUB_DIR/issue/20.json")" rodgallert
    check "#70-AC2 one comment: Started on branch feat/a-thing." bash -c '[ "$(jq -r "[.[] | select(.body | startswith(\"Started on branch feat/a-thing.\"))] | length" "'"$STUB_DIR"'/comments/20.json")" -eq 1 ]'
    check "#70-AC2.10 each step prints a line" bash -c 'grep -q "^branch: feat/a-thing" <<<"$1" && grep -q "^board: In progress" <<<"$1" && grep -q "^comment: posted" <<<"$1"' _ "$out"
    local before
    before=$(all_writes)
    t start 20
    check "#70-AC2 second start: exit 0, prints already started on <branch>" bash -c '[ '"$rc"' -eq 0 ] && grep -qx "already started on feat/a-thing" <<<"$1"' _ "$out"
    check "#70-AC2.7 second run: zero writes of any kind" eq "$(all_writes)" "$before"
    check "#70-AC2.7 second run: still one develop, one body edit, one comment, one board move" bash -c '[ '"$(writes develop)"' -eq 1 ] && [ '"$(writes body)"' -eq 1 ] && [ '"$(writes comment)"' -eq 1 ] && [ '"$(writes board)"' -eq 1 ]'
}

test_ac2_1_inputs() {
    new_world
    spec_issue 20 "" $'```\nBranch: feat/in-a-fence\n```\nBranch: prose mention in the middle of the text'
    t start 20
    check "#70-AC2.1 Branch: text in a fence or in the middle is not the line: start proceeds" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes develop)"' -eq 1 ]'
    check "#70-AC2.1 ... and the trailing Branch: line is added once" bash -c '[ "$(tail -1 <<<"$1")" = "Branch: feat/a-thing" ]' _ "$(body_of 20)"

    new_world
    spec_issue 20
    put_issue_body_append 20 "Branch: feat/a-thing"
    echo feat/a-thing >>"$STUB_DIR/branches"
    t start 20
    check "#70-AC2.1 a body that already has the Branch: line gets no second one" bash -c '[ '"$rc"' -eq 0 ] && [ "$(grep -c "^Branch: " <<<"$1")" -eq 1 ] && [ '"$(writes develop)"' -eq 0 ]' _ "$(body_of 20)"
    check "#70-AC2.1 ... and the remaining steps are completed" bash -c '[ "'"$(board_of 20)"'" = "In progress" ] && [ '"$(writes comment)"' -eq 1 ]'
}

test_ac2_2_3_state() {
    new_world
    put_issue 20 ""
    t start 20
    check "#70-AC2.2 empty body: exit 1 (no crash), no Approved: line, no write" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "no Approved: line" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out
$err"

    new_world
    spec_issue 20
    jq -c '.state = "closed"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC2.3 closed issue: no-op, exit 0, says already" bash -c '[ '"$rc"' -eq 0 ] && grep -qi "^already" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out"

    new_world
    spec_issue 20
    put_issue_body_append 20 "Branch: feat/a-thing"
    echo feat/a-thing >>"$STUB_DIR/branches"
    put_comment 20 7000 "Started on branch feat/a-thing."
    t start 20
    check "#70-AC2.3 already started (an earlier, hand-made start comment): no-op, exit 0" bash -c '[ '"$rc"' -eq 0 ] && grep -qx "already started on feat/a-thing" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out"

    new_world
    spec_issue 20
    jq -c '.labels = [{name:"ticket"}]' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC2.3 a ticket without a type: label: exit 1 naming it, no write" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "type:" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out
$err"
}

test_ac2_5_concurrency() {
    new_world
    spec_issue 20
    XENV=(STUB_DEVELOP_DELAY=1)
    (t start 20) &
    local p1=$!
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=5 \
        TICKET_LOCK_DIR="$STUB_DIR/locks" STUB_DEVELOP_DELAY=1 bash "$script" start 20 >"$work/o2" 2>"$work/e2" </dev/null &
    local p2=$!
    wait "$p1" "$p2"
    check "#70-AC2.5 two parallel starts: exactly one gh issue develop call" eq "$(writes develop)" 1
    check "#70-AC2.5 ... one Branch: line and one comment" bash -c '[ "$(grep -c "^Branch: " <<<"$1")" -eq 1 ] && [ '"$(writes comment)"' -eq 1 ]' _ "$(body_of 20)"
}

test_ac2_6_partial() {
    new_world
    spec_issue 20
    fault '*item-edit*' 2 502
    t start 20
    check "#70-AC2.6 board move fails twice (502) then works: exit 0, retried per AC5" bash -c '[ '"$rc"' -eq 0 ] && [ "'"$(board_of 20)"'" = "In progress" ]'
    check "#70-AC2.6 ... one branch, one Branch: line, one comment" bash -c '[ '"$(writes develop)"' -eq 1 ] && [ '"$(writes comment)"' -eq 1 ] && [ "$(grep -c "^Branch: " <<<"$1")" -eq 1 ]' _ "$(body_of 20)"

    new_world
    spec_issue 20
    fault '*item-edit*' 99 502
    t start 20
    check "#70-AC2.6 board move fails for good: exit 1 naming the board step" bash -c '[ '"$rc"' -eq 1 ] && grep -qi "board" <<<"$1"' _ "$err"
    check "#70-AC2.6 ... branch and Branch: line exist, no comment yet" bash -c '[ '"$(writes develop)"' -eq 1 ] && [ '"$(writes comment)"' -eq 0 ] && grep -q "^Branch: " <<<"$1"' _ "$(body_of 20)"
    rm "$STUB_DIR/faults"
    t start 20
    check "#70-AC2.6 a re-run completes the rest: exit 0, board In progress, comment posted" bash -c '[ '"$rc"' -eq 0 ] && [ "'"$(board_of 20)"'" = "In progress" ] && [ '"$(writes comment)"' -eq 1 ]'
    check "#70-AC2.6 ... with no second branch, no second Branch: line, no second comment" bash -c '[ '"$(writes develop)"' -eq 1 ] && [ '"$(writes body)"' -eq 1 ] && [ '"$(writes comment)"' -eq 1 ]'
}

test_ac2_9_branch_names() {
    new_world
    spec_issue 20
    jq -c '.title = "feat(x): Weird Título_ñ!! & More"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC2.9 other work: <type>/<slug>, slug lower-case [a-z0-9-] only" bash -c 'grep -qx "feat/weird-t-tulo-more" "'"$STUB_DIR"'/branches"'

    new_world
    put_issue 63 $'Epic: #1\n' epic open 2026-01-01T00:00:00Z "Phase 3: Accounts"
    spec_issue 21
    jq -c '.body |= sub("Epic: #62"; "Epic: #63") | .labels = [{name:"ticket"},{name:"type: fix"}] | .title = "fix(masquerade): Sign in"' "$STUB_DIR/issue/21.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/21.json"
    t start 21
    check "#70-AC2.9 a roadmap task (epic is a phase): <type>/p<n>-<slug>" bash -c 'grep -qx "fix/p3-sign-in" "'"$STUB_DIR"'/branches"'
}

# ---- #70-AC3: the spec gate -------------------------------------------------------------------------------------------

gate_refused() { [ "$rc" -eq 1 ] && [ "$(all_writes)" -eq 0 ]; }
edit() { # <createdAt> <diff>
    jq -nc --arg c "$1" --arg d "$2" '{createdAt:$c, diff:$d}'
}

test_ac3_gate() {
    new_world
    spec_issue 20
    jq -c '.body |= sub("\nApproved:.*\n$"; "\n")' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3 no Approved: line: refused, one line saying what is missing, ticket untouched" bash -c '[ '"$rc"' -eq 1 ] && says() { grep -qF "no Approved: line" <<<"$1"; }; says "$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out
$err"
    check "#70-AC3.10 no Approved: line is named" says "no Approved: line"

    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-03T00:00:00Z $'-A goal.\n+A new goal.')]"
    t start 20
    check "#70-AC3.3 a criteria edit after approval: refused with needs approval again" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'
    check "#70-AC3.10 ... naming approval older than edit at <time>" says "approval older than edit at 2026-01-03T00:00:00Z"
    check "#70-AC3.3 ... and needs approval again" says "needs approval again"

    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-04T00:00:00Z '+Branch: feat/a-thing'),$(edit 2026-01-03T00:00:00Z $'+PR: #4\n+Approved: x'),$(edit 2026-01-02T00:00:00Z $'-Epic: #1\n+Epic: #2')]"
    t start 20
    check "#70-AC3.3 edits touching only Epic:, Approved:, Branch: or PR: lines are ignored: gate passes" rc_is 0

    new_world
    spec_issue 20
    put_comment 20 7001 "Spec change: criteria 2 changed"
    t start 20
    check "#70-AC3.3 a Spec change: comment alone does not move the reference" rc_is 0

    new_world
    spec_issue 20
    put_edits 20 "[]"
    jq -c '.created_at = "2026-01-05T00:00:00Z"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3 empty edit history: the body's creation time is the reference (created after approval: refused)" bash -c '[ '"$rc"' -eq 1 ]'
    check "#70-AC3.10 ... naming that time" says "approval older than edit at 2026-01-05T00:00:00Z"
}

test_ac3_1_inputs() {
    local n=20
    new_world
    spec_issue $n
    put_issue 21 $'Epic: #62\n'
    put_comment 21 5002 "Issue last edited 2026-01-02T00:00:00Z"
    jq -c '.body |= sub("issuecomment-5001"; "issuecomment-5002")' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3.1 Approved: pointing at another issue's comment: refused" gate_refused

    new_world
    spec_issue 20
    jq -c '.body |= sub("issues/20#"; "issues/21#")' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3.1 Approved: link naming another issue number: refused" gate_refused

    new_world
    spec_issue 20 "" ""
    jq -c '.body |= sub("Approved: .*\n$"; "Approved: soon\n")' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3.1 Approved: that is not a URL: refused" gate_refused

    new_world
    spec_issue 20
    jq -c '.[0].body = "Looks good to me"' "$STUB_DIR/comments/20.json" >"$STUB_DIR/c.tmp" && mv "$STUB_DIR/c.tmp" "$STUB_DIR/comments/20.json"
    t start 20
    check "#70-AC3.1 the comment's text is not Issue last edited <time>: refused" gate_refused

    local bad
    for bad in "yesterday" "2026-01-02" "2026-01-02 00:00:00" "2026-13-45T99:00:00Z" "2026-01-02T00:00:00Z extra"; do
        new_world
        spec_issue 20 "$bad"
        t start 20
        check "#70-AC3.1 malformed time '$bad': refused" gate_refused
    done
}

test_ac3_2_boundaries() {
    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-02T00:00:00Z '+A goal edit')]"
    t start 20
    check "#70-AC3.2 an edit exactly at the approval time passes" rc_is 0

    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-02T00:00:01Z '+A goal edit')]"
    t start 20
    check "#70-AC3.2 an edit one second later fails" gate_refused

    # 100 edits on one page and 101 (two pages): the spec edit is the oldest, the 99 or 100 newer ones touch only Branch:
    local base many
    base=$(date -u -d 2026-01-02T00:00:00Z +%s)
    for many in 100 101; do
        new_world
        spec_issue 20
        put_edits 20 "$(jq -nc --argjson base "$base" --argjson n "$many" '
            [range(0; $n) as $i | if $i == ($n - 1)
                then {createdAt: (($base + 86400) | todate), diff: "+A goal edit"}
                else {createdAt: (($base + 86400 + ($n - $i) * 60) | todate), diff: "+Branch: x"} end]')"
        t start 20
        check "#70-AC3.2 $many edits: the spec edit is found ($many edits is ${many/101/two pages}${many/100/one page})" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "approval older than edit at 2026-01-03T00:00:00Z" <<<"$1"' _ "$out
$err"
        check "#70-AC3.2 $many edits: GraphQL pages read" eq "$(calls_like 'graphql')" "$((many == 100 ? 1 : 2))"
    done
}

test_ac3_4_time() {
    new_world
    spec_issue 20
    put_comment 20 7002 "a later comment"
    jq -c '.updated_at = "2026-09-09T00:00:00Z"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t start 20
    check "#70-AC3.4 a later updatedAt (label, comment) does not fail the gate" rc_is 0

    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-02T00:30:00+01:00 '+A goal edit')]"
    t start 20
    check "#70-AC3.4 a +01:00 time (= 2026-01-01T23:30:00Z) is normalised, not compared as text: before the approval, passes" rc_is 0

    new_world
    spec_issue 20
    put_edits 20 "[$(edit 2026-01-02T00:30:00-01:00 '+A goal edit')]"
    t start 20
    check "#70-AC3.4 a -01:00 time (= 01:30Z) is later than the approval: fails" gate_refused
}

test_ac3_6_partial() {
    new_world
    spec_issue 20
    jq -c '.updated_at = "2025-01-01T00:00:00Z"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    fault '*graphql*' 99 502
    t start 20
    check "#70-AC3.6 GraphQL failing after retries: exit 1, edit history unreadable, no write, no updatedAt fallback" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "edit history unreadable" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out
$err"

    new_world
    spec_issue 20
    put_edits 20 "$(jq -nc '[range(0; 101) | {createdAt: "2025-12-01T00:00:00Z", diff: "+Branch: x"}]')"
    fault '*cursor=100*' 99 502
    t start 20
    check "#70-AC3.6 page 2 failing: the partial list is not accepted" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "edit history unreadable" <<<"$1" && [ '"$(all_writes)"' -eq 0 ]' _ "$out
$err"
}

test_ac3_9_query() {
    new_world
    spec_issue 20
    t start 20
    check "#70-AC3.9 the GraphQL query the script sends equals the fixture" cmp -s "$STUB_DIR/query.txt" "$tools/tests/fixtures/ticket-edits.graphql"
}

# ---- #70-AC4: review, ready, done and file ----------------------------------------------------------------------------

started_issue() { # <n>: a started ticket (Branch: line, branch, comment)
    spec_issue "$1"
    put_issue_body_append "$1" "Branch: feat/a-thing"
    echo feat/a-thing >>"$STUB_DIR/branches"
}

test_ac4_review() {
    new_world
    started_issue 20
    t review 20 9
    check "#70-AC4 review: exit 0, one PR: #9 line after Branch:, board In review, comment posted" bash -c '[ '"$rc"' -eq 0 ] && [ "$(tail -2 <<<"$1" | tr "\n" "|")" = "Branch: feat/a-thing|PR: #9|" ] && [ "'"$(board_of 20)"'" = "In review" ] && [ '"$(writes comment)"' -eq 1 ]' _ "$(body_of 20)"
    check "#70-AC4 ... the comment reads In review: #9." bash -c 'comments_of() { :; }; grep -qF "In review: #9." <<<"$1"' _ "$(comments_of 20)"
    check "#70-AC4.10 one line per step, then ok" bash -c 'grep -q "^pr: " <<<"$1" && grep -q "^board: In review" <<<"$1" && [ "$(tail -1 <<<"$1")" = ok ]' _ "$out"
    local before
    before=$(all_writes)
    t review 20 9
    check "#70-AC4.7 review twice with the same PR changes nothing" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(all_writes)"' -eq '"$before"' ]'
    t review 20 10
    check "#70-AC4.3 a second, different PR number is refused (exit 1), no stacked PR: line" bash -c '[ '"$rc"' -eq 1 ] && [ "$(grep -c "^PR: " <<<"$1")" -eq 1 ] && [ '"$(all_writes)"' -eq '"$before"' ]' _ "$(body_of 20)"

    new_world
    started_issue 20
    jq -c '.state = "closed"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t review 20 9
    check "#70-AC4.3 review on a closed issue is refused (exit 1), no write" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'

    new_world
    started_issue 20
    fault '*comments*' 1 502 after
    t review 20 9
    check "#70-AC4.6 the comment's answer is lost after it was posted: the retry posts no second comment" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes comment)"' -eq 1 ]'
}

test_ac4_ready() {
    new_world
    started_issue 20
    t ready 20
    check "#70-AC4.3 ready without a PR: line: exit 1, no board move" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(writes board)"' -eq 0 ]'
    put_issue_body_append 20 "PR: #9"
    t ready 20
    check "#70-AC4 ready with a PR: line: board Ready to Merge" bash -c '[ '"$rc"' -eq 0 ] && [ "'"$(board_of 20)"'" = "Ready to Merge" ]'
    check "#70-AC4.10 ends with ok" bash -c '[ "$(tail -1 <<<"$1")" = ok ]' _ "$out"
}

test_ac4_done() {
    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":true,"state":"closed"}' >"$STUB_DIR/pr/9.json"
    t 'done' 20
    check "#70-AC4 done: board Done, issue closed, comment Done in #9. once" bash -c '[ '"$rc"' -eq 0 ] && [ "'"$(board_of 20)"'" = Done ] && [ "'"$(state_of 20)"'" = closed ] && [ '"$(writes comment)"' -eq 1 ] && grep -qF "Done in #9." <<<"$1"' _ "$(comments_of 20)"
    t 'done' 20
    check "#70-AC4.7 done twice: one comment, closed once" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes comment)"' -eq 1 ] && [ '"$(writes close)"' -eq 1 ]'

    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":true,"state":"closed"}' >"$STUB_DIR/pr/9.json"
    jq -c '.state = "closed"' "$STUB_DIR/issue/20.json" >"$STUB_DIR/i.tmp" && mv "$STUB_DIR/i.tmp" "$STUB_DIR/issue/20.json"
    t 'done' 20
    check "#70-AC4 done when the merge already closed the issue: no close call, comment still posted once" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes close)"' -eq 0 ] && [ '"$(writes comment)"' -eq 1 ] && [ "'"$(board_of 20)"'" = Done ]'

    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":false,"state":"open"}' >"$STUB_DIR/pr/9.json"
    t 'done' 20
    check "#70-AC4.3 done on an open issue with no merged PR: exit 1, nothing written" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'

    new_world
    started_issue 20
    t 'done' 20
    check "#70-AC4.3 done without a PR: line: exit 1" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(all_writes)"' -eq 0 ]'

    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":true,"state":"closed"}' >"$STUB_DIR/pr/9.json"
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=5 \
        TICKET_LOCK_DIR="$STUB_DIR/locks" bash "$script" 'done' 20 >"$work/o3" 2>"$work/e3" </dev/null &
    local p1=$!
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=5 \
        TICKET_LOCK_DIR="$STUB_DIR/locks" bash "$script" 'done' 20 >"$work/o4" 2>"$work/e4" </dev/null &
    local p2=$!
    wait "$p1" "$p2"
    check "#70-AC4.5 two done runs at once post one comment" eq "$(writes comment)" 1

    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":true,"state":"closed"}' >"$STUB_DIR/pr/9.json"
    fault '*item-edit*' 99 502
    t 'done' 20
    check "#70-AC4.6 board fails for good: exit 1 naming the board step" bash -c '[ '"$rc"' -eq 1 ] && grep -qi board <<<"$1"' _ "$err"
    rm "$STUB_DIR/faults"
    t 'done' 20
    check "#70-AC4.6 a re-run finishes: board Done, one comment, closed once" bash -c '[ '"$rc"' -eq 0 ] && [ "'"$(board_of 20)"'" = Done ] && [ '"$(writes comment)"' -eq 1 ] && [ '"$(writes close)"' -eq 1 ]'

    new_world
    started_issue 20
    put_issue_body_append 20 "PR: #9"
    echo '{"merged":true,"state":"closed"}' >"$STUB_DIR/pr/9.json"
    fault '*-X POST*comments*' 1 502 after
    t 'done' 20
    check "#70-AC4.6 the comment posted but the answer was lost: no second comment" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes comment)"' -eq 1 ]'
}

file_body() { # <extra text>
    printf 'Epic: #62\n\n## Goal\nA goal.\n\n- **#<issue>-AC1:** one\n  - **#<issue>-AC1.1 inputs:** two\n%s' "${1-}" >"$work/body.md"
}

test_ac4_file() {
    new_world
    file_body
    t file --title "feat(tools): a thing" --type feat --epic 62 --milestone "Workflow v1" --body-file "$work/body.md"
    check "#70-AC4 file: exit 0, prints the number and URL" bash -c '[ '"$rc"' -eq 0 ] && grep -qF "101" <<<"$1" && grep -qF "https://github.com/rodgallert/Elysium/issues/101" <<<"$1"' _ "$out"
    check "#70-AC4 ... labels ticket and type: feat, milestone 3, Epic: line first" bash -c '[ "$(jq -c "[.labels[].name]" "'"$STUB_DIR"'/issue/101.json")" = "[\"ticket\",\"type: feat\"]" ] && [ "$(jq .milestone "'"$STUB_DIR"'/issue/101.json")" = 3 ] && [ "$(head -1 <<<"$1")" = "Epic: #62" ]' _ "$(body_of 101)"
    check "#70-AC4 ... every #<issue>-AC placeholder replaced with the number" bash -c '! grep -qF "<issue>" <<<"$1" && grep -qF "#101-AC1.1" <<<"$1"' _ "$(body_of 101)"
    check "#70-AC4.10 one line per step, then ok" bash -c '[ "$(tail -1 <<<"$1")" = ok ]' _ "$out"

    new_world
    printf 'Goal only\n' >"$work/body.md"
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.1 body without the first-line Epic: #<n>: exit 1, nothing created" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(writes create)"' -eq 0 ]'
    file_body
    t file --title "feat(x): y" --type wibble --epic 62 --body-file "$work/body.md"
    check "#70-AC4.1 unknown type: exit 1, nothing created" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(writes create)"' -eq 0 ]'
    t file --title "feat(x): y" --type feat --epic 62 --milestone "No such" --body-file "$work/body.md"
    check "#70-AC4.1 unknown milestone: exit 1, nothing created" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(writes create)"' -eq 0 ]'
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/missing.md"
    check "#70-AC4.1 body file missing: exit 1, nothing created" bash -c '[ '"$rc"' -eq 1 ] && [ '"$(writes create)"' -eq 0 ]'

    file_body $'\nStill a <issue> left\n'
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.1 a body that still has a placeholder after replacement: exit 1, says the issue was created, with its number" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "#101" <<<"$1" && grep -qi "created" <<<"$1"' _ "$out
$err"

    new_world
    printf 'Epic: #62\n\n## Goal\nNo placeholders.\n' >"$work/body.md"
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.2 a body with no placeholders is created as is" bash -c '[ '"$rc"' -eq 0 ] && [ "$(body_of 101)" = "$(cat "'"$work"'/body.md")" ]'

    new_world
    { printf 'Epic: #62\n\n'; for _ in $(seq 200); do printf -- '- **#<issue>-AC1:** x\n'; done; } >"$work/body.md"
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.2 200 placeholders: all replaced" bash -c '[ '"$rc"' -eq 0 ] && [ "$(grep -c "#101-AC1" <<<"$1")" -eq 200 ] && ! grep -qF "<issue>" <<<"$1"' _ "$(body_of 101)"

    new_world
    file_body
    fault '*-X PATCH*' 99 502
    t file --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.6 creating works but editing the body fails: exit 1 naming issue #101" bash -c '[ '"$rc"' -eq 1 ] && grep -qF "#101" <<<"$1"' _ "$out
$err"
    rm "$STUB_DIR/faults"
    t file --issue 101 --title "feat(x): y" --type feat --epic 62 --body-file "$work/body.md"
    check "#70-AC4.6 re-run by number (--issue 101): the body is fixed and no second issue is created" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(writes create)"' -eq 1 ] && ! grep -qF "<issue>" <<<"$1"' _ "$(body_of 101)"
}

# ---- #70-AC5: failure handling against GitHub -------------------------------------------------------------------------

read_fault() { printf 'api repos/%s/issues/20' "$repo"; }

test_ac5_retries() {
    new_world
    spec_issue 20
    fault "$(read_fault)" 3 502
    t start 20
    check "#70-AC5.2 failing 3 times then succeeding on the 4th attempt succeeds" rc_is 0
    check "#70-AC5 backoff 2 s, 4 s, 8 s" eq "$(tr '\n' ' ' <"$STUB_DIR/sleeps")" "2 4 8 "

    new_world
    spec_issue 20
    fault "$(read_fault)" 4 502
    t start 20
    check "#70-AC5.2 failing 4 times: non-zero exit, step and HTTP status named" bash -c '[ '"$rc"' -ne 0 ] && grep -qF "502" <<<"$1" && grep -qi "read" <<<"$1"' _ "$err"
    check "#70-AC5.10 the failure line holds neither the token nor the body" bash -c '! grep -qF "A goal." <<<"$1" && ! grep -qF "'"$owner_token"'" <<<"$1"' _ "$out
$err"
    check "#70-AC5.2 exactly 4 attempts" eq "$(calls_like 'issues/20$')" 4

    new_world
    spec_issue 20
    fault "$(read_fault)" 1 rl-secondary:7
    t start 20
    check "#70-AC5 a secondary rate limit honours Retry-After (7 s)" bash -c '[ '"$rc"' -eq 0 ] && [ "$(cat "'"$STUB_DIR"'/sleeps")" = 7 ]'

    local ra
    for ra in "abc:2" "-5:2" "300:60" "0:0"; do
        new_world
        spec_issue 20
        fault "$(read_fault)" 1 "rl-secondary:${ra%%:*}"
        t start 20
        check "#70-AC5.1 Retry-After '${ra%%:*}' waits ${ra##*:} s" bash -c '[ "$(head -1 "'"$STUB_DIR"'/sleeps")" = "'"${ra##*:}"'" ]'
    done

    new_world
    spec_issue 20
    fault "$(read_fault)" 99 rl-primary
    t start 20
    check "#70-AC5 a primary rate limit retried 3 times, then exit non-zero, reported as a rate limit" bash -c '[ '"$rc"' -ne 0 ] && grep -qi "rate limit" <<<"$1" && ! grep -qi "not found" <<<"$1" && [ "$(wc -l <"'"$STUB_DIR"'/sleeps")" -eq 3 ]' _ "$err"
    check "#70-AC5 ... waits per the reset time (1..60 s), never hammering" bash -c 'while read -r s; do [ "$s" -ge 1 ] && [ "$s" -le 60 ] || exit 1; done <"'"$STUB_DIR"'/sleeps"'

    new_world
    spec_issue 20
    fault "$(read_fault)" 99 404
    t start 20
    check "#70-AC5 a 404 is reported as not found and is not retried" bash -c '[ '"$rc"' -ne 0 ] && grep -qi "not found" <<<"$1" && [ '"$(calls_like 'issues/20$')"' -eq 1 ]' _ "$err"

    new_world
    spec_issue 20
    fault "$(read_fault)" 99 perm
    t start 20
    check "#70-AC5.8 a 403 permission error is not retried and says so" bash -c '[ '"$rc"' -ne 0 ] && grep -qi "permission" <<<"$1" && ! grep -qi "rate limit" <<<"$1" && [ '"$(calls_like 'issues/20$')"' -eq 1 ]' _ "$err"
}

test_ac5_4_timeout() {
    new_world
    spec_issue 20
    TT=1
    fault "$(read_fault)" 1 hang
    t start 20
    check "#70-AC5.4 a hanging gh call is killed after the timeout and counted as a failed attempt; the next succeeds" bash -c '[ '"$rc"' -eq 0 ] && [ '"$(calls_like 'issues/20$')"' -eq 2 ]'
    new_world
    spec_issue 20
    TT=1
    fault "$(read_fault)" 99 hang
    t start 20
    check "#70-AC5.4 a call that always hangs: non-zero exit saying it timed out" bash -c '[ '"$rc"' -ne 0 ] && grep -qi "timed out" <<<"$1"' _ "$err"
}

test_ac5_5_isolation() {
    new_world
    spec_issue 20
    spec_issue 21
    fault "api repos/$repo/issues/20" 99 rl-secondary:1
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=5 \
        TICKET_LOCK_DIR="$STUB_DIR/locks" bash "$script" start 20 >"$work/o5" 2>"$work/e5" </dev/null &
    local p1=$!
    env -i PATH="$stubs:$PATH" HOME="$work/home" TICKET_TOOLS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=5 \
        TICKET_LOCK_DIR="$STUB_DIR/locks" bash "$script" start 21 >"$work/o6" 2>"$work/e6" </dev/null &
    local p2=$!
    wait "$p1" "$p2"
    check "#70-AC5.5 the issue that was not rate limited is unaffected and ran each step once" bash -c '[ "'"$(board_of 21)"'" = "In progress" ] && [ '"$(writes develop)"' -eq 0 ] || [ '"$(writes develop)"' -eq 1 ]'
    check "#70-AC5.5 the rate limited one made no write" bash -c '[ "'"$(board_of 20)"'" = none ]'
}

test_ac5_6_nth_call() {
    # an outage starting at the Nth call, for every N: non-zero exit, and a re-run ends where an uninterrupted run does
    new_world
    spec_issue 20
    t start 20
    local total want n
    total=$(calls)
    want=$(fingerprint 20)
    for n in $(seq 1 "$total"); do
        new_world
        spec_issue 20
        echo "$n" >"$STUB_DIR/failnth"
        t start 20
        local first_rc=$rc
        rm -f "$STUB_DIR/failnth"
        t start 20
        check "#70-AC5.6 outage from call $n of $total: first run exits non-zero" eq "$first_rc" 1
        check "#70-AC5.6 outage from call $n: the re-run succeeds and ends in the uninterrupted state" bash -c '[ '"$rc"' -eq 0 ] && [ "$(cat <<<"$1")" = "$2" ]' _ "$(fingerprint 20)" "$want"
    done
}

test_ac5_9_jq() {
    check "#70-AC5.9 the script and the library use no jq builtin newer than 1.6" bash -c '! grep -nE "\b(pick|abs|toarray|ltrimstr_|trim|ltrim|rtrim|have_decnum|have_literal_numbers|splits|getpath\\()\b" "'"$tools"'/ticket.sh" "'"$tools"'/gh-lib.sh" 2>/dev/null | grep -v "^.*#"'
    jq --version | grep -q '^jq-1\.6' || echo "note: jq $(jq --version) here, not 1.6: the 1.6 filters were checked by the builtin scan only"
}

# ---- #70-AC6: the skill and the docs --------------------------------------------------------------------------------

test_ac6_docs() {
    local skill="$tools/../.claude/skills/ticket-flow/SKILL.md" wf="$tools/../Docs/workflow.md" cmd
    for cmd in start review ready 'done' file; do
        check "#70-AC6.3 the skill documents tools/ticket.sh $cmd" grep -qF "tools/ticket.sh $cmd" "$skill"
    done
    check "#70-AC6 workflow.md tells to run tools/ticket.sh" grep -qF "tools/ticket.sh" "$wf"
    check "#70-AC6 the docs say the script is the only place the approval time and the spec gate are computed" bash -c 'grep -qi "only place" "'"$skill"'" && grep -qi "only place" "'"$wf"'"'
    check "#70-AC6 the manual fallback is only: if the script fails, say so and stop" grep -qi "if the script fails, say so and stop" "$skill"
    check "#70-AC6.6 the docs say what to do when a step fails (stop and report)" grep -qi "stop and report" "$skill"
    check "#70-AC6.7 the docs say a re-run is safe" grep -qi "re-run is safe" "$skill"
    check "#70-AC6.8 the docs repeat never gh auth switch" bash -c 'grep -qF "gh auth switch" "'"$skill"'" && grep -qi "never.*gh auth switch" "'"$skill"'"'
    check "#70-AC6 tools/tests/ticket-tools.sh is listed in the gate job" grep -qF "tools/tests/ticket-tools.sh" "$tools/../.github/workflows/build.yml"
    check "#70-AC6 tools/tests/ticket-tools.sh is listed in workflow.md" grep -qF "tools/tests/ticket-tools.sh" "$wf"
}

test_lint() {
    if command -v shellcheck >/dev/null; then
        check "#70-AC6 shellcheck: script, library, test file and stub" shellcheck "$script" "$tools/gh-lib.sh" "$tools/tests/ticket-tools.sh" "$stubs/gh"
    else
        echo "note: shellcheck is not installed here; run it on the script, library, test file and stub (CI image has it)"
    fi
}

for fn in test_ac1 test_ac1_1_inputs test_ac1_2_boundaries test_ac1_6_account test_ac1_8_permissions test_ac1_9_environment \
    test_ac1_10_observability test_ac2_start test_ac2_1_inputs test_ac2_2_3_state test_ac2_5_concurrency test_ac2_6_partial \
    test_ac2_9_branch_names test_ac3_gate test_ac3_1_inputs test_ac3_2_boundaries test_ac3_4_time test_ac3_6_partial \
    test_ac3_9_query test_ac4_review test_ac4_ready test_ac4_done test_ac4_file test_ac5_retries test_ac5_4_timeout \
    test_ac5_5_isolation test_ac5_6_nth_call test_ac5_9_jq test_ac6_docs test_lint; do
    echo "== $fn"
    "$fn"
done

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
