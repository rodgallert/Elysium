#!/usr/bin/env bash
set +x # a caller's xtrace must never print the token
# Issue and board bookkeeping for a ticket (.claude/skills/ticket-flow/SKILL.md, Docs/workflow.md "Specs and tests"),
# the same result every time and safe to run again: it is the only place the approval time and the spec gate are computed.
#
# Usage: tools/ticket.sh start <n>
#        tools/ticket.sh review <n> <pr>
#        tools/ticket.sh ready <n>
#        tools/ticket.sh done <n>
#        tools/ticket.sh file --title <title> --type <type> --epic <n> [--milestone <name>] --body-file <file> [--issue <n>]
# Exit codes: 0 done or already done, 1 failure (the last line says which step), 2 usage.
# Needs gh (see tools/gh-lib.sh for the minimum version) logged in as the repo owner, and jq. It uses only the owner's
# token (never the active account's, never gh auth switch) and tools/board.sh for board moves.
#
# Every step prints one line; a command ends with "ok". A run that stops half way is finished by running it again:
# each step looks at what already exists first (the Branch: and PR: lines, the branch, comments carrying a hidden
# marker) and the comment, always the last step, is what marks a command as complete.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/gh-lib.sh
. "$here/gh-lib.sh"

repo="$GH_LIB_REPO"
types="feat fix docs refactor test chore ci perf build"
# The query that reads an issue's body edit history (the only place GitHub keeps it); tests compare it with a fixture
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
edits_query='query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){issue(number:$number){userContentEdits(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{createdAt diff}}}}}'

usage() {
    echo "Usage: ticket.sh start <n> | review <n> <pr> | ready <n> | done <n> | file --title <t> --type <type> --epic <n> [--milestone <m>] --body-file <file> [--issue <n>]" >&2
    exit 2
}
say() { printf '%s\n' "$*"; }

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

# ---- the body's trailer lines ------------------------------------------------------------------------------------------

