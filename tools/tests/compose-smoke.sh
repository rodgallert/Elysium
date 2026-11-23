#!/usr/bin/env bash
# Smoke tests for Prince's Compose file (#74): restart policies, narrow dependencies, health checks and timings.
# Real containers in a Compose project of their own (loopback port only, no fixed host ports), removed afterwards
# with their volumes and built images. The values come from a throwaway .env written into a temporary directory;
# no value is ever printed.
#
# Usage: tools/tests/compose-smoke.sh            every phase (about 15 minutes, 5 of them the observation window)
# COMPOSE_SMOKE_ONLY=static   only the checks on `docker compose config` (seconds, nothing is started)
# COMPOSE_SMOKE_ONLY=stub     only the stub services of the health check boundaries (about 90 s)
# COMPOSE_SMOKE_ONLY=live     only the real stack (without the bucket phase)
# COMPOSE_SMOKE_ONLY=env      only the .env rules before any service starts (#74-AC2.9, #74-AC6, about 1 minute)
# COMPOSE_SMOKE_ONLY=bucket   only the file storage's bucket (#74-AC5, about 3 minutes)
# COMPOSE_SMOKE_OBSERVE=<s>   the RestartCount observation window of #74-AC1 (default 300)
# COMPOSE_SMOKE_RUNS=<n>      cold starts measured for the budget and the check durations (default 3)
# COMPOSE_SMOKE_PROJECT       overrides the project name
# Needs Docker with Compose 2.22+ (start_interval), curl, jq and a free loopback port.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose="$root/Prince/docker-compose.yml"
fixture="$root/tools/tests/compose-smoke"
only="${COMPOSE_SMOKE_ONLY:-all}"
observe="${COMPOSE_SMOKE_OBSERVE:-300}"
runs="${COMPOSE_SMOKE_RUNS:-3}"
project="${COMPOSE_SMOKE_PROJECT:-elysium-composesmoke-$$}"
work="$(mktemp -d)"
log="$work/output.log"
pass=0
failed=0

# One throwaway .env: a password nobody uses elsewhere (the leak checks grep for it) and a free loopback port
password="Zq$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
port="$(for p in $(seq 18200 18400); do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; break; }; done)"
env_file="$work/env"
printf '%s\n' "POSTGRES_USER=prince" "POSTGRES_PASSWORD=$password" "POSTGRES_DB=prince" "COMPOSE_SMOKE_PROXY_PORT=$port" \
    "JOBS_ADMIN_EMAIL=admin@prince.local" "JOBS_ADMIN_PASSWORD=ChangeMe123!" "FILE_STORAGE_ROOT_USER=prince-admin" \
    "FILE_STORAGE_ROOT_PASSWORD=ChangeMe123!" "FILE_STORAGE_BUCKET=product-files" >"$env_file"

say() { printf '%s\n' "$*" | tee -a "$log"; }
ok() { pass=$((pass + 1)); }
bad() { # id description detail
    failed=$((failed + 1))
    say "FAIL: $1 $2"
    [ -n "${3:-}" ] && say "    ${3//$'\n'/$'\n    '}"
}
check() { # id description command...: passes when the command succeeds
    local id="$1" desc="$2"
    shift 2
    if "$@"; then ok; else bad "$id" "$desc"; fi
}
note() { say "note: $*"; }

dc() { docker compose -p "$project" --env-file "$env_file" -f "$compose" -f "$fixture/override.yml" "$@"; }
dcf() { # extra override files first: dcf <file.yml> args...
    local extra="$1"
    shift
    docker compose -p "$project" --env-file "$env_file" -f "$compose" -f "$fixture/override.yml" -f "$fixture/$extra" "$@"
}
stub() { docker compose -p "${project}-stub" -f "$fixture/health-stub.yml" "$@"; }

