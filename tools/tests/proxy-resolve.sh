#!/usr/bin/env bash
# Smoke tests for Prince's reverse proxy (#73): it finds recreated and late backends on its own, keeps its routing,
# and runs on the maintained nginx branch. Real containers: the proxy is built from Prince/reverse-proxy and put in front
# of seven echo backends (tools/tests/proxy-resolve/compose.yml) in a Compose project of its own, published on 127.0.0.1
# only and removed afterwards (volumes, containers, network and built image).
#
# Usage: tools/tests/proxy-resolve.sh            run every case
#        tools/tests/proxy-resolve.sh --record   rewrite tools/tests/proxy-resolve/routes.capture from the current
#                                                config (done once against the old config; it is the "before" of AC3;
#                                                PROXY_DIR=<dir with the old nginx.conf and Dockerfile> records from there)
# PROXY_TEST_ONLY=drift runs only the deploy drift check (#73-AC4.3).
# Needs Docker with Compose. About 6 minutes (6m12s measured with the frontend builds; PROXY_TEST_ONLY=drift alone about 1 minute). PROXY_TEST_PROJECT overrides the project name.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$root/tools/tests/proxy-resolve"
# PROXY_DIR points --record at a copy of the old proxy (nginx.conf and Dockerfile of the commit before the fix)
proxy_dir="${PROXY_DIR:-$root/Prince/reverse-proxy}"
capture_file="$fixture/routes.capture"
record=0
[ "${1:-}" = "--record" ] && record=1

project="${PROXY_TEST_PROJECT:-elysium-proxytest-$$}"
work="$(mktemp -d)"
pass=0
failed=0

# shellcheck source=lib/deploy-drift.sh
source "$root/tools/tests/lib/deploy-drift.sh"
ECHO_IMAGE="$(sed -n 's/^FROM \(nginx:[^ ]*\).*/\1/p' "$proxy_dir/Dockerfile" | head -1)"
export ECHO_IMAGE PROXY_CONTEXT="$proxy_dir"
compose_files=(-f "$fixture/compose.yml")
dc() { docker compose -p "$project" "${compose_files[@]}" "$@"; }

