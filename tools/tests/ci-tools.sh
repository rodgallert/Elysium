#!/usr/bin/env bash
# Fixture tests for tools/ci-gate.sh and tools/ci-release-run.sh. Everything happens in a temporary directory.
# Usage: tools/tests/ci-tools.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0

check() { # name, expected exit code, actual exit code, output
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $1 (expected exit $2, got $3)"
        printf "%s\n" "    ${4//$'\n'/$'\n    '}"
    fi
}

# --- the gate -------------------------------------------------------------------------------------------------------
# needs JSON from "job=result" words; outputs from CODE, APPS and IMAGES
needs() {
    local code="$1" apps="$2" images="$3"
    shift 3
    local json='{}' pair
    for pair in "$@"; do
        json="$(jq -c --arg j "${pair%%=*}" --arg r "${pair#*=}" '.[$j] = {result: $r, outputs: {}}' <<<"$json")"
    done
    jq -c --arg c "$code" --arg a "$apps" --arg i "$images" '
        (if has("changes") then .changes.outputs.code = $c else . end)
        | (if has("find-frontends") then ."find-frontends".outputs.apps = $a else . end)
        | (if has("find-images") then ."find-images".outputs.images = $i else . end)' <<<"$json"
}

gate() { # name, expected exit code, event, ref, needs JSON
    local out rc
    out="$(NEEDS="$5" EVENT="$3" REF="$4" "$root/tools/ci-gate.sh" 2>&1)"
    rc=$?
    check "gate: $1" "$2" "$rc" "$out"
}

all_ok=(changes=success boundaries=success dotnet=success release-checks=success find-frontends=success
    frontends=success find-images=success publish=skipped)
APPS='["Prince/Frontend/web"]'
IMAGES='[{"image":"x"}]'

gate "code PR, everything green" 0 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" "${all_ok[@]}")"
gate "Markdown-only PR, only changes ran" 0 pull_request refs/pull/1/merge "$(needs false '' '' \
    changes=success boundaries=skipped dotnet=skipped release-checks=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "dotnet failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=failure release-checks=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "frontends failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=failure \
    find-images=success publish=skipped)"
gate "a job was cancelled" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=cancelled release-checks=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "release-checks skipped by mistake" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=skipped find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "no apps: frontends skipped is fine" 0 pull_request refs/pull/1/merge "$(needs true '[]' "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=skipped \
    find-images=success publish=skipped)"
gate "apps exist but frontends skipped" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=skipped \
    find-images=success publish=skipped)"
gate "push to main: publish succeeded" 0 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=success)"
gate "push to main: publish failed" 1 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=failure)"
gate "push to main: publish skipped by mistake" 1 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "push to main with no images: publish skipped" 0 push refs/heads/main "$(needs true "$APPS" '[]' \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "push to a release branch: publish skipped" 0 push refs/heads/release/prince-0.1 "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "publish ran where it must not" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=success)"
gate "changes failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=failure boundaries=skipped dotnet=skipped release-checks=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "Markdown-only but dotnet ran" 1 pull_request refs/pull/1/merge "$(needs false '' '' \
    changes=success boundaries=skipped dotnet=success release-checks=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "a needed job is missing from needs" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success find-frontends=success frontends=success find-images=success \
    publish=skipped)"
gate "a job nobody told the gate about" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    "${all_ok[@]}" newjob=success)"
gate "changes gave no verdict" 1 pull_request refs/pull/1/merge "$(needs maybe "$APPS" "$IMAGES" "${all_ok[@]}")"

# --- Markdown-only changes ------------------------------------------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
[ "$(git -C "$repo" rev-parse --git-dir)" = .git ] || { echo "fixture repo is not isolated"; exit 1; }
commit() { git -C "$repo" add -A && git -C "$repo" commit -q -m "$1"; }
mkdir -p "$repo/docs" "$repo/src"
echo a >"$repo/README.md" && commit base
base="$(git -C "$repo" rev-parse HEAD)"

changed() { # name, expected output, base
    local out
    out="$(cd "$repo" && "$root/tools/ci-code-changed.sh" "$3" 2>&1)"
    check "changed: $1" 0 "$([ "$out" = "$2" ] && echo 0 || echo 1)" "$out"
}

echo b >"$repo/docs/notes.md" && echo c >>"$repo/README.md" && commit docs
changed "only Markdown files changed" false "$base"
echo x >"$repo/src/app.cs" && commit code
changed "a code file changed" true "$base"
changed "Markdown in an earlier commit, code in the last" true "HEAD^1"
echo y >"$repo/notes.md.txt" && commit odd
changed "a file that merely contains .md in its name" true "HEAD^1"
changed "base is not a commit" true "0000000000000000000000000000000000000000"
changed "base is not a plain revision" true "--output=x"
changed "nothing changed" true "HEAD"
git -C "$repo" mv src/app.cs src/app.md && commit rename
changed "code renamed to .md" true "HEAD^1"

