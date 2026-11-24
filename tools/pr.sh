#!/usr/bin/env bash
set +x # a caller's xtrace must never print the token
# Pull request checks and review verdicts (.claude/skills/ticket-flow/SKILL.md "review", .claude/skills/pr-review/SKILL.md),
# read-only for status and idempotent for verdict.
#
# Usage: tools/pr.sh status <pr>
#        tools/pr.sh status --branch <name>
#        tools/pr.sh verdict <pr> <approve|changes|comment> --body-file <file> --sha <sha>
# Exit codes: 0 ready, or review posted, 1 not ready or failure (the last line says which fact or step), 2 usage.
# Needs gh (see tools/gh-lib.sh for the minimum version) logged in as the repo owner, and jq. It uses only the owner's
# token (never the active account's, never gh auth switch).
#
# status prints one line per fact, in this order, then "ready" or "not ready: <first failing fact>":
#   state, base, head (branch), sha, tip (does the head SHA equal the branch tip on GitHub), up-to-date (is the head
#   based on the base's tip), gate (the required check's conclusion on that SHA), closes (does a "Closes #<n>" line start
#   the body). Every fact is read before anything is printed, and the head SHA is read again at the end: a push in
#   between exits 1 ("head moved") and prints nothing. The tip is the exact branch of the PR's head repository, so a
#   fork's same-named branch is never confused with a branch here; refnames are matched exactly, never by prefix.
# verdict posts one review with the body read from a file; --sha must be the PR's head (the commit that was reviewed).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_LIB_NAME=pr.sh
# shellcheck source=tools/gh-lib.sh
. "$here/gh-lib.sh"

repo="$GH_LIB_REPO"
max_body=65536
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

usage() {
    echo "Usage: pr.sh status <pr> | status --branch <name> | verdict <pr> <approve|changes|comment> --body-file <file> --sha <sha>" >&2
    exit 2
}
say() { printf '%s\n' "$*"; }

