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
#   ruleset <name>: ...           "Protect main" and "Release branches": required status check gate from GitHub
#                                 Actions (integration_id 15368), no required approvals, no required code owner
#                                 review, no required last-push approval; "Protect main" also dismisses stale reviews
#   codeowners ...                .github/CODEOWNERS has no errors and names the owner for the guarded paths
#
# Needs only bash, gh and jq (gh 2.97.0 or newer), and an admin token for the repository (the owner's: GH_TOKEN if set, else
# `gh auth token --user rodgallert`; it never switches gh accounts). It is not run in CI: the settings endpoints need
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
fi
export GH_TOKEN

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
check_ruleset() { # <name> <must dismiss stale reviews: yes|no>
    local name="$1" dismiss="$2" id body gate pr val
    if [ -z "$rulesets" ]; then
        fail "ruleset $name" "cannot read"
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
    gate=$(jq -c '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == "gate")][0] // empty' <<<"$body")
    if [ -z "$gate" ]; then
        fail "ruleset $name: required status check gate" missing
    else
        pass "ruleset $name: required status check gate"
        val=$(jq -r '.integration_id // empty' <<<"$gate")
        if [ "$val" = 15368 ]; then pass "ruleset $name: gate integration_id"; else fail "ruleset $name: gate integration_id" "${val:-(none)}"; fi
    fi
    pr=$(jq -c '[.rules[]? | select(.type == "pull_request") | .parameters][0] // empty' <<<"$body")
    if [ -z "$pr" ]; then
        fail "ruleset $name: pull_request rule" missing
        return
    fi
    check "ruleset $name: required_approving_review_count" "$(jq -r '.required_approving_review_count | tostring' <<<"$pr")" 0
    check "ruleset $name: require_code_owner_review" "$(jq -r '.require_code_owner_review | tostring' <<<"$pr")" false
    check "ruleset $name: require_last_push_approval" "$(jq -r '.require_last_push_approval | tostring' <<<"$pr")" false
    if [ "$dismiss" = yes ]; then
        check "ruleset $name: dismiss_stale_reviews_on_push" "$(jq -r '.dismiss_stale_reviews_on_push | tostring' <<<"$pr")" true
    fi
}
rulesets=""
if api "$repo/rulesets" && jq -e 'type == "array"' <<<"$GH_OUT" >/dev/null 2>&1; then rulesets="$GH_OUT"; fi
check_ruleset "Protect main" yes
check_ruleset "Release branches" no

# ---- CODEOWNERS ---------------------------------------------------------------------------------------------------
q="${ref:+?ref=$ref}"
if api "$repo/codeowners/errors$q" && n=$(jq -er '.errors | if type == "array" then length else empty end' <<<"$GH_OUT" 2>/dev/null); then
    check "codeowners errors" "$n" 0
elif [ "${GH_KIND:-}" = ok ]; then
    fail "codeowners errors" "(no errors list)"
else
    fail "codeowners errors" "cannot read"
fi
if api "$repo/contents/.github/CODEOWNERS$q" -H "Accept: application/vnd.github.raw+json"; then
    for p in /.github/ /tools/ /docker-compose.prod.yml /Docs/workflow.md; do
        if awk -v p="$p" -v o="@$owner" '$1 == p { for (i = 2; i <= NF; i++) if ($i == o) found = 1 } END { exit !found }' <<<"$GH_OUT"; then
            pass "codeowners: $p"
        else
            fail "codeowners: $p" "no owner @$owner"
        fi
    done
else
    fail "codeowners" "cannot read"
fi

[ "$failures" = 0 ]
