#!/usr/bin/env bash
# Fixture tests for tools/check-compose-images.sh (#74-AC4): every image name in a Compose file either matches an image
# tools/list-images.sh publishes (ours: ghcr.io/rodgallert/elysium-<service folder>-<service>) or, for third-party
# images, carries a tag or a digest. Compose files are written into a temporary directory only; the repository's own files
# are only read (the last cases run the check on them). Needs Docker with Compose (config only, nothing is started).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$root/tools/check-compose-images.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/filter.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/filter.sh"
pass=0
failed=0

ours=ghcr.io/rodgallert
digest64="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
digest63="${digest64%?}"

_ok() { pass=$((pass + 1)); } # a case that already passed the filter in its own helper
ok() {
    filter_site_gate || return 0
    pass=$((pass + 1))
}
bad() { # id description detail
    filter_selected "$1 $2" || return 0 # an assertion that is not a counted pass: filtered out silently
    failed=$((failed + 1))
    echo "FAIL: $1 $2"
    [ -n "${3:-}" ] && printf '%s\n' "    ${3//$'\n'/$'\n    '}"
}

n=0
# compose <service folder> <yaml body of the services, indented by 2>: writes <work>/<n>/<folder>/docker-compose.yml, prints its path
compose() {
    n=$((n + 1))
    mkdir -p "$work/$n/$1"
    printf 'services:\n%s\n' "$2" >"$work/$n/$1/docker-compose.yml"
    echo "$work/$n/$1/docker-compose.yml"
}
# svc <name> <image> [build]: one service as yaml; the image is quoted exactly as given (a trailing space stays)
svc() {
    local out="  $1:"
    [ -n "${3:-}" ] && out+=$'\n    build:\n      context: .'
    [ "$2" != "-" ] && out+=$'\n'"    image: \"$2\""
    [ "$2" = "-" ] && [ -z "${3:-}" ] && out+=$'\n    command: ["true"]'
    printf '%s' "$out"
}

# run_case <id> <description> <expected exit: pass|fail> <expected text in the output, or ""> <compose file...>
out=""
run_case() {
    local id="$1" desc="$2" want="$3" text="$4" rc
    shift 4
    filter_gate "$id $desc" || return 0
    out="$("$check" "$@" 2>&1)"
    rc=$?
    case "$want" in
    pass) [ "$rc" -eq 0 ] || { bad "$id" "$desc: expected exit 0, got $rc" "$out"; return; } ;;
    fail)
        [ "$rc" -ne 0 ] || { bad "$id" "$desc: expected a non-zero exit" "$out"; return; }
        # #74-AC4.10: every failure line is <file>: <service>: <reason>
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "$line" =~ ^[^:]+:\ [^:]+:\ .+ ]] || { bad "$id" "$desc: line is not <file>: <service>: <reason>" "$line"; return; }
        done <<<"$out"
        ;;
    esac
    if [ -n "$text" ] && ! grep -qF -- "$text" <<<"$out"; then
        bad "$id" "$desc: output lacks \"$text\"" "$out"
        return
    fi
    _ok
}

# --- #74-AC4: ours must be published, third-party needs a tag or digest ------------------------------------------------
f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api:main" build)")"
run_case "#74-AC4" "our image with its build and the published name passes" pass "" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-checkout-api:main" build)")"
run_case "#74-AC4" "an image of ours that is not the one this service publishes fails" fail "core-api: " "$f"
grep -q "$f: core-api: " <<<"$out" || bad "#74-AC4" "failure line names the file and the service" "$out"

f="$(compose Prince "$(svc core-api "postgres:17" build)")"
run_case "#74-AC4" "a build and an image that disagree fail" fail "build and image disagree" "$f"

f="$(compose Prince "$(svc other "$ours/elysium-prince-other:main")")"
run_case "#74-AC4" "an image of ours that no Compose build publishes fails" fail "publishes" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api:main" build)
$(svc copy "$ours/elysium-prince-core-api:main")")"
run_case "#74-AC4" "an image of ours another service of the files publishes passes" pass "" "$f"

f="$(compose Prince "$(svc db "postgres:17-alpine")
$(svc silo "pgsty/silo:RELEASE.2026-11-12T00-00-00Z")
$(svc tool "alpine:3.22@$digest64")")"
run_case "#74-AC4" "third-party images with a tag, or a tag and a digest, pass" pass "" "$f"

# --- #74-AC4.1 inputs ----------------------------------------------------------------------------------------------------
f="$(compose Prince "$(svc core-api "$ours/Elysium-Prince-Core-Api:main" build)")"
run_case "#74-AC4.1" "an uppercase name fails" fail "lower case" "$f"

