#!/usr/bin/env bash
# Reads the live repository settings the Hardening design depends on and prints one line per check, `ok: <name>` or
# `FAIL: <name>: <value read>` (`cannot read` when the API did not answer, which is never a pass). Exit 0 when every
# check is ok, 1 when any is not, 2 on a usage error. Read-only: it changes nothing, so running it twice gives the
# same output.
#
#   tools/check-repo-settings.sh
#
# Checks (Docs/workflow.md, "Repository settings"):
#   fork-approval                 Actions -> Fork pull request workflows: approval_policy is all_external_contributors
#   dependabot-alerts             vulnerability alerts are enabled (the endpoint answers 204; 404 means disabled)
#   dependabot-security-updates   automated security fixes are enabled and not paused
#   ruleset <name>: ...           "Protect main" and "Release branches", each unique by name and: active, targeting
#                                 ~DEFAULT_BRANCH / refs/heads/release/** only, no bypass actors, `gate` required from
#                                 GitHub Actions (integration_id 15368) with up-to-date branches, no required approvals,
#                                 no required code owner review, no required last-push approval, and stale reviews
#                                 dismissed on push
#   codeowners ...                .github/CODEOWNERS has no errors and, by its last matching line per path, names the
#                                 owner for the guarded paths
#
# Needs only bash, gh and jq (gh 2.97.0 or newer), and an admin token for the repository: a GH_TOKEN in the environment
# must belong to the owner (else `FAIL: token`); without one it uses `gh auth token --user rodgallert`. It never switches
# gh accounts. It is not run in CI: the settings endpoints need
# an admin token, which the workflow's token never has.
#
# Environment:
#   REPO_SETTINGS_REF  branch or commit whose CODEOWNERS is read (default: the default branch). Use it to check the file
#                      from a ticket branch before it is merged.
#   TICKET_SLEEP, TICKET_TIMEOUT  see tools/gh-lib.sh (the tests override them)
{ set +x; } 2>/dev/null # a caller's xtrace must never print the token
set -uo pipefail

GH_LIB_NAME="check-repo-settings.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/gh-lib.sh
. "$here/gh-lib.sh"
min_gh=2.97.0
owner=rodgallert
repo="repos/$GH_LIB_REPO"
usage="usage: tools/check-repo-settings.sh (no arguments; REPO_SETTINGS_REF selects the CODEOWNERS ref)"

if [ $# -gt 0 ]; then
    echo "$usage" >&2
    exit 2
fi
ref="${REPO_SETTINGS_REF-}"
if [ -n "$ref" ] && ! [[ "$ref" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]]; then
    echo "$usage" >&2
    exit 2
fi

command -v jq >/dev/null 2>&1 || die "jq is missing: install jq"
command -v gh >/dev/null 2>&1 || die "gh is missing: install the GitHub CLI (version $min_gh or newer)"
version=$(gh --version 2>/dev/null | head -1 | awk '{print $3}')
if [ -z "$version" ] || [ "$(printf '%s\n%s\n' "$min_gh" "$version" | sort -V | head -1)" != "$min_gh" ]; then
    die "gh ${version:-of unknown version} is older than $min_gh: upgrade the GitHub CLI"
fi
export GH_HOST=github.com
if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN=$(gh auth token --user "$owner" --hostname github.com 2>/dev/null) && [ -n "$GH_TOKEN" ] ||
        die "gh has no login for $owner: gh auth login --skip-ssh-key"
    export GH_TOKEN
else
    export GH_TOKEN
    # a token given in the environment must be the owner's, as in gh_init (tools/gh-lib.sh)
    if ! gh_call "check the token's account" gh api user || ! login=$(jq -er '.login' <<<"$GH_OUT" 2>/dev/null); then
        echo "FAIL: token: cannot read"
        exit 1
    fi
    if [ "$login" != "$owner" ]; then
        echo "FAIL: token: not the $owner account's"
        exit 1
    fi
fi

failures=0
pass() { echo "ok: $1"; }
fail() { # <name> <value read>
    failures=$((failures + 1))
    echo "FAIL: $1: $2"
}
# check <name> <value read> <expected>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "${2:-(empty)}"; fi; }
# api <path> [gh api args...]: GH_OUT, returns 1 when unreadable (GH_KIND says why)
api() { local p="$1"; shift; gh_call "read $p" gh api "$@" "$p"; }

# ---- fork pull request approval ---------------------------------------------------------------------------------
if api "$repo/actions/permissions/fork-pr-contributor-approval" && policy=$(jq -er '.approval_policy // ""' <<<"$GH_OUT" 2>/dev/null); then
    check fork-approval "$policy" all_external_contributors
else
    fail fork-approval "cannot read"
fi

# ---- Dependabot ---------------------------------------------------------------------------------------------------
if api "$repo/vulnerability-alerts"; then
    pass dependabot-alerts
elif [ "$GH_KIND" = notfound ]; then
    fail dependabot-alerts disabled
else
    fail dependabot-alerts "cannot read"
fi
if api "$repo/automated-security-fixes" && enabled=$(jq -er '(.enabled | tostring) + " " + (.paused | tostring)' <<<"$GH_OUT" 2>/dev/null); then
    case "$enabled" in
        "true false") pass dependabot-security-updates ;;
        "true true") fail dependabot-security-updates paused ;;
        "false "*) fail dependabot-security-updates false ;;
        *) fail dependabot-security-updates "(missing)" ;;
    esac
else
    fail dependabot-security-updates "cannot read"
fi