cleanup() {
    dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker compose -p "${project}-fe" -f "$root/Prince/docker-compose.yml" down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker images --format '{{.Repository}}' | grep "^${project}-fe-" | xargs -r docker rmi -f >/dev/null 2>&1
    docker ps -aq --filter "label=proxytest=$project" | xargs -r docker rm -f >/dev/null 2>&1
    docker rmi -f "${project}-reverse-proxy" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
bad() { # id description detail
    failed=$((failed + 1))
    echo "FAIL: $1 $2"
    [ -n "${3:-}" ] && printf '%s\n' "    ${3//$'\n'/$'\n    '}"
}
check() { # id description command...: passes when the command succeeds
    local id="$1" desc="$2"
    shift 2
    if "$@"; then ok; else bad "$id" "$desc"; fi
}

# --- helpers -----------------------------------------------------------------------------------------------------

# Config values: the resolver's cache time is read from the config (a missing value fails AC1.2 and the run goes on
# with the 10 s the spec states)
valid="$(grep -oE 'valid=[0-9]+s' "$proxy_dir/nginx.conf" | head -1 | tr -dc 0-9)"
config_valid="$valid"
valid="${valid:-10}"
wait_limit_ms=$(((valid + 2) * 1000))
# #73-AC1.4: no fixed sleeps in the recovery checks: poll_until_200 polls once a second and returns on the first 200

now_ms() { date +%s%3N; }
cid() { dc ps -q "$1"; }
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(cid "$1")" 2>/dev/null; }
health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$(cid "$1")" 2>/dev/null; }
wait_healthy() { # service [timeout seconds]
    local i
    for ((i = 0; i < ${2:-60}; i++)); do
        [ "$(health_of "$1")" = "healthy" ] && return 0
        sleep 1
    done
    return 1
}
port="" base=""
refresh_port() {
    port="$(dc port reverse-proxy 80 2>/dev/null | head -1 | sed 's/.*://')"
    base="http://127.0.0.1:$port"
}
code() { curl -s -o /dev/null --max-time 10 --path-as-is -w '%{http_code}' "$base$1" 2>/dev/null; }
get() { curl -s --max-time 10 --path-as-is "$base$1" 2>/dev/null; }

# the route that reaches each backend, and the other way round
declare -A route_of=(
    [core-api]=/api/x [checkout-api]=/api/checkout/x [jobs-api]=/jobs/x
    [core-web-vue]=/vue/x [checkout-web-vue]=/vue/checkout/x [core-web-react]=/react/x [checkout-web-react]=/react/checkout/x
)
backends=(core-api checkout-api jobs-api core-web-vue checkout-web-vue core-web-react checkout-web-react)
# the eight routes and the backend behind each
routes=(/vue/checkout/ /vue/ /react/checkout/ /react/ /api/checkout/ /api/ /jobs/ /admin/)
declare -A backend_of=(
    [/vue/checkout/]=checkout-web-vue [/vue/]=core-web-vue [/react/checkout/]=checkout-web-react [/react/]=core-web-react
    [/api/checkout/]=checkout-api [/api/]=core-api [/jobs/]=jobs-api [/admin/]=jobs-api
)

# (#73-AC1.4)
# poll_until_200 <route>: polls once a second until 200 or the limit; sets $elapsed_ms, $seen (statuses in order) and
# $stray (a status other than 200 and 502, or an answer from the wrong backend)
elapsed_ms=0 seen="" stray=""
poll_until_200() {
    local route="$1" want="$2" start status body
    start="$(now_ms)"
    seen="" stray=""
    while :; do
        body="$(curl -s --max-time 10 --path-as-is -w '\n%{http_code}' "$base$route" 2>/dev/null)"
        status="${body##*$'\n'}"
        seen+=" $status"
        elapsed_ms=$(($(now_ms) - start))
        if [ "$status" = 200 ]; then
            grep -q "backend=$want " <<<"$body" || stray+=" wrong-backend($status)"
            return 0
        fi
        [ "$status" = 502 ] || stray+=" $status"
        [ "$elapsed_ms" -ge "$wait_limit_ms" ] && return 1
        sleep 1
    done
}

# recreate <service>: replaces the container and makes sure it got a new address. Docker hands a freed address to the
# next container, so the old one is stopped, a throwaway container takes its address, and then the service is recreated.
recreate() {
    local svc="$1" old new f n=0
    old="$(ip_of "$svc")"
    dc stop "$svc" >/dev/null 2>&1
    # throwaway containers until one holds the old address (Docker gives out the lowest free one)
    while [ "$n" -lt 12 ]; do
        f="$(docker run -d --label "proxytest=$project" --network "${project}_default" --entrypoint sleep "$ECHO_IMAGE" 300 2>/dev/null)"
        n=$((n + 1))
        [ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$f" 2>/dev/null)" = "$old" ] && break
    done
    dc up -d --force-recreate --no-deps "$svc" >/dev/null 2>&1
    wait_healthy "$svc" || { cleanup_fillers; return 1; }
    new="$(ip_of "$svc")"
    cleanup_fillers
    [ -n "$new" ] && [ "$new" != "$old" ]
}
cleanup_fillers() { docker ps -aq --filter "label=proxytest=$project" | xargs -r docker rm -f >/dev/null 2>&1; }

# recovers <id> <description> <service>: the route answers 200 from that backend within valid+2 s, 200 at or before valid
recovers() {
    local id="$1" desc="$2" svc="$3" route="${route_of[$3]}"
    if poll_until_200 "$route" "$svc"; then
        if [ "$elapsed_ms" -le $((valid * 1000)) ]; then
            [ -z "$stray" ] && ok || bad "$id" "$desc: unexpected answers:$stray"
        else
            bad "$id" "$desc: 200 only after ${elapsed_ms} ms (limit $((valid * 1000)) ms), statuses:$seen"
        fi
    else
        bad "$id" "$desc: no 200 within ${elapsed_ms} ms, statuses:$seen"
    fi
}

all_routes_are() { # expected status, over the eight routes; prints the offenders
    local r s bad_ones=""
    for r in "${routes[@]}"; do
        s="$(code "${r}probe")"
        [ "$s" = "$1" ] || bad_ones+=" $r=$s"
    done
    [ -z "$bad_ones" ] && return 0
    echo "expected $1 on every route, got:$bad_ones"
    return 1
}
routes_of_backend_are() { # backend, expected status
    local r s
    for r in "${routes[@]}"; do
        [ "${backend_of[$r]}" = "$1" ] || continue
        s="$(code "${r}probe")"
        [ "$s" = "$2" ] || { echo "$r answered $s, expected $2"; return 1; }
    done
}

# --- AC3: routing capture ----------------------------------------------------------------------------------------

long_a() { head -c "$1" /dev/zero | tr '\0' a; }
# #73-AC3.1 (query string, no trailing slash, //, %2F per route), #73-AC3.2 (request line of 8 KiB and over it),
# #73-AC3.8 (Host, X-Forwarded-For, X-Forwarded-Proto in the echoed request: the "headers" case spoofs both)
# one line per case: name, path, extra curl arguments (the capture is name-keyed, so the order doesn't matter)
route_cases() {
    local r name
    for r in "${routes[@]}"; do
        name="${r//\//_}"
        printf '%s\t%s\t\n' "plain$name" "${r}plain"
        printf '%s\t%s\t\n' "root$name" "$r"
        printf '%s\t%s\t\n' "query$name" "${r}q?a=1&b=%2F"
        printf '%s\t%s\t\n' "noslash$name" "${r%/}"
        printf '%s\t%s\t\n' "dslash$name" "${r}a//b"
        printf '%s\t%s\t\n' "encslash$name" "${r}a%2Fb"
        printf '%s\t%s\t\n' "nlmid$name" "${r}foo%0Abar"  # an encoded newline: PCRE's . skips it, so a rewrite without (?s) misses
        printf '%s\t%s\t\n' "nlend$name" "${r}foo%0A"
        printf '%s\t%s\t\n' "redir$name" "${r}redir"
        printf '%s\t%s\t%s\n' "headers$name" "${r}h" "-H|X-Forwarded-For: 203.0.113.9|-H|X-Forwarded-Proto: spoofed"
        printf '%s\t%s\t\n' "long8k$name" "${r}$(long_a 8100)"
        printf '%s\t%s\t\n' "longover$name" "${r}$(long_a 9000)"
    done
}
# observe <name> <path> <curl args joined by |>: one normalised line "name status location body"
observe() {
    local name="$1" path="$2" extra="$3" hdr="$work/hdr" bodyf="$work/body" status loc body
    local -a args=()
    if [ -n "$extra" ]; then IFS='|' read -r -a args <<<"$extra"; fi
    curl -s --max-time 5 --path-as-is -D "$hdr" -o "$bodyf" "${args[@]}" "$base$path" 2>/dev/null
    status="$(sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' "$hdr")"
    loc="$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | sed "s/:$port/:PORT/g")"
    case "$name" in
        long*) body="-" ;; # only the status of the over-long request lines matters
        *) body="$(sed -e "s/:$port/:PORT/g" -e 's/xff=\(203\.0\.113\.9, \)\{0,1\}[0-9a-f.:]*/xff=\1IP/' "$bodyf" | head -c 2000 | tr '\n' ' ')" ;;
    esac
    # nginx's own error pages and redirects carry a body we don't compare, only their status and Location
    case "$status" in 200) ;; *) body="-" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$loc" "$body"
}