f="$(compose Prince "$(svc registry "localhost:5000/elysium-prince-core-api:main")")"
run_case "#74-AC4.1" "a registry with a port is third-party: its tag is read after the port, so it passes" pass "" "$f"

f="$(compose Prince "$(svc registry "localhost:5000/elysium-prince-core-api")")"
run_case "#74-AC4.1" "a registry with a port and no tag fails (the port is not a tag)" fail "no tag or digest" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api@$digest64" build)")"
run_case "#74-AC4.1" "a digest-only reference of ours passes" pass "" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api@$digest63" build)")"
run_case "#74-AC4.1" "a digest of 63 hex characters fails" fail "digest" "$f"

f="$(compose Prince "$(svc tool "alpine@$digest64")")"
run_case "#74-AC4.1" "a digest-only third-party reference passes" pass "" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api" build)")"
run_case "#74-AC4.1" "a reference of ours with no tag fails" fail "no tag or digest" "$f"

f="$(compose Prince "$(svc db "postgres")")"
run_case "#74-AC4.1" "a third-party reference with no tag fails" fail "no tag or digest" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api:main " build)")"
run_case "#74-AC4.1" "a trailing space in the name fails" fail "space" "$f"

f="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api:\${TAG}" build)")"
run_case "#74-AC4.1" "a \${VAR} in the image name fails" fail "variable" "$f"

# --- #74-AC4.2 boundaries ----------------------------------------------------------------------------------------------
tag128="$(printf 'a%.0s' $(seq 128))"
f="$(compose Prince "$(svc db "postgres:$tag128")")"
run_case "#74-AC4.2" "a tag of 128 characters passes" pass "" "$f"

f="$(compose Prince "$(svc db "postgres:${tag128}a")")"
run_case "#74-AC4.2" "a tag of 129 characters fails" fail "128" "$f"

f="$(compose Prince "$(svc db "")")"
run_case "#74-AC4.2" "an empty image fails" fail "empty" "$f"

# --- #74-AC4.3 state: no image at all passes -----------------------------------------------------------------------------
f="$(compose Prince "$(svc core-api - build)
$(svc job -)")"
run_case "#74-AC4.3" "a Compose file with no image: anywhere passes" pass "" "$f"

# --- #74-AC4.6 partial failure -------------------------------------------------------------------------------------------
n=$((n + 1))
mkdir -p "$work/$n/Prince"
printf 'services: [\n' >"$work/$n/Prince/docker-compose.yml"
broken="$work/$n/Prince/docker-compose.yml"
run_case "#74-AC4.6" "a file docker compose config rejects is reported by name and the exit is non-zero" fail "$broken" "$broken"
grep -qi "no problems" <<<"$out" && bad "#74-AC4.6" "never says no problems"

good="$(compose Prince "$(svc core-api "$ours/elysium-prince-core-api:main" build)")"
bad2="$(compose Other "$(svc db postgres)")"
run_case "#74-AC4.6" "one broken file among good ones still fails and names the one with the problem" fail "$bad2" "$good" "$bad2"
grep -qF "$good" <<<"$out" && bad "#74-AC4.6" "the good file is not reported" "$out"

# --- #74-AC4.7 idempotence -----------------------------------------------------------------------------------------------
f="$(compose Prince "$(svc core-api "$ours/Elysium-Prince-Core-Api:main" build)
$(svc db postgres)")"
first="$("$check" "$f" 2>&1)"
second="$("$check" "$f" 2>&1)"
[ "$first" = "$second" ] && [ -n "$first" ] && ok || bad "#74-AC4.7" "two runs print the same output" "$first
--
$second"

# --- #74-AC4.9 environment: no .env, a required variable is not resolved -------------------------------------------------
n=$((n + 1))
mkdir -p "$work/$n/Prince"
f="$work/$n/Prince/docker-compose.yml"
printf 'services:\n  core-api:\n    build:\n      context: .\n    image: "%s/elysium-prince-core-api:main"\n    environment:\n      SECRET: ${SECRET:?set it}\n' "$ours" >"$f"
run_case "#74-AC4.9" "a required \${VAR} elsewhere in the file needs no .env" pass "" "$f"

# --- the repository as it is ---------------------------------------------------------------------------------------------
out="$("$check" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok || bad "#74-AC4" "the repository's own Compose files pass" "$out"

echo "check-compose-images tests: $pass passed, $failed failed"
filter_report "$pass" "$failed" || exit 1
[ "$failed" -eq 0 ]