cleanup() {
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker compose -p "${project}-noenv" --env-file "$work/env-missing" -f "$compose" -f "$fixture/override.yml" down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    stub down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker images --format '{{.Repository}}' | grep -E "^${project}(-noenv)?-" | xargs -r docker rmi -f >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

now_ms() { date +%s%3N; }
secs() { awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'; }

# --- what the Compose file must say ------------------------------------------------------------------------------------
oneshots=(env-check)
longrunning=(postgres core-api checkout-api jobs-api file-storage core-web-vue checkout-web-vue core-web-react checkout-web-react reverse-proxy)
backends=(core-api checkout-api jobs-api)
frontends=(core-web-vue checkout-web-vue core-web-react checkout-web-react)

# every service's depends_on, one line each, in the order of the expected list below (#74-AC2, #74-AC2.2)
expected_deps='checkout-api postgres:service_healthy
checkout-web-react
checkout-web-vue
core-api postgres:service_healthy
core-web-react
core-web-vue
env-check
file-storage env-check:service_completed_successfully
jobs-api env-check:service_completed_successfully,postgres:service_healthy
postgres env-check:service_completed_successfully
reverse-proxy '

static_checks() {
    local cfg svc got
    cfg="$(docker compose --env-file "$env_file" -f "$compose" config --format json 2>&1)" || { bad "#74-AC2" "docker compose config" "$cfg"; return; }

    # #74-AC1: restart policy
    for svc in "${longrunning[@]}"; do
        got="$(jq -r --arg s "$svc" '.services[$s].restart // "none"' <<<"$cfg")"
        [ "$got" = "unless-stopped" ] && ok || bad "#74-AC1" "$svc restart policy is unless-stopped (got $got)"
    done
    for svc in "${oneshots[@]}"; do
        got="$(jq -r --arg s "$svc" '.services[$s].restart // "none"' <<<"$cfg")"
        [ "$got" = "no" ] && ok || bad "#74-AC1" "$svc (a one-shot) keeps restart: \"no\" (got $got)"
    done

    # #74-AC2, #74-AC2.2: the whole dependency graph against the expected list
    got="$(jq -r '.services | to_entries | sort_by(.key)[] | "\(.key) \([.value.depends_on // {} | to_entries[] | "\(.key):\(.value.condition)"] | sort | join(","))"' <<<"$cfg")"
    got="$(sed 's/ *$//' <<<"$got")"
    if [ "$got" = "$(sed 's/ *$//' <<<"$expected_deps")" ]; then ok; else
        bad "#74-AC2.2" "the dependency graph differs from the expected list (< expected, > got)" "$(diff <(sed 's/ *$//' <<<"$expected_deps") <(printf '%s\n' "$got"))"
    fi
    # the proxy and the frontends have no depends_on at all
    got="$(jq -r '[.services["reverse-proxy"].depends_on // {} | keys[]] | length' <<<"$cfg")"
    [ "$got" = 0 ] && ok || bad "#74-AC2" "reverse-proxy has no depends_on on the backends"

    # #74-AC3: timings
    for svc in "${backends[@]}"; do
        got="$(jq -r --arg s "$svc" '.services[$s].healthcheck | [.interval, .timeout, .retries, .start_period, .start_interval] | join(" ")' <<<"$cfg")"
        [ "$got" = "10s 3s 3 30s 2s" ] && ok || bad "#74-AC3" "$svc health timings: interval timeout retries start_period start_interval (got: $got)"
        # #74-AC3.4: start_interval must reach the config (older Compose ignores it silently)
        jq -e --arg s "$svc" '.services[$s].healthcheck | has("start_interval")' <<<"$cfg" >/dev/null && ok || bad "#74-AC3.4" "$svc: start_interval is missing from docker compose config (Compose older than 2.22 ignores it)"
        # #74-AC3: the check fails when postgres:5432 does not accept a connection
        jq -e --arg s "$svc" '.services[$s].healthcheck.test | join(" ") | test("postgres[:/]5432")' <<<"$cfg" >/dev/null && ok || bad "#74-AC3" "$svc check does not connect to postgres:5432"
    done
    for svc in "${frontends[@]}"; do
        got="$(jq -r --arg s "$svc" '.services[$s].healthcheck | [.interval, .timeout, .retries] | join(" ")' <<<"$cfg")"
        [ "$got" = "10s 3s 3" ] && ok || bad "#74-AC3" "$svc health timings interval timeout retries (got: $got)"
    done
    got="$(jq -r '.services["reverse-proxy"].healthcheck // {} | [.interval, .timeout, .retries] | join(" ")' <<<"$cfg")"
    [ "$got" = "5s 3s 3" ] && ok || bad "#74-AC3" "reverse-proxy health timings interval timeout retries (got: $got)"
    got="$(jq -r '.services.postgres.healthcheck | [.start_period, (.test | join(" "))] | join(" | ")' <<<"$cfg")"
    case "$got" in
    "10s | "*pg_isready*"select 1"*) ok ;;
    *) bad "#74-AC3" "postgres: start_period 10s and a check with pg_isready and select 1 (got: $got)" ;;
    esac

    # #74-AC5: the file storage's health check confirms the bucket; no password in it (it reads the environment)
    got="$(jq -r '.services["file-storage"].healthcheck.test | join(" ")' <<<"$cfg")"
    case "$got" in *mcli*'$$FILE_STORAGE_BUCKET'*) ok ;; *) bad "#74-AC5" "file-storage's health check confirms the bucket (got: $got)" ;; esac

    # #74-AC3.3: the limit of "healthy" is stated next to the checks (a comment, so it is read from the file)
    got="$(grep -c 'cannot see a missing application' "$compose")"
    [ "$got" = 3 ] && grep -q 'mean the services have migrated' "$compose" && ok || bad "#74-AC3.3" "the readiness limit is stated in a comment next to each backend check and the Postgres check (backend comments: $got)"

    # #74-AC3.1: no password in any health command; the commands use "$$VAR", never ${VAR}
    got="$(jq -r '.services | to_entries[] | select(.value.healthcheck) | "\(.key): \(.value.healthcheck.test | join(" "))"' <<<"$cfg")"
    if grep -qF -- "$password" <<<"$got"; then bad "#74-AC3.1" "a health command contains the password (a \${VAR} expanded into the config)"; else ok; fi
    # #74-AC3.9: POSIX sh only (busybox and dash): no [[ and no ==
    if grep -E -- '\[\[|==' <<<"$got" >/dev/null; then bad "#74-AC3.9" "a health command uses [[ or == (not POSIX sh)" "$(grep -E -- '\[\[|==' <<<"$got")"; else ok; fi
    # #74-AC3.8: no extra capability, no docker.sock
    if jq -e '[.services[] | select(.healthcheck) | (.cap_add // []) , (.volumes // [] | map(.source // "")) ] | flatten | any(. == "SYS_ADMIN" or test("docker.sock"))' <<<"$cfg" >/dev/null; then bad "#74-AC3.8" "a service with a health check adds a capability or mounts docker.sock"; else ok; fi

    # #74-AC1.2: the RestartCount boundary the live phase applies: 3 passes, 4 fails
    restart_count_ok 3 && ok || bad "#74-AC1.2" "RestartCount 3 passes"
    restart_count_ok 4 && bad "#74-AC1.2" "RestartCount 4 fails" || ok
}

