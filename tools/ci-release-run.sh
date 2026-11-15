#!/usr/bin/env bash
# Waits for the Release workflow's pull request run on a commit and succeeds only when it succeeded.
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
    runs="$(gh run list --workflow release.yml --event pull_request --commit "$sha" --limit 30 \
        --json databaseId,status,conclusion,createdAt)"
    # The newest run counts: a re-run replaces an earlier failed one
    run="$(jq -c 'sort_by(.createdAt) | last // empty' <<<"$runs")"
    elapsed=$((SECONDS - start))
    if [ -z "$run" ]; then
        if [ "$elapsed" -ge "$appear" ]; then
            echo "release run: no Release workflow run for $sha after ${appear}s" >&2
            exit 1
        fi
        echo "release run: waiting for the Release workflow to start (${elapsed}s)"
    else
        id="$(jq -r .databaseId <<<"$run")"
        status="$(jq -r .status <<<"$run")"
        if [ "$status" = completed ]; then
            conclusion="$(jq -r .conclusion <<<"$run")"
            if [ "$conclusion" = success ]; then
                echo "release run: Release run $id succeeded"
                exit 0
            fi
            echo "release run: Release run $id concluded $conclusion" >&2
            exit 1
        fi
        if [ "$elapsed" -ge "$total" ]; then
            echo "release run: Release run $id still $status after ${total}s" >&2
            exit 1
        fi
        echo "release run: Release run $id is $status (${elapsed}s)"
    fi
    sleep "$interval"
done
