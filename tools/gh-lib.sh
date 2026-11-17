# shellcheck shell=bash
# Shared by tools/ticket.sh (and the scripts that follow it): the owner's token, the number check and one wrapper for
# every gh call that adds a timeout, retries and a failure line. Sourced, never run.
#
# Minimum gh version: 2.40.0 (gh api --input, gh issue develop and gh auth token --user).
#
# Environment (the tests override these):
#   TICKET_SLEEP    command that waits for the given seconds (default sleep)
#   TICKET_TIMEOUT  seconds a single gh call may take (default 30)
#   TICKET_LOCK_DIR where the per-issue lock files live (default ~/.cache/elysium)
#
# The GitHub GraphQL quota (5,000 an hour) is shared by every tool and agent: callers read in batches (one issue read,
# one comment list), use REST where GraphQL isn't needed, never poll in a loop, and this wrapper waits out a rate limit
# (Retry-After or the reset time, at most 60 s, three retries) instead of calling again at once.
set +x # a caller's xtrace (set -x, SHELLOPTS) must never print the token
GH_LIB_OWNER=rodgallert
# shellcheck disable=SC2034 # used by the scripts that source this file
GH_LIB_REPO=rodgallert/Elysium
GH_LIB_MIN_VERSION=2.40.0
GH_LIB_NAME="${GH_LIB_NAME:-ticket.sh}"
TICKET_SLEEP="${TICKET_SLEEP:-sleep}"
TICKET_TIMEOUT="${TICKET_TIMEOUT:-30}"
GH_OUT=""
GH_KIND=""
GH_MSG=""
GH_VERIFY=""

die() { # one line on stderr, exit 1
    echo "$GH_LIB_NAME: $*" >&2
    exit 1
}

# valid_number <value>: an issue or PR number, 1 to 9999999 with no leading zero
valid_number() { [[ "${1-}" =~ ^[1-9][0-9]{0,6}$ ]]; }

# gh_init: checks the tools, then sets GH_TOKEN to the owner's token without switching accounts or reading the active
# account's token. A GH_TOKEN already in the environment is accepted only if it belongs to the owner.
gh_init() {
    command -v jq >/dev/null 2>&1 || die "jq is missing: install jq"
    command -v gh >/dev/null 2>&1 || die "gh is missing: install the GitHub CLI (version $GH_LIB_MIN_VERSION or newer)"
    local version
    version=$(gh --version 2>/dev/null | head -1 | awk '{print $3}')
    if [ -z "$version" ] || [ "$(printf '%s\n%s\n' "$GH_LIB_MIN_VERSION" "$version" | sort -V | head -1)" != "$GH_LIB_MIN_VERSION" ]; then
        die "gh ${version:-of unknown version} is older than $GH_LIB_MIN_VERSION: upgrade the GitHub CLI"
    fi
    if [ -n "${GH_TOKEN:-}" ]; then
        export GH_TOKEN
        gh_call "check the token's account" gh api user -q .login || die "$GH_MSG"
        [ "$GH_OUT" = "$GH_LIB_OWNER" ] || die "GH_TOKEN is not the $GH_LIB_OWNER account's: unset it to use the $GH_LIB_OWNER login"
    else
        GH_TOKEN=$(gh auth token --user "$GH_LIB_OWNER" 2>/dev/null) && [ -n "$GH_TOKEN" ] ||
            die "gh has no login for $GH_LIB_OWNER: gh auth login --skip-ssh-key -s project"
        export GH_TOKEN
    fi
}

# gh_call <step> <command...>: runs the command (gh, or a script that calls gh) with a timeout and retries a 5xx, a rate
# limit or a timeout up to 3 times (2 s, 4 s, 8 s, or the Retry-After / reset time, at most 60 s). On success GH_OUT holds
# stdout. On failure it returns 1 with GH_KIND (notfound, perm, ratelimit, server, timeout, other) and GH_MSG, one line
# naming the step and the HTTP status, never the token or the request. A function named in GH_VERIFY is run before each
# retry: when it succeeds the earlier attempt did take effect and the call counts as done (no duplicate writes).
gh_call() {
    local step="$1" attempt=0 rc text status wait ra reset errf verify="$GH_VERIFY"
    shift
    GH_VERIFY=""
    errf=$(mktemp) || die "mktemp failed"
    while :; do
        GH_OUT=$(timeout -k 2 "$TICKET_TIMEOUT" "$@" 2>"$errf" </dev/null)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -f "$errf"
            GH_KIND=ok
            return 0
        fi
        text="$(cat "$errf")
$GH_OUT"
        status=$(grep -oE 'HTTP [0-9]{3}' <<<"$text" | head -1 | cut -d' ' -f2)
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            GH_KIND=timeout
        elif [[ "$status" =~ ^5[0-9][0-9]$ ]]; then
            GH_KIND=server
        elif [ "$status" = 403 ] || [ "$status" = 429 ]; then
            if grep -qiE 'rate limit|retry-after:|x-ratelimit-remaining: *0' <<<"$text"; then GH_KIND=ratelimit; else GH_KIND=perm; fi
        elif [ "$status" = 404 ]; then
            GH_KIND=notfound
        else
            GH_KIND=other
        fi
        if { [ "$GH_KIND" = server ] || [ "$GH_KIND" = ratelimit ] || [ "$GH_KIND" = timeout ]; } && [ "$attempt" -lt 3 ]; then
            wait=$((2 << attempt))
            if [ "$GH_KIND" = ratelimit ]; then
                ra=$(grep -iE '^retry-after:' <<<"$text" | head -1 | sed -E 's/^[^:]*: *//; s/[[:space:]]*$//')
                reset=$(grep -iE '^x-ratelimit-reset:' <<<"$text" | head -1 | sed -E 's/^[^:]*: *//; s/[[:space:]]*$//')
                if [[ "$ra" =~ ^[0-9]+$ ]]; then
                    wait=$ra
                elif [[ "$reset" =~ ^[0-9]+$ ]] && [ $((reset - $(date +%s))) -ge 1 ]; then
                    wait=$((reset - $(date +%s)))
                fi
            fi
            [ "$wait" -le 60 ] || wait=60
            "$TICKET_SLEEP" "$wait"
            attempt=$((attempt + 1))
            if [ -n "$verify" ] && "$verify"; then
                rm -f "$errf"
                GH_KIND=ok
                GH_OUT=""
                return 0
            fi
            continue
        fi
        rm -f "$errf"
        case "$GH_KIND" in
            notfound) GH_MSG="$step: not found (HTTP 404)" ;;
            perm) GH_MSG="$step: permission denied (HTTP 403), not retried" ;;
            ratelimit) GH_MSG="$step: rate limited (HTTP $status) after $((attempt + 1)) attempts" ;;
            server) GH_MSG="$step: failed (HTTP $status) after $((attempt + 1)) attempts" ;;
            timeout) GH_MSG="$step: timed out after ${TICKET_TIMEOUT}s ($((attempt + 1)) attempts)" ;;
            *) GH_MSG="$step: failed (exit $rc${status:+, HTTP $status})" ;;
        esac
        return 1
    done
}

# must <step> <command...>: gh_call that stops the script with the failure line
must() { gh_call "$@" || die "$GH_MSG"; }

# lock_issue <n>: one script at a time per issue (the lock lasts until the script exits); other issues are not held up
lock_issue() {
    local dir="${TICKET_LOCK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/elysium}"
    (umask 077 && mkdir -p "$dir") || die "cannot create the lock directory $dir"
    exec 9>"$dir/issue-$1.lock"
    flock -w 120 9 || die "issue #$1 is busy: another run holds its lock"
}