# start_all: backends first, then the proxy (the old config cannot start before its upstreams exist)
start_all() {
    dc up -d --wait "${backends[@]}" >/dev/null 2>&1 && dc up -d --wait reverse-proxy >/dev/null 2>&1
}

# --- start -------------------------------------------------------------------------------------------------------

echo "== image: $ECHO_IMAGE"
if ! dc build reverse-proxy >"$work/build.log" 2>&1; then
    echo "FAIL: the proxy image does not build"
    tail -20 "$work/build.log"
    exit 1
fi

# record mode: all backends up, capture the eight routes, done
if [ "$record" = 1 ]; then
    start_all || { echo "stack did not start"; exit 1; }
    refresh_port
    while IFS=$'\t' read -r name path extra; do observe "$name" "$path" "$extra"; done < <(route_cases) >"$capture_file"
    echo "recorded $(wc -l <"$capture_file") cases in $capture_file (nginx $(dc exec -T reverse-proxy nginx -v 2>&1))"
    exit 0
fi

# === AC4.3: a deploy replaces the old containers and nothing drifts ================================================
# Deploy the proxy with a changed config (a new image) over the running one with `up -d --build`, and the four real
# frontends; deploy_drift (tools/tests/lib/deploy-drift.sh) must then find every container on the image just built, with
# the committed config, created after the deploy started and in the right Compose project, with no leftover container.
drift_section() {
    echo "== #73-AC4.3: up -d --build replaces the old containers, no drift"
    local scratch="$work/proxy-v2" started svc cids id out expect old_id other past_ns f rc
    mkdir -p "$scratch"
    cp "$proxy_dir/Dockerfile" "$scratch/Dockerfile"
    { cat "$proxy_dir/nginx.conf"; echo "# deploy drift check: a changed file, so the image changes"; } >"$scratch/nginx.conf"
    old_id="$(cid reverse-proxy)"
    started="$(date +%s%N)"
    PROXY_CONTEXT="$scratch" dc up -d --build --no-deps reverse-proxy >/dev/null 2>&1
    cids="$(dc ps -aq reverse-proxy)"
    if [ "$(wc -w <<<"$cids")" = 1 ] && [ "$cids" != "$old_id" ]; then ok
    else bad "#73-AC4.3" "the old proxy container was not replaced by exactly one new one" "old=$old_id now=$cids"; fi
    expect="$(docker image inspect -f '{{.Id}}' "${project}-reverse-proxy")"
    if out="$(deploy_drift "$cids" "$project" "$started" "$expect" /etc/nginx/nginx.conf "$scratch/nginx.conf")"; then ok
    else bad "#73-AC4.3" "the redeployed proxy drifted" "$out"; fi
    # the check itself must fail, naming the container and the field, for each kind of drift
    other="$work/other.conf"
    { cat "$scratch/nginx.conf"; echo "# edited"; } >"$other"
    past_ns="$(($(date +%s%N) + 3600000000000))"
    declare -A cases=(
        [image]="$cids $project $started sha256:0000000000000000000000000000000000000000000000000000000000000000 /etc/nginx/nginx.conf $scratch/nginx.conf"
        [config]="$cids $project $started $expect /etc/nginx/nginx.conf $other"
        [created]="$cids $project $past_ns $expect /etc/nginx/nginx.conf $scratch/nginx.conf"
        [project]="$cids some-other-project $started $expect /etc/nginx/nginx.conf $scratch/nginx.conf"
    )
    for f in image config created project; do
        # shellcheck disable=SC2086
        out="$(deploy_drift ${cases[$f]} 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -ne 0 ] && grep -q "drift: .*reverse-proxy.*: $f" <<<"$out"; then ok
        else bad "#73-AC4.3" "drift in the $f is not reported (exit $rc)" "$out"; fi
    done
    # the four frontends, built from the repository and deployed in a project of their own
    local fe="${project}-fe" fecompose=(-f "$root/Prince/docker-compose.yml")
    declare -A fe_dir=([core-web-vue]=prince-core-vue [checkout-web-vue]=prince-checkout-vue [core-web-react]=prince-core-react [checkout-web-react]=prince-checkout-react)
    started="$(date +%s%N)"
    docker compose -p "$fe" "${fecompose[@]}" up -d --build --no-deps "${!fe_dir[@]}" >"$work/fe-up.log" 2>&1 \
        || bad "#73-AC4.3" "the frontends did not deploy" "$(tail -5 "$work/fe-up.log")"
    for svc in "${!fe_dir[@]}"; do
        id="$(docker compose -p "$fe" "${fecompose[@]}" ps -aq "$svc" 2>/dev/null)"
        expect="$(docker image inspect -f '{{.Id}}' "${fe}-${svc}" 2>/dev/null)"
        if out="$(deploy_drift "$id" "$fe" "$started" "$expect" /etc/nginx/conf.d/default.conf "$root/Prince/Frontend/${fe_dir[$svc]}/nginx.conf")"; then ok
        else bad "#73-AC4.3" "$svc drifted" "$out"; fi
    done
}
if [ "${PROXY_TEST_ONLY:-}" = drift ]; then # only the drift section (about 2 minutes, mostly the frontend builds)
    start_all || bad "#73" "the stack did not start"
    refresh_port
    drift_section
    echo "$pass passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# === AC2: the proxy starts with every backend down ===================================================================