# valid_ref <name>: a branch name that is safe to put in a path and a query: 1 to 255 of letters, digits and . _ / -,
# no leading dash or slash, no "..", no "//", no trailing slash or ".lock", no component starting with ".", no "refs/" prefix,
# no "/refs/" inside
valid_ref() {
    local n="${1-}"
    [ "${#n}" -ge 1 ] && [ "${#n}" -le 255 ] || return 1
    [[ "$n" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || return 1
    [[ "$n" != *..* && "$n" != *//* && "$n" != */ && "$n" != *.lock && "$n" != .* && "$n" != */.* && "$n" != refs/* && "$n" != */refs/* ]]
}
valid_sha() { [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]; }
valid_repo() { [[ "${1-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# ---- reads ---------------------------------------------------------------------------------------------------------------

read_pr() { # <n>: PR (json) from the REST pull
    must "read PR #$1" gh api "repos/$repo/pulls/$1"
    PR="$GH_OUT"
    jq -e 'type == "object" and (.number | type == "number")' <<<"$PR" >/dev/null || die "read PR #$1: unexpected answer"
}
pr_state() { jq -r 'if .merged == true then "merged" else .state end' <<<"$PR"; }

# resolve_branch <name>: the number of the PR whose head is exactly this branch of this repository (sets PR_NUMBER)
resolve_branch() {
    local name="$1" open count nums
    must "list the open PRs" gh api "repos/$repo/pulls?state=open&per_page=100" --paginate
    open="$(jq -s -c --arg b "$name" 'add // [] | map(select(.head.ref == $b) | {number, repo: (.head.repo.full_name // "")})' <<<"$GH_OUT")"
    count="$(jq length <<<"$open")"
    if [ "$count" -ge 2 ]; then
        nums="$(jq -r 'map("#" + (.number | tostring)) | join(" and ")' <<<"$open")"
        die "two open PRs have the head branch $name: $nums"
    fi
    if [ "$count" -eq 1 ]; then
        if [ "$(jq -r '.[0].repo' <<<"$open")" = "$repo" ]; then
            PR_NUMBER="$(jq -r '.[0].number' <<<"$open")"
            return 0
        fi
        die "no PR for $name: the only open PR with this head branch is #$(jq -r '.[0].number' <<<"$open"), from another repository"
    fi
    must "list the closed PRs of $name" gh api "repos/$repo/pulls?state=closed&head=$GH_LIB_OWNER:$name&per_page=100" --paginate
    PR_NUMBER="$(jq -s -r --arg b "$name" --arg r "$repo" 'add // [] | map(select(.head.ref == $b and .head.repo.full_name == $r) | .number) | max // empty' <<<"$GH_OUT")"
    [ -n "$PR_NUMBER" ] || die "no PR for $name: no open or closed PR has this head branch in $repo"
}

# ---- status --------------------------------------------------------------------------------------------------------------

# read_tip: TIPSHA is the SHA of the exact branch $ref in the head repository $hrepo, empty when it has none
read_tip() {
    TIPSHA=""
    [ -n "$hrepo" ] || return 0
    if gh_call "read the tip of $ref" gh api "repos/$hrepo/git/ref/heads/$ref"; then
        TIPSHA="$(jq -r --arg r "refs/heads/$ref" 'select(type == "object" and .ref == $r) | .object.sha // empty' <<<"$GH_OUT")"
        valid_sha "$TIPSHA" || TIPSHA=""
    elif [ "$GH_KIND" != notfound ]; then
        die "$GH_MSG"
    fi
}

cmd_status() {
    local n="$1" state base ref sha hrepo body first tip first_tip behind gate runs closes fail="" TIPSHA=""
    read_pr "$n"
    state="$(pr_state)"
    base="$(jq -r '.base.ref // ""' <<<"$PR")"
    ref="$(jq -r '.head.ref // ""' <<<"$PR")"
    sha="$(jq -r '.head.sha // ""' <<<"$PR")"
    hrepo="$(jq -r '.head.repo.full_name // ""' <<<"$PR")"
    body="$(jq -j '.body // ""' <<<"$PR")"
    # nothing from the PR's data reaches a path or a query before it is checked
    valid_ref "$base" || die "PR #$n: its base branch is not a safe branch name, refusing to use it"
    valid_ref "$ref" || die "PR #$n: its head branch is not a safe branch name, refusing to use it"
    valid_sha "$sha" || die "PR #$n: its head SHA is not 40 hex digits"

    # the tip of the head branch in the head repository (an exact ref, never a prefix match)
    if [ -n "$hrepo" ] && ! valid_repo "$hrepo"; then
        die "PR #$n: its head repository name is not safe, refusing to use it"
    fi
    read_tip
    if [ -z "$TIPSHA" ]; then
        tip=missing
    elif [ "$TIPSHA" = "$sha" ]; then
        tip=equal
    else
        tip="differs (remote $TIPSHA)"
    fi
    first_tip="$TIPSHA"
    if [ "$hrepo" != "$repo" ] && [ "$tip" != missing ]; then tip="$tip (fork $hrepo)"; fi

    # the base by its full refname: a tag with the base's name must not decide what the head is compared with
    must "compare the head with its base" gh api "repos/$repo/compare/refs/heads/$base...$sha"
    behind="$(jq -r '.behind_by // empty' <<<"$GH_OUT")"
    [[ "$behind" =~ ^[0-9]+$ ]] || die "compare the head with its base: unexpected answer"

    # the gate is the check run named gate of GitHub Actions (app 15368) in a run of build.yml on this commit; every such
    # run must have succeeded, so another workflow's job with the same name can neither add nor hide a failure
    must "read the build workflow's runs on the head" gh api "repos/$repo/actions/workflows/build.yml/runs?head_sha=$sha&per_page=100" --paginate
    runs="$(jq -s -c '[.[].workflow_runs[]?.id]' <<<"$GH_OUT")" || die "read the build workflow's runs on the head: unexpected answer"
    must "read the checks of the head" gh api "repos/$repo/commits/$sha/check-runs?per_page=100" --paginate
    gate="$(jq -s -r --arg sha "$sha" --argjson runs "$runs" '
        def runid: ((.details_url // "") | capture("/actions/runs/(?<r>[0-9]+)/") | .r | tonumber)?;
        [.[].check_runs[]? | select(.name == "gate" and (.app.id // 0) == 15368 and .head_sha == $sha and (runid as $r | any($runs[]; . == $r)))] as $g
        | ([$g[] | select(.status == "completed" and .conclusion != "success")] | first) as $bad
        | if ($g | length) == 0 then "none"
          elif $bad != null then ($bad.conclusion // "failure")
          elif any($g[]; .status != "completed") then "pending"
          else "success" end' <<<"$GH_OUT")"
    [ -n "$gate" ] || die "read the checks of the head: unexpected answer"

    first="${body%%$'\n'*}"
    first="${first%$'\r'}"
    if [[ "$first" =~ ^Closes\ \#[1-9][0-9]{0,6}[[:space:]]*$ ]]; then closes=yes; else closes=no; fi

    # a push since the first read: the facts above may belong to two different commits
    read_pr "$n"
    [ "$(jq -r '.head.sha // ""' <<<"$PR")" = "$sha" ] || die "head moved: PR #$n has a new head since it was read, run again"
    read_tip
    [ "$TIPSHA" = "$first_tip" ] || die "head moved: the branch $ref changed since it was read, run again"

    if [ "$state" != open ]; then
        fail="state is $state"
    elif [ "$hrepo" != "$repo" ]; then
        fail="head is a fork"
    elif [ "$tip" != equal ]; then
        fail="head differs from the branch tip"
    elif [ "$behind" -gt 0 ]; then
        fail="branch is behind $base"
    elif [ "$gate" != success ]; then
        fail="gate is $gate"
    elif [ "$closes" != yes ]; then
        fail="no Closes line at the start of the body"
    fi
    [ -z "${BRANCH_MODE:-}" ] || say "pr: $n"
    say "state: $state"
    say "base: $base"
    say "head: $ref"
    say "sha: $sha"
    say "tip: $tip"
    if [ "$behind" -eq 0 ]; then say "up-to-date: yes"; else say "up-to-date: no (behind $behind)"; fi
    say "gate: $gate"
    say "closes: $closes"
    if [ -z "$fail" ]; then
        say ready
        return 0
    fi
    say "not ready: $fail"
    return 1
}

# ---- verdict -------------------------------------------------------------------------------------------------------------

V_N="" V_EVENT="" V_SHA="" V_FILE="" V_URL=""
# match_reviews <json>: sets V_URL to the URL of this account's review of V_N with the same verdict, on the same commit and
# with the same whole body (line ends and trailing whitespace normalised)
match_reviews() {
    V_URL="$(jq -s -r --arg o "$GH_LIB_OWNER" --arg ev "$V_EVENT" --arg c "$V_SHA" --rawfile f "$V_FILE" '
        def norm: (. // "") | gsub("\r\n"; "\n") | gsub("\r"; "\n") | split("\n") | map(sub("[ \t]+$"; "")) | join("\n") | sub("^\n+"; "") | sub("\n+$"; "");
        add // [] | map(select(.user.login == $o and .state == $ev and .commit_id == $c and (.body | norm) == ($f | norm))) | last | .html_url // empty' <<<"$1")"
    [ -n "$V_URL" ]
}
# find_review: the same, reading the reviews itself (one try, no retries): 0 found, 1 none, 2 could not read
find_review() {
    local out
    out=$(timeout -k 2 "$TICKET_TIMEOUT" gh api "repos/$repo/pulls/$V_N/reviews?per_page=100" --paginate 2>/dev/null </dev/null) || return 2
    match_reviews "$out"
}

cmd_verdict() {
    local n="$1" verdict="$2" file="$3" sha="$4" chars event lockdir
    case "$verdict" in
        approve) event=APPROVE V_EVENT=APPROVED ;;
        changes) event=REQUEST_CHANGES V_EVENT=CHANGES_REQUESTED ;;
        comment) event=COMMENT V_EVENT=COMMENTED ;;
    esac
    chars="$(LC_ALL=C.UTF-8 wc -m <"$file" | tr -d ' ')"
    if [ "$chars" -gt "$max_body" ]; then
        echo "pr.sh: the body has $chars characters; GitHub accepts at most $max_body" >&2
        exit 1
    fi
    # a line that is a tool attribution, however decorated (Markdown emphasis, quote, list, HTML tag, robot emoji)
    if LC_ALL=C grep -qiE '^([[:space:]>*_~+#|`-]|<[^>]*>|🤖)*(Generated with|Co-Authored-By[[:space:]]*:)' "$file"; then
        echo "pr.sh: the body has a tool-attribution line (Generated with, Co-Authored-By): remove it" >&2
        exit 1
    fi
    gh_init
    lockdir="${TICKET_LOCK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/elysium}"
    (umask 077 && mkdir -p "$lockdir") || die "cannot create the lock directory $lockdir"
    exec 9>"$lockdir/pr-$n.lock"
    flock -w 120 9 || die "PR #$n is busy: another run holds its lock"

    read_pr "$n"
    case "$(pr_state)" in
        open) ;;
        *) die "PR #$n is $(pr_state): no review is posted on it" ;;
    esac
    [ "$(jq -r '.head.sha // ""' <<<"$PR")" = "$sha" ] || die "head moved: PR #$n has head $(jq -r '.head.sha // ""' <<<"$PR"), not $sha"

    V_N="$n" V_SHA="$sha" V_FILE="$file"
    gh_call "list the reviews of #$n" gh api "repos/$repo/pulls/$n/reviews?per_page=100" --paginate || die "$GH_MSG"
    if match_reviews "$GH_OUT"; then
        say "already posted: $V_URL"
        return 0
    fi

    read_pr "$n" # right before the call: a push since the first read stops the review
    [ "$(jq -r '.head.sha // ""' <<<"$PR")" = "$sha" ] || die "head moved: PR #$n has a new head since the review started, nothing was posted"

    # the review is attached to the reviewed commit (commit_id), and the body reaches gh only inside a request file
    jq -n --rawfile b "$file" --arg c "$sha" --arg e "$event" '{commit_id: $c, event: $e, body: $b}' >"$tmp/review.json" || die "cannot build the review request"
    GH_VERIFY=find_review
    if gh_call "post the review on #$n" gh api -X POST "repos/$repo/pulls/$n/reviews" --input "$tmp/review.json"; then
        V_URL="$(jq -r '.html_url // empty' <<<"$GH_OUT" 2>/dev/null)"
        [ -n "$V_URL" ] || find_review || V_URL=""
    else
        if grep -qi 'own pull request' <<<"$GH_ERR"; then
            die "GitHub refused the review: ${GH_ERR%% }"
        fi
        # the review may have been posted although the call failed (the last attempt's answer lost): look before saying so
        find_review
        case $? in
            0)
                say "review: $V_URL"
                return 0
                ;;
            2) die "$GH_MSG; could not check whether the review exists on #$n" ;;
        esac
        die "$GH_MSG; no review with this body exists on #$n"
    fi
    say "review: ${V_URL:-posted}"
}

# ---- entry ---------------------------------------------------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
    status)
        BRANCH_MODE=""
        if [ $# -eq 1 ] && valid_number "$1"; then
            target="$1"
        elif [ $# -eq 2 ] && [ "$1" = --branch ] && valid_ref "$2"; then
            BRANCH_MODE=1
            target="$2"
        else
            usage
        fi
        gh_init
        if [ -n "$BRANCH_MODE" ]; then
            resolve_branch "$target"
            target="$PR_NUMBER"
        fi
        cmd_status "$target"
        exit $?
        ;;
    verdict)
        if [ $# -lt 2 ] || ! valid_number "$1"; then usage; fi
        vpr="$1"
        vverdict="$2"
        shift 2
        case "$vverdict" in approve | changes | comment) ;; *) usage ;; esac
        vfile="" vsha=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --body-file) [ $# -ge 2 ] && [ -z "$vfile" ] || usage; vfile="$2" ;;
                --sha) [ $# -ge 2 ] && [ -z "$vsha" ] || usage; vsha="$2" ;;
                *) usage ;;
            esac
            shift 2
        done
        valid_sha "$vsha" || usage
        if [ -z "$vfile" ] || [ ! -f "$vfile" ] || [ ! -r "$vfile" ] || ! grep -q '[^[:space:]]' "$vfile"; then usage; fi
        cmd_verdict "$vpr" "$vverdict" "$vfile" "$vsha"
        exit $?
        ;;
    *) usage ;;
esac
