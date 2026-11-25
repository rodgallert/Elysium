#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2181  # fixtures hold literal ${{ }} expressions; $? is read right after the command it judges
# Fixture tests for tools/ci-gate.sh, tools/ci-release-run.sh, tools/check-action-pins.sh and
# tools/check-workflow-permissions.sh (plus the pin, permission and runner rules of the repository's own workflows). Everything happens in a temporary directory.
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

all_ok=(changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success
    frontends=success find-images=success publish=skipped)
APPS='["Prince/Frontend/web"]'
IMAGES='[{"image":"x"}]'

gate "code PR, everything green" 0 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" "${all_ok[@]}")"
gate "Markdown-only PR, only changes ran" 0 pull_request refs/pull/1/merge "$(needs false '' '' \
    changes=success boundaries=skipped dotnet=skipped release-checks=skipped action-pins=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "dotnet failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=failure release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "frontends failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=failure \
    find-images=success publish=skipped)"
gate "a job was cancelled" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=cancelled release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "release-checks skipped by mistake" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=skipped action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "no apps: frontends skipped is fine" 0 pull_request refs/pull/1/merge "$(needs true '[]' "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=skipped \
    find-images=success publish=skipped)"
gate "apps exist but frontends skipped" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=skipped \
    find-images=success publish=skipped)"
gate "push to main: publish succeeded" 0 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=success)"
gate "push to main: publish failed" 1 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=failure)"
gate "push to main: publish skipped by mistake" 1 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "push to main with no images: publish skipped" 0 push refs/heads/main "$(needs true "$APPS" '[]' \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "push to a release branch: publish skipped" 0 push refs/heads/release/prince-0.1 "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=skipped)"
gate "publish ran where it must not" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success action-pins=success find-frontends=success frontends=success \
    find-images=success publish=success)"
gate "changes failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=failure boundaries=skipped dotnet=skipped release-checks=skipped action-pins=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "Markdown-only but dotnet ran" 1 pull_request refs/pull/1/merge "$(needs false '' '' \
    changes=success boundaries=skipped dotnet=success release-checks=skipped action-pins=skipped find-frontends=skipped frontends=skipped \
    find-images=skipped publish=skipped)"
gate "a needed job is missing from needs" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success find-frontends=success frontends=success find-images=success \
    publish=skipped)"
gate "a job nobody told the gate about" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    "${all_ok[@]}" newjob=success)"
gate "changes gave no verdict" 1 pull_request refs/pull/1/merge "$(needs maybe "$APPS" "$IMAGES" "${all_ok[@]}")"
# #83-AC2, #83-AC2.3 and #83-AC2.6: the action-pins job is held to the same rules as the other build jobs
gate "#83-AC2 action-pins failed" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    "${all_ok[@]/action-pins=success/action-pins=failure}")"
gate "#83-AC2.6 action-pins crashed (cancelled)" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    "${all_ok[@]/action-pins=success/action-pins=cancelled}")"
gate "#83-AC2 action-pins skipped by mistake" 1 pull_request refs/pull/1/merge "$(needs true "$APPS" "$IMAGES" \
    "${all_ok[@]/action-pins=success/action-pins=skipped}")"
gate "#83-AC2.3 action-pins ran on a Markdown-only change" 1 pull_request refs/pull/1/merge "$(needs false '' '' \
    changes=success boundaries=skipped dotnet=skipped release-checks=skipped action-pins=success find-frontends=skipped \
    frontends=skipped find-images=skipped publish=skipped)"
gate "#83-AC2 action-pins missing from needs" 1 push refs/heads/main "$(needs true "$APPS" "$IMAGES" \
    changes=success boundaries=success dotnet=success release-checks=success find-frontends=success frontends=success \
    find-images=success publish=success)"

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

# --- pinned actions, default permissions, runner labels (#83) -------------------------------------------------------------
# The checks are POSIX sh scripts: CI runs them under dash (/bin/sh on Ubuntu), so every case runs under bash and, when
# it is installed, dash. Fixtures are written into the temporary directory; the scripts never touch the network.
pins="$root/tools/check-action-pins.sh"
perms="$root/tools/check-workflow-permissions.sh"
shells=(bash)
if command -v dash >/dev/null 2>&1; then
    shells+=(dash)
elif [ -n "${CI:-}" ]; then
    failed=$((failed + 1))
    echo "FAIL: #83-AC1.9 dash is not installed, so the checks cannot be run under the CI shell"
else
    echo "SKIP: dash is not installed; the #83 checks run under bash only here (CI runs them under dash)"
fi