echo "== #73-AC2: start with every backend down"
dc up -d reverse-proxy --no-deps >/dev/null 2>&1
check "#73-AC2" "the proxy container becomes healthy with every backend missing" wait_healthy reverse-proxy 30
refresh_port
logs="$(dc logs reverse-proxy 2>&1)"
if grep -qiE 'host not found in upstream|\[emerg\]' <<<"$logs"; then
    bad "#73-AC2.10" "start-up logs show an error with backends down" "$(grep -iE 'host not found|\[emerg\]' <<<"$logs" | head -3)"
else ok; fi
check "#73-AC2" "nginx -t passes with backends down" dc exec -T reverse-proxy nginx -t
out="$(all_routes_are 502)" && ok || bad "#73-AC2.2" "all seven backends down: every route answers 502" "$out"
# #73-AC2.6: with every backend missing nothing resolves at start (Docker answers NXDOMAIN); nginx must start and answer 502
# nginx -s reload with every backend down succeeds and changes nothing
before="$(dc exec -T reverse-proxy nginx -T 2>/dev/null | md5sum)"
if dc exec -T reverse-proxy nginx -s reload >/dev/null 2>&1; then
    sleep 1
    after="$(dc exec -T reverse-proxy nginx -T 2>/dev/null | md5sum)"
    out="$(all_routes_are 502)"
    [ "$before" = "$after" ] && [ -z "${out:-}" ] && ok || bad "#73-AC2.7" "reload with backends down changed something" "$out"