# the release tooling filter in release.yml's plan job: pulled out of the workflow and run on a fixture diff
filter="$(grep -o "grep -qE '[^']*'" "$root/.github/workflows/release.yml" | sed "s/^grep -qE '//; s/'\$//")"
[ -n "$filter" ] || { echo "FAIL: release tooling filter not found in release.yml"; exit 1; }
tooling() { # name, expected (yes/no), base
    local got=no
    if (cd "$repo" && git diff --name-only --no-renames "$3" HEAD | grep -qE "$filter"); then got=yes; fi
    check "release tooling filter: $1" 0 "$([ "$got" = "$2" ] && echo 0 || echo 1)" "got $got"
}
mkdir -p "$repo/tools"
echo r >"$repo/tools/release-publish.sh" && echo o >"$repo/tools/other.sh" && commit tools
tooling "a release tool added" yes "HEAD^1"
git -C "$repo" mv tools/release-publish.sh tools/gone.sh && commit move
tooling "a release tool moved out of the list" yes "HEAD^1"
echo z >>"$repo/tools/other.sh" && commit other
tooling "an unrelated tool changed" no "HEAD^1"

# gate.needs lists every job of build.yml (and ci-gate.sh knows each of them)
jobs_in_workflow="$(awk '/^jobs:/{j=1;next} j && /^  [a-z][a-z-]*:$/{gsub(/[ :]/,"");print}' "$root/.github/workflows/build.yml" | grep -vx gate | sort | tr '\n' ' ')"
gate_needs="$(awk '/^  gate:/{g=1} g && /needs:/{gsub(/.*\[|\].*|,/," ");print;exit}' "$root/.github/workflows/build.yml" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"
known_in_script="$(sed -n 's/^known="\(.*\)"$/\1/p' "$root/tools/ci-gate.sh" | tr ' ' '\n' | sort | tr '\n' ' ')"
check "gate.needs lists every job of build.yml" 0 "$([ "$jobs_in_workflow" = "$gate_needs" ] && [ -n "$gate_needs" ] && echo 0 || echo 1)" "jobs: $jobs_in_workflow / needs: $gate_needs"
check "ci-gate.sh knows every job of build.yml" 0 "$([ "$jobs_in_workflow" = "$known_in_script" ] && echo 0 || echo 1)" "jobs: $jobs_in_workflow / script: $known_in_script"


# --- waiting for the Release workflow's run -------------------------------------------------------------------------
sha=0123456789abcdef0123456789abcdef01234567
export CI_TOOLS_TEST=1 STUB_DIR="$work/stub" POLL_INTERVAL=0
mkdir -p "$work/bin"
cp "$root/tools/tests/ci-stubs/gh" "$work/bin/gh"

release_run() { # name, expected exit code, response files as "n=json"
    local name="$1" want="$2" out rc pair
    shift 2
    rm -rf "$STUB_DIR"
    mkdir -p "$STUB_DIR"
    for pair in "$@"; do printf '%s\n' "${pair#*=}" >"$STUB_DIR/response-${pair%%=*}"; done
    out="$(PATH="$work/bin:$PATH" APPEAR_TIMEOUT="${APPEAR_TIMEOUT:-2}" TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-2}" \
        "$root/tools/ci-release-run.sh" "$sha" 2>&1)"
    rc=$?
    check "release run: $name" "$want" "$rc" "$out"
}

run() { # id, status, conclusion
    printf '[{"databaseId":%s,"status":"%s","conclusion":"%s"}]' "$1" "$2" "$3"
}

release_run "finished and green" 0 "1=$(run 1 completed success)"
release_run "finished and red" 1 "1=$(run 1 completed failure)"
release_run "cancelled" 1 "1=$(run 1 completed cancelled)"
release_run "starts late, then green" 0 "1=[]" "2=$(run 1 queued '')" \
    "3=$(run 1 in_progress '')" "4=$(run 1 completed success)"
release_run "never starts" 1 "1=[]"
release_run "never finishes" 1 "1=$(run 1 in_progress '')"
two() { # first run's conclusion, second run's conclusion
    printf '[{"databaseId":1,"status":"completed","conclusion":"%s"},{"databaseId":2,"status":"completed","conclusion":"%s"}]' "$1" "$2"
}
release_run "a re-run (a new attempt of the same run) going, then green" 0 "1=$(run 1 in_progress '')" \
    "2=$(run 1 completed success)"
release_run "another PR's green run does not cover this PR's red one" 1 "1=$(two success failure)"
release_run "a fork's red run on the same commit blocks" 1 "1=$(two failure success)"
release_run "two green runs on the same commit" 0 "1=$(two success success)"
release_run "one green run, another still going" 1 "1=$(printf '[{"databaseId":1,"status":"completed","conclusion":"success"},{"databaseId":2,"status":"in_progress","conclusion":""}]')"

out="$("$root/tools/ci-release-run.sh" 'not-a-commit' 2>&1)"
check "release run: refuses a value that is not a commit" 2 $? "$out"

echo "ci tools: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