# ---- rulesets -----------------------------------------------------------------------------------------------------
check_ruleset() { # <name> <expected ref include> (both rulesets must also dismiss stale reviews on push)
    local name="$1" include="$2" id body gate pr val n
    if [ -z "$rulesets" ]; then
        fail "ruleset $name" "cannot read"
        return
    fi
    n=$(jq -r --arg n "$name" '[.[] | select(.name == $n)] | length' <<<"$rulesets")
    if [ "$n" -gt 1 ]; then
        fail "ruleset $name" "duplicate name ($n rulesets)"
        return
    fi
    id=$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .id][0] // empty' <<<"$rulesets")
    if [ -z "$id" ]; then
        fail "ruleset $name" "not found"
        return
    fi
    if ! api "$repo/rulesets/$id" || ! body=$(jq -e . <<<"$GH_OUT" 2>/dev/null); then
        fail "ruleset $name" "cannot read"
        return
    fi
    check "ruleset $name: enforcement" "$(jq -r '.enforcement | tostring' <<<"$body")" active
    check "ruleset $name: target" "$(jq -r '.target | tostring' <<<"$body")" branch
    val=$(jq -c '.conditions.ref_name // {} | if .include != [$i] then (.include | tostring) elif (.exclude // []) != [] then "exclude " + (.exclude | tostring) else "ok" end' --arg i "$include" <<<"$body")
    val=$(jq -r . <<<"$val")
    check "ruleset $name: conditions" "$val" ok
    check "ruleset $name: bypass_actors" "$(jq -r '(.bypass_actors // []) | length' <<<"$body")" 0
    gate=$(jq -c '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == "gate")][0] // empty' <<<"$body")
    if [ -z "$gate" ]; then
        fail "ruleset $name: required status check gate" missing
    else
        pass "ruleset $name: required status check gate"
        val=$(jq -r '.integration_id // empty' <<<"$gate")
        if [ "$val" = 15368 ]; then pass "ruleset $name: gate integration_id"; else fail "ruleset $name: gate integration_id" "${val:-(none)}"; fi
        check "ruleset $name: strict_required_status_checks_policy" \
            "$(jq -r '[.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy][0] | tostring' <<<"$body")" true
    fi
    pr=$(jq -c '[.rules[]? | select(.type == "pull_request") | .parameters][0] // empty' <<<"$body")
    if [ -z "$pr" ]; then
        fail "ruleset $name: pull_request rule" missing
        return
    fi
    check "ruleset $name: required_approving_review_count" "$(jq -r '.required_approving_review_count | tostring' <<<"$pr")" 0
    check "ruleset $name: require_code_owner_review" "$(jq -r '.require_code_owner_review | tostring' <<<"$pr")" false
    check "ruleset $name: require_last_push_approval" "$(jq -r '.require_last_push_approval | tostring' <<<"$pr")" false
    check "ruleset $name: dismiss_stale_reviews_on_push" "$(jq -r '.dismiss_stale_reviews_on_push | tostring' <<<"$pr")" true
}
rulesets=""
if api "$repo/rulesets?per_page=100" && jq -e 'type == "array"' <<<"$GH_OUT" >/dev/null 2>&1; then rulesets="$GH_OUT"; fi
check_ruleset "Protect main" "~DEFAULT_BRANCH"
check_ruleset "Release branches" "refs/heads/release/**"

# ---- CODEOWNERS ---------------------------------------------------------------------------------------------------
q="${ref:+?ref=$ref}"
lbl="codeowners${ref:+ (ref $ref)}"
if api "$repo/codeowners/errors$q" && n=$(jq -er '.errors | if type == "array" then length else empty end' <<<"$GH_OUT" 2>/dev/null); then
    check "codeowners errors${ref:+ (ref $ref)}" "$n" 0
elif [ "${GH_KIND:-}" = ok ]; then
    fail "codeowners errors${ref:+ (ref $ref)}" "(no errors list)"
else
    fail "codeowners errors${ref:+ (ref $ref)}" "cannot read"
fi
# GitHub applies the last line that matches a path, so the owner of a guarded path is the owner on the last line that
# covers it: the same path, a parent (a glob like *, or a directory), or a path inside it.
codeowners_effective() { # stdin: the file. Prints, per guarded path, "ok|<path>" or "fail|<path>|<last matching line>"
    awk -v o="@$owner" '
        BEGIN { n = split("/.github/ /tools/ /docker-compose.prod.yml /Docs/workflow.md", P, " ") }
        { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
        /^[ \t]*(#|$)/ { next }
        {
            pat = $1
            if (pat !~ /^\// && pat !~ /\*/) pat = "/" pat
            for (i = 1; i <= n; i++) {
                p = P[i]; q = p; sub(/\/$/, "", q)
                if (pat == p || pat == q || pat == "*" || pat == "**" || pat == "/" || pat == "/*" || pat == "/**" ||
                    substr(pat, 1, length(p)) == p || (pat ~ /\/$/ && index(p, pat) == 1)) last[i] = $0
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                found = 0; m = split(last[i], F, /[ \t]+/)
                for (k = 2; k <= m; k++) if (F[k] == o) found = 1
                if (found) print "ok|" P[i]; else print "fail|" P[i] "|" (last[i] == "" ? "none" : last[i])
            }
        }'
}
if api "$repo/contents/.github/CODEOWNERS$q" -H "Accept: application/vnd.github.raw+json"; then
    while IFS='|' read -r res path line; do
        if [ "$res" = ok ]; then pass "$lbl: $path"; else fail "$lbl: $path" "last matching line is \`$line\`"; fi
    done < <(codeowners_effective <<<"$GH_OUT")
else
    fail "$lbl" "cannot read"
fi

[ "$failures" = 0 ]