else bad "#73-AC2.7" "nginx -s reload failed with every backend down"; fi

echo "== #73-AC2.3: backends start in two different orders"
order_run() { # id, backends in start order
    local id="$1" last i b s
    shift
    for b in "$@"; do
        dc up -d --no-deps "$b" >/dev/null 2>&1
        wait_healthy "$b" || { bad "$id" "$b never became healthy"; return; }
        last="$b"
    done
    local start r now
    start="$(now_ms)"
    local -a pending=("${routes[@]}")
    while [ "${#pending[@]}" -gt 0 ]; do
        local -a still=()
        for r in "${pending[@]}"; do
            [ "$(code "${r}probe")" = 200 ] || still+=("$r")
        done
        pending=("${still[@]}")
        [ "${#pending[@]}" -eq 0 ] && break
        now="$(now_ms)"
        if [ $((now - start)) -ge "$wait_limit_ms" ]; then
            bad "$id" "routes still not 200 ${wait_limit_ms} ms after $last was healthy:" "${pending[*]}"
            return
        fi
        sleep 1
    done
    [ $(($(now_ms) - start)) -le $((valid * 1000)) ] && ok || bad "$id" "the last route answered 200 later than ${valid} s"
}
# while the first backend is up and the others still missing, only its routes answer 200 (never 404, never another backend)
dc up -d --no-deps core-api >/dev/null 2>&1
wait_healthy core-api
poll_until_200 /api/x core-api || bad "#73-AC2" "a backend started late is not found within the limit (statuses:$seen)"
out="$(routes_of_backend_are core-api 200; for b in "${routes[@]}"; do [ "${backend_of[$b]}" = core-api ] || [ "$(code "${b}probe")" = 502 ] || echo "$b is not 502"; done)"
[ -z "$out" ] && ok || bad "#73-AC2.2" "one backend up: only its routes answer 200, the others 502" "$out"
dc rm -sf core-api >/dev/null 2>&1
order_run "#73-AC2.3" "${backends[@]}"
dc rm -sf "${backends[@]}" >/dev/null 2>&1
rev=()
for ((i = ${#backends[@]} - 1; i >= 0; i--)); do rev+=("${backends[$i]}"); done
order_run "#73-AC2.3" "${rev[@]}"

# the proxy of the next section starts after its backends, from a clean stack
dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
start_all || bad "#73-AC1" "the stack did not start for the recreation cases"
refresh_port
proxy_started="$(docker inspect -f '{{.State.StartedAt}}' "$(cid reverse-proxy)")"

# === AC1: recreated backends are found again =========================================================================
echo "== #73-AC1: recreate backends"
# #73-AC1.9: 127.0.0.11 is Docker's embedded DNS on the project's own user-defined network, where this whole run happens
check "#73-AC1.2" "the resolver's valid= is set in the config (read: '${config_valid:-nothing}')" test -n "$config_valid"
for b in "${backends[@]}"; do
    if [ "$b" = core-api ]; then
        # AC1.5: five requests per second during the recreation, only 200 or 502 and never another backend's answer
        : >"$work/stream"
        touch "$work/streaming"
        (
            while [ -e "$work/streaming" ]; do
                ( # each request in its own process: a slow answer must not hold back the next one
                    reply="$(curl -s --max-time 12 -w '\n%{http_code}' "$base/api/x" 2>/dev/null)"
                    echo "${reply##*$'\n'} $(grep -o 'backend=[a-z-]*' <<<"$reply")" >>"$work/stream"
                ) &
                sleep 0.2
            done
            wait
        ) &
    fi
    recreate "$b" || { bad "#73-AC1" "$b did not come back healthy with a new address"; continue; }
    proxy_now="$(docker inspect -f '{{.State.StartedAt}}' "$(cid reverse-proxy)")"
    recovers "#73-AC1" "after recreating $b the route answers 200 without a proxy restart" "$b"
    [ "$proxy_now" = "$proxy_started" ] && ok || bad "#73-AC1" "the proxy was restarted while recreating $b"
    if [ "$b" = core-api ]; then
        rm -f "$work/streaming"
        wait
        n_stream="$(wc -l <"$work/stream")"
        odd="$(grep -vE '^200 backend=core-api$|^502 $' "$work/stream" | sort | uniq -c | head -3)"
        [ -z "$odd" ] && [ "$(wc -l <"$work/stream")" -gt 5 ] && ok || bad "#73-AC1.5" "requests during the recreation got something else than 200 from core-api or 502 (${n_stream:-0} requests)" "$odd"
    fi
done
# AC1.7: the same backend recreated twice in a row recovers both times
for n in 1 2; do
    recreate core-api && recovers "#73-AC1.7" "core-api recreated for the ${n}. time in a row recovers" core-api \
        || bad "#73-AC1.7" "core-api recreated for the ${n}. time did not recover"
done

# one backend down: only its routes answer 502
dc stop checkout-api >/dev/null 2>&1
sleep $((valid + 2)) # the stale address may still be cached; 502 either way, but wait so the check below is exact
out="$(routes_of_backend_are checkout-api 502)" && ok || bad "#73-AC2.2" "checkout-api down: its route answers 502" "$out"
out="$(for r in "${routes[@]}"; do [ "${backend_of[$r]}" = checkout-api ] && continue; [ "$(code "${r}probe")" = 200 ] || echo "$r is not 200"; done)"
[ -z "$out" ] && ok || bad "#73-AC2.2" "checkout-api down: the other routes keep answering 200" "$out"
# AC1.10: the failed resolution is logged with the upstream name and no request headers
get_logged="$(curl -s -o /dev/null --max-time 10 -H 'X-Canary: canary-secret-73' -H 'Authorization: Bearer canary-secret-73' "$base/api/checkout/x"; sleep 1; dc logs reverse-proxy 2>&1 | grep -F 'could not be resolved' | tail -1)"
if grep -q 'checkout-api' <<<"$get_logged" && ! grep -qi 'canary-secret-73' <<<"$get_logged"; then ok
else bad "#73-AC1.10" "error log of a failed resolution names the upstream and holds no request headers" "${get_logged:-<no 'could not be resolved' line>}"; fi
# AC1.6: removed backend, 502 and never another backend's content
dc rm -sf checkout-api >/dev/null 2>&1
body="$(curl -s --max-time 10 -w '\n%{http_code}' "$base/api/checkout/x")"
[ "${body##*$'\n'}" = 502 ] && ! grep -q 'backend=' <<<"$body" && ok || bad "#73-AC1.6" "removed backend: 502 with nothing from another backend" "${body: -300}"
dc up -d --no-deps checkout-api >/dev/null 2>&1
wait_healthy checkout-api
recovers "#73-AC1.3" "a backend stopped and started again recovers" checkout-api

# === AC2.9: a dual-stack network (AAAA answers) ======================================================================
echo "== #73-AC2.9: dual-stack network"
dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
compose_files=(-f "$fixture/compose.yml" -f "$fixture/compose.ipv6.yml")
if start_all; then
    refresh_port
    out="$(all_routes_are 200)" && ok || bad "#73-AC2.9" "dual-stack network: every route answers 200" "$out"
    recreate core-api && recovers "#73-AC2.9" "dual-stack network: a recreated backend is found again" core-api
else
    bad "#73-AC2.9" "the dual-stack fixture did not start (is IPv6 enabled in Docker?)"
fi
dc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
compose_files=(-f "$fixture/compose.yml")

# === AC3: routing before and after ===================================================================================
echo "== #73-AC3: routing equals the recorded capture"
# #73-AC3.9: the "before" is routes.capture, a fixture recorded on the old config; the old image is not needed
start_all || bad "#73-AC3" "the stack did not start for the routing comparison"
refresh_port
while IFS=$'\t' read -r name path extra; do observe "$name" "$path" "$extra"; done < <(route_cases) >"$work/now"
while IFS=$'\t' read -r name path extra; do observe "$name" "$path" "$extra"; done < <(route_cases) >"$work/again"
if diff "$capture_file" "$work/now" >"$work/diff"; then ok; else bad "#73-AC3" "routing differs from the recorded capture" "$(head -20 "$work/diff")"; fi
check "#73-AC3.7" "the same requests twice return the same responses" diff -q "$work/now" "$work/again" >/dev/null

# the fail-closed rewrite check
# A rewrite that misses must fail closed: every location has `return 400` after its rewrite. A scratch copy whose first
# rewrite can't match (the 400 comes before any lookup, so no backend is needed) must answer 400, not forward the raw URI.
echo "== fail-closed: a rewrite that misses answers 400"
sed 's#rewrite "(?s)^/api/(\.\*)$"#rewrite "(?s)^/nomatch/(.*)$"#' "$proxy_dir/nginx.conf" >"$work/miss.conf"
cid_miss="$(docker run -d --entrypoint nginx -v "$work/miss.conf":/etc/nginx/nginx.conf:ro -p 127.0.0.1::80 "${project}-reverse-proxy" -g 'daemon off;' 2>/dev/null)"
sleep 2
miss_port="$(docker port "$cid_miss" 80 2>/dev/null | head -1 | sed 's/.*://')"
if grep -q nomatch "$work/miss.conf" && [ "$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "http://127.0.0.1:$miss_port/api/x")" = 400 ]; then ok
else bad "#73-AC3" "a rewrite that misses answers 400"; fi
docker rm -f "$cid_miss" >/dev/null 2>&1
echo "== #73-AC4: nginx branch and images"
echo "nginx -v (proxy): $(dc exec -T reverse-proxy nginx -v 2>&1)"
dockerfiles=("$proxy_dir/Dockerfile" "$root"/Prince/Frontend/*/Dockerfile)
froms="$(grep -h '^FROM nginx:' "${dockerfiles[@]}" | sed 's/ AS .*//' | sort -u)"
nfroms="$(grep -h '^FROM nginx:' "${dockerfiles[@]}" | wc -l)"
if [ "$nfroms" = 5 ] && [ "$(wc -l <<<"$froms")" = 1 ] && grep -qE '^FROM nginx:[0-9.]+-alpine@sha256:[0-9a-f]{64}$' <<<"$froms" && ! grep -q 'nginx:1\.27' <<<"$froms"; then ok
else bad "#73-AC4" "the proxy and the four frontends name one maintained nginx version pinned by digest (found $nfroms)" "$froms"; fi
for conf in "$root"/Prince/Frontend/*/nginx.conf; do
    check "#73-AC4" "nginx -t passes for $(basename "$(dirname "$conf")")'s config" \
        docker run --rm --entrypoint nginx -v "$conf":/etc/nginx/conf.d/default.conf:ro "$ECHO_IMAGE" -t >/dev/null 2>&1
done
# #73-AC4.10: nginx -v is printed above; the version and digest are in the PR
# the effective config of the proxy image equals the committed one
effective="$(docker run --rm --entrypoint nginx "${project}-reverse-proxy" -T 2>/dev/null | awk '/^# configuration file \/etc\/nginx\/nginx.conf:/{f=1;next} /^# configuration file /{f=0} f')"
if [ "$effective" = "$(cat "$proxy_dir/nginx.conf")" ]; then ok; else bad "#73-AC4.9" "nginx -T of the proxy image differs from the committed nginx.conf"; fi
# a digest that does not exist fails the build and the log names it
mkdir -p "$work/baddigest"
cp "$proxy_dir/nginx.conf" "$work/baddigest/"
sed 's/sha256:[0-9a-f]\{64\}/sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$proxy_dir/Dockerfile" >"$work/baddigest/Dockerfile"
if docker build -q "$work/baddigest" >"$work/baddigest.log" 2>&1; then bad "#73-AC4.6" "a build with a wrong digest succeeded"
elif grep -q 'sha256:0000000000000000' "$work/baddigest.log"; then ok
else bad "#73-AC4.6" "the failed build's log does not name the digest" "$(tail -5 "$work/baddigest.log")"; fi
# the proxy runs the way it does today: user nginx for the workers, no extra capability
workers="$(dc exec -T reverse-proxy sh -c "ps -o user,args | grep 'nginx: worker' | grep -v grep | awk '{print \$1}' | sort -u" 2>/dev/null | tr -d '\r')"
[ "$workers" = nginx ] && ok || bad "#73-AC4.8" "worker processes run as nginx (found: '${workers:-none}')"
# recorded for the runtime-hardening ticket, not a pass or fail: would the image start read-only, without capabilities, as nginx, on 8080?
sed -e 's/listen 80;/listen 8080;/' -e '/^user nginx;/d' -e 's#^worker_processes auto;#pid /tmp/nginx.pid;\nworker_processes auto;#' "$proxy_dir/nginx.conf" >"$work/hardened.conf"
hid="$(docker run -d --read-only --cap-drop ALL --user 101:101 --tmpfs /tmp --tmpfs /var/cache/nginx:uid=101,gid=101 \
    -v "$work/hardened.conf":/etc/nginx/nginx.conf:ro --entrypoint nginx "${project}-reverse-proxy" -g 'daemon off;' 2>&1)"
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "$hid" 2>/dev/null)" = true ]; then
    echo "INFO #73-AC4.8: the image starts read-only, cap_drop ALL, user 101, port 8080 (pid file moved to /tmp)"
else
    echo "INFO #73-AC4.8: the image does NOT start hardened: $(docker logs "$hid" 2>&1 | tail -2 | tr '\n' ' ')"
fi
docker rm -f "$hid" >/dev/null 2>&1

# last: it rebuilds the proxy image from a changed copy
drift_section

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