# trailer <branch|pr|approved|epic>: the value on the line, reading the body on stdin. Branch: and PR: count only at the end
# of the body (Branch: last, or followed by PR:) and never inside a code fence; Approved: may be anywhere outside a fence.
trailer() {
    awk -v key="$1" '
        { sub(/\r$/, ""); line[NR] = $0
          if ($0 ~ /^(```|~~~)/) fence = !fence
          infence[NR] = fence }
        END {
            last = NR
            while (last >= 1 && line[last] ~ /^[ \t]*$/) last--
            if (key == "epic") { if (NR >= 1 && line[1] ~ /^Epic: /) { v = line[1]; sub(/^Epic: /, "", v); print v }; exit }
            if (key == "approved") {
                for (i = 1; i <= NR; i++) if (!infence[i] && line[i] ~ /^Approved: /) { v = line[i]; sub(/^Approved: /, "", v); r = v }
                if (r != "") print r
                exit
            }
            if (last >= 1 && !infence[last] && line[last] ~ /^PR: /) {
                if (key == "pr") { v = line[last]; sub(/^PR: /, "", v); print v; exit }
                last--
                while (last >= 1 && line[last] ~ /^[ \t]*$/) last--
            }
            if (key == "branch" && last >= 1 && !infence[last] && line[last] ~ /^Branch: /) { v = line[last]; sub(/^Branch: /, "", v); print v }
        }'
}

# with_line <body> <line>: the body with the line added at the end (sets NEWBODY); a PR: line follows the Branch: line directly
with_line() {
    local body="$1"
    body="${body%"${body##*[![:space:]]}"}"
    if [[ "$2" == PR:* ]] && [[ "$(tail -1 <<<"$body")" == Branch:* ]]; then
        NEWBODY="$(printf '%s\n%s\n.' "$body" "$2")"
    else
        NEWBODY="$(printf '%s\n\n%s\n.' "$body" "$2")"
    fi
    NEWBODY="${NEWBODY%.}"
}

# valid_branch <name>: <type>/<slug> or <type>/p<n>-<slug> style names only: no leading dash, space, "..", extra slashes
valid_branch() {
    [[ "$1" =~ ^[a-z]+/[a-z0-9][a-z0-9._-]*$ ]] && [[ "$1" != *..* ]] && [[ "$1" != */refs/* ]] && [[ "$1" != *.lock ]]
}

# ---- reads and writes (REST: GraphQL's quota is shared and these need none) -----------------------------------------

read_issue() { # <n>: ISSUE (json), BODY, STATE
    must "read issue #$1" gh api "repos/$repo/issues/$1"
    ISSUE="$GH_OUT"
    jq -e 'has("pull_request") | not' <<<"$ISSUE" >/dev/null || die "#$1 is a pull request, not an issue"
    BODY="$(jq -j '.body // ""' <<<"$ISSUE")"
    STATE="$(jq -r .state <<<"$ISSUE")"
}
read_comments() { # <n>: COMMENTS (json array)
    must "read comments of #$1" gh api "repos/$repo/issues/$1/comments?per_page=100" --paginate
    COMMENTS="$(jq -s 'add // []' <<<"$GH_OUT")"
}
has_marker() { jq -e --arg m "$1" 'any(.[]; .body | contains($m))' <<<"$COMMENTS" >/dev/null; }

PATCH_NOTE=""
patch_issue() { # <n> <step> <request file>
    must "$2$PATCH_NOTE" gh api -X PATCH "repos/$repo/issues/$1" --input "$3"
}
write_body() { # <n> <exact new body>
    printf '%s' "$2" >"$tmp/body.new"
    jq -n --rawfile b "$tmp/body.new" '{body: $b}' >"$tmp/patch.json"
    patch_issue "$1" "edit the body of #$1" "$tmp/patch.json"
}

# post_once <n> <marker> <text>: one comment carrying a hidden marker line; a retry first looks for the marker, so a post
# whose answer was lost is never repeated
MARK_N=""
MARK=""
marker_posted() {
    local out
    out=$(timeout -k 2 "$TICKET_TIMEOUT" gh api "repos/$repo/issues/$MARK_N/comments?per_page=100" --paginate 2>/dev/null </dev/null) || return 1
    jq -s -e --arg m "$MARK" 'add // [] | any(.[]; .body | contains($m))' <<<"$out" >/dev/null
}
post_once() {
    if has_marker "$2"; then
        say "comment: already"
        return 0
    fi
    MARK_N="$1"
    MARK="$2"
    printf '%s\n\n%s\n' "$3" "$2" >"$tmp/comment.txt"
    jq -n --rawfile b "$tmp/comment.txt" '{body: $b}' >"$tmp/comment.json"
    GH_VERIFY=marker_posted gh_call "post the comment on #$1" gh api -X POST "repos/$repo/issues/$1/comments" --input "$tmp/comment.json" || die "$GH_MSG"
    say "comment: posted"
}

board() { # <n> <column>
    must "board move of #$1" "$here/board.sh" "$1" "$2"
    say "board: $2"
}

# ---- time and the spec gate -----------------------------------------------------------------------------------------------

# norm_time <time>: UTC ISO-8601 with a Z suffix, or nothing when it isn't a time
norm_time() {
    local t="$1"
    if [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        date -u -d "$t" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1 && printf '%s' "$t"
    elif [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|\.[0-9]+Z)$ ]]; then
        date -u -d "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
    fi
}

# read_edits <n>: EDITS, every userContentEdits node of the issue, newest first, following the pages to the end
read_edits() {
    local cursor="" pages=0 page
    printf '%s' "$edits_query" >"$tmp/edits.graphql"
    EDITS='[]'
    while :; do
        local -a args=(gh api graphql -F "query=@$tmp/edits.graphql" -f owner="${repo%/*}" -f name="${repo#*/}" -F "number=$1")
        [ -z "$cursor" ] || args+=(-f "cursor=$cursor")
        if ! gh_call "read the edit history of #$1" "${args[@]}"; then
            die "edit history unreadable ($GH_MSG)"
        fi
        page="$GH_OUT"
        jq -e '.data.repository.issue.userContentEdits.nodes | type == "array"' <<<"$page" >/dev/null 2>&1 || die "edit history unreadable (unexpected answer)"
        EDITS="$(jq -c --argjson p "$page" '. + $p.data.repository.issue.userContentEdits.nodes' <<<"$EDITS")"
        pages=$((pages + 1))
        [ "$(jq -r '.data.repository.issue.userContentEdits.pageInfo.hasNextPage' <<<"$page")" = true ] || break
        cursor="$(jq -r '.data.repository.issue.userContentEdits.pageInfo.endCursor // empty' <<<"$page")"
        [ -n "$cursor" ] && [ "$pages" -lt 50 ] || die "edit history unreadable (pages did not end)"
    done
}

# spec_gate <n>: refuses unless the body's Approved: line points at this issue's "Issue last edited <time>" comment, and
# no spec edit is newer than <time>. Needs ISSUE, BODY and COMMENTS. The time of the last spec edit comes only from the
# edit history (never updatedAt, not even when the history can't be read).
spec_gate() {
    local n="$1" approved cid comment text at last t
    approved="$(trailer approved <<<"$BODY")"
    [ -n "$approved" ] || die "no Approved: line: the spec needs the PO's approval (Docs/workflow.md, Specs and tests)"
    [[ "$approved" =~ ^https://github\.com/rodgallert/Elysium/issues/([1-9][0-9]{0,6})#issuecomment-([0-9]+)$ ]] ||
        die "the Approved: line is not a link to a comment of this repository"
    [ "${BASH_REMATCH[1]}" = "$n" ] || die "the Approved: line points at another issue's comment (#${BASH_REMATCH[1]})"
    cid="${BASH_REMATCH[2]}"
    comment="$(jq -c --arg id "$cid" --arg u "https://api.github.com/repos/$repo/issues/$n" \
        '[.[] | select((.id | tostring) == $id and .issue_url == $u)] | first // empty' <<<"$COMMENTS")"
    [ -n "$comment" ] || die "the Approved: comment is not a comment of #$n"
    text="$(jq -r .body <<<"$comment" | tr -d '\r')"
    [[ "$text" =~ ^Issue\ last\ edited\ ([^[:space:]]+)$ ]] || die "the Approved: comment does not read 'Issue last edited <time>'"
    at="$(norm_time "${BASH_REMATCH[1]}")"
    [ -n "$at" ] || die "the approval time '${BASH_REMATCH[1]}' is not an ISO-8601 time"

    read_edits "$n"
    last="$(norm_time "$(jq -r .created_at <<<"$ISSUE")")"
    [ -n "$last" ] || die "the issue's creation time is unreadable"
    local spec_edits
    # an edit that changes only Epic:, Approved:, Branch: or PR: lines is bookkeeping, not a spec edit
    spec_edits="$(jq -r '.[]
        | select(((.diff // "") | split("\n")
                  | map(select(test("^[+-]")) | select(test("^(\\+\\+\\+|---)") | not) | sub("^[+-]"; ""))) as $c
                 | (($c | length) > 0 and ($c | all(test("^(Epic|Approved|Branch|PR): ") or test("^[[:space:]]*$")))) | not)
        | .createdAt' <<<"$EDITS")"
    if [ -n "$spec_edits" ]; then
        last=""
        while IFS= read -r t; do
            t="$(norm_time "$t")"
            [ -n "$t" ] || die "edit history unreadable (an edit has an unreadable time)"
            [ -z "$last" ] || [[ "$t" > "$last" ]] && last="$t"
        done <<<"$spec_edits"
    fi
    if [[ "$at" < "$last" ]]; then
        die "approval older than edit at $last: the spec needs approval again"
    fi
}

# ---- commands ------------------------------------------------------------------------------------------------------------

slug_of() { # <title>: lower-case [a-z0-9-] only, without the Conventional Commits prefix
    local s="$1"
    [[ "$s" =~ ^[a-z]+(\([^\)]*\))?\!?:\ (.*)$ ]] && s="${BASH_REMATCH[2]}"
    LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$s" | LC_ALL=C tr -c 'a-z0-9' '-' | LC_ALL=C tr -s '-' | sed -E 's/^-+//; s/-+$//'
}

branch_exists() { # <name>: uses gh_call's kinds, 404 meaning "no"
    gh_call "look up branch $1" gh api "repos/$repo/git/ref/heads/$1" && return 0
    [ "$GH_KIND" = notfound ] && return 1
    die "$GH_MSG"
}
BR=""
branch_verify() { gh api "repos/$repo/git/ref/heads/$BR" >/dev/null 2>&1 </dev/null; }

cmd_start() {
    local n="$1" branch type epic phase slug title
    lock_issue "$n"
    read_issue "$n"
    read_comments "$n"
    if [ "$STATE" != open ]; then
        say "already: #$n is $STATE"
        return 0
    fi
    branch="$(trailer branch <<<"$BODY")"
    if [ -n "$branch" ]; then
        valid_branch "$branch" || die "the Branch: line of #$n is not a valid branch name"
        if has_marker "ticket.sh:started" || jq -e --arg t "Started on branch $branch." 'any(.[]; .body | startswith($t))' <<<"$COMMENTS" >/dev/null; then
            say "already started on $branch"
            return 0
        fi
    fi
    spec_gate "$n"
    if [ -z "$branch" ]; then
        type="$(jq -r '[.labels[].name | select(startswith("type: ")) | ltrimstr("type: ")] | first // empty' <<<"$ISSUE")"
        [ -n "$type" ] || die "#$n has no 'type: <type>' label"
        [[ " $types hotfix " == *" $type "* ]] || die "#$n has an unknown type label 'type: $type'"
        title="$(jq -r .title <<<"$ISSUE")"
        slug="$(slug_of "$title")"
        [ -n "$slug" ] || die "the title of #$n gives an empty branch name"
        epic="$(trailer epic <<<"$BODY")"
        phase=""
        if [[ "$epic" =~ ^#([1-9][0-9]{0,6})$ ]]; then
            if gh_call "read epic ${BASH_REMATCH[0]}" gh api "repos/$repo/issues/${BASH_REMATCH[1]}"; then
                [[ "$(jq -r .title <<<"$GH_OUT")" =~ ^Phase\ ([0-9]+) ]] && phase="${BASH_REMATCH[1]}"
            elif [ "$GH_KIND" != notfound ]; then
                die "$GH_MSG"
            fi
        fi
        if [ -n "$phase" ]; then branch="$type/p$phase-$slug"; else branch="$type/$slug"; fi
        valid_branch "$branch" || die "the branch name $branch is not valid"
    fi
    BR="$branch"
    if branch_exists "$branch"; then
        say "branch: $branch (exists)"
    else
        GH_VERIFY=branch_verify gh_call "create branch $branch" gh issue develop "$n" -R "$repo" --base main --name "$branch" || die "$GH_MSG"
        say "branch: $branch"
    fi
    if [ -z "$(trailer branch <<<"$BODY")" ]; then
        with_line "$BODY" "Branch: $branch"
        write_body "$n" "$NEWBODY"
        say "body: Branch line added"
    fi
    board "$n" "In progress"
    if jq -e 'any(.assignees[]; .login == "'"$GH_LIB_OWNER"'")' <<<"$ISSUE" >/dev/null; then
        say "assign: already"
    else
        jq -n --arg a "$GH_LIB_OWNER" '{assignees: [$a]}' >"$tmp/assign.json"
        must "assign #$n" gh api -X POST "repos/$repo/issues/$n/assignees" --input "$tmp/assign.json"
        say "assign: $GH_LIB_OWNER"
    fi
    post_once "$n" "<!-- ticket.sh:started -->" "Started on branch $branch."
    say ok
}

pr_number_of() { # <PR line value>: the number after the #
    [[ "$1" =~ ^\#([1-9][0-9]{0,6})($|[[:space:]]) ]] && printf '%s' "${BASH_REMATCH[1]}"
}

cmd_review() {
    local n="$1" pr="$2" line have
    lock_issue "$n"
    read_issue "$n"
    [ "$STATE" = open ] || die "#$n is $STATE: review needs an open issue"
    read_comments "$n"
    line="$(trailer pr <<<"$BODY")"
    if [ -n "$line" ]; then
        have="$(pr_number_of "$line")"
        [ "$have" = "$pr" ] || die "#$n already has the line 'PR: $line': refusing to add PR #$pr"
        if has_marker "ticket.sh:review:$pr"; then
            say "already in review: #$pr"
            return 0
        fi
        say "pr: PR: #$pr already there"
    else
        with_line "$BODY" "PR: #$pr"
        write_body "$n" "$NEWBODY"
        say "pr: PR: #$pr added"
    fi
    board "$n" "In review"
    post_once "$n" "<!-- ticket.sh:review:$pr -->" "In review: #$pr."
    say ok
}

cmd_ready() {
    local n="$1"
    lock_issue "$n"
    read_issue "$n"
    [ "$STATE" = open ] || die "#$n is $STATE: ready needs an open issue"
    [ -n "$(trailer pr <<<"$BODY")" ] || die "#$n has no PR: line: run review first"
    board "$n" "Ready to Merge"
    say ok
}

cmd_done() {
    local n="$1" line pr
    lock_issue "$n"
    read_issue "$n"
    read_comments "$n"
    line="$(trailer pr <<<"$BODY")"
    pr="$(pr_number_of "$line")"
    [ -n "$pr" ] || die "#$n has no PR: line: nothing to mark as done"
    if has_marker "ticket.sh:done"; then
        say "already done: #$n"
        return 0
    fi
    must "read PR #$pr" gh api "repos/$repo/pulls/$pr"
    [ "$(jq -r .merged <<<"$GH_OUT")" = true ] || die "PR #$pr is not merged: done needs a merged PR"
    board "$n" "Done"
    if [ "$STATE" = open ]; then
        jq -n '{state: "closed", state_reason: "completed"}' >"$tmp/close.json"
        patch_issue "$n" "close #$n" "$tmp/close.json"
        say "close: closed"
    else
        say "close: already closed"
    fi
    post_once "$n" "<!-- ticket.sh:done -->" "Done in #$pr."
    say ok
}

cmd_file() {
    local title="" type="" epic="" milestone="" bodyfile="" resume=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --title | --type | --epic | --milestone | --body-file | --issue)
                [ $# -ge 2 ] || usage
                case "$1" in
                    --title) title="$2" ;; --type) type="$2" ;; --epic) epic="$2" ;;
                    --milestone) milestone="$2" ;; --body-file) bodyfile="$2" ;; --issue) resume="$2" ;;
                esac
                shift 2
                ;;
            *) usage ;;
        esac
    done
    [ -n "$title" ] && [ -n "$type" ] && [ -n "$bodyfile" ] || usage
    valid_number "$epic" || usage
    [ -z "$resume" ] || valid_number "$resume" || usage
    case "$title" in *$'\n'*) echo "ticket.sh: the title must be one line" >&2; exit 2 ;; esac
    [[ " $types " == *" $type "* ]] || die "unknown type '$type' (one of: $types)"
    [ -f "$bodyfile" ] && [ -r "$bodyfile" ] || die "cannot read the body file $bodyfile"
    local first
    first="$(head -1 "$bodyfile" | tr -d '\r')"
    [ "$first" = "Epic: #$epic" ] || die "the first line of the body must be 'Epic: #$epic'"
    gh_init

    local n="$resume" url="" mnum="null"
    if [ -z "$n" ]; then
        if [ -n "$milestone" ]; then
            must "list milestones" gh api "repos/$repo/milestones?state=all&per_page=100" --paginate
            mnum="$(jq -s --arg m "$milestone" 'add // [] | [.[] | select(.title == $m) | .number] | first // empty' <<<"$GH_OUT")"
            [ -n "$mnum" ] || die "unknown milestone '$milestone'"
        fi
        printf '%s' "$title" >"$tmp/title.txt"
        jq -n --rawfile t "$tmp/title.txt" --rawfile b "$bodyfile" --arg ty "$type" --argjson m "$mnum" \
            '{title: $t, body: $b, labels: ["ticket", ("type: " + $ty)], milestone: $m}' >"$tmp/create.json"
        FILE_TITLE="$title"
        GH_VERIFY=recent_issue gh_call "create the issue" gh api -X POST "repos/$repo/issues" --input "$tmp/create.json" || die "$GH_MSG"
        [ -n "$GH_OUT" ] || GH_OUT="$RECENT"
        n="$(jq -r .number <<<"$GH_OUT")"
        url="$(jq -r .html_url <<<"$GH_OUT")"
        say "create: #$n"
    else
        must "read issue #$n" gh api "repos/$repo/issues/$n"
        url="$(jq -r .html_url <<<"$GH_OUT")"
        say "create: #$n (re-run)"
    fi
    local body replaced
    body="$(cat "$bodyfile"; printf x)"
    body="${body%x}"
    replaced="${body//'#<issue>-AC'/#$n-AC}"
    if [[ "$replaced" == *'<issue>'* ]]; then
        die "issue #$n was created ($url), but its body still has an <issue> placeholder: fix the body file and run again with --issue $n"
    fi
    if [ "$replaced" != "$body" ]; then
        PATCH_NOTE=" (issue #$n was created, $url: run again with --issue $n)"
        write_body "$n" "$replaced"
        say "body: placeholders replaced"
    fi
    say "issue: #$n $url"
    say ok
}
FILE_TITLE=""
RECENT=""
recent_issue() {
    local out
    out=$(timeout -k 2 "$TICKET_TIMEOUT" gh api "repos/$repo/issues?state=all&creator=$GH_LIB_OWNER&sort=created&direction=desc&per_page=10" 2>/dev/null </dev/null) || return 1
    RECENT="$(jq -c --arg t "$FILE_TITLE" '[.[] | select(.title == $t)] | first // empty' <<<"$out")"
    [ -n "$RECENT" ]
}

# ---- entry ---------------------------------------------------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
    start | ready | done)
        if [ $# -ne 1 ] || ! valid_number "$1"; then usage; fi
        ;;
    review)
        if [ $# -ne 2 ] || ! valid_number "$1" || ! valid_number "$2"; then usage; fi
        ;;
    file) ;;
    *) usage ;;
esac

if [ "$cmd" = file ]; then
    cmd_file "$@"
    exit $?
fi
gh_init
case "$cmd" in
    start) cmd_start "$1" ;;
    review) cmd_review "$1" "$2" ;;
    ready) cmd_ready "$1" ;;
    done) cmd_done "$1" ;;
esac
