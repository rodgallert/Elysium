#!/usr/bin/env bash
# Waits for the Release workflow's pull request runs on a commit and succeeds only when every one succeeded.
# The Build workflow's gate calls this, so the one required check also covers the Release workflow's jobs (a gate
# can't `needs` a job of another workflow). Usage: tools/ci-release-run.sh <PR head commit>
# Needs gh with GH_TOKEN and GH_REPO. Settings (seconds): APPEAR_TIMEOUT (the run must exist by then, default 300),
# TOTAL_TIMEOUT (it must be finished by then, default 2400), POLL_INTERVAL (default 10).
set -euo pipefail

sha="${1:?usage: ci-release-run.sh <commit>}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "release run: not a commit hash: $sha" >&2; exit 2; }
appear="${APPEAR_TIMEOUT:-300}"
total="${TOTAL_TIMEOUT:-2400}"
interval="${POLL_INTERVAL:-10}"

start=$SECONDS
while :; do
    runs="$(gh run list --workflow release.yml --event pull_request --commit "$sha" --limit 100 \
        --json databaseId,status,conclusion)"
    # Every pull_request run on this commit must be green, not just the newest or "this PR's": another pull request
    # (the same branch into another base, or a fork's) can share the commit, and the run list can't tell them apart
    # reliably. One run is one id; re-running it makes a new attempt of the same run, and the list shows the latest.
    count="$(jq length <<<"$runs")"
    elapsed=$((SECONDS - start))
    bad="$(jq -r '[.[] | select(.status == "completed" and .conclusion != "success") | "\(.databaseId) (\(.conclusion))"] | join(", ")' <<<"$runs")"
    if [ -n "$bad" ]; then
        echo "release run: Release run(s) not green: $bad" >&2
        exit 1
    fi
    pending="$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")"
    if [ "$count" -eq 0 ]; then
        if [ "$elapsed" -ge "$appear" ]; then
            echo "release run: no Release workflow run for $sha after ${appear}s" >&2
            exit 1
        fi
        echo "release run: waiting for the Release workflow to start (${elapsed}s)"
    elif [ "$pending" -eq 0 ]; then
        echo "release run: $count Release run(s) on $sha, all succeeded"
        exit 0
    else
        if [ "$elapsed" -ge "$total" ]; then
            echo "release run: $pending Release run(s) still going after ${total}s" >&2
            exit 1
        fi
        echo "release run: $pending of $count Release run(s) still going (${elapsed}s)"
    fi
    sleep "$interval"
done