restart_count_ok() { [ "$1" -le 3 ]; }

# --- the stub services: where the health check's timeout and start period fall (#74-AC3.2) ------------------------------
stub_checks() {
    local cfg hc
    cfg="$(docker compose --env-file "$env_file" -f "$compose" config --format json 2>/dev/null)" || { bad "#74-AC3.2" "docker compose config failed"; return; }
    hc="$(jq -r '.services["core-api"].healthcheck | [.interval, .timeout, (.retries | tostring), .start_period, .start_interval] | @tsv' <<<"$cfg")"
    IFS=$'\t' read -r HC_INTERVAL HC_TIMEOUT HC_RETRIES HC_START_PERIOD HC_START_INTERVAL <<<"$hc"
    if [ -z "${HC_INTERVAL:-}" ] || [ "$HC_START_INTERVAL" = "null" ] || [ -z "$HC_START_INTERVAL" ]; then
        bad "#74-AC3.2" "the backends have no complete health check yet, so the boundaries can't be measured"
        return
    fi
    STUB_IMAGE="$(jq -r '.services["env-check"].image' <<<"$cfg")"
    export HC_INTERVAL HC_TIMEOUT HC_RETRIES HC_START_PERIOD HC_START_INTERVAL STUB_IMAGE
    stub up -d >/dev/null 2>&1 || { bad "#74-AC3.2" "the stub services did not start"; return; }
    local s start statuses last seen_unhealthy elapsed
    declare -A trail=()
    start="$(now_ms)"
    local boots=(boot20 boot35 boot70) all="check29 check31 boot20 boot35 boot70"
    while [ $(($(now_ms) - start)) -lt 95000 ]; do
        for s in $all; do
            statuses="$(docker inspect -f '{{.State.Health.Status}}' "$(stub ps -q "$s")" 2>/dev/null)"
            last="${trail[$s]:-}"
            last="${last##* }"
            [ "$statuses" = "$last" ] || trail[$s]+=" $statuses"
        done
        [[ "${trail[boot70]:-}" == *" unhealthy healthy" ]] && break
        sleep 1
    done
    elapsed="$(secs $(($(now_ms) - start)))"
    for s in $all; do say "stub $s: status trail:${trail[$s]:-} (after ${elapsed}s, restarts $(docker inspect -f '{{.RestartCount}}' "$(stub ps -q "$s")" 2>/dev/null))"; done
    [[ "${trail[check29]:-}" == " starting healthy" ]] && ok || bad "#74-AC3.2" "a check taking 2.9 s passes (trail:${trail[check29]:-})"
    [[ "${trail[check31]:-}" == *unhealthy* && "${trail[check31]:-}" != *" healthy" ]] && ok || bad "#74-AC3.2" "a check taking 3.1 s counts as failed (trail:${trail[check31]:-})"
    [[ "${trail[boot20]:-}" == " starting healthy" ]] && ok || bad "#74-AC3.2" "a boot needing 20 s stays starting, never unhealthy (trail:${trail[boot20]:-})"
    for s in "${boots[@]}"; do
        [ "$(docker inspect -f '{{.RestartCount}}' "$(stub ps -q "$s")")" = 0 ] && ok || bad "#74-AC3.2" "$s is not restarted in a loop"
    done
    # a boot of 35 s: after the 30 s start period the first failed checks count; unhealthy at most once and it recovers
    seen_unhealthy="$(grep -o unhealthy <<<"${trail[boot35]:-}" | wc -l)"
    { [ "$seen_unhealthy" -le 1 ] && [[ "${trail[boot35]:-}" == *" healthy" ]]; } && ok || bad "#74-AC3.2" "a boot needing 35 s goes unhealthy at most once and ends healthy (trail:${trail[boot35]:-})"
    seen_unhealthy="$(grep -o unhealthy <<<"${trail[boot70]:-}" | wc -l)"
    { [ "$seen_unhealthy" = 1 ] && [[ "${trail[boot70]:-}" == *" healthy" ]]; } && ok || bad "#74-AC3.2" "a boot needing 70 s goes unhealthy once and ends healthy (trail:${trail[boot70]:-})"
    stub down -v --remove-orphans --timeout 2 >/dev/null 2>&1
}