nroot=0
newroot() { # sets R to a fresh fixture root with .github/workflows
    nroot=$((nroot + 1))
    R="$work/pins/$nroot"
    mkdir -p "$R/.github/workflows"
}
case_run() { # id, name, script, root, expected exit code, expected output (exactly), extra arguments
    local sh out rc id="$1" name="$2" script="$3" dir="$4" want="$5" wantout="$6"
    shift 6
    # the checks read the files git tracks: a fixture is its own repository (never the real one)
    case "$dir" in
        "$work"/*)
            if [ -d "$dir" ] && [ -z "${NOGIT:-}" ]; then
                [ -e "$dir/.git" ] || git -C "$dir" init -q
                git -C "$dir" add -A >/dev/null 2>&1
            fi ;;
    esac
    for sh in "${shells[@]}"; do
        out="$("$sh" "$script" "$@" "$dir" 2>&1)"
        rc=$?
        if [ "$rc" = "$want" ] && [ "$out" = "$wantout" ]; then
            pass=$((pass + 1))
        else
            failed=$((failed + 1))
            echo "FAIL: $id $name [$sh] (expected exit $want, got $rc)"
            printf '%s\n' "    wanted: ${wantout//$'\n'/$'\n            '}" "    got:    ${out//$'\n'/$'\n            '}"
        fi
    done
}
require() { # id, name, 0 when the condition holds
    if [ "$3" = 0 ]; then pass=$((pass + 1)); else
        failed=$((failed + 1))
        echo "FAIL: $1 $2"
        [ -n "${4:-}" ] && printf '%s\n' "    ${4//$'\n'/$'\n    '}"
    fi
}

W=.github/workflows/w.yml
HDR=$'name: t\non: push\npermissions: {}\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:'
s40=11d5960a326750d5838078e36cf38b85af677262
s39="${s40%?}"
s41="${s40}0"
s7="${s40:0:7}"
sU="${s40^^}"
sv="v${s40:0:39}"
d64="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"

pin_case() { # id, name, expected exit code, the workflow's step lines (line 9 is the first), expected output
    newroot
    printf '%s\n%s\n' "$HDR" "$4" >"$R/$W"
    case_run "$1" "$2" "$pins" "$R" "$3" "$5"
}
pin_ok() { pin_case "$1" "$2" 0 "$3" ''; }
pin_bad() { # id, name, step lines, the ref as it is printed
    pin_case "$1" "$2" 1 "$3" "$W:9: $4"
}

# #83-AC1.1 inputs: one case per value
pin_ok "#83-AC1.1" "a full SHA with a version comment" "      - uses: actions/checkout@$s40 # v4.4.0"
pin_ok "#83-AC1.1" "a SHA with the release tag it came from" "      - uses: docker/build-push-action@$s40 # v7.4.0"
pin_ok "#83-AC1.1" "an action in a sub-path" "      - uses: github/codeql-action/analyze@$s40 # v3.28.1"
pin_ok "#83-AC1.1" "a uses key after a name key" $'      - name: Checkout\n        uses: actions/checkout@'"$s40 # v4.4.0"
pin_ok "#83-AC1.1" "a commented-out uses is not a uses" "      # - uses: actions/checkout@v4"
pin_bad "#83-AC1.1" "@v4" "      - uses: actions/checkout@v4" "actions/checkout@v4"
pin_bad "#83-AC1.1" "@v4.4.0" "      - uses: actions/checkout@v4.4.0" "actions/checkout@v4.4.0"
pin_bad "#83-AC1.1" "@main" "      - uses: actions/checkout@main" "actions/checkout@main"
pin_bad "#83-AC1.1" "a short SHA (7)" "      - uses: actions/checkout@$s7 # v4.4.0" "actions/checkout@$s7"
pin_bad "#83-AC1.1" "an uppercase SHA" "      - uses: actions/checkout@$sU # v4.4.0" "actions/checkout@$sU"
pin_bad "#83-AC1.1" "a 41-character hex" "      - uses: actions/checkout@$s41 # v4.4.0" "actions/checkout@$s41"
pin_bad "#83-AC1.1" "40 characters that are not all hex" "      - uses: actions/checkout@$sv # v4.4.0" "actions/checkout@$sv"
pin_bad "#83-AC1.1" "a docker:// tag" "      - uses: docker://alpine:3.22" "docker://alpine:3.22"
pin_bad "#83-AC1.1" "a docker:// digest" "      - uses: docker://alpine@$d64" "docker://alpine@$d64"
pin_bad "#83-AC1.1" "a missing version comment" "      - uses: actions/checkout@$s40" "actions/checkout@$s40"
pin_bad "#83-AC1.1" "a comment that is not a version" "      - uses: actions/checkout@$s40 # latest" "actions/checkout@$s40"
pin_bad "#83-AC1.1" "a major-only comment" "      - uses: actions/checkout@$s40 # v4" "actions/checkout@$s40"
pin_bad "#83-AC1.1" "an expression instead of a ref" '      - uses: ${{ matrix.action }}' '${{ matrix.action }}'
pin_bad "#83-AC1.1" "a double-quoted value" "      - uses: \"actions/checkout@$s40\" # v4.4.0" "\"actions/checkout@$s40\""
pin_bad "#83-AC1.1" "a single-quoted value" "      - uses: 'actions/checkout@$s40' # v4.4.0" "'actions/checkout@$s40'"
pin_bad "#83-AC1.1" "a | block" $'      - uses: |\n          actions/checkout@'"$s40 # v4.4.0" "|"
pin_bad "#83-AC1.1" "a > block" $'      - uses: >\n          actions/checkout@'"$s40 # v4.4.0" ">"
pin_bad "#83-AC1.1" "the value on the next line" $'      - uses:\n          actions/checkout@'"$s40 # v4.4.0" "<empty>"
pin_bad "#83-AC1.1" "an owner without a repository" "      - uses: checkout@$s40 # v4.4.0" "checkout@$s40"
pin_case "#83-AC1.1" "a uses key after a name key, unpinned" 1 $'      - name: Checkout\n        uses: actions/checkout@v4' \
    "$W:10: actions/checkout@v4"
# the line printed is the one with the problem, wherever it is
newroot
printf '%s\n%s\n' "$HDR" $'      - uses: actions/checkout@'"$s40"$' # v4.4.0\n      - run: echo hi\n      - uses: actions/setup-node@v4\n      - uses: actions/cache@main' >"$R/$W"
case_run "#83-AC1.1" "every offender of a file is listed, in line order" "$pins" "$R" 1 "$W:11: actions/setup-node@v4
$W:12: actions/cache@main"
# files other than workflows/*.yml: composite actions at any depth, .yaml files
newroot
mkdir -p "$R/.github/actions/x" "$R/.github/actions/a/b"
printf 'name: x\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@v4\n' >"$R/.github/actions/x/action.yml"
printf 'name: y\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@%s # v4.4.0\n    - uses: docker://alpine:3.22\n' "$s40" >"$R/.github/actions/a/b/action.yml"
printf 'on: push\njobs:\n  j:\n    steps:\n      - uses: actions/cache@v4\n' >"$R/.github/workflows/z.yaml"
case_run "#83-AC1.1" "composite actions and .yaml workflows are checked too" "$pins" "$R" 1 ".github/actions/a/b/action.yml:6: docker://alpine:3.22
.github/actions/x/action.yml:5: actions/checkout@v4
.github/workflows/z.yaml:5: actions/cache@v4"

# fail closed: a `uses` or `runs-on` key written in any form the check does not read is an offender (#83-AC1.1, #83-AC4.1)
U='<unrecognised: uses>'
pin_bad "#83-AC1.1" "a flow-mapping step" "      - { uses: actions/checkout@v4 }" "$U"
pin_bad "#83-AC1.1" "a flow-mapping step that is pinned" "      - { uses: actions/checkout@$s40 }" "$U"
pin_bad "#83-AC1.1" "a double-quoted key" "      - \"uses\": actions/checkout@main" "$U"
pin_bad "#83-AC1.1" "a single-quoted key" "      - 'uses': x/y@main" "$U"
pin_bad "#83-AC1.1" "a space before the colon" "      - uses : actions/checkout@v4" "$U"
pin_ok "#83-AC1.1" "the word uses in a trailing comment is not a key" "      - run: echo hi # uses: x/y@main"
newroot
printf '%s\n' 'name: t' 'on: push' 'permissions: {}' 'jobs:' \
    '  evil: { runs-on: [ubuntu-latest], permissions: {}, steps: [ { uses: actions/checkout@v4 } ] }' >"$R/$W"
case_run "#83-AC1.1" "a job written as a flow mapping, steps and runs-on in it" "$pins" "$R" 1 "$W:5: $U
$W:5: <unrecognised: runs-on>"
newroot
mkdir -p "$R/tools/evil" "$R/tools/ok" "$R/Prince/Frontend/x/node_modules/pkg" "$R/.claude/worktrees/w/.github/workflows"
printf 'name: e\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@main\n' >"$R/tools/evil/action.yml"
printf 'name: o\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@%s # v4.4.0\n' "$s40" >"$R/tools/ok/action.yaml"
printf 'name: n\nruns:\n  steps:\n    - uses: actions/checkout@v4\n' >"$R/Prince/Frontend/x/node_modules/pkg/action.yml"
printf 'on: push\njobs:\n  j:\n    steps:\n      - uses: actions/checkout@v4\n' >"$R/.claude/worktrees/w/.github/workflows/a.yml"
printf 'node_modules/\n.claude/worktrees/\n' >"$R/.gitignore"
case_run "#83-AC1.1" "a tracked local action anywhere is scanned; ignored node_modules and worktrees are not" "$pins" "$R" 1 \
    "tools/evil/action.yml:5: actions/checkout@main"
# local actions in directories the scan used to skip, and reached through symlinks (#83-AC1.2)
unpinned=$'name: e\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@main\n'
newroot
mkdir -p "$R/.claude/evil" "$R/node_modules/pkg"
printf '%s' "$unpinned" >"$R/.claude/evil/action.yml"
printf '%s' "$unpinned" >"$R/node_modules/pkg/action.yml"
printf '%s\n%s\n%s\n' "$HDR" "      - uses: ./.claude/evil" "      - uses: ./node_modules/pkg" >"$R/$W"
case_run "#83-AC1.2" "a tracked action under .claude/ or node_modules/ is scanned" "$pins" "$R" 1 \
    ".claude/evil/action.yml:5: actions/checkout@main
node_modules/pkg/action.yml:5: actions/checkout@main"
newroot
mkdir -p "$R/tools/s" "$R/tools/real"
printf '%s' "$unpinned" >"$R/real.yml"
ln -s ../../real.yml "$R/tools/s/action.yml"
printf '%s\n%s\n' "$HDR" "      - uses: ./tools/s" >"$R/$W"
case_run "#83-AC1.2" "an action.yml that is a symlink is an offender, and so is the reference to it" "$pins" "$R" 1 \
    "$W:9: ./tools/s
tools/s/action.yml:1: <symlink>"
newroot
mkdir -p "$R/tools/real"
printf 'name: o\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@%s # v4.4.0\n' "$s40" >"$R/tools/real/action.yml"
ln -s real "$R/tools/x"
printf '%s\n%s\n' "$HDR" "      - uses: ./tools/x" >"$R/$W"
case_run "#83-AC1.2" "a reference through a symlinked directory is an offender" "$pins" "$R" 1 "$W:9: ./tools/x"
newroot
mkdir -p "$R/tools/ok"
printf 'name: o\nruns:\n  using: composite\n  steps:\n    - run: echo hi\n' >"$R/tools/ok/action.yml"
printf 'readme\n' >"$R/README.md"
printf '%s\n%s\n' "$HDR" "      - uses: ./README.md" >"$R/$W"
case_run "#83-AC1.2" "a ./ reference to a file that is not an action or a workflow" "$pins" "$R" 1 "$W:9: ./README.md"
newroot
mkdir -p "$R/tools/ok"
printf 'name: o\nruns:\n  using: composite\n  steps:\n    - run: echo hi\n' >"$R/tools/ok/action.yml"
printf '%s\n%s\n' "$HDR" "      - uses: ./tools/../tools/ok" >"$R/$W"
case_run "#83-AC1.2" "a ./ path that is not normalised" "$pins" "$R" 1 "$W:9: ./tools/../tools/ok"
newroot
printf 'name: o\n' >"$R/tools-action.yml"
printf '%s\n' "$HDR" >"$R/$W"
mkdir -p "$R/untracked"
git -C "$R" init -q
git -C "$R" add -A
printf 'name: e\nruns:\n  steps:\n    - uses: actions/checkout@main\n' >"$R/untracked/action.yml"
NOGIT=1 case_run "#83-AC1.2" "a file git does not track is not scanned" "$pins" "$R" 0 ''
newroot
printf 'gitdir: /nonexistent\n' >"$R/.git"
NOGIT=1 case_run "#83-AC1.2" "a repository git cannot read is an error, not an empty list" "$pins" "$R" 2 "check-action-pins.sh: git cannot list the files of $R"
NOGIT=1 case_run "#83-AC3.2" "the permissions check says the same" "$perms" "$R" 2 "check-workflow-permissions.sh: git cannot list the files of $R"
newroot
NOGIT=1 case_run "#83-AC1.2" "a directory that is not a git repository is a usage error" "$pins" "$R" 2 "check-action-pins.sh: $R is not a git repository"

newroot
printf '%s\n' "$HDR" "      - uses: actions/checkout@$s40 # v4.4.0" "      - uses: ./.github/actions/x" >"$R/$W"
case_run "#83-AC1.10" "--list prints every runs-on and uses value, in line order, and exits 0" "$pins" "$R" 0 \
    "$W: runs-on ubuntu-24.04
$W: uses actions/checkout@$s40
$W: uses ./.github/actions/x" --list

# a local `./` reference must have its action.yml (or be a workflow file) in the repository (#83-AC1.2)
local_case() { # name, expected exit code, expected output, uses value, files to create (relative paths)
    newroot
    local f
    for f in $5; do
        mkdir -p "$R/$(dirname "$f")"
        printf 'name: x\nruns:\n  using: composite\n  steps:\n    - run: echo hi\n' >"$R/$f"
    done
    printf '%s\n%s\n' "$HDR" "      - uses: $4" >"$R/$W"
    case_run "#83-AC1.2" "$1" "$pins" "$R" "$2" "$3"
}
local_case "a local action with its action.yml" 0 '' "./.github/actions/release-image" ".github/actions/release-image/action.yml"
local_case "a local action outside .github with action.yaml" 0 '' "./ci/release" "ci/release/action.yaml"
local_case "a local reusable workflow that exists" 0 '' "./.github/workflows/other.yml" ".github/workflows/other.yml"
local_case "a local path with no action.yml" 1 "$W:9: ./tools/nope" "./tools/nope" ""
local_case "a local path with a shell character" 1 "$W:9: ./a;b" "./a;b" ""
# #83-AC1.2 boundaries
newroot
printf 'name: t\non: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n' >"$R/$W"
case_run "#83-AC1.2" "a workflow with no uses passes" "$pins" "$R" 0 ''
newroot
case_run "#83-AC1.2" "a repository with no workflows passes" "$pins" "$R" 0 ''
newroot
rmdir "$R/.github/workflows" "$R/.github"
case_run "#83-AC1.2" "a repository with no .github folder passes" "$pins" "$R" 0 ''
pin_ok "#83-AC1.2" "exactly 40 hex" "      - uses: actions/checkout@$s40 # v4.4.0"
pin_bad "#83-AC1.2" "39 hex" "      - uses: actions/checkout@$s39 # v4.4.0" "actions/checkout@$s39"
pin_bad "#83-AC1.2" "41 hex" "      - uses: actions/checkout@$s41 # v4.4.0" "actions/checkout@$s41"
case_run "#83-AC1.2" "a root that is not a directory is a usage error" "$pins" "$work/pins/none" 2 \
    "check-action-pins.sh: $work/pins/none is not a directory"

# #83-AC1.6: the check reads files and nothing else; its header says so
head -45 "$pins" | grep -qi 'network'
require "#83-AC1.6" "the header says the check does not use the network (a deleted SHA is found by GitHub)" $?
head -45 "$pins" | grep -qi 'delet'
require "#83-AC1.6" "the header says a deleted upstream SHA cannot be detected offline" $?
grep -nE '(^|[|;&(]|[$][(])[[:space:]]*(curl|wget|gh|git|nc)[[:space:]]' "$pins" | grep -v 'ls-files' | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null
require "#83-AC1.6" "the script calls no network tool and git only to list the tracked files" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# #83-AC1.7 idempotence: the check changes nothing and gives the same output every time
newroot
printf '%s\n%s\n' "$HDR" "      - uses: actions/checkout@v4" >"$R/$W"
before="$(cksum <"$R/$W")"
first="$(bash "$pins" "$R" 2>&1)"
second="$(bash "$pins" "$R" 2>&1)"
require "#83-AC1.7" "two runs print the same, and the file is untouched" "$([ "$first" = "$second" ] && [ "$before" = "$(cksum <"$R/$W")" ] && [ -n "$first" ] && echo 0 || echo 1)"

# #83-AC1.9 environment: a /bin/sh script with no [[, here-string, process substitution or grep -P (dash runs every case above)
for script in "$pins" "$perms"; do
    name="$(basename "$script")"
    require "#83-AC1.9" "$name starts with #!/bin/sh" "$([ "$(head -1 "$script")" = '#!/bin/sh' ] && echo 0 || echo 1)"
    grep -nE '\[\[[[:space:]]|grep[[:space:]]+(-[a-zA-Z]*P|--perl)|<<<|<\(' "$script" >/dev/null
    require "#83-AC1.9" "$name has no bashism and no grep -P" "$([ $? -ne 0 ] && echo 0 || echo 1)"
done

# #83-AC1.10 observability: only offenders are printed, and no value of a workflow reaches the output
newroot
printf '%s\n' "$HDR" '      - uses: actions/checkout@v4' '        with:' '          token: ${{ secrets.TOP_SECRET_NAME }}' \
    '      - run: echo "$SOME_VALUE_abc123"' >"$R/$W"
case_run "#83-AC1.10" "only <file>:<line>: <ref> is printed, nothing from the rest of the file" "$pins" "$R" 1 \
    "$W:9: actions/checkout@v4"
case_run "#83-AC1.10" "a clean tree prints nothing" "$pins" "$root" 0 ''

# #83-AC4 runner labels (checked by the same script; offenders as <file>:<line>: <value>)
runner_case() { # id, name, expected exit code, the runs-on lines, expected output
    newroot
    printf 'name: t\non: push\npermissions: {}\njobs:\n  j:\n%s\n    permissions: {}\n    steps:\n      - run: echo hi\n' "$4" >"$R/$W"
    case_run "$1" "$2" "$pins" "$R" "$3" "$5"
}
runner_case "#83-AC4" "ubuntu-24.04 is the one allowed label" 0 "    runs-on: ubuntu-24.04" ''
runner_case "#83-AC4" "ubuntu-24.04 with a trailing comment" 0 "    runs-on: ubuntu-24.04 # pinned" ''
runner_case "#83-AC4.1" "ubuntu-latest" 1 "    runs-on: ubuntu-latest" "$W:6: ubuntu-latest"
runner_case "#83-AC4.1" "ubuntu-22.04" 1 "    runs-on: ubuntu-22.04" "$W:6: ubuntu-22.04"
runner_case "#83-AC4.1" "macos-latest" 1 "    runs-on: macos-latest" "$W:6: macos-latest"
runner_case "#83-AC4.1" "a matrix expression" 1 '    runs-on: ${{ matrix.os }}' "$W:6: "'${{ matrix.os }}'
runner_case "#83-AC4.1" "a flow list" 1 "    runs-on: [ubuntu-24.04]" "$W:6: [ubuntu-24.04]"
runner_case "#83-AC4.1" "a block list" 1 $'    runs-on:\n      - ubuntu-24.04' "$W:6: <empty>"
runner_case "#83-AC4.1" "an arm runner" 1 "    runs-on: ubuntu-24.04-arm" "$W:6: ubuntu-24.04-arm"
runner_case "#83-AC4.1" "a quoted label" 1 "    runs-on: 'ubuntu-24.04'" "$W:6: 'ubuntu-24.04'"
runner_case "#83-AC4.1" "a double-quoted key" 1 '    "runs-on": ubuntu-latest' "$W:6: <unrecognised: runs-on>"
runner_case "#83-AC4.1" "a single-quoted key" 1 "    'runs-on': ubuntu-24.04" "$W:6: <unrecognised: runs-on>"
runner_case "#83-AC4.1" "a space before the colon" 1 "    runs-on : ubuntu-24.04" "$W:6: <unrecognised: runs-on>"
runner_case "#83-AC4.10" "every offender of a file is listed" 1 $'    runs-on: ubuntu-latest\n  k:\n    runs-on: macos-latest' \
    "$W:6: ubuntu-latest
$W:8: macos-latest"
runs_on_count="$(grep -h '^ *runs-on:' "$root"/.github/workflows/*.yml | wc -l)"
runs_on_ok="$(grep -h '^ *runs-on: ubuntu-24.04$' "$root"/.github/workflows/*.yml | wc -l)"
require "#83-AC4" "every runs-on in the repository's workflows is ubuntu-24.04" "$([ "$runs_on_count" -gt 0 ] && [ "$runs_on_count" = "$runs_on_ok" ] && echo 0 || echo 1)" \
    "$runs_on_ok of $runs_on_count"

# #83-AC3 permissions: top level {}, a block on every job
perm_case() { # id, name, expected exit code, expected output, the workflow text
    newroot
    printf '%s\n' "$5" >"$R/$W"
    case_run "$1" "$2" "$perms" "$R" "$3" "$4"
}
GOOD=$'name: t\non: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo hi\n  b:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi'
perm_case "#83-AC3" "top level {} and a block on every job" 0 '' "$GOOD"
perm_case "#83-AC3.1" "a job-level permissions: {}" 0 '' $'name: t\non: push\npermissions: {}   # nothing by default\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "permissions after jobs still counts" 0 '' $'on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi\npermissions: {}'
perm_case "#83-AC3.1" "top level write-all" 1 "$W: top level: permissions must be {} (found: write-all)" "${GOOD/permissions: \{\}/permissions: write-all}"
perm_case "#83-AC3.1" "top level read-all" 1 "$W: top level: permissions must be {} (found: read-all)" "${GOOD/permissions: \{\}/permissions: read-all}"
perm_case "#83-AC3.1" "top level contents: read" 1 "$W: top level: permissions must be {} (found: a block)" "${GOOD/permissions: \{\}/permissions:
  contents: read}"
perm_case "#83-AC3.1" "top level key missing" 1 "$W: top level: permissions must be {} (found: no permissions key)" "${GOOD/permissions: \{\}
/}"
perm_case "#83-AC3.1" "a job without a block" 1 "$W: job b: no permissions block" $'name: t\non: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo hi\n  b:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "every offending job is named, and the top level too" 1 "$W: top level: permissions must be {} (found: no permissions key)
$W: job a: no permissions block
$W: job b: no permissions block" $'on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n  b:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "a job with write-all" 1 "$W: job a: permissions: write-all is not allowed" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: write-all\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "a permissions key of a step input is not the job's block" 1 "$W: job a: no permissions block" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: ./x\n        with:\n          permissions: contents: read'
perm_case "#83-AC3.1" "a permissions key only inside a job is not the top level" 1 "$W: top level: permissions must be {} (found: no permissions key)" $'on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "a job block with nothing in it" 1 "$W: job a: permissions block is empty (write {} to grant nothing)" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions:\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.1" "a job id in quotes (a flow job that grants write-all)" 1 "$W: job (line 11): not a plain job key" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi\n  # next\n  \n  "evil": { runs-on: ubuntu-24.04, permissions: write-all, steps: [] }'
perm_case "#83-AC3.1" "a job written as a flow mapping" 1 "$W: job (line 7): not a plain job key" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n  evil: { runs-on: ubuntu-24.04, permissions: write-all }'
perm_case "#83-AC3.1" "a job id with a value after the colon" 1 "$W: job (line 4): not a plain job key" $'on: push\npermissions: {}\njobs:\n  a: &anchor\n    runs-on: ubuntu-24.04\n    permissions: {}'
perm_case "#83-AC3.1" "a quoted jobs key" 1 "$W: top level: line 3: not a plain key" $'on: push\npermissions: {}\n"jobs":\n  a:\n    runs-on: ubuntu-24.04'
perm_case "#83-AC3.1" "jobs as a flow mapping" 1 "$W: top level: line 3: jobs must be a block, not an inline value" $'on: push\npermissions: {}\njobs: { a: { runs-on: ubuntu-24.04, permissions: write-all } }'
perm_case "#83-AC3.1" "a quoted top-level permissions key" 1 "$W: top level: line 2: not a plain key
$W: top level: permissions must be {} (found: no permissions key)" $'on: push\n"permissions": {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}'
perm_case "#83-AC3.1" "a quoted job-level permissions key" 1 "$W: job a: no permissions block" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    "permissions": write-all'
perm_case "#83-AC3.1" "a space before the colon in a job's permissions" 1 "$W: job a: no permissions block" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions : write-all'
perm_case "#83-AC3.1" "a quoted job name with its block is read as the job it names" 0 '' $'on: push\npermissions: {}\njobs:\n  "build":\n    runs-on: ubuntu-24.04\n    permissions: {}\n  \'test\':\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read'
perm_case "#83-AC3.1" "a quoted job name without a block is named" 1 "$W: job build: no permissions block" $'on: push\npermissions: {}\njobs:\n  "build":\n    runs-on: ubuntu-24.04'
perm_case "#83-AC3.1" "a top-level flow mapping" 1 "$W: top level: permissions must be {} (found: { contents: read })" $'on: push\npermissions: { contents: read }\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}'
perm_case "#83-AC3.1" "a permissions flow mapping that does not close on its line" 1 "$W: job a: permissions flow mapping must close on its line" $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {\n      contents: write }'
perm_case "#83-AC3.2" "a single job with its block" 0 '' $'on: push\npermissions: {}\njobs:\n  only:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo hi'
perm_case "#83-AC3.2" "a single job without a block" 1 "$W: job only: no permissions block" $'on: push\npermissions: {}\njobs:\n  only:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi'
newroot
printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n' >"$R/$W"
before="$(cksum <"$R/$W")"
first="$(bash "$perms" "$R" 2>&1)"
second="$(bash "$perms" "$R" 2>&1)"
require "#83-AC3.7" "two runs print the same, and the file is untouched" "$([ "$first" = "$second" ] && [ "$before" = "$(cksum <"$R/$W")" ] && [ -n "$first" ] && echo 0 || echo 1)"
case_run "#83-AC3" "the repository's own workflows pass" "$perms" "$root" 0 ''
newroot
case_run "#83-AC3.2" "a repository with no workflows passes" "$perms" "$R" 0 ''

# #83-AC3.8: no job gains a permission. --list prints each job's grants; the table is what the workflows granted
# before #83 (a job without a block inherited the workflow's contents: read), plus the one new job
before_grants=(
    ".github/workflows/build.yml: job changes: contents:read"
    ".github/workflows/build.yml: job boundaries: contents:read"
    ".github/workflows/build.yml: job dotnet: contents:read"
    ".github/workflows/build.yml: job release-checks: attestations:read contents:read"
    ".github/workflows/build.yml: job find-frontends: contents:read"
    ".github/workflows/build.yml: job frontends: contents:read"
    ".github/workflows/build.yml: job find-images: contents:read"
    ".github/workflows/build.yml: job publish: attestations:write contents:read id-token:write packages:write"
    ".github/workflows/build.yml: job gate: actions:read contents:read"
    ".github/workflows/release.yml: job plan: contents:read"
    ".github/workflows/release.yml: job dry-run-pr: contents:read"
    ".github/workflows/release.yml: job dry-run: attestations:write contents:read id-token:write"
    ".github/workflows/release.yml: job dry-run-summary: contents:read"
    ".github/workflows/release.yml: job prepare: attestations:write contents:read id-token:write packages:write"
    ".github/workflows/release.yml: job prepare-pin: actions:write contents:write"
    ".github/workflows/release.yml: job release: attestations:read contents:write packages:write"
)
after_list="$(bash "$perms" --list "$root" 2>&1)"
extra=""
gone=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%: *}"
    grants=" ${line##*: } "
    found=""
    for b in "${before_grants[@]}"; do
        [ "${b%: *}" = "$key" ] && found="$b"
    done
    if [ -z "$found" ]; then
        [ "$line" = ".github/workflows/build.yml: job action-pins: contents:read" ] || extra="$extra$line"$'\n'
        continue
    fi
    for g in ${grants}; do
        case " ${found##*: } " in
            *" $g "*) ;;
            *) extra="$extra$key gained $g"$'\n' ;;
        esac
    done
done <<<"$after_list"
for b in "${before_grants[@]}"; do
    case $'\n'"$after_list"$'\n' in
        *$'\n'"${b%: *}: "*) ;;
        *) gone="$gone${b%: *}"$'\n' ;;
    esac
done
require "#83-AC3.8" "no job gains a permission, and no job is missing from the list" "$([ -z "$extra" ] && [ -z "$gone" ] && echo 0 || echo 1)" \
    "gained: $extra missing: $gone"
require "#83-AC3.8" "the new action-pins job reads contents and nothing else" \
    "$(grep -qxF '.github/workflows/build.yml: job action-pins: contents:read' <<<"$after_list" && echo 0 || echo 1)" "$after_list"
newroot
printf '%s\n' $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions:\n      id-token: write # signs\n      contents: read\n    steps:\n      - run: echo hi\n  b:\n    runs-on: ubuntu-24.04\n    permissions: { packages: write, contents: read }\n    steps:\n      - run: echo hi\n  c:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo hi' >"$R/$W"
case_run "#83-AC3.8" "--list sorts each job's grants, reads flow form, drops comments, says none" "$perms" "$R" 0 \
    "$W: job a: contents:read id-token:write
$W: job b: contents:read packages:write
$W: job c: none" --list
# #113: checks: write (what could forge the gate's own status) is granted nowhere
grep -nE '^[[:space:]]*(checks|statuses):[[:space:]]*write' "$root"/.github/workflows/*.yml >/dev/null
require "#83-AC3.8" "no workflow grants checks: write or statuses: write" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# #83-AC2: the action-pins job in build.yml
block() { # file, job: the job's lines (from its key to the next job)
    awk -v j="$2" '$0 == "  " j ":" {on=1; print; next} on && /^  [a-zA-Z0-9_-]+:/ {on=0} on {print}' "$1"
}
ap="$(block "$root/.github/workflows/build.yml" action-pins)"
require "#83-AC2" "build.yml has an action-pins job" "$([ -n "$ap" ] && echo 0 || echo 1)"
grep -qE '^    needs: changes$' <<<"$ap"
require "#83-AC2.2" "action-pins needs the changes job" $?
grep -qF "if: needs.changes.outputs.code == 'true'" <<<"$ap"
require "#83-AC2.3" "action-pins is skipped by the same Markdown-only rule as the other build jobs" $?
grep -q 'tools/check-action-pins.sh' <<<"$ap" && grep -q 'tools/check-workflow-permissions.sh' <<<"$ap"
require "#83-AC2" "action-pins runs both checks" $?
grep -qE '^    runs-on: ubuntu-24.04$' <<<"$ap"
require "#83-AC2.9" "action-pins runs on ubuntu-24.04" $?
grep -qE '^      - uses: actions/checkout@[0-9a-f]{40} # v' <<<"$ap" && grep -q 'persist-credentials: false' <<<"$ap"
require "#83-AC2.8" "action-pins checks out without keeping the token" $?
grep -qE '^    needs: \[.*\baction-pins\b.*\]$' <<<"$(block "$root/.github/workflows/build.yml" gate)"
require "#83-AC2" "gate lists action-pins in needs" $?
grep -qE '^name: gate$|^  gate:$' "$root/.github/workflows/build.yml" && ! grep -qE '^    name:' <<<"$(block "$root/.github/workflows/build.yml" gate)"
require "#83-AC2" "the gate job keeps its key and has no name: that renames the required check" $?

# #83-AC5 dependabot.yml and the documentation
yaml_json() { # file: the file as JSON, with yq (the runner image has it) or its container; empty when neither exists
    if command -v yq >/dev/null 2>&1; then
        yq -o=json . "$1" 2>/dev/null
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm -i mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2 -o=json . <"$1" 2>/dev/null
    fi
}
dep="$root/.github/dependabot.yml"
depjson=""
[ -f "$dep" ] && depjson="$(yaml_json "$dep")"
dep_is() { # id, name, jq filter that must be true
    require "$1" "$2" "$(jq -e "$3" <<<"${depjson:-null}" >/dev/null 2>&1 && echo 0 || echo 1)" "${depjson:-no .github/dependabot.yml, or no yq to read it}"
}
dep_is "#83-AC5" "dependabot.yml is version 2 with exactly one update entry" '.version == 2 and (.updates | length) == 1'
dep_is "#83-AC5" "the entry is the github-actions ecosystem" '.updates[0]["package-ecosystem"] == "github-actions"'
dep_is "#83-AC5" "it reads / and every composite action under .github/actions" '.updates[0].directories == ["/", "/.github/actions/*"] and (.updates[0] | has("directory") | not)'
dep_is "#83-AC5" "the schedule is weekly" '.updates[0].schedule.interval == "weekly"'
dep_is "#83-AC5" "one group takes every action update" '(.updates[0].groups | length) == 1 and ((.updates[0].groups | to_entries[0].value.patterns) == ["*"])'
dep_is "#83-AC5" "the cooldown is 14 days" '.updates[0].cooldown["default-days"] == 14'
dep_is "#83-AC5" "at most 5 open pull requests" '.updates[0]["open-pull-requests-limit"] == 5'
doc="$root/Docs/workflow.md"
for phrase in 'tools/check-action-pins.sh' 'tools/check-workflow-permissions.sh' 'permissions: {}' 'ubuntu-24.04' \
    'full-length commit SHA' '.github/dependabot.yml' 'action-pins' 'by hand'; do
    require "#83-AC5" "Docs/workflow.md states: $phrase" "$(grep -qF -- "$phrase" "$doc" && echo 0 || echo 1)"
done
require "#83-AC4.4" "Docs/workflow.md says where the runner image's retirement is tracked" \
    "$(grep -qiE 'retire|deprecat' "$doc" && grep -q 'actions/runner-images' "$doc" && echo 0 || echo 1)"

# #83 cross-check: yq (the YAML parser GitHub's own reading is closest to) lists every job with its permissions and every
# uses and runs-on, and the lists must equal what the awk checks saw. A form the checks cannot read shows up as a difference.
cross="$root/tools/check-workflow-crosscheck.sh"
have_yq=1
if ! command -v yq >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    have_yq=0
    if [ -n "${CI:-}" ]; then
        failed=$((failed + 1))
        echo "FAIL: #83 yq is not installed on CI, so the cross-check cannot run"
    else
        echo "SKIP: neither yq nor docker is available; the #83 cross-check cases are skipped"
    fi
fi
cross_case() { # name, expected exit code, expected output, workflow text
    [ "$have_yq" = 1 ] || return 0
    newroot
    printf '%s\n' "$4" >"$R/$W"
    case_run "#83-AC1.1" "cross-check: $1" "$cross" "$R" "$2" "$3"
}
cross_case "a clean workflow agrees" 0 '' "$GOOD"$'\n'"      - uses: actions/checkout@$s40 # v4.4.0"
cross_case "a flow-mapping step is seen by yq only" 1 "only in yq: $W: uses actions/checkout@v4" \
    $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - { uses: actions/checkout@v4 }'
cross_case "a quoted job that grants write-all is seen by yq only" 1 "only in yq: $W: job evil: write-all
only in yq: $W: runs-on ubuntu-24.04" \
    $'on: push\npermissions: {}\njobs:\n  "evil": { runs-on: ubuntu-24.04, permissions: write-all, steps: [] }'
cross_case "a quoted runs-on is seen by yq only" 1 "only in yq: $W: runs-on ubuntu-latest" \
    $'on: push\npermissions: {}\njobs:\n  a:\n    "runs-on": ubuntu-latest\n    permissions: {}\n    steps:\n      - run: echo hi'
cross_case "a job without a block agrees (both say so)" 0 '' \
    $'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi'
if [ "$have_yq" = 1 ]; then
    newroot
    mkdir -p "$R/tools/evil"
    printf 'name: e\nruns:\n  using: composite\n  steps:\n    - { uses: actions/checkout@main }\n' >"$R/tools/evil/action.yml"
    case_run "#83-AC1.1" "cross-check: a composite action outside .github is read too" "$cross" "$R" 1 \
        "only in yq: tools/evil/action.yml: uses actions/checkout@main"
    newroot
    mkdir -p "$R/.claude/evil" "$R/node_modules/pkg"
    printf 'name: e\nruns:\n  using: composite\n  steps:\n    - { uses: actions/checkout@main }\n' >"$R/.claude/evil/action.yml"
    printf 'name: e\nruns:\n  using: composite\n  steps:\n    - { uses: actions/checkout@v4 }\n' >"$R/node_modules/pkg/action.yml"
    case_run "#83-AC1.2" "cross-check: tracked actions under .claude/ and node_modules/ are read too" "$cross" "$R" 1 \
        "only in yq: .claude/evil/action.yml: uses actions/checkout@main
only in yq: node_modules/pkg/action.yml: uses actions/checkout@v4"
    case_run "#83-AC1.1" "cross-check: the repository agrees" "$cross" "$root" 0 ''
    case_run "#83-AC1.2" "cross-check: a root that is not a directory is a usage error" "$cross" "$work/pins/none" 2 \
        "check-workflow-crosscheck.sh: $work/pins/none is not a directory"
fi
aj="$(block "$root/.github/workflows/build.yml" action-pins)"
grep -q 'tools/check-workflow-crosscheck.sh' <<<"$aj"
require "#83-AC2" "action-pins runs the yq cross-check" $?

# review fixes: shellcheck and the docs
rc="$root/.shellcheckrc"
require "#83-AC4.9" ".shellcheckrc no longer switches SC2015 off for the whole repository" \
    "$(grep -q '^disable=.*SC2015' "$rc" && echo 1 || echo 0)"
require "#83-AC4.9" ".shellcheckrc keeps SC2002 (style only) off" "$(grep -q 'SC2002' "$rc" && echo 0 || echo 1)"
if command -v shellcheck >/dev/null 2>&1; then
    out="$(cd "$root" && shellcheck -x tools/gh-lib.sh tools/pr.sh tools/ticket.sh 2>&1)"
    require "#83-AC4.9" "the guards that used to be A && B || die pass shellcheck without the SC2015 disable" "$?" "$out"
else
    echo "note: shellcheck is not installed here; CI's shellcheck runs this case"
fi
require "#83-AC4.9" "no 'A && B || C' guard is left in the linted scripts" \
    "$(grep -nE '\] && \[.*\] \|\| (die|usage)|\) && \[ -n .*\] \|\|$' "$root/tools/gh-lib.sh" "$root/tools/pr.sh" "$root/tools/ticket.sh" >/dev/null && echo 1 || echo 0)"
for phrase in 'impostor' 'check-workflow-crosscheck.sh' 'spellings they do not read' 'git ls-files' 'not bumped' 'only the cross-check'; do
    require "#83-AC5" "Docs/workflow.md states: $phrase" "$(grep -qiF -- "$phrase" "$doc" && echo 0 || echo 1)"
done
skill="$root/.claude/skills/pr-review/SKILL.md"
require "#83-AC5" "the pr-review skill has the pin step: the comment's tag resolves to the pinned SHA" \
    "$(grep -qi 'impostor' "$skill" && grep -q 'git/ref/tags' "$skill" && echo 0 || echo 1)"

grep -q 'node_modules`, `.git` and `.claude` excepted' "$doc"
require "#83-AC1.2" "Docs/workflow.md no longer says node_modules, .git and .claude are excepted" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qE 'mikefarah/yq:[0-9.]+@sha256:[0-9a-f]{64}' "$cross"
require "#83-AC5.9" "the cross-check's docker fallback pins yq by tag and digest" $?
grep -rn 'mikefarah/yq[ ]' "$cross" "$root/tools/tests/ci-tools.sh" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' >/dev/null
require "#83-AC5.9" "every yq container image is pinned" "$([ $? -ne 0 ] && echo 0 || echo 1)"
echo "ci tools: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
