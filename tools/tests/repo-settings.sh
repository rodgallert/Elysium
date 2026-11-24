#!/usr/bin/env bash
# Tests for tools/check-repo-settings.sh (issue #82), against the stub gh in tools/tests/repo-settings-stubs/gh: the
# live API is never called. Every case runs in a fresh "world" (a state directory) under one temporary directory.
# Each test function and comment cites the criterion or edge case it covers (#82-AC<n>, #82-AC<n>.<m>).
# Run from anywhere: tools/tests/repo-settings.sh (VERBOSE=1 also shows the output of passing cases)
# shellcheck disable=SC2015,SC2016 # "A && ok || bad" is the pass-or-fail report, never a branch that can fail midway
set -uo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$tools/check-repo-settings.sh"
stubs="$tools/tests/repo-settings-stubs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0

case "$work" in
    "${TMPDIR:-/tmp}"/*) ;;
    *) echo "Refusing to run: the work directory $work is not a fresh temporary directory" >&2; exit 1 ;;
esac
mkdir -p "$work/bin"
ln -s "$stubs/gh" "$work/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/sleep"
chmod +x "$work/sleep"

world=0
STUB_DIR=""
out=""
rc=0

# ---- fixtures ---------------------------------------------------------------------------------------------------

put() { printf '%s' "$2" >"$STUB_DIR/api/$1"; } # <key> <body>
fail_with() { printf '%s' "$2" >"$STUB_DIR/api/$1.status"; } # <key> <status|hang>

# ruleset_json <name> <count> <gate integration id or none> <dismiss> <code owner review> <last push approval>
ruleset_json() {
    jq -nc --arg n "$1" --argjson c "$2" --arg g "$3" --argjson d "$4" --argjson o "$5" --argjson l "$6" '
        {name:$n, rules:[{type:"deletion", parameters:null}, {type:"non_fast_forward", parameters:null},
          {type:"pull_request", parameters:{required_approving_review_count:$c, dismiss_stale_reviews_on_push:$d,
            require_code_owner_review:$o, require_last_push_approval:$l, allowed_merge_methods:["squash"]}},
          {type:"required_status_checks", parameters:{strict_required_status_checks_policy:true,
            required_status_checks:[({context:"gate"} + (if $g == "none" then {} else {integration_id:($g|tonumber)} end))]}}]}'
}
put_ruleset() { put "rulesets_$1" "$(ruleset_json "$2" "$3" "$4" "$5" "$6" "$7")"; } # <id> as ruleset_json

good_codeowners=$'# the PO owns the machinery\n/.github/ @rodgallert\n/tools/ @rodgallert\n/docker-compose.prod.yml @rodgallert\n/Docs/workflow.md @rodgallert\n'

# new_world: every setting as it should be after the change; a case then breaks one thing
new_world() {
    world=$((world + 1))
    STUB_DIR="$work/w$world"
    mkdir -p "$STUB_DIR/api"
    : >"$STUB_DIR/calls"
    : >"$STUB_DIR/loggedin"
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"all_external_contributors"}'
    put vulnerability-alerts ''
    put automated-security-fixes '{"enabled":true,"paused":false}'
    put rulesets '[{"id":1,"name":"Protect main"},{"id":2,"name":"Release branch creation"},{"id":3,"name":"Release branches"},{"id":4,"name":"Release tags"}]'
    put_ruleset 1 "Protect main" 0 15368 true false false
    put_ruleset 3 "Release branches" 0 15368 false false false
    put codeowners_errors '{"errors":[]}'
    put contents_.github_CODEOWNERS "$good_codeowners"
}

# run_check [VAR=value ...] -- [args]: runs the script with the stub gh first on PATH and no inherited token
run_check() {
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    out=$(env -u GH_TOKEN PATH="$work/bin:$PATH" REPO_SETTINGS_TEST=1 STUB_DIR="$STUB_DIR" TICKET_SLEEP="$work/sleep" TICKET_TIMEOUT=2 \
        "${envs[@]}" "$script" "$@" 2>&1)
    rc=$?
}

# ---- assertions ---------------------------------------------------------------------------------------------------

ok() { pass=$((pass + 1)); [ -z "${VERBOSE:-}" ] || echo "ok: $1"; }
bad() {
    failed=$((failed + 1))
    echo "FAIL: $1"
    printf '%s\n' "$out" | sed 's/^/    | /'
}
rc_is() { # <id> <expected rc>
    if [ "$rc" = "$2" ]; then ok "$1 (exit $2)"; else bad "$1: exit $rc, expected $2"; fi
}
has() { # <id> <fixed string> (a line of the output contains it)
    if grep -qF -- "$2" <<<"$out"; then ok "$1 (has: $2)"; else bad "$1: output lacks: $2"; fi
}
lacks() { # <id> <fixed string>
    if grep -qF -- "$2" <<<"$out"; then bad "$1: output has: $2"; else ok "$1 (lacks: $2)"; fi
}
called() { # <id> <fixed string> (the stub saw a call containing it)
    if grep -qF -- "$2" "$STUB_DIR/calls"; then ok "$1 (call: $2)"; else bad "$1: no call with: $2"; fi
}
not_called() { # <id> <fixed string>
    if grep -qF -- "$2" "$STUB_DIR/calls"; then bad "$1: call with: $2"; else ok "$1 (no call: $2)"; fi
}

# ---- #82-AC1: fork approval ----------------------------------------------------------------------------------------

t_ac1_happy() {
    new_world; run_check
    rc_is "#82-AC1 all settings right" 0
    has "#82-AC1 one ok line" "ok: fork-approval"
    called "#82-AC1 reads the approval endpoint" "actions/permissions/fork-pr-contributor-approval"
}
t_ac1_today() { # the settings as they are on 2026-11-24
    new_world
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"first_time_contributors"}'
    run_check
    rc_is "#82-AC1 today's policy fails" 1
    has "#82-AC1 FAIL line names value read" "FAIL: fork-approval: first_time_contributors"
}
t_ac1_1_inputs() {
    new_world
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"first_time_contributors_new_to_github"}'
    run_check
    rc_is "#82-AC1.1 new-to-github policy fails" 1
    has "#82-AC1.1 new-to-github value read" "FAIL: fork-approval: first_time_contributors_new_to_github"
    new_world
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":""}'
    run_check
    rc_is "#82-AC1.1 empty policy fails" 1
    has "#82-AC1.1 empty policy named" "FAIL: fork-approval: (empty)"
    new_world
    put actions_permissions_fork-pr-contributor-approval '{}'
    run_check
    rc_is "#82-AC1.1 missing key fails" 1
    has "#82-AC1.1 missing key named" "FAIL: fork-approval: (empty)"
    new_world; run_check -- --all
    rc_is "#82-AC1.1 an argument is a usage error" 2
    has "#82-AC1.1 usage line" "usage: tools/check-repo-settings.sh"
    [ "$(wc -l <<<"$out")" = 1 ] && ok "#82-AC1.1 usage is one line" || bad "#82-AC1.1 usage is not one line"
    [ ! -s "$STUB_DIR/calls" ] && ok "#82-AC1.1 no gh call on usage error" || bad "#82-AC1.1 gh was called on a usage error"
}
t_ac1_3_state() { # a setting reverted in the UI makes the next run fail
    new_world; run_check
    rc_is "#82-AC1.3 before the revert" 0
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"first_time_contributors"}'
    run_check
    rc_is "#82-AC1.3 after the revert" 1
    has "#82-AC1.3 reverted value read" "FAIL: fork-approval: first_time_contributors"
}
t_ac1_6_partial() {
    local s
    for s in 403 404 500 502; do
        new_world; fail_with actions_permissions_fork-pr-contributor-approval "$s"; run_check
        rc_is "#82-AC1.6 HTTP $s is not a pass" 1
        has "#82-AC1.6 HTTP $s cannot read" "FAIL: fork-approval: cannot read"
        lacks "#82-AC1.6 HTTP $s not ok" "ok: fork-approval"
    done
    new_world; fail_with actions_permissions_fork-pr-contributor-approval hang; run_check
    rc_is "#82-AC1.6 a timeout is not a pass" 1
    has "#82-AC1.6 a timeout cannot read" "FAIL: fork-approval: cannot read"
    new_world; put actions_permissions_fork-pr-contributor-approval 'not json'; run_check
    rc_is "#82-AC1.6 an unparsable answer is not a pass" 1
    has "#82-AC1.6 an unparsable answer cannot read" "FAIL: fork-approval: cannot read"
}
t_ac1_7_idempotent() {
    new_world
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"first_time_contributors"}'
    run_check; local first="$out" rc1=$rc
    run_check
    [ "$out" = "$first" ] && [ "$rc" = "$rc1" ] && ok "#82-AC1.7 two runs, same output and exit" || bad "#82-AC1.7 runs differ"
    if grep -qE -- '-X|--method|-f |-F |--input|PUT|POST|PATCH|DELETE' "$STUB_DIR/calls"; then bad "#82-AC1.7 a write call was made"; else ok "#82-AC1.7 only reads"; fi
}
t_ac1_8_permissions() {
    new_world; rm "$STUB_DIR/loggedin"; run_check
    [ "$rc" != 0 ] && ok "#82-AC1.8 not logged in exits non-zero" || bad "#82-AC1.8 not logged in exited 0"
    not_called "#82-AC1.8 no API call without the login" "api"
    called "#82-AC1.8 asked for the owner's login" "auth token --user rodgallert"
    new_world; run_check
    not_called "#82-AC1.8 never switches account" "auth switch"
    new_world; run_check GH_TOKEN=bad
    [ "$rc" != 0 ] && ok "#82-AC1.8 a bad GH_TOKEN exits non-zero" || bad "#82-AC1.8 a bad token exited 0"
    has "#82-AC1.8 a bad GH_TOKEN cannot read" "FAIL: fork-approval: cannot read"
    not_called "#82-AC1.8 a given GH_TOKEN is used, no login lookup" "auth token"
    new_world; fail_with actions_permissions_fork-pr-contributor-approval 403; run_check
    has "#82-AC1.8 a token without admin read is a 403 read" "FAIL: fork-approval: cannot read"
}
t_ac1_9_environment() {
    new_world; run_check STUB_GH_VERSION=2.96.0
    [ "$rc" != 0 ] && ok "#82-AC1.9 gh 2.96.0 is refused" || bad "#82-AC1.9 gh 2.96.0 accepted"
    has "#82-AC1.9 names the minimum" "2.97.0"
    not_called "#82-AC1.9 no API call with an old gh" "api"
    new_world; run_check STUB_GH_VERSION=2.97.0
    rc_is "#82-AC1.9 gh 2.97.0 is enough" 0
    local header
    header=$(head -30 "$script")
    grep -qF "2.97.0" <<<"$header" && ok "#82-AC1.9 header names the minimum gh" || { out="$header"; bad "#82-AC1.9 header lacks 2.97.0"; }
    grep -qiE 'not run in CI|never run in CI|not run by CI' <<<"$header" && ok "#82-AC1.9 header says it is not run in CI" || { out="$header"; bad "#82-AC1.9 header lacks the CI note"; }
    grep -qE 'bash, `?gh`? and `?jq`?|bash, gh and jq' <<<"$header" && ok "#82-AC1.9 header names bash, gh and jq" || { out="$header"; bad "#82-AC1.9 header lacks the tools"; }
}
t_ac1_10_observability() {
    new_world
    put actions_permissions_fork-pr-contributor-approval '{"approval_policy":"first_time_contributors"}'
    fail_with vulnerability-alerts 500
    run_check
    lacks "#82-AC1.10 no gho_ in the output" "gho_"
    lacks "#82-AC1.10 no ghp_ in the output" "ghp_"
    new_world; run_check SHELLOPTS=xtrace
    lacks "#82-AC1.10 no token under xtrace" "gho_"
    if grep -qE '^\++ ' <<<"$out"; then bad "#82-AC1.10 a set -x trace in the output"; else ok "#82-AC1.10 no trace lines"; fi
    new_world; run_check GH_TOKEN=ghp_stubGivenToken00002
    lacks "#82-AC1.10 a given token is not echoed" "ghp_"
}

# ---- #82-AC2: Dependabot -----------------------------------------------------------------------------------------

t_ac2() {
    new_world; run_check
    has "#82-AC2 alerts ok" "ok: dependabot-alerts"
    has "#82-AC2 security updates ok" "ok: dependabot-security-updates"
    called "#82-AC2 reads vulnerability-alerts" "vulnerability-alerts"
    called "#82-AC2 reads automated-security-fixes" "automated-security-fixes"
}
t_ac2_3_state() {
    new_world; fail_with vulnerability-alerts 404; put automated-security-fixes '{"enabled":false,"paused":false}'; run_check
    rc_is "#82-AC2.3 both off (today) fails" 1
    has "#82-AC2.3 alerts off named" "FAIL: dependabot-alerts: disabled"
    has "#82-AC2.3 security updates off named" "FAIL: dependabot-security-updates: false"
    new_world; put automated-security-fixes '{"enabled":false,"paused":false}'; run_check
    rc_is "#82-AC2.3 alerts on, updates off fails" 1
    has "#82-AC2.3 updates off named" "FAIL: dependabot-security-updates: false"
    has "#82-AC2.3 alerts still ok" "ok: dependabot-alerts"
    new_world; fail_with vulnerability-alerts 404; run_check
    rc_is "#82-AC2.3 alerts off, updates on fails" 1
    has "#82-AC2.3 alerts off named" "FAIL: dependabot-alerts: disabled"
    has "#82-AC2.3 updates still ok" "ok: dependabot-security-updates"
    new_world; put automated-security-fixes '{"enabled":true,"paused":true}'; run_check
    rc_is "#82-AC2.3 paused security updates fail" 1
    has "#82-AC2.3 paused named" "FAIL: dependabot-security-updates: paused"
}
t_ac2_6_partial() {
    local s
    for s in 403 500 502; do
        new_world; fail_with vulnerability-alerts "$s"; run_check
        rc_is "#82-AC2.6 alerts HTTP $s fails" 1
        has "#82-AC2.6 alerts HTTP $s cannot read" "FAIL: dependabot-alerts: cannot read"
        lacks "#82-AC2.6 alerts HTTP $s is not reported as disabled" "disabled"
    done
    new_world; fail_with vulnerability-alerts hang; run_check
    has "#82-AC2.6 alerts timeout cannot read" "FAIL: dependabot-alerts: cannot read"
    for s in 403 404 500; do
        new_world; fail_with automated-security-fixes "$s"; run_check
        rc_is "#82-AC2.6 security updates HTTP $s fails" 1
        has "#82-AC2.6 security updates HTTP $s cannot read" "FAIL: dependabot-security-updates: cannot read"
    done
    new_world; put automated-security-fixes '{}'; run_check
    rc_is "#82-AC2.6 security updates answer without enabled fails" 1
    has "#82-AC2.6 missing enabled is not ok" "FAIL: dependabot-security-updates"
}
t_ac2_8_10() {
    new_world; rm "$STUB_DIR/loggedin"; run_check
    [ "$rc" != 0 ] && ok "#82-AC2.8 same account rule" || bad "#82-AC2.8 not logged in exited 0"
    new_world; fail_with vulnerability-alerts 403; fail_with automated-security-fixes 500; run_check
    lacks "#82-AC2.10 FAIL lines never carry the token" "gho_"
}

# ---- #82-AC3: rulesets and CODEOWNERS ------------------------------------------------------------------------------

t_ac3_happy() {
    new_world; run_check
    rc_is "#82-AC3 rulesets as decided" 0
    has "#82-AC3 Protect main status check" "ok: ruleset Protect main: required status check gate"
    has "#82-AC3 Release branches status check" "ok: ruleset Release branches: required status check gate"
    has "#82-AC3 Protect main dismiss stale" "ok: ruleset Protect main: dismiss_stale_reviews_on_push"
    has "#82-AC3 Protect main review count" "ok: ruleset Protect main: required_approving_review_count"
    has "#82-AC3 Release branches review count" "ok: ruleset Release branches: required_approving_review_count"
    has "#82-AC3 codeowners file" "ok: codeowners"
}
t_ac3_dismiss() { # the live value on 2026-11-24 was false
    new_world; put_ruleset 1 "Protect main" 0 15368 false false false; run_check
    rc_is "#82-AC3 dismiss stale off on Protect main fails" 1
    has "#82-AC3 names ruleset and field" "FAIL: ruleset Protect main: dismiss_stale_reviews_on_push: false"
    new_world; put_ruleset 3 "Release branches" 0 15368 true false false; run_check
    rc_is "#82-AC3 dismiss stale on Release branches is allowed" 0
}
t_ac3_2_boundaries() {
    new_world; put_ruleset 1 "Protect main" 1 15368 true false false; run_check
    rc_is "#82-AC3.2 one required approval fails (Protect main)" 1
    has "#82-AC3.2 names ruleset and field" "FAIL: ruleset Protect main: required_approving_review_count: 1"
    new_world; put_ruleset 3 "Release branches" 2 15368 false false false; run_check
    rc_is "#82-AC3.2 two required approvals fail (Release branches)" 1
    has "#82-AC3.2 names ruleset and field (Release branches)" "FAIL: ruleset Release branches: required_approving_review_count: 2"
}
t_ac3_flags() {
    new_world; put_ruleset 1 "Protect main" 0 15368 true true false; run_check
    rc_is "#82-AC3 required code owner review fails" 1
    has "#82-AC3 code owner review named" "FAIL: ruleset Protect main: require_code_owner_review: true"
    new_world; put_ruleset 3 "Release branches" 0 15368 false false true; run_check
    rc_is "#82-AC3 required last push approval fails" 1
    has "#82-AC3 last push approval named" "FAIL: ruleset Release branches: require_last_push_approval: true"
}
t_ac3_3_state() {
    new_world; put_ruleset 1 "Protect main" 0 none true false false; run_check
    rc_is "#82-AC3.3 gate from any source fails" 1
    has "#82-AC3.3 integration_id named" "FAIL: ruleset Protect main: gate integration_id: (none)"
    new_world; put_ruleset 3 "Release branches" 0 999 false false false; run_check
    rc_is "#82-AC3.3 gate from another app fails" 1
    has "#82-AC3.3 other id named" "FAIL: ruleset Release branches: gate integration_id: 999"
    new_world
    put rulesets_1 "$(ruleset_json "Protect main" 0 15368 true false false | jq -c '.rules |= map(select(.type != "required_status_checks"))')"
    run_check
    rc_is "#82-AC3.3 no status check rule fails" 1
    has "#82-AC3.3 gate missing named" "FAIL: ruleset Protect main: required status check gate: missing"
    new_world
    put rulesets_1 "$(ruleset_json "Protect main" 0 15368 true false false | jq -c '.rules |= map(select(.type != "pull_request"))')"
    run_check
    rc_is "#82-AC3.3 no pull_request rule fails" 1
    has "#82-AC3.3 pull_request rule missing named" "FAIL: ruleset Protect main: pull_request rule: missing"
}
t_ac3_6_partial() {
    local s
    for s in 403 500; do
        new_world; fail_with rulesets "$s"; run_check
        rc_is "#82-AC3.6 ruleset list HTTP $s fails" 1
        has "#82-AC3.6 Protect main cannot read" "FAIL: ruleset Protect main: cannot read"
        has "#82-AC3.6 Release branches cannot read" "FAIL: ruleset Release branches: cannot read"
        lacks "#82-AC3.6 no ok for rulesets" "ok: ruleset"
        new_world; fail_with rulesets_3 "$s"; run_check
        rc_is "#82-AC3.6 one ruleset HTTP $s fails" 1
        has "#82-AC3.6 Release branches cannot read (one)" "FAIL: ruleset Release branches: cannot read"
        has "#82-AC3.6 the other is still checked" "ok: ruleset Protect main: required_approving_review_count"
    done
    new_world; put rulesets '[{"id":1,"name":"Protect main"}]'; run_check
    rc_is "#82-AC3.6 a ruleset missing from the list fails" 1
    has "#82-AC3.6 not found named" "FAIL: ruleset Release branches: not found"
    new_world; fail_with rulesets_1 hang; run_check
    has "#82-AC3.6 a timeout reads as cannot read" "FAIL: ruleset Protect main: cannot read"
}
t_ac3_1_codeowners() {
    new_world; put codeowners_errors '{"errors":[{"line":2,"column":1,"kind":"Unknown owner","message":"Unknown owner"}]}'; run_check
    rc_is "#82-AC3.1 errors fail" 1
    has "#82-AC3.1 errors named" "FAIL: codeowners errors: 1"
    new_world; fail_with codeowners_errors 404; run_check
    rc_is "#82-AC3.1 no CODEOWNERS on the default branch fails" 1
    has "#82-AC3.1 cannot read" "FAIL: codeowners errors: cannot read"
    new_world; fail_with codeowners_errors 500; run_check
    has "#82-AC3.1 5xx cannot read" "FAIL: codeowners errors: cannot read"
    new_world; put codeowners_errors '{}'; run_check
    rc_is "#82-AC3.1 an answer without errors list fails" 1
    has "#82-AC3.1 missing list named" "FAIL: codeowners errors"
}
t_ac3_codeowners_content() {
    local p
    for p in /.github/ /tools/ /docker-compose.prod.yml /Docs/workflow.md; do
        new_world
        put contents_.github_CODEOWNERS "$(grep -vF "$p " <<<"$good_codeowners")"
        run_check
        rc_is "#82-AC3 CODEOWNERS without $p fails" 1
        has "#82-AC3 CODEOWNERS without $p named" "FAIL: codeowners: $p"
    done
    new_world
    put contents_.github_CODEOWNERS "${good_codeowners//@rodgallert/@someone-else}"
    run_check
    rc_is "#82-AC3 CODEOWNERS naming another owner fails" 1
    has "#82-AC3 another owner named" "FAIL: codeowners: /tools/"
    new_world; fail_with contents_.github_CODEOWNERS 404; run_check
    rc_is "#82-AC3 CODEOWNERS file absent fails" 1
    has "#82-AC3 absent file named" "FAIL: codeowners: cannot read"
    new_world
    put contents_.github_CODEOWNERS $'# /tools/ @rodgallert\n/.github/ @rodgallert\n/docker-compose.prod.yml @rodgallert\n/Docs/workflow.md @rodgallert\n'
    run_check
    rc_is "#82-AC3 a commented-out line does not count" 1
    has "#82-AC3 commented-out line named" "FAIL: codeowners: /tools/"
}
t_ac3_ref() { # the optional ref lets the file be checked from a branch before it is merged
    new_world
    mv "$STUB_DIR/api/codeowners_errors" "$STUB_DIR/api/codeowners_errors_ref_chore_x"
    mv "$STUB_DIR/api/contents_.github_CODEOWNERS" "$STUB_DIR/api/contents_.github_CODEOWNERS_ref_chore_x"
    run_check REPO_SETTINGS_REF=chore/x
    rc_is "#82-AC3 with a ref, the branch's file is read" 0
    called "#82-AC3 ref passed to codeowners/errors" "codeowners/errors?ref=chore/x"
    called "#82-AC3 ref passed to the contents call" ".github/CODEOWNERS?ref=chore/x"
    new_world; run_check "REPO_SETTINGS_REF=x;rm -rf y"
    rc_is "#82-AC3 an unsafe ref is a usage error" 2
    [ ! -s "$STUB_DIR/calls" ] && ok "#82-AC3 no gh call with an unsafe ref" || bad "#82-AC3 gh called with an unsafe ref"
    new_world; run_check "REPO_SETTINGS_REF=--paginate"
    rc_is "#82-AC3 a ref starting with a dash is a usage error" 2
}

# ---- #82-AC4: docs --------------------------------------------------------------------------------------------------

t_ac4_docs() { # the paragraph exists and states the values the script asserts (the read-through checks the rest)
    local doc="$tools/../Docs/workflow.md"
    for s in all_external_contributors "tools/check-repo-settings.sh" "CODEOWNERS" "dismiss_stale_reviews_on_push" "15368" "Dependabot alerts" "security updates"; do
        grep -qF -- "$s" "$doc" && ok "#82-AC4 workflow.md mentions $s" || { out="$s"; bad "#82-AC4 workflow.md lacks: $s"; }
    done
    [ -f "$tools/../.github/CODEOWNERS" ] && ok "#82-AC3 .github/CODEOWNERS exists" || { out=""; bad "#82-AC3 .github/CODEOWNERS is missing"; }
}

for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do "$t"; done

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