# --- the real stack ------------------------------------------------------------------------------------------------------
cid() { dc ps -aq "$1" 2>/dev/null | head -1; }
health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(cid "$1")" 2>/dev/null; }
restarts_of() { docker inspect -f '{{.RestartCount}}' "$(cid "$1")" 2>/dev/null; }
wait_health() { # service status limit_s: polls until the service has that health status; sets $took_ms
    local i start
    start="$(now_ms)"
    for ((i = 0; i < ${3:-60} * 2; i++)); do
        [ "$(health_of "$1")" = "$2" ] && { took_ms=$(($(now_ms) - start)); return 0; }
        sleep 0.5
    done
    took_ms=$(($(now_ms) - start))
    return 1
}
# #74-AC3.6: a check that failed shortly before an outage would shorten the time to "unhealthy"; wait until every backend's
# FailingStreak is 0 before one starts
wait_streaks_zero() { # limit_s
    local i s streak all
    for ((i = 0; i < ${1:-60} * 2; i++)); do
        all=1
        for s in "${backends[@]}"; do
            streak="$(docker inspect -f '{{.State.Health.FailingStreak}}' "$(cid "$s")" 2>/dev/null)"
            [ "$streak" = 0 ] || all=0
        done
        [ "$all" = 1 ] && return 0
        sleep 0.5
    done
    return 1
}
unhealthy_now() { # prints the services whose health isn't healthy
    local s
    for s in "${longrunning[@]}"; do [ "$(health_of "$s")" = healthy ] || printf '%s(%s) ' "$s" "$(health_of "$s")"; done
}
wait_all_healthy() { # limit_s: sets $took_ms and $still_not
    local start
    start="$(now_ms)"
    while :; do
        still_not="$(unhealthy_now)"
        took_ms=$(($(now_ms) - start))
        [ -z "$still_not" ] && return 0
        [ "$took_ms" -lt $((${1:-60} * 1000)) ] || return 1
        sleep 0.5
    done
}
# `up -d --wait` and then the wait for every long-running service to be healthy (#74-AC5: no service exits after starting, so
# --wait returns 0). Sets $up_out, $took_ms (the whole time) and $still_not; returns 0 when it did and every service is healthy.
up_wait() { # limit_s
    local start rc
    start="$(now_ms)"
    up_out="$(dc up -d --wait 2>&1)"
    rc=$?
    wait_all_healthy "${1:-90}" || rc=1
    took_ms=$(($(now_ms) - start))
    return "$rc"
}
# #74-AC1.10: per service RestartCount, last exit code and health, never a value from the .env
summary() {
    local s id line
    for s in "${longrunning[@]}" "${oneshots[@]}"; do
        id="$(cid "$s")"
        [ -n "$id" ] || { say "  $s: no container"; continue; }
        line="$(docker inspect -f 'restarts={{.RestartCount}} exit={{.State.ExitCode}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$id")"
        say "  $s: $line"
    done
}
check_restart_counts() { # id when
    local s n code
    for s in "${longrunning[@]}"; do
        n="$(restarts_of "$s")"
        code="$(docker inspect -f '{{.State.ExitCode}}' "$(cid "$s")" 2>/dev/null)"
        if [[ "$n" =~ ^[0-9]+$ ]] && restart_count_ok "$n"; then ok; else bad "$1" "$s RestartCount $n is over 3 ($2; last exit code $code)"; fi
    done
}
# #74-AC1.9: a login Postgres rejected is reported as one line (never its value)
login_note() {
    local n
    n="$(dc logs postgres 2>/dev/null | grep -c 'password authentication failed')"
    [ "${n:-0}" -gt 0 ] && note "postgres rejected $n logins: a volume created with other credentials? (down -v recreates it)"
    return 0
}
crash_postgres() { docker exec -u postgres "$(cid postgres)" pg_ctl stop -m immediate -D /var/lib/postgresql/data >/dev/null 2>&1; }
sql() { docker exec "$(cid postgres)" psql -U prince -d "${2:-prince}" -Atc "$1" 2>/dev/null; }
tables() { sql "select schemaname || '.' || tablename from pg_tables where schemaname not in ('pg_catalog', 'information_schema') order by 1"; }
base="http://127.0.0.1:$port"
code() { curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$base$1" 2>/dev/null; }

p95() { sort -n | awk '{ a[NR] = $1 } END { if (NR) { i = int(NR * 0.95 + 0.999); if (i < 1) i = 1; print a[i] } }'; }
check_durations() { # health check durations in ms of every service, from the live health log
    local s id
    for s in "${longrunning[@]}"; do
        id="$(cid "$s")"
        docker inspect "$id" 2>/dev/null | jq -r '.[0].State.Health.Log[]? | [.Start, .End] | @tsv' | while IFS=$'\t' read -r a b; do
            [ -n "$a" ] && echo $(($(date -d "$b" +%s%3N) - $(date -d "$a" +%s%3N)))
        done
    done
}

live_checks() {
    local i t first_fault="" cold=() warm run_durations="" ids_before ids_after out key s start rc

    dc build >"$work/build.log" 2>&1 || { bad "#74-AC3" "docker compose build failed" "$(tail -5 "$work/build.log")"; return; }

    # #74-AC1.7: Postgres crashed during the first boot; the second boot ends healthy with the same schema as a clean boot
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    dc up -d >"$work/up.log" 2>&1
    crash_postgres
    if wait_all_healthy 120; then ok; else bad "#74-AC1.7" "after Postgres was crashed during the first boot, the stack did not become healthy by itself" "$still_not"; fi
    schema_killed="$(tables)"

    # cold starts, from empty volumes, measured (#74-AC3: recorded, not gated)
    for ((i = 1; i <= runs; i++)); do
        dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
        up_wait 90
        rc=$?
        t="$took_ms"
        out="$up_out"
        cold+=("$t")
        say "cold start $i: $(secs "$t") s until up -d returned and everything is healthy (budget 45 s), exit $rc"
        if [ "$rc" -ne 0 ]; then bad "#74-AC3" "cold start $i: the stack did not come up healthy" "$(grep -iE 'dependency|unhealthy|failed|error' <<<"$out" | head -5)
$still_not"; fi
        [ "$t" -le 45000 ] || note "cold start $i took $(secs "$t") s, over the 45 s budget (recorded, not gated)"
        run_durations+="$(check_durations)"$'\n'
    done
    note "check durations at cold start over $runs runs: p95 $(grep -v '^$' <<<"$run_durations" | p95) ms of $(grep -vc '^$' <<<"$run_durations") samples"
    schema_clean="$(tables)"
    if [ -n "$schema_clean" ] && [ "$schema_clean" = "$schema_killed" ]; then ok; else bad "#74-AC1.7" "the schema after a boot with Postgres killed differs from a clean boot (tables: killed $(wc -l <<<"$schema_killed"), clean $(wc -l <<<"$schema_clean"))"; fi

    # warm start: existing volumes, same credentials (#74-AC1.9)
    dc down --timeout 2 >/dev/null 2>&1
    up_wait 90
    rc=$?
    t="$took_ms"
    out="$up_out"
    say "warm start: $(secs "$t") s until up -d returned and everything is healthy (budget 25 s), exit $rc"
    [ "$rc" -eq 0 ] && ok || bad "#74-AC1.9" "the stack did not start from existing volumes" "$(grep -iE 'dependency|unhealthy|failed|error' <<<"$out" | head -5)"
    [ "$t" -le 25000 ] || note "warm start took $(secs "$t") s, over the 25 s budget (recorded, not gated)"
    login_note

    # #74-AC2.7: a second up -d changes nothing
    ids_before="$(dc ps -aq | sort)"
    out="$(dc up -d 2>&1)"
    ids_after="$(dc ps -aq | sort)"
    if [ "$ids_before" = "$ids_after" ] && ! grep -qiE 'recreat' <<<"$out"; then ok; else bad "#74-AC2.7" "a second docker compose up -d recreated a container" "$(grep -iE 'recreat' <<<"$out")"; fi

    # #74-AC1: crash Postgres; the restart policy brings it back, and everything is healthy within 30 s of that
    first_fault="$(now_ms)"
    # (a crash, not `docker kill`: Docker 29 treats `docker kill` like `docker stop`, so no restart policy applies to it)
    before="$(restarts_of postgres)"
    crash_postgres
    sleep 1
    wait_health postgres healthy 90 || bad "#74-AC1" "Postgres did not come back after crashing by itself (restarts $(restarts_of postgres), exit $(docker inspect -f '{{.State.ExitCode}}' "$(cid postgres)"))"
    [ "$(restarts_of postgres)" -gt "$before" ] && ok || bad "#74-AC1" "Postgres crashed but was not restarted by the policy"
    if wait_all_healthy 60; then
        [ "$took_ms" -le 30000 ] && ok || bad "#74-AC1.4" "everything healthy $(secs "$took_ms") s after Postgres (limit 30 s)" "$still_not"
        say "recovery after a Postgres crash: all healthy $(secs "$took_ms") s after Postgres was healthy"
    else bad "#74-AC1" "after Postgres was killed and restarted, not everything became healthy within 60 s" "$still_not"; fi

    # #74-AC1, #74-AC3.6: Postgres down for 20 s (docker stop keeps it down), then a longer outage that turns the backends unhealthy
    wait_streaks_zero 60 || note "a backend still had failing checks before the 20 s outage"
    docker stop "$(cid postgres)" >/dev/null 2>&1
    sleep 20
    docker start "$(cid postgres)" >/dev/null 2>&1
    wait_health postgres healthy 60
    if wait_all_healthy 60; then
        [ "$took_ms" -le 30000 ] && ok || bad "#74-AC1.6" "after a 20 s outage everything was healthy $(secs "$took_ms") s after Postgres (limit 30 s)" "$still_not"
    else bad "#74-AC1.6" "after a 20 s outage not everything became healthy again" "$still_not"; fi

    wait_streaks_zero 60 || bad "#74-AC3.6" "a backend still had failing checks before the long outage"
    docker stop "$(cid postgres)" >/dev/null 2>&1
    start="$(now_ms)"
    for s in "${backends[@]}"; do
        left=$((39 - ($(now_ms) - start) / 1000))
        [ "$left" -ge 1 ] || left=1
        if wait_health "$s" unhealthy "$left"; then ok; else bad "#74-AC3.6" "$s is not unhealthy within 39 s of the Postgres outage (health: $(health_of "$s"))"; fi
    done
    say "backends unhealthy $(secs $(($(now_ms) - start))) s after the outage began"
    docker start "$(cid postgres)" >/dev/null 2>&1
    wait_health postgres healthy 60
    if wait_all_healthy 60; then
        [ "$took_ms" -le 30000 ] && ok || bad "#74-AC3.6" "after the long outage everything was healthy $(secs "$took_ms") s after Postgres (limit 30 s)" "$still_not"
    else bad "#74-AC3.6" "after the long outage not everything became healthy again" "$still_not"; fi

    # #74-AC1.3: a service stopped by hand stays stopped; a one-shot is not restarted after it exited 0
    docker stop "$(cid checkout-api)" >/dev/null 2>&1
    sleep 15
    [ "$(docker inspect -f '{{.State.Running}}' "$(cid checkout-api)")" = false ] && ok || bad "#74-AC1.3" "checkout-api stopped by hand was started again"
    docker start "$(cid checkout-api)" >/dev/null 2>&1
    for s in "${oneshots[@]}"; do
        if [ "$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.RestartCount}}' "$(cid "$s")")" = "exited 0 0" ]; then ok; else bad "#74-AC1.3" "$s (a one-shot) exited 0 and was not restarted (got $(docker inspect -f '{{.State.Status}} exit {{.State.ExitCode}} restarts {{.RestartCount}}' "$(cid "$s")"))"; fi
    done
    wait_all_healthy 60 || true

    # #74-AC2: Silo stopped by hand: the routes that don't need storage answer 200 (the API routes are asked for /health: the
    # APIs have no root route, so /api/checkout/ itself answers 404 with or without Silo)
    docker stop "$(cid file-storage)" >/dev/null 2>&1
    sleep 3
    for r in /vue/ /react/ /api/checkout/health; do
        [ "$(code "$r")" = 200 ] && ok || bad "#74-AC2" "$r answers 200 with Silo stopped (got $(code "$r"))"
    done
    # #74-AC2.3: record which routes fail without Silo
    local failing=""
    for r in /vue/checkout/ /vue/ /react/checkout/ /react/ /api/checkout/health /api/health /jobs/ /admin/; do
        [ "$(code "$r")" = 200 ] || failing+=" $r($(code "$r"))"
    done
    note "with Silo stopped, these routes do not answer 200:${failing:- none}"
    docker start "$(cid file-storage)" >/dev/null 2>&1
    wait_all_healthy 60 || true

    # #74-AC1.6: Postgres up but the application database missing: Postgres is not healthy
    sql "drop database prince with (force)" postgres >/dev/null
    if wait_health postgres unhealthy 90; then ok; else bad "#74-AC1.6" "Postgres reports $(health_of postgres) with the application database missing (select 1 must fail)"; fi
    say "with the application database missing after $(secs "$took_ms") s: $(for s in postgres "${backends[@]}"; do printf '%s=%s ' "$s" "$(health_of "$s")"; done)"
    note "the backends' own checks reach only TCP and /health: the database-aware readiness is Prince's /ready (design sprint)"
    sql "create database prince" postgres >/dev/null
    wait_health postgres healthy 60 || true

    # observation window: RestartCount read after the backoff, over the whole window (#74-AC1.4, #74-AC1.2)
    left=$((observe - ($(now_ms) - first_fault) / 1000))
    [ "$left" -gt 30 ] || left=30
    say "observing RestartCount for another ${left}s"
    sleep "$left"
    wait_all_healthy 30 || true
    summary
    check_restart_counts "#74-AC1" "after the observation window"

    # #74-AC3.10: no health log holds the password
    for s in "${longrunning[@]}"; do
        if docker inspect -f '{{json .State.Health}}' "$(cid "$s")" 2>/dev/null | grep -qF -- "$password"; then bad "#74-AC3.10" "$s health log contains the password"; else ok; fi
    done

    # #74-AC2.3: Silo that never serves for the whole run; everything else still starts
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    out="$(dcf silo-down.yml up -d --wait 2>&1)"
    rc=$?
    say "silo-down up -d exit $rc; the message: $(grep -iE 'dependency failed|unhealthy' <<<"$out" | head -2 | tr '\n' ' ')"
    # #74-AC2.10: the failed dependency is named by Compose
    [ "$rc" -ne 0 ] && grep -qE 'file-storage' <<<"$out" && ok || bad "#74-AC2.10" "Compose names file-storage as the failed dependency (exit $rc)"
    # (file-storage itself is excluded; everything else must be up and healthy)
    local expect=(postgres core-api checkout-api jobs-api core-web-vue checkout-web-vue core-web-react checkout-web-react reverse-proxy)
    local bad_list=""
    for ((i = 0; i < 90; i++)); do
        bad_list=""
        for s in "${expect[@]}"; do [ "$(health_of "$s")" = healthy ] || bad_list+="$s($(health_of "$s")) "; done
        [ -z "$bad_list" ] && break
        sleep 1
    done
    [ -z "$bad_list" ] && ok || bad "#74-AC2" "with Silo unhealthy, up -d did not start everything else" "$bad_list"
    for r in /vue/ /react/ /api/checkout/health; do
        [ "$(code "$r")" = 200 ] && ok || bad "#74-AC2.3" "$r answers 200 with Silo down for the whole run (got $(code "$r"))"
    done

    env_checks
}

# --- the .env rules refuse before any service starts (#74-AC2.9, #74-AC6) --------------------------------------------------
env_checks() {
    local out rc n s i nproject="${project}-noenv"
    # #74-AC2.9: a missing key still fails before the services that use its values start (the stack above is down first:
    # both would publish the same proxy port)
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    grep -v '^POSTGRES_PASSWORD=' "$env_file" >"$work/env-missing"
    out="$(docker compose -p "$nproject" --env-file "$work/env-missing" -f "$compose" -f "$fixture/override.yml" up -d 2>&1)"
    rc=$?
    [ "$rc" -ne 0 ] && ok || bad "#74-AC2.9" "up -d with POSTGRES_PASSWORD missing was not refused"
    for s in postgres jobs-api file-storage; do
        n="$(docker ps -aq --filter "label=com.docker.compose.project=$nproject" --filter "label=com.docker.compose.service=$s" --filter status=running | wc -l)"
        [ "$n" = 0 ] && ok || bad "#74-AC2.9" "$s started although env-check failed"
    done
    for ((i = 0; i < 15; i++)); do
        out="$(docker compose -p "$nproject" --env-file "$work/env-missing" -f "$compose" -f "$fixture/override.yml" logs env-check 2>&1)"
        grep -q 'env-check: POSTGRES_PASSWORD' <<<"$out" && break
        sleep 1
    done
    grep -q 'env-check: POSTGRES_PASSWORD' <<<"$out" && ok || bad "#74-AC2.9" "env-check's log names the missing key" "$out"
    docker compose -p "$nproject" --env-file "$work/env-missing" -f "$compose" -f "$fixture/override.yml" down -v --remove-orphans --timeout 2 >/dev/null 2>&1

    # #74-AC6.6: a colon in the Silo user with a valid password refuses the whole up before any service starts
    local colon_user="usr:Zx9Secret"
    sed "s/^FILE_STORAGE_ROOT_USER=.*/FILE_STORAGE_ROOT_USER=$colon_user/" "$env_file" >"$work/env-colon"
    local ncd=(docker compose -p "$nproject" --env-file "$work/env-colon" -f "$compose" -f "$fixture/override.yml")
    out="$("${ncd[@]}" up -d 2>&1)"
    rc=$?
    [ "$rc" -ne 0 ] && ok || bad "#74-AC6.6" "up -d with a colon in FILE_STORAGE_ROOT_USER was not refused"
    for s in postgres jobs-api file-storage core-api checkout-api; do
        n="$(docker ps -aq --filter "label=com.docker.compose.project=$nproject" --filter "label=com.docker.compose.service=$s" --filter status=running | wc -l)"
        [ "$n" = 0 ] && ok || bad "#74-AC6.6" "$s started although env-check refused a colon in the Silo user"
    done
    for ((i = 0; i < 15; i++)); do
        out="$("${ncd[@]}" logs env-check 2>&1)"
        grep -q 'env-check: FILE_STORAGE_ROOT_USER must not contain a colon' <<<"$out" && break
        sleep 1
    done
    grep -q 'env-check: FILE_STORAGE_ROOT_USER must not contain a colon' <<<"$out" && ok || bad "#74-AC6.6" "env-check's log names FILE_STORAGE_ROOT_USER and the colon rule" "$out"
    # #74-AC6.10: the submitted value is in neither env-check's output nor any service log
    local all_logs
    all_logs="$out
$("${ncd[@]}" logs 2>&1)"
    if grep -qF -- "$colon_user" <<<"$all_logs"; then bad "#74-AC6.10" "the submitted value appears in the logs"; else ok; fi
    # #74-AC6.7: a second run on the same .env refuses the same way; without the colon the next run passes
    out="$("${ncd[@]}" up -d 2>&1)"
    [ $? -ne 0 ] && ok || bad "#74-AC6.7" "a second run on the same .env was not refused"
    "${ncd[@]}" down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker compose -p "$nproject" --env-file "$env_file" -f "$compose" -f "$fixture/override.yml" up env-check >/dev/null 2>&1 && ok || bad "#74-AC6.7" "env-check passes once the colon is removed, with no other change"
    docker compose -p "$nproject" --env-file "$env_file" -f "$compose" -f "$fixture/override.yml" down -v --remove-orphans --timeout 2 >/dev/null 2>&1
}

# --- file storage is healthy only once its bucket exists (#74-AC5) -----------------------------------------------------------
fs_password="ChangeMe123!"
bucket_exists() { docker exec "$(cid file-storage)" sh -c 'MC_HOST_local="http://$FILE_STORAGE_ROOT_USER:$FILE_STORAGE_ROOT_PASSWORD@127.0.0.1:9000" mcli stat "local/$FILE_STORAGE_BUCKET"' >/dev/null 2>&1; }
failed_creation() { # override-file description
    local out id cmdlines
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    dcf "$1" up -d >/dev/null 2>&1
    wait_health core-api healthy 90 && ok || bad "#74-AC2.6" "core-api did not become healthy with the bucket creation failing ($2; health: $(health_of core-api))"
    sleep 20
    id="$(cid file-storage)"
    [ "$(health_of file-storage)" != healthy ] && ok || bad "#74-AC5.6" "file-storage reports healthy although its bucket creation fails ($2)"
    out="$(dcf "$1" logs file-storage 2>&1)"
    grep -qiE 'bucket creation failed' <<<"$out" && ok || bad "#74-AC5.6" "the log names the failed bucket creation ($2)" "$(tail -3 <<<"$out")"
    if grep -qF -e "$fs_password" -e another-Password-9 <<<"$out"; then bad "#74-AC5.10" "the log of a failed creation contains a password ($2)"; else ok; fi
    if docker inspect -f '{{json .State.Health}}' "$id" 2>/dev/null | grep -qF -e "$fs_password" -e another-Password-9; then bad "#74-AC5.10" "the health log contains a password ($2)"; else ok; fi
    # #74-AC5.8: while the creation is being retried, no process has the password in its command line
    cmdlines="$(docker exec "$id" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " <"$f"; echo; done' 2>/dev/null)"
    if [ -z "$cmdlines" ]; then bad "#74-AC5.8" "could not read the process list ($2)"; elif grep -qF -e "$fs_password" -e another-Password-9 <<<"$cmdlines"; then bad "#74-AC5.8" "a command line holds the password ($2)"; else ok; fi
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
}
bucket_checks() {
    local rc out s exited id
    dc build >"$work/build.log" 2>&1 || { bad "#74-AC5" "docker compose build failed" "$(tail -5 "$work/build.log")"; return; }
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    up_wait 90
    rc=$?
    [ "$rc" -eq 0 ] && ok || bad "#74-AC5" "docker compose up -d --wait exits 0 with every service healthy (exit $rc)" "$(tail -3 <<<"$up_out")
$still_not"
    # nothing exits after starting, except the env-check one-shot that others wait for
    exited="$(dc ps -a --status exited --format '{{.Service}}' | grep -v '^env-check$' | tr '\n' ' ')"
    [ -z "$exited" ] && ok || bad "#74-AC5" "no service exits after starting (exited: $exited)"
    # #74-AC5.9: from empty volumes
    bucket_exists && ok || bad "#74-AC5.9" "the bucket exists when file-storage is healthy, from empty volumes"
    grep -qiE 'bucket .*(created|already exists)' <<<"$(dc logs file-storage 2>&1)" && ok || bad "#74-AC5.10" "the log says the bucket was created or already exists"
    # #74-AC5.9: from an existing volume with the same credentials: down keeps the volume, up --wait exits 0, the bucket is there
    dc down --timeout 2 >/dev/null 2>&1
    up_wait 90
    rc=$?
    if [ "$rc" -eq 0 ] && bucket_exists; then ok; else bad "#74-AC5.9" "up -d --wait from an existing volume exits 0 with the bucket in place (exit $rc)" "$still_not"; fi
    grep -qiE 'bucket .*already exists' <<<"$(dc logs file-storage 2>&1)" && ok || bad "#74-AC5.9" "the log says the bucket already exists on an existing volume"
    # #74-AC5.7: an existing bucket is fine: the storage restarts on its volume and is healthy again
    docker restart "$(cid file-storage)" >/dev/null 2>&1
    if wait_health file-storage healthy 60 && bucket_exists; then ok; else bad "#74-AC5.7" "file-storage restarted with its bucket already there did not become healthy (health: $(health_of file-storage))"; fi
    dc logs file-storage 2>&1 | grep -qF -- "$fs_password" && bad "#74-AC5" "file-storage's log contains its password" || ok
    # #74-AC5.10: the log says whether the bucket was created or already there; #74-AC5.8: no password in the command line
    if grep -qiE 'bucket .*already exists' <<<"$(dc logs file-storage 2>&1)"; then ok; else bad "#74-AC5.10" "the log of the restarted file-storage says the bucket already exists"; fi
    id="$(cid file-storage)"
    if docker inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Args}}' "$id" | grep -qF -- "$fs_password"; then bad "#74-AC5.8" "the password is in the container's Config.Entrypoint, Cmd or Args"; else ok; fi
    # a failed creation: wrong server password (#74-AC5.6) and a bucket name Silo refuses (#74-AC5.2)
    failed_creation bucket-wrong-password.yml "wrong root password"
    failed_creation bucket-invalid.yml "bucket name Silo refuses"
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
}

case "$only" in
all | static) static_checks ;;
esac
case "$only" in
all | stub) stub_checks ;;
esac
case "$only" in
all | live) live_checks ;;
esac
case "$only" in
all | bucket) bucket_checks ;;
esac
case "$only" in
env) env_checks ;;
esac

# #74-AC1.10: nothing in this output is a value from the .env
if grep -qF -- "$password" "$log" 2>/dev/null; then bad "#74-AC1.10" "the output contains the Postgres password"; else ok; fi

say "compose smoke tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
