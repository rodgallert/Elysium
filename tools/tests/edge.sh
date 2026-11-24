#!/usr/bin/env bash
# Tests for the edge proxy (#75): Edge/docker-compose.yml and Edge/nginx.conf. Real containers: the edge from Edge/ (project
# elysium-edge, network elysium-edge, host port 80 on loopback) in front of two stub upstreams named as the aliases of the
# stacks' entry proxies (tools/tests/edge/stubs.yml). Everything it creates is removed afterwards.
#
# Ids: every test names its criterion or edge case (#75-AC<n>[.<m>]) in its check call or its section comment.
#
# Usage: tools/tests/edge.sh
#   EDGE_SMOKE=1  also runs the smoke against the real Prince stack (#75-AC6, AC7.9): the stack is built and started in a
#                 Compose project of its own (a few minutes). Not run in CI.
# Needs Docker with Compose 2.22+, curl, jq, ss and a free loopback port 80 (the test uses the real ports and network names,
# so it can't run next to a running edge: it says so and stops, or fails when CI is set).
# Takes about 2 minutes (one 30 s wait for the upstream read timeout). The windows of 10 s (the name lookup, #75-AC1.3 and AC3.3, and
# the client header and body timeouts, AC3.4) are tested with 12 s: two seconds of tolerance on a loaded machine.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$root/tools/tests/edge"
edge_src="$root/Edge"
work="$(mktemp -d)"
tag="edgetest$$"
stubs_project="elysium-$tag"
pass=0
failed=0
skipped=0

ECHO_IMAGE="$(sed -n 's/^ *image: \(nginx:[^ ]*\).*/\1/p' "$edge_src/docker-compose.yml" | head -1)"
ALPINE_IMAGE="$(sed -n 's/^ *image: \(alpine:[^ ]*\).*/\1/p' "$root/Prince/docker-compose.yml" | head -1)"
export ECHO_IMAGE

edge_dir="$work/edge" # a copy of Edge/ with a .env of markers next to it (#75-AC1.10)
edc() { docker compose -f "$edge_dir/docker-compose.yml" "$@"; }
sdc() { docker compose -p "$stubs_project" -f "$fixture/stubs.yml" "$@"; }
stackdc() { docker compose -f "$fixture/stack.yml" "$@"; }

ok() { pass=$((pass + 1)); }
bad() { # id description detail
    failed=$((failed + 1))
    echo "FAIL: $1 $2"
    [ -n "${3:-}" ] && printf '%s\n' "    ${3//$'\n'/$'\n    '}"
}
skip() { # id reason
    skipped=$((skipped + 1))
    echo "SKIP: $1 $2"
}
check() { # id description command...: passes when the command succeeds
    local id="$1" desc="$2"
    shift 2
    if "$@"; then ok; else bad "$id" "$desc"; fi
}
eq() { # id description expected actual
    if [ "$3" = "$4" ]; then ok; else bad "$1" "$2" "expected: $3"$'\n'"got:      $4"; fi
}

cleanup() {
    sdc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    stackdc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    [ -f "$edge_dir/docker-compose.yml" ] && edc down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker ps -aq --filter "label=edgetest=$tag" | xargs -r docker rm -f >/dev/null 2>&1
    docker compose -p "${tag}-prince" -f "$root/Prince/docker-compose.yml" down -v --remove-orphans --timeout 2 >/dev/null 2>&1
    docker images --format '{{.Repository}}' | grep "^${tag}-prince-" | xargs -r docker rmi -f >/dev/null 2>&1
    # the network belongs to the edge project; if something is still attached it stays and the next run says so
    docker network rm elysium-edge >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

# --- preconditions -----------------------------------------------------------------------------------------------

refuse() { # reason: SKIP locally (a real edge may be running), FAIL in CI
    if [ -n "${CI:-}" ]; then
        echo "FAIL: precondition: $1"
        exit 1
    fi
    echo "SKIP: all of #75: $1"
    trap - EXIT
    rm -rf "$work"
    exit 0
}
for tool in docker curl jq ss; do
    command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not installed"
done
if docker network inspect elysium-edge >/dev/null 2>&1; then
    refuse "the network elysium-edge exists (a running edge?): stop it first, this test uses the real names"
fi
if (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null; then
    refuse "something already listens on 127.0.0.1:80: stop it first, this test uses the real port"
fi

# --- helpers -----------------------------------------------------------------------------------------------------

now_ms() { date +%s%3N; }
edge_id() { docker inspect -f '{{.Id}}' elysium-edge-edge-1 2>/dev/null; }
edge_started() { docker inspect -f '{{.State.StartedAt}}' elysium-edge-edge-1 2>/dev/null; }
restarts() { docker inspect -f '{{.RestartCount}}' elysium-edge-edge-1 2>/dev/null; }
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' elysium-edge-edge-1 2>/dev/null; }

# get <host> <path> [curl args...]: sets $status, $hdrs (CR removed) and $body. A host of "" sends curl's own Host.
status="" hdrs="" body=""
get() {
    local host="$1" path="$2"
    shift 2
    local -a h=()
    [ -n "$host" ] && h=(-H "Host: $host")
    status="$(curl -s -o "$work/body" -D "$work/hdr" --max-time 40 --path-as-is -w '%{http_code}' "${h[@]}" "$@" "http://127.0.0.1:80$path" 2>/dev/null)"
    hdrs="$(tr -d '\r' <"$work/hdr" 2>/dev/null)"
    body="$(cat "$work/body" 2>/dev/null)"
}
# raw <printf format> [args]: sends the bytes on a fresh connection and prints the whole response (waits up to 15 s)
raw() {
    local fmt="$1"
    shift
    (
        exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
        # shellcheck disable=SC2059
        printf "$fmt" "$@" >&3
        timeout 15 cat <&3
    ) 2>/dev/null
}
raw_status() { raw "$@" | head -1 | awk '{print $2}'; }
header() { # name: the first value of a response header from $hdrs
    sed -n "s/^$1: *//Ip" <<<"$hdrs" | head -1
}
header_count() { grep -ci "^$1:" <<<"$hdrs"; }
# what the echo stub saw
echo_req() { sed -n 's/^backend=[a-z]* request=\(.*\) host=.*/\1/p' <<<"$body"; }
echo_field() { sed -n "s/^.* $1=\([^ ]*\).*/\1/p" <<<"$body" | head -1; }
echo_backend() { sed -n 's/^backend=\([a-z]*\) .*/\1/p' <<<"$body"; }

# poll_status <host> <path> <status> <seconds>: 0 when the status shows up within the time; sets $elapsed_ms
elapsed_ms=0
poll_status() {
    local start i
    start="$(now_ms)"
    for ((i = 0; i < $4; i++)); do
        get "$1" "$2"
        elapsed_ms=$(($(now_ms) - start))
        [ "$status" = "$3" ] && return 0
        sleep 1
    done
    return 1
}

# --- the published-port lint (#75-AC2, AC2.1) --------------------------------------------------------------------
# lint_ports <compose file> [edge|stack]: prints one line per published port that breaks the rule. Every published port
# names 127.0.0.1 or ::1. In the edge's file the ports are exactly 127.0.0.1:80 and [::1]:80 (container 8080); in any
# other file nothing is published except the Silo console, 127.0.0.1:9001 of file-storage. `network_mode: host` fails in every
# file: the container would listen on every interface with no `ports` to read.
lint_ports() {
    local file="$1" kind="${2:-any}" cfg
    cfg="$(docker compose -f "$file" config --no-interpolate --format json 2>&1)" || { echo "$file: docker compose config failed: $(head -1 <<<"$cfg")"; return 1; }
    jq -r --arg f "$file" --arg kind "$kind" '
        [.services | to_entries[] | .key as $s | (.value.ports // [])[] | {s: $s, ip: (.host_ip // ""), pub: (.published // ""), tgt: (.target | tostring)}] as $ports
        | ($ports[] | select(.ip != "127.0.0.1" and .ip != "::1") | "\($f): \(.s): published port \(.pub):\(.tgt) is not bound to 127.0.0.1 or ::1 (host address \(.ip | if . == "" then "missing, so every interface" else . end))"),
          (.services | to_entries[] | select(.value.network_mode == "host") | "\($f): \(.key): network_mode: host listens on every interface of the machine"),
          (if $kind == "edge" then
              (if ([$ports[] | "\(.ip)|\(.pub)|\(.tgt)"] | sort) != ["127.0.0.1|80|8080", "::1|80|8080"] then "\($f): the edge must publish exactly 127.0.0.1:80 and [::1]:80 (container 8080)" else empty end)
           elif $kind == "stack" then
              ($ports[] | select((.s == "file-storage" and .ip == "127.0.0.1" and .pub == "9001" and .tgt == "9001") | not) | "\($f): \(.s): only the edge publishes (the Silo console 127.0.0.1:9001 is the one exception), not \(.ip):\(.pub)")
           else empty end)' <<<"$cfg" | sort -u
}
lint_fails() { [ -n "$(lint_ports "$@")" ]; }

# === static checks: no containers ================================================================================

echo "== static: config, lint, nginx -t"

edge_json="$(docker compose -f "$edge_src/docker-compose.yml" config --no-interpolate --format json 2>&1)"
[ -n "$edge_json" ] && jq -e . >/dev/null 2>&1 <<<"$edge_json" || { echo "FAIL: Edge/docker-compose.yml does not parse: $edge_json"; exit 1; }
# jq_ok <json> <filter>: succeeds when the filter is true; its output goes nowhere, so a check's own FAIL line is still printed
jq_ok() { jq -e "$2" >/dev/null <<<"$1"; }
svc() { jq -r ".services.edge | $1" <<<"$edge_json"; }

# #75-AC1.1 inputs: nginx -t rejects a broken config before any container starts, and accepts the real one (same flags as the container)
nginx_t() { # config file
    docker run --rm --read-only --tmpfs /tmp:uid=101,gid=101 --tmpfs /var/cache/nginx:uid=101,gid=101 -u 101:101 --cap-drop ALL \
        -v "$1:/etc/nginx/nginx.conf:ro,z" "$ECHO_IMAGE" nginx -t 2>&1
}
if out="$(nginx_t "$fixture/fixtures/broken-nginx.conf")"; then bad "#75-AC1.1" "nginx -t accepted a broken config" "$out"; else ok; fi
out="$(nginx_t "$edge_src/nginx.conf")" && ok || bad "#75-AC1.1" "nginx -t rejects Edge/nginx.conf" "$out"

# #75-AC1: the container's hardening as written in the file
eq "#75-AC1" "runs as a non-root user" "101:101" "$(svc .user)"
eq "#75-AC1" "read_only" "true" "$(svc .read_only)"
eq "#75-AC1" "cap_drop ALL" '["ALL"]' "$(svc '.cap_drop' | jq -c .)"
eq "#75-AC1" "no-new-privileges" '["no-new-privileges:true"]' "$(svc '.security_opt' | jq -c .)"
check "#75-AC1" "tmpfs for nginx's cache and pid paths" jq_ok "$edge_json" '.services.edge.tmpfs | (index("/tmp:uid=101,gid=101,mode=1777,size=16m") != null) and (map(startswith("/var/cache/nginx:")) | any)'
check "#75-AC1" "the pid file is on the tmpfs, not on a read-only path" grep -q '^pid /tmp/' "$edge_src/nginx.conf"
# the PO-confirmed values (2026-11-23): the cache tmpfs, the process limit and the health check's retries and start timings
check "#75-AC1" "tmpfs /var/cache/nginx is 128 MiB" jq_ok "$edge_json" '.services.edge.tmpfs | index("/var/cache/nginx:uid=101,gid=101,mode=0755,size=128m") != null'
eq "#75-AC1" "pids_limit 100" "100" "$(svc .pids_limit)"
eq "#75-AC1.4" "health check retries 3, start_period 5s, start_interval 1s" "3 5s 1s" "$(svc '.healthcheck | "\(.retries) \(.start_period) \(.start_interval)"')"
# #75-AC1.4 time: the check's interval 5 s and timeout 3 s
eq "#75-AC1.4" "healthcheck interval and timeout" "5s 3s" "$(svc '.healthcheck | "\(.interval) \(.timeout)"')"
# #75-AC1.8 permissions: no Docker socket, no network but elysium-edge
check "#75-AC1.8" "no Docker socket mounted" bash -c '! grep -q "docker.sock" <<<"$1"' _ "$edge_json"
eq "#75-AC1.8" "the edge joins no network but elysium-edge" '["elysium-edge"]' "$(svc '.networks | keys' | jq -c .)"
eq "#75-AC1.8" "no network_mode and no privileged" "null null" "$(svc '"\(.network_mode) \(.privileged)"')"
# #75-AC1.9 environment differences: the bind mount carries :z for SELinux
eq "#75-AC1.9" "the config bind mount is relabelled (selinux z)" "z" "$(svc '.volumes[] | select(.target == "/etc/nginx/nginx.conf") | .bind.selinux')"
# #75-AC2 (config): exactly two published ports; the lint passes on the repository's own files
eq "#75-AC2" "two published ports, loopback only" "127.0.0.1:80->8080 ::1:80->8080" \
    "$(svc '.ports | map("\(.host_ip):\(.published)->\(.target)") | sort | join(" ")' | sed 's/^::1/::1/')"
for f in "$root/Prince/docker-compose.yml" "$root/docker-compose.prod.yml"; do
    [ -f "$f" ] || continue
    out="$(lint_ports "$f" stack)" && [ -z "$out" ] && ok || bad "#75-AC2" "$(basename "$f"): a published port breaks the rule" "$out"
done
out="$(lint_ports "$edge_src/docker-compose.yml" edge)" && [ -z "$out" ] && ok || bad "#75-AC2" "Edge/docker-compose.yml: a published port breaks the rule" "$out"
# #75-AC2.1 inputs: a bare port, 0.0.0.0, [::] and network_mode: host fail the lint (fixture files); a loopback port passes
for n in bare all v6all hostmode; do
    check "#75-AC2.1" "the lint fails the case \"$n\"" lint_fails "$fixture/fixtures/ports-$n.yml"
done
out="$(lint_ports "$fixture/fixtures/ports-ok.yml")"
[ -z "$out" ] && ok || bad "#75-AC2.1" "the lint fails a loopback port" "$out"
# the same file in the edge's strict mode names what is wrong with a wrong port
out="$(lint_ports "$fixture/fixtures/ports-ok.yml" edge)"
grep -q "exactly 127.0.0.1:80 and \[::1\]:80" <<<"$out" && ok || bad "#75-AC2.1" "the edge rule accepts one port only" "$out"
# #75-AC3.9 environment differences: the resolver and the allow-list live in the config, the same everywhere
conf="$edge_src/nginx.conf"
check "#75-AC3.9" "resolver 127.0.0.11 valid=10s ipv6=off" grep -q '^ *resolver 127\.0\.0\.11 valid=10s ipv6=off;' "$conf"
check "#75-AC3.4" "timeouts as specified" bash -c 'for d in "proxy_connect_timeout 3s" "proxy_read_timeout 30s" "proxy_send_timeout 30s" "client_header_timeout 10s" "client_body_timeout 10s"; do grep -q "^ *$d;" "$1" || exit 1; done' _ "$conf"
check "#75-AC3.2" "buffers and body limit as specified" bash -c 'grep -q "^ *large_client_header_buffers 4 8k;" "$1" && grep -q "^ *client_max_body_size 10m;" "$1"' _ "$conf"
check "#75-AC3.10" "server_tokens off" grep -q '^ *server_tokens off;' "$conf"
check "#75-AC5" "access log is one json line with escape=json" grep -q 'log_format edge escape=json' "$conf"
check "#75-AC4.8" "no cookie rewriting" bash -c '! grep -q "proxy_cookie" "$1"' _ "$conf"
check "#75-AC4.9" "the policy stays report-only (no enforcing header)" bash -c '! grep -qi "add_header Content-Security-Policy " "$1"' _ "$conf"

# #75-AC6 (config): the stack joins the edge network under its alias and publishes nothing
pj="$(docker compose -f "$root/Prince/docker-compose.yml" config --no-interpolate --format json 2>&1)"
eq "#75-AC6" "reverse-proxy has the alias prince-prod-proxy on elysium-edge" '["prince-prod-proxy"]' "$(jq -c '.services["reverse-proxy"].networks["elysium-edge"].aliases' <<<"$pj")"
eq "#75-AC6" "reverse-proxy keeps the stack's default network" "true" "$(jq '.services["reverse-proxy"].networks | has("default")' <<<"$pj")"
eq "#75-AC6" "elysium-edge is external, with the fixed name" '{"name":"elysium-edge","external":true}' "$(jq -c '.networks["elysium-edge"] | {name, external}' <<<"$pj")"
eq "#75-AC6" "reverse-proxy publishes no port" "null" "$(jq -c '.services["reverse-proxy"].ports' <<<"$pj")"
eq "#75-AC6" "postgres publishes no port" "null" "$(jq -c '.services.postgres.ports' <<<"$pj")"
eq "#75-AC6" "only services that need the edge are on it" '["reverse-proxy"]' "$(jq -c '[.services | to_entries[] | select(.value.networks // {} | has("elysium-edge")) | .key]' <<<"$pj")"
check "#75-AC6" "no REVERSE_PROXY_PORT setting left in the example env, the compose file or env-check (comments may mention it)" bash -c '! cat "$1/Prince/.env.example" "$1/Prince/docker-compose.yml" "$1/Prince/env-check.sh" | grep -v "^ *#" | grep -q REVERSE_PROXY_PORT' _ "$root"
# #75-AC6.9 environment differences: an .env that still sets the removed key is ignored, no error
printf '%s\n' POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d REVERSE_PROXY_PORT=8080 JOBS_ADMIN_EMAIL=a@b.c 'JOBS_ADMIN_PASSWORD=ChangeMe123!' \
    FILE_STORAGE_ROOT_USER=prince-admin 'FILE_STORAGE_ROOT_PASSWORD=ChangeMe123!' FILE_STORAGE_BUCKET=product-files >"$work/old.env"
out="$(docker compose --env-file "$work/old.env" -f "$root/Prince/docker-compose.yml" config --format json 2>&1)" \
    && jq -e '.services["reverse-proxy"].ports == null' >/dev/null <<<"$out" && ok || bad "#75-AC6.9" "an .env that still sets REVERSE_PROXY_PORT is not ignored" "$(head -3 <<<"$out")"
sed '/^REVERSE_PROXY_PORT=/d' "$work/old.env" >"$work/new.env"
out="$(env -i PATH="$PATH" POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d JOBS_ADMIN_EMAIL=a@b.c 'JOBS_ADMIN_PASSWORD=ChangeMe123!' \
    FILE_STORAGE_ROOT_USER=prince-admin 'FILE_STORAGE_ROOT_PASSWORD=ChangeMe123!' FILE_STORAGE_BUCKET=product-files sh "$root/Prince/env-check.sh" 2>&1)" \
    && ok || bad "#75-AC6.9" "env-check rejects an .env without REVERSE_PROXY_PORT" "$out"

# === a stack's up with no edge network (#75-AC1.5, AC1.6) =========================================================

echo "== #75-AC1.5, AC1.6: a stack and the missing network"
mkdir -p "$edge_dir"
cp "$edge_src/docker-compose.yml" "$edge_src/nginx.conf" "$edge_dir/"
# an .env of markers next to the compose file: none of its values may show up in the edge's output (#75-AC1.10, AC2.10)
env_marker="EDGE-ENV-MARKER-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n' "POSTGRES_PASSWORD=$env_marker" "EDGE_SECRET=$env_marker" >"$edge_dir/.env"

# #75-AC1.6: no network: non-zero within 10 s, the output names elysium-edge, no hang, nothing created
start="$(now_ms)"
out="$(timeout 30 docker compose -f "$fixture/stack.yml" up -d 2>&1)" && rc=0 || rc=$?
took=$(($(now_ms) - start))
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ok || bad "#75-AC1.6" "a stack's up without the network did not fail (exit $rc)" "$out"
[ "$took" -le 10000 ] && ok || bad "#75-AC1.6" "the failing up took ${took} ms (limit 10000)"
grep -q 'elysium-edge' <<<"$out" && ok || bad "#75-AC1.6" "the output does not name elysium-edge" "$out"
eq "#75-AC1.5" "the stack's up does not create a network named elysium-edge" "0" "$(docker network ls -q --filter name='^elysium-edge$' | wc -l)"
stackdc down -v --timeout 2 >/dev/null 2>&1

# #75-AC1.5 concurrency: a stack's up while the edge starts fails or waits, and one network named elysium-edge exists afterwards
(edc up -d >/dev/null 2>&1) &
bg=$!
out="$(timeout 30 docker compose -f "$fixture/stack.yml" up -d 2>&1)" && rc=0 || rc=$?
wait "$bg"
if [ "$rc" -ne 0 ]; then
    grep -q 'elysium-edge' <<<"$out" && ok || bad "#75-AC1.5" "the stack's up failed without naming elysium-edge" "$out"
else ok; fi
eq "#75-AC1.5" "one network named elysium-edge" "1" "$(docker network ls -q --filter name='^elysium-edge$' | wc -l)"
stackdc down -v --timeout 2 >/dev/null 2>&1
edc down -v --timeout 2 >/dev/null 2>&1
eq "#75-AC1.5" "the network is gone after down" "0" "$(docker network ls -q --filter name='^elysium-edge$' | wc -l)"

# === the edge starts with no stack running ===========================================================================

echo "== #75-AC1: start"
start="$(now_ms)"
out="$(edc up -d --wait 2>&1)" && rc=0 || rc=$?
up_ms=$(($(now_ms) - start))
[ "$rc" -eq 0 ] && ok || bad "#75-AC1" "docker compose up -d --wait failed" "$out"
echo "note: up --wait took ${up_ms} ms"
# healthy within 3 s of up returning
for _ in 1 2 3; do [ "$(health)" = healthy ] && break; sleep 1; done
eq "#75-AC1" "healthy within 3 s of up returning" "healthy" "$(health)"
eq "#75-AC1" "RestartCount 0" "0" "$(restarts)"
eq "#75-AC1" "the network elysium-edge exists" "1" "$(docker network ls -q --filter name='^elysium-edge$' | wc -l)"
eq "#75-AC1" "the container's user is 101" "101:101" "$(docker inspect -f '{{.Config.User}}' elysium-edge-edge-1)"
eq "#75-AC1" "the process does not run as root" "101" "$(docker exec elysium-edge-edge-1 id -u)"
eq "#75-AC1" "read-only root file system" "true" "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' elysium-edge-edge-1)"
check "#75-AC1" "a write to the root file system fails" bash -c '! docker exec elysium-edge-edge-1 touch /etc/nginx/x 2>/dev/null'
check "#75-AC1" "/tmp and the cache path are tmpfs" bash -c 'docker exec elysium-edge-edge-1 sh -c "grep -q \" /tmp tmpfs \" /proc/mounts && grep -q \" /var/cache/nginx tmpfs \" /proc/mounts"'
eq "#75-AC1" "all capabilities dropped" '["ALL"]' "$(docker inspect -f '{{json .HostConfig.CapDrop}}' elysium-edge-edge-1)"
check "#75-AC1" "no-new-privileges" bash -c 'docker inspect -f "{{json .HostConfig.SecurityOpt}}" elysium-edge-edge-1 | grep -q "no-new-privileges:true"'
sleep 3 # idle: let nginx settle before the memory reading
mem="$(docker stats --no-stream --format '{{.MemUsage}}' elysium-edge-edge-1 | awk '{v=$1; u=v; gsub(/[0-9.]/, "", u); sub(/[A-Za-z]+/, "", v); if (u=="KiB") v=v/1024; else if (u=="GiB") v=v*1024; else if (u=="B") v=v/1048576; printf "%.1f", v}')"
echo "note: idle memory ${mem} MiB"
check "#75-AC1" "memory at idle is at most 32 MiB (${mem} MiB)" awk -v m="$mem" 'BEGIN { exit !(m + 0 <= 32 && m + 0 > 0) }'
eq "#75-AC1.4" "the container's healthcheck interval and timeout" "5s 3s" "$(docker inspect -f '{{.Config.Healthcheck.Interval}} {{.Config.Healthcheck.Timeout}}' elysium-edge-edge-1)"
check "#75-AC1.8" "the container is on no network but elysium-edge" bash -c '[ "$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}" elysium-edge-edge-1)" = "elysium-edge " ]'
check "#75-AC1.8" "no Docker socket in the container's mounts" bash -c '! docker inspect -f "{{range .Mounts}}{{.Source}} {{end}}" elysium-edge-edge-1 | grep -q docker.sock'
# #75-AC1.10 observability: no value of the .env in the healthcheck output, the logs or the config
check "#75-AC1.10" "no .env value in the docker logs" bash -c '! docker logs elysium-edge-edge-1 2>&1 | grep -q "$1"' _ "$env_marker"
check "#75-AC1.10" "no .env value in the healthcheck log" bash -c '! docker inspect -f "{{json .State.Health.Log}}" elysium-edge-edge-1 | grep -q "$1"' _ "$env_marker"
check "#75-AC1.10" "no .env value in the container's environment" bash -c '! docker inspect -f "{{json .Config.Env}}" elysium-edge-edge-1 | grep -q "$1"' _ "$env_marker"

# #75-AC1.3 state and lifecycle: with no stack the edge answers (502 for a known host, 421 for an unknown one) and stays up
start_id="$(edge_id)" started_at="$(edge_started)"
get prince.localhost /
eq "#75-AC1.3" "no stack: a known host answers 502" "502" "$status"
get evil.example /
eq "#75-AC1.3" "no stack: an unknown host answers 421" "421" "$status"
eq "#75-AC1.3" "the edge did not exit on the unresolvable name" "running" "$(docker inspect -f '{{.State.Status}}' elysium-edge-edge-1)"
sdc up -d --wait >/dev/null 2>&1 || bad "#75-AC1.3" "the stub upstreams did not start"
if poll_status prince.localhost / 200 14; then
    [ "$elapsed_ms" -le 12000 ] && ok || bad "#75-AC1.3" "the stack became reachable only after ${elapsed_ms} ms (limit 12000)"
else bad "#75-AC1.3" "a stack started later is not reachable within 12 s"; fi
poll_status prince.dev.localhost / 200 14 && ok || bad "#75-AC1.3" "the dev stub is not reachable within 12 s"
eq "#75-AC1.3" "the edge was not restarted" "$start_id $started_at 0" "$(edge_id) $(edge_started) $(restarts)"

# === #75-AC2: published ports ========================================================================================

echo "== #75-AC2: ports"
ports="$(docker port elysium-edge-edge-1 | sort)"
eq "#75-AC2" "the container publishes 8080 on 127.0.0.1:80 and [::1]:80 and nothing else" $'8080/tcp -> 127.0.0.1:80\n8080/tcp -> [::1]:80' "$ports"
listeners="$(ss -ltn 'sport = :80' | awk 'NR > 1 {print $4}' | sort -u)"
check "#75-AC2" "ss shows 127.0.0.1:80" grep -qx '127.0.0.1:80' <<<"$listeners"
check "#75-AC2" "ss shows [::1]:80" grep -qx '\[::1\]:80' <<<"$listeners"
check "#75-AC2" "no 0.0.0.0, * or [::] listener on port 80" bash -c '! grep -Eq "^(0\.0\.0\.0|\*|\[::\]):80$" <<<"$1"' _ "$listeners"
# #75-AC2.8 permissions: the machine's LAN address is refused on port 80
lan="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
if [ -n "$lan" ] && [ "$lan" != 127.0.0.1 ]; then
    curl -s -o /dev/null --max-time 5 -H 'Host: prince.localhost' "http://$lan:80/"
    eq "#75-AC2.8" "a request to the LAN address $lan:80 is refused (curl exit 7)" "7" "$?"
else
    skip "#75-AC2.8" "no LAN address (the listener assertion above covers the loopback-only binding)"
fi
# #75-AC2.9 environment differences: IPv4, IPv6 and --resolve are tested separately
v4="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve prince.localhost:80:127.0.0.1 http://prince.localhost/ 2>/dev/null)"
eq "#75-AC2.9" "IPv4: --resolve prince.localhost to 127.0.0.1" "200" "$v4"
if ip -6 addr show dev lo 2>/dev/null | grep -q ' ::1/'; then
    v6="$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve 'prince.localhost:80:[::1]' http://prince.localhost/ 2>/dev/null)"
    if [ "$v6" = 200 ]; then ok; else
        bad "#75-AC2.9" "IPv6: --resolve prince.localhost to [::1] answered ${v6:-nothing}" "docker info: $(docker info 2>/dev/null | grep -i ip6tables | head -2 | tr '\n' ' ') (publishing [::1] needs Docker's ip6tables or the userland proxy)"
    fi
    v6="$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve 'prince.dev.localhost:80:[::1]' http://prince.dev.localhost/ 2>/dev/null)"
    eq "#75-AC2.9" "IPv6: prince.dev.localhost on [::1]" "200" "$v6"
else
    skip "#75-AC2.9" "no IPv6 loopback: the [::1] cases are covered by the manual check"
fi
# the names themselves, resolved by this machine (nested .localhost names need the system resolver to know them)
if getent ahosts prince.localhost >/dev/null 2>&1 && getent ahosts prince.dev.localhost >/dev/null 2>&1; then
    eq "#75-AC2.9" "curl -4 http://prince.localhost/" "200" "$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 http://prince.localhost/ 2>/dev/null)"
    eq "#75-AC2.9" "curl -4 http://prince.dev.localhost/" "200" "$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 http://prince.dev.localhost/ 2>/dev/null)"
    if ip -6 addr show dev lo 2>/dev/null | grep -q ' ::1/'; then
        eq "#75-AC2.9" "curl -6 http://prince.localhost/" "200" "$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 10 http://prince.localhost/ 2>/dev/null)"
    fi
else
    skip "#75-AC2.9" "this machine's resolver does not know prince.localhost or prince.dev.localhost (the --resolve cases above cover the edge itself)"
fi

# === #75-AC3: routing by Host ========================================================================================

echo "== #75-AC3: routing"
get prince.localhost /x
eq "#75-AC3" "prince.localhost reaches the production proxy" "prod" "$(echo_backend)"
get prince.dev.localhost /x
eq "#75-AC3" "prince.dev.localhost reaches the development proxy" "dev" "$(echo_backend)"
# #75-AC3.1 inputs: the same name in other spellings routes like the plain one; each is asked twice (#75-AC3.7: the same answer)
for h in 'PRINCE.localhost' 'prince.localhost.' 'prince.localhost:80' 'Prince.Localhost'; do
    for _ in 1 2; do
        get "$h" /x
        eq "#75-AC3.1" "Host: $h routes to the production proxy (host seen: prince.localhost)" "200 prod prince.localhost" "$status $(echo_backend) $(echo_field host)"
    done
done
for h in 'PRINCE.DEV.localhost' 'prince.dev.localhost.' 'prince.dev.localhost:80'; do
    get "$h" /x
    eq "#75-AC3.1" "Host: $h routes to the development proxy" "200 dev prince.dev.localhost" "$status $(echo_backend) $(echo_field host)"
done
for h in 'prince.localhost:8080' 'localhost' '127.0.0.1' '127.0.0.1:80' '[::1]' 'prince.dev.localhost.evil.com' 'prince.localhost.evil.com' 'evil.prince.localhost' \
    'prince.dev.localhost:8080' 'prince' 'prince.localhost:' 'prince.localhost%00' 'dev.localhost' '.prince.localhost'; do
    get "$h" /x
    eq "#75-AC3.1" "Host: $h gets 421" "421" "$status"
    eq "#75-AC3.10" "the 421 for Host: $h has an empty body and reaches no upstream" "" "$body"
done
# a Host that is not even a valid name is refused by nginx itself (400, or 421 here), reaching no upstream
for h in 'prince.localhost:80:80' 'prince.localhost @evil' 'prince.localhost/evil'; do
    get "$h" /x
    case "$status" in 400 | 421) ok ;; *) bad "#75-AC3.1" "Host: $h got $status, expected 400 or 421" ;; esac
    check "#75-AC3.1" "Host: $h reaches no upstream" bash -c '! grep -q "backend=" <<<"$1"' _ "$body"
done
# no Host (HTTP/1.0) and an empty Host are refused with 421, two Host headers with 400
eq "#75-AC3.1" "no Host header (HTTP/1.0) gets 421" "421" "$(raw_status 'GET / HTTP/1.0\r\n\r\n')"
eq "#75-AC3.1" "an empty Host header gets 421" "421" "$(raw_status 'GET / HTTP/1.1\r\nHost:\r\nConnection: close\r\n\r\n')"
eq "#75-AC3.1" "no Host header (HTTP/1.1) gets 421" "421" "$(raw_status 'GET / HTTP/1.1\r\nConnection: close\r\n\r\n')"
eq "#75-AC3.1" "two Host headers get 400" "400" "$(raw_status 'GET / HTTP/1.1\r\nHost: prince.localhost\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n')"
eq "#75-AC3.1" "two different Host headers get 400" "400" "$(raw_status 'GET / HTTP/1.1\r\nHost: prince.localhost\r\nHost: prince.dev.localhost\r\nConnection: close\r\n\r\n')"
# A request nginx can't parse is the edge's own 400, never a 5xx and never an upstream (PO decision 2026-11-23): a malformed
# request line, an invalid percent sequence, a raw space, a NUL, a path above /, an invalid header line (Host sent before it).
# Only an empty, missing or unknown Host is 421.
hostline='Host: prince.localhost\r\nConnection: close\r\n\r\n'
malformed_400() { # description printf-format: 400, no upstream content, the security headers on the answer
    local resp st
    resp="$(raw "$2")"
    st="$(head -1 <<<"$resp" | awk '{print $2}')"
    eq "#75-AC3.1" "$1: the edge answers 400" "400" "$st"
    check "#75-AC3.1" "$1: no upstream was reached" bash -c '! grep -q "backend=" <<<"$1"' _ "$resp"
}
malformed_400 "a garbage request line" 'GARBAGE\r\n\r\n'
malformed_400 "a method with an invalid character (G@T)" "G@T / HTTP/1.1\r\n$hostline"
malformed_400 "a request line with no leading slash (GET x)" "GET x HTTP/1.1\r\n$hostline"
malformed_400 "a request line with no target" 'GET\r\n\r\n'
malformed_400 "junk after the protocol" "GET / HTTP/1.1 x\r\n$hostline"
malformed_400 "an invalid percent sequence (/%zz)" "GET /%%zz HTTP/1.1\r\n$hostline"
malformed_400 "an encoded NUL (/a%00b)" "GET /a%%00b HTTP/1.1\r\n$hostline"
malformed_400 "a raw space in the path" "GET /a b HTTP/1.1\r\n$hostline"
malformed_400 "a path that climbs above / (/x/../../etc, encoded)" "GET /x/%%2e%%2e/%%2e%%2e/etc HTTP/1.1\r\n$hostline"
malformed_400 "an invalid header line after the Host line" 'GET / HTTP/1.1\r\nHost: prince.localhost\r\nbad header line\r\nConnection: close\r\n\r\n'
# the same on an unknown or missing Host: a request that can't be parsed never gets a 5xx either
st="$(raw_status 'GARBAGE\r\n\r\n')"
case "$st" in 5*) bad "#75-AC3.1" "a garbage request line got $st" ;; *) ok ;; esac
# an invalid header line sent before the Host line leaves the Host unread: an empty Host, so 421 (documented in Edge/README.md)
eq "#75-AC3.1" "an invalid header line before the Host line leaves the Host unread: 421" "421" "$(raw_status 'GET / HTTP/1.1\r\nbad header line\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n')"
resp="$(raw 'GARBAGE\r\n\r\n')"
hdrs="$(tr -d '\r' <<<"$resp")"
# (expect_headers is defined below with the headers tests; this one is repeated there)
malformed_hdrs="$hdrs"
# the edge's internal error location is not reachable by a client: 404 or 421, never its content
for h in prince.localhost evil.example; do
    get "$h" /.edge-400
    eq "#75-AC3.1" "a client requesting /.edge-400 with Host $h gets 404 (it is internal and proxies nothing)" "404" "$status"
    check "#75-AC3.1" "a client requesting /.edge-400 (Host $h) sees no content of the error location" bash -c '! grep -q "bad request" <<<"$1"' _ "$body"
done
# an absolute-form request line does not smuggle another Host past the allow-list
resp="$(raw 'GET http://prince.localhost/x HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n')"
check "#75-AC3.1" "an absolute-form request line with a foreign Host header never reaches the production proxy" bash -c '! grep -q "backend=prod" <<<"$1"' _ "$resp"
# the other environment's name never reaches the production proxy, whatever the path or spelling
for p in / /x /prod /prince-prod-proxy; do
    get prince.dev.localhost "$p"
    check "#75-AC3.1" "prince.dev.localhost$p never reaches prince-prod-proxy" bash -c '[ "$(sed -n "s/^backend=\([a-z]*\) .*/\1/p" <<<"$1")" != prod ]' _ "$body"
done
# the 421 response: empty body, no version in Server
get evil.example /
eq "#75-AC3.10" "421 body is empty" "" "$body"
eq "#75-AC3.10" "Content-Length of the 421 is 0" "0" "$(header content-length)"
eq "#75-AC3.10" "Server header carries no version" "nginx" "$(header server)"

# #75-AC3.2 boundaries
bigval() { head -c "$1" /dev/zero | tr '\0' a; }
# a header line of 8 KiB (name, colon, space and value, 8192 bytes) is rejected and reaches no upstream
resp="$(raw 'GET / HTTP/1.1\r\nHost: prince.localhost\r\nX-Big: %s\r\nConnection: close\r\n\r\n' "$(bigval $((8192 - 7)))")"
st="$(head -1 <<<"$resp" | awk '{print $2}')"
case "$st" in 400 | 414) ok ;; *) bad "#75-AC3.2" "a header line of 8 KiB got ${st:-no answer}, expected 400 or 414" ;; esac
check "#75-AC3.2" "the over-long header line reaches no upstream" bash -c '! grep -q "backend=" <<<"$1"' _ "$resp"
# a request line of 8 KiB + 1 byte ("GET " + path + " HTTP/1.1")
pathlen=$((8193 - 4 - 9))
resp="$(raw 'GET /%s HTTP/1.1\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n' "$(bigval $((pathlen - 1)))")"
st="$(head -1 <<<"$resp" | awk '{print $2}')"
case "$st" in 400 | 414) ok ;; *) bad "#75-AC3.2" "a request line of 8 KiB + 1 got ${st:-no answer}, expected 400 or 414" ;; esac
check "#75-AC3.2" "the over-long request line reaches no upstream" bash -c '! grep -q "backend=" <<<"$1"' _ "$resp"
# a request line just under the limit passes
resp="$(raw 'GET /%s HTTP/1.1\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n' "$(bigval $((8190 - 4 - 9 - 1)))")"
eq "#75-AC3.2" "a request line of 8190 bytes passes" "200" "$(head -1 <<<"$resp" | awk '{print $2}')"
# bodies: exactly 10 MiB passes, one byte more gets 413
head -c 10485760 /dev/zero >"$work/b10"
head -c 10485761 /dev/zero >"$work/b10p"
get prince.localhost /upload --data-binary "@$work/b10" -H 'Content-Type: application/octet-stream'
eq "#75-AC3.2" "a body of exactly 10 MiB passes" "200" "$status"
eq "#75-AC3.2" "the upstream saw the full Content-Length" "10485760" "$(echo_field len)"
get prince.localhost /upload --data-binary "@$work/b10p" -H 'Content-Type: application/octet-stream'
eq "#75-AC3.2" "a body of 10 MiB + 1 byte gets 413" "413" "$status"
rm -f "$work/b10" "$work/b10p"
# #75-AC3.2 (spec change 2026-11-23, per environment): at most 4 requests with a body in flight per environment at the edge (Content-Length
# above 0 or any Transfer-Encoding), so the body tmpfs can't fill (2 x 4 x 10 MiB < 128 MiB). The 5th of one environment gets 503 and
# reaches no upstream, the other environment is not affected, a request with no body is never counted, nothing of the query string
# reaches the logs, and a new upload passes once the held ones have finished.
head -c 2500000 /dev/zero >"$work/slow"
cap_marker="SECRET-MARKER-CAP-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cap_scenario() { # held-host other-host: holds 4 uploads on the first (2 with Content-Length, 2 chunked), then probes
    local held="$1" other="$2" i pid st
    local -a pids=()
    for i in 1 2 3 4; do
        local -a te=()
        [ "$i" -gt 2 ] && te=(-H 'Transfer-Encoding: chunked')
        curl -s -o "$work/cap$i" -w '%{http_code}\n' --limit-rate 250k --max-time 60 -H "Host: $held" --data-binary "@$work/slow" \
            -H 'Content-Type: application/octet-stream' "${te[@]}" "http://127.0.0.1:80/cap$i" >"$work/cap$i.code" 2>/dev/null &
        pids+=($!)
    done
    sleep 3
    get "$held" "/cap5?token=$cap_marker" --data-binary 'x'
    eq "#75-AC3.2" "$held: the 5th concurrent request with a body (Content-Length) gets 503" "503" "$status"
    check "#75-AC3.2" "$held: the 5th reaches no upstream" bash -c '! grep -q "backend=" <<<"$1"' _ "$body"
    get "$held" "/cap5c?token=$cap_marker" -H 'Transfer-Encoding: chunked' --data-binary 'x'
    eq "#75-AC3.2" "$held: a 5th chunked request (Transfer-Encoding) gets 503 too" "503" "$status"
    check "#75-AC3.2" "$held: the chunked 5th reaches no upstream" bash -c '! grep -q "backend=" <<<"$1"' _ "$body"
    get "$other" /cap-other --data-binary 'x'
    eq "#75-AC3.2" "$other: an upload passes while $held holds 4" "200" "$status"
    get "$held" /cap-get
    eq "#75-AC3.2" "$held: a request with no body still gets 200 while 4 uploads are in flight" "200" "$status"
    get "$held" /cap-get0 -X POST -H 'Content-Length: 0'
    eq "#75-AC3.2" "$held: a request with Content-Length: 0 is not counted" "200" "$status"
    get evil.example /cap-evil --data-binary 'x'
    eq "#75-AC3.2" "an unknown host with a body gets 421, not 503" "421" "$status"
    check "#75-AC3.2" "no query string reaches the edge's output" bash -c '! docker logs elysium-edge-edge-1 2>&1 | grep -q "$1"' _ "$cap_marker"
    for pid in "${pids[@]}"; do wait "$pid"; done
    eq "#75-AC3.2" "$held: the 4 slow uploads all finished with 200" "200 x4 " "$(cat "$work"/cap?.code | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
    get "$held" /cap-after --data-binary @"$work/slow" -H 'Content-Type: application/octet-stream'
    eq "#75-AC3.2" "$held: a new upload passes after the held ones have finished" "200" "$status"
    rm -f "$work"/cap?*
}
cap_scenario prince.localhost prince.dev.localhost
cap_scenario prince.dev.localhost prince.localhost
rm -f "$work/slow"
# a WebSocket upgrade reaches the upstream with Upgrade and Connection: upgrade; any other Upgrade value (h2c, a list, a
# misspelling) is not forwarded, and the request goes out with Connection: close like any other
get prince.localhost /ws -H 'Upgrade: websocket' -H 'Connection: Upgrade'
eq "#75-AC3.2" "WebSocket upgrade: Upgrade and Connection reach the upstream" "websocket upgrade" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: WebSocket' -H 'Connection: upgrade'
eq "#75-AC3.2" "WebSocket upgrade in another case: forwarded as websocket" "websocket upgrade" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: h2c' -H 'Connection: Upgrade, HTTP2-Settings' -H 'HTTP2-Settings: AAMAAABkAAQAAP__'
eq "#75-AC3.2" "Upgrade: h2c is not forwarded and the request goes out with Connection: close" " close" "$(echo_field upgrade) $(echo_field connection)"
for u in 'websocket, h2c' 'websockets' 'h2c, websocket' 'foo'; do
    get prince.localhost /ws -H "Upgrade: $u" -H 'Connection: Upgrade'
    eq "#75-AC3.2" "Upgrade: $u is not forwarded (Connection: close)" "close" "$(echo_field connection)"
    check "#75-AC3.2" "Upgrade: $u leaves no Upgrade header on the request to the stack" bash -c '[ -z "$1" ]' _ "$(echo_field upgrade)"
done
# the Upgrade value can't supply the `upgrade` token that the Connection header must list
get prince.localhost /ws -H 'Upgrade: websocket upgrade'
eq "#75-AC3.2" "Upgrade: websocket upgrade (no Connection) is not forwarded" " close" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: websocket upgrade' -H 'Connection: close'
eq "#75-AC3.2" "Upgrade: websocket upgrade with Connection: close is not forwarded" " close" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: websocket h2c' -H 'Connection: upgrade'
eq "#75-AC3.2" "Upgrade: websocket h2c with Connection: upgrade is not forwarded" " close" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: websocket' -H 'Connection: close'
eq "#75-AC3.2" "Upgrade: websocket with a Connection header that does not list upgrade is not forwarded" " close" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /ws -H 'Upgrade: websocket' -H 'Connection: keep-alive, Upgrade'
eq "#75-AC3.2" "Upgrade: websocket with Connection: keep-alive, Upgrade is forwarded" "websocket upgrade" "$(echo_field upgrade) $(echo_field connection)"
get prince.localhost /x
eq "#75-AC3.2" "no Upgrade from the client: no Upgrade to the stack and Connection: close" " close" "$(echo_field upgrade) $(echo_field connection)"

# #75-AC3.5 concurrency: 200 parallel requests, only 200 (stubs are up), RestartCount stays 0
codes="$(seq 1 200 | xargs -P 40 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 -H 'Host: prince.localhost' "http://127.0.0.1:80/p{}" | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
eq "#75-AC3.5" "200 parallel requests: all 200" "200 x200 " "$codes"
codes="$(seq 1 100 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 -H 'Host: evil.example' "http://127.0.0.1:80/p{}" | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
eq "#75-AC3.5" "100 parallel requests to an unknown host: all 421" "421 x100 " "$codes"
eq "#75-AC3.5" "RestartCount stays 0" "0" "$(restarts)"

# === #75-AC4: headers ================================================================================================

echo "== #75-AC4: headers"
# #75-AC4.1 inputs: what the client says about itself is replaced
get prince.localhost /h -H 'X-Forwarded-Host: prince.dev.localhost' -H 'X-Forwarded-For: 1.2.3.4' -H 'X-Forwarded-Proto: https' -H 'X-Real-IP: 5.6.7.8' -H 'Forwarded: for=9.9.9.9' \
    -H 'X-Forwarded-Prefix: /evil' -H 'X-Forwarded-Port: 4443' -H 'X-Forwarded-Server: evil.example' -H 'X-Original-URL: /admin' -H 'X-Rewrite-URL: /admin'
eq "#75-AC4.1" "X-Forwarded-Host is the matched host" "prince.localhost" "$(echo_field xfh)"
eq "#75-AC4.1" "X-Forwarded-Proto is http" "http" "$(echo_field proto)"
eq "#75-AC4.1" "X-Real-IP is removed" "" "$(echo_field xri)"
xff="$(echo_field xff)"
check "#75-AC4.1" "X-Forwarded-For holds one address, the client's, not 1.2.3.4 (got: $xff)" bash -c '[[ "$1" =~ ^[0-9a-f.:]+$ ]] && [ "$1" != 1.2.3.4 ]' _ "$xff"
check "#75-AC4.1" "Forwarded is not passed on" bash -c '! grep -qi "9.9.9.9" <<<"$1"' _ "$body"
for f in xfp xfport xfs xou xru; do
    eq "#75-AC4.1" "the client's value of the field $f does not reach the stack" "" "$(echo_field $f)"
done
get 'PRINCE.localhost:80' /h
eq "#75-AC4.1" "Host and X-Forwarded-Host are the normalised name" "prince.localhost prince.localhost" "$(echo_field host) $(echo_field xfh)"
# the security headers on every response (#75-AC4.3: 200, 421, 404, 502 and the edge's own 400/413)
expect_headers() { # id description
    local ok_=1
    [ "$(header x-content-type-options)" = nosniff ] || ok_=0
    [ "$(header x-frame-options)" = DENY ] || ok_=0
    [ "$(header referrer-policy)" = same-origin ] || ok_=0
    [ "$(header content-security-policy-report-only)" = "default-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" ] || ok_=0
    [ "$(header_count x-content-type-options)$(header_count x-frame-options)$(header_count referrer-policy)$(header_count content-security-policy-report-only)" = 1111 ] || ok_=0
    [ "$(header_count content-security-policy)" = 0 ] || ok_=0
    if [ "$ok_" = 1 ]; then ok; else bad "$1" "$2" "$hdrs"; fi
}
get prince.localhost /x
expect_headers "#75-AC4" "security headers on a 200"
get evil.example /x
expect_headers "#75-AC4.3" "security headers on a 421"
get prince.localhost /missing
eq "#75-AC4.3" "the stub's 404 passes through" "404" "$status"
expect_headers "#75-AC4.3" "security headers on a 404"
get prince.localhost /redir
eq "#75-AC4.3" "a relative redirect stays relative" "/redirected" "$(header location)"
resp="$(raw 'GET / HTTP/1.1\r\nHost: prince.localhost\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n')"
hdrs="$(tr -d '\r' <<<"$resp")"
expect_headers "#75-AC4.3" "security headers on the edge's own 400"
hdrs="$malformed_hdrs"
expect_headers "#75-AC4.3" "security headers on the 400 for a malformed request line"
# #75-AC4.6 partial failure: an upstream that sets the same headers does not double them
get prince.localhost /dup
expect_headers "#75-AC4.6" "an upstream's own X-Frame-Options, X-Content-Type-Options, Referrer-Policy and CSP are replaced, not doubled"
# #75-AC4.8 permissions: Cookie and Authorization pass unchanged, Set-Cookie is not rewritten (no Domain)
get prince.localhost /c -H 'Cookie: sid=abc123' -H 'Authorization: Bearer tok-abc'
eq "#75-AC4.8" "Cookie and Authorization reach the upstream unchanged" "sid=abc123 Bearer" "$(echo_field cookie) $(sed -n 's/^.* auth=\([A-Za-z]*\).*/\1/p' <<<"$body")"
get prince.localhost /dup
eq "#75-AC4.8" "Set-Cookie is passed as it was, with no Domain" "sid=1; Path=/; HttpOnly" "$(header set-cookie)"

# === #75-AC5: the access log =========================================================================================

echo "== #75-AC5: access log"
log_lines() { docker logs elysium-edge-edge-1 2>/dev/null | wc -l; }
logs_since() { docker logs elysium-edge-edge-1 2>/dev/null | tail -n +$(($1 + 1)); }
marker="SECRET-MARKER-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mark="$(log_lines)"
get prince.localhost "/x?token=$marker&a=b" -H "Authorization: Bearer $marker" -H "Cookie: s=$marker" --data "body=$marker"
eq "#75-AC5.1" "the marker request reached the upstream (the headers pass, only the log is clean)" "200" "$status"
new="$(logs_since "$mark")"
eq "#75-AC5.1" "one log line for the request" "1" "$(wc -l <<<"$new")"
check "#75-AC5.1" "no query string, Authorization, Cookie or body in the edge's output (stdout and stderr)" bash -c '! docker logs elysium-edge-edge-1 2>&1 | grep -q "$1"' _ "$marker"
# the same on a failing request: the error log must not quote the request either
sdc stop prod >/dev/null 2>&1
sleep 11
get prince.localhost "/x?token=$marker" -H "Authorization: Bearer $marker" -H "Cookie: s=$marker"
eq "#75-AC5.3" "a request to a stopped stack answers 502" "502" "$status"
check "#75-AC5.1" "no marker in the output after a 502" bash -c '! docker logs elysium-edge-edge-1 2>&1 | grep -q "$1"' _ "$marker"
last="$(docker logs elysium-edge-edge-1 2>/dev/null | tail -1)"
eq "#75-AC5.3" "the 502 line has status 502 and a - or an address as upstream" "502" "$(jq -r .status <<<"$last")"
check "#75-AC5.3" "the 502 upstream is - or the failed address" bash -c '[[ "$1" == "-" || "$1" =~ ^[0-9.:]+$ ]]' _ "$(jq -r .upstream <<<"$last")"
sdc start prod >/dev/null 2>&1
poll_status prince.localhost /x 200 14 || bad "#75-AC5.3" "the production stub is not back within 12 s"
# a 421 line shows the rejected Host
mark="$(log_lines)"
get 'Rejected.Example' /x
line="$(logs_since "$mark" | tail -1)"
eq "#75-AC5.3" "a 421 line shows the rejected Host as sent" "421 Rejected.Example" "$(jq -r '"\(.status) \(.host)"' <<<"$line")"
# the log shows the Host that was routed on, the header, not the host of an absolute-form request line (#75-AC5.10)
mark="$(log_lines)"
raw 'GET http://evil.example/x HTTP/1.1\r\nHost: prince.dev.localhost\r\nConnection: close\r\n\r\n' >/dev/null
sleep 0.3
line="$(logs_since "$mark" | tail -1)"
eq "#75-AC5.10" "absolute-form with a foreign request-line host: the line shows the Host header that was routed" "200 prince.dev.localhost" "$(jq -r '"\(.status) \(.host)"' <<<"$line")"
mark="$(log_lines)"
raw 'GET http://prince.dev.localhost/ HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n' >/dev/null
sleep 0.3
line="$(logs_since "$mark" | tail -1)"
eq "#75-AC5.3" "absolute-form with a foreign Host header: the 421 line shows the rejected Host header" "421 evil.example" "$(jq -r '"\(.status) \(.host)"' <<<"$line")"
# #75-AC5.10: the fields
get prince.localhost /x
sleep 0.2
line="$(docker logs elysium-edge-edge-1 2>/dev/null | tail -1)"
check "#75-AC5.10" "the line has time, host, method, path, status, upstream and request_time" jq_ok "$line" 'has("time") and has("host") and has("method") and has("path") and has("status") and has("upstream") and has("request_time") and (keys | length == 7)'
eq "#75-AC5.10" "host and upstream are filled in" "prince.localhost GET /x 200 true" "$(jq -r '"\(.host) \(.method) \(.path) \(.status) \(.upstream | test("^[0-9.]+:80$"))"' <<<"$line")"
# #75-AC5.4: UTC ISO 8601
check "#75-AC5.4" "the time is UTC ISO 8601 (got $(jq -r .time <<<"$line"))" bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' _ "$(jq -r .time <<<"$line")"
# #75-AC5.1: a newline or an ESC byte in a path stays inside its own line
mark="$(log_lines)"
get prince.localhost '/a%0Ab%1B%0D%0Ac'
raw 'GET /raw\033esc HTTP/1.1\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n' >/dev/null
raw 'GET /two%%0aline HTTP/1.1\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n' >/dev/null
sleep 0.3
new="$(logs_since "$mark")"
eq "#75-AC5.1" "three requests with a newline or an ESC byte in the path make exactly three lines" "3" "$(wc -l <<<"$new")"
check "#75-AC5.1" "every one of the lines is valid json" bash -c 'while IFS= read -r l; do jq -e . >/dev/null <<<"$l" || exit 1; done <<<"$1"' _ "$new"
check "#75-AC5.1" "no raw ESC byte in the log" bash -c '! grep -q $'"'"'\033'"'"' <<<"$1"' _ "$new"
# #75-AC5.2 boundaries: an 8 KiB URI is rejected and logged on one line
mark="$(log_lines)"
raw 'GET /%s HTTP/1.1\r\nHost: prince.localhost\r\nConnection: close\r\n\r\n' "$(bigval 8300)" >/dev/null
sleep 0.3
new="$(logs_since "$mark")"
eq "#75-AC5.2" "an 8 KiB URI makes one line" "1" "$(wc -l <<<"$new")"
check "#75-AC5.2" "that line is valid json and is not longer than the URI plus the fixed fields" bash -c 'jq -e . >/dev/null <<<"$1" && [ "${#1}" -lt 9000 ]' _ "$new"

# === #75-AC3.3, AC3.6: one stack down, DNS failure ===================================================================

echo "== #75-AC3.3, AC3.6: one stack down"
sdc stop prod >/dev/null 2>&1
sleep 11 # the edge's resolver keeps an address for 10 s
start="$(now_ms)"
get prince.localhost /x
took=$(($(now_ms) - start))
eq "#75-AC3.3" "the stopped stack's host answers 502" "502" "$status"
expect_headers "#75-AC4.3" "security headers on a 502"
[ "$took" -le 4000 ] && ok || bad "#75-AC3.4" "a stack that does not accept answers within 4 s (took ${took} ms)"
check "#75-AC3.6" "the 502 holds no other backend's response" bash -c '! grep -q "backend=" <<<"$1"' _ "$body"
get prince.dev.localhost /x
eq "#75-AC3.3" "the other host still answers 200 in the same run" "200" "$status"
eq "#75-AC3.3" "and it is the dev proxy" "dev" "$(echo_backend)"
# #75-AC6.6, #75-AC7.6 partial failure (against the stubs): never the other content
get prince.dev.localhost '/a\b'
eq "#75-AC7.8" "a raw-character path to a known host is routed (dev)" "dev" "$(echo_backend)"
get prince.localhost '/a\b'
eq "#75-AC7.6" "a raw-character request to the stopped stack gets the same 502, never prod content" "502" "$status"
sdc start prod >/dev/null 2>&1
if poll_status prince.localhost /x 200 14; then ok; else bad "#75-AC3.3" "the stack that starts again is not reachable within 12 s without an edge restart"; fi
[ "$elapsed_ms" -le 12000 ] && ok || bad "#75-AC3.3" "reachable again only after ${elapsed_ms} ms"
eq "#75-AC3.3" "no edge restart" "0" "$(restarts)"

# === #75-AC7: path normalisation =====================================================================================

echo "== #75-AC7: path normalisation"
# the cases of #73-AC3.1: the raw character, and what the upstream must receive
declare -A enc=([$'\\']='%5C' ['"']='%22' ['<']='%3C' ['>']='%3E' ['`']='%60' ['|']='%7C' ['^']='%5E')
prince_routes=(/vue/ /vue/checkout/ /react/ /react/checkout/ /api/ /api/checkout/ /jobs/ /admin/)
# #75-AC7.1 inputs: on every route of prince.localhost and on / of prince.dev.localhost; plain, with a query string, with a trailing slash
norm_case() { # host route char variant
    local host="$1" route="$2" ch="$3" variant="$4" e="${enc[$3]}" path want
    case "$variant" in
    plain) path="${route}a${ch}b" want="${route}a${e}b" ;;
    query) path="${route}a${ch}b?x=1&y=${e}" want="${route}a${e}b?x=1&y=${e}" ;;
    slash) path="${route}a${ch}b/" want="${route}a${e}b/" ;;
    esac
    get "$host" "$path"
    [ "$(echo_req)" = "GET $want HTTP/1.1" ] && ok || bad "#75-AC7.1" "$host $path: the upstream got \"$(echo_req)\", expected \"GET $want HTTP/1.1\"" "status $status"
}
for route in "${prince_routes[@]}"; do
    for ch in "${!enc[@]}"; do
        for variant in plain query slash; do norm_case prince.localhost "$route" "$ch" "$variant"; done
    done
done
for ch in "${!enc[@]}"; do
    for variant in plain query slash; do norm_case prince.dev.localhost / "$ch" "$variant"; done
done
# several in one path (the whole set of #73-AC3.1)
get prince.localhost '/api/a\b"c<d>e`f|g^h'
eq "#75-AC7.1" "all seven characters in one path" 'GET /api/a%5Cb%22c%3Cd%3Ee%60f%7Cg%5Eh HTTP/1.1' "$(echo_req)"
# an already percent-encoded %5C is not encoded again
get prince.localhost '/api/a%5Cb'
eq "#75-AC7.1" "an already encoded %5C is not encoded again" 'GET /api/a%5Cb HTTP/1.1' "$(echo_req)"
get prince.localhost '/api/a%255Cb'
eq "#75-AC7.1" "an encoded percent sign stays %25" 'GET /api/a%255Cb HTTP/1.1' "$(echo_req)"
# an encoded newline and CRLF stay encoded all the way (#73-AC3.1)
get prince.localhost '/api/a%0Ab'
eq "#75-AC7.1" "an encoded newline stays encoded" 'GET /api/a%0Ab HTTP/1.1' "$(echo_req)"
get prince.localhost '/api/a%0D%0Ab'
eq "#75-AC7.1" "an encoded CRLF stays encoded" 'GET /api/a%0D%0Ab HTTP/1.1' "$(echo_req)"
# #75-AC6.1 (spec change 2026-11-23): percent-encoded characters, an encoded slash included, are decoded once and the path
# normalised at the edge, as the stack's proxy has done since #73: /api/a%2Fb reaches the API as /api/a/b, /api/%2F as /api/
get prince.localhost '/api/a%2Fb'
eq "#75-AC6.1" "/api/a%2Fb reaches the upstream as /api/a/b" 'GET /api/a/b HTTP/1.1' "$(echo_req)"
get prince.localhost '/api/%2F'
eq "#75-AC6.1" "/api/%2F reaches the upstream as /api/" 'GET /api/ HTTP/1.1' "$(echo_req)"
get prince.localhost '/api/a%2fb?x=%2F'
eq "#75-AC6.1" "a lower-case %2f is decoded too, and the query string is not touched" 'GET /api/a/b?x=%2F HTTP/1.1' "$(echo_req)"
# #75-AC7.7 idempotence: the raw and the encoded form of one path reach the upstream as the same request line
for ch in "${!enc[@]}"; do
    get prince.localhost "/api/a${ch}b"
    raw_line="$(echo_req)"
    get prince.localhost "/api/a${enc[$ch]}b"
    eq "#75-AC7.7" "raw and encoded form of $ch reach the upstream as the same request line" "$raw_line" "$(echo_req)"
done
# #75-AC7.2 boundaries: a path of 8 KiB with raw characters gets the same status as the same path percent-encoded
rawpath="/api/$(bigval 8000)"'\b"c<d>e`f|g^h'
encpath="/api/$(bigval 8000)%5Cb%22c%3Cd%3Ee%60f%7Cg%5Eh"
get prince.localhost "$rawpath"
st_raw="$status"
get prince.localhost "$encpath"
eq "#75-AC7.2" "8 KiB path: raw and encoded forms get the same status" "$status" "$st_raw"
eq "#75-AC7.2" "and that status is 200" "200" "$st_raw"
# #75-AC7.8 permissions: a raw-character path on an unknown host is 421
get evil.example '/api/a\b'
eq "#75-AC7.8" "a raw-character path on an unknown host gets 421" "421" "$status"

# === #75-AC3.4: time =================================================================================================

echo "== #75-AC3.4: timeouts (about 40 s)"
# an upstream that accepts and never answers: the dev alias goes to a container that listens and says nothing
sdc stop dev >/dev/null 2>&1
docker run -d --rm --name "${tag}-hang" --label "edgetest=$tag" --network elysium-edge --network-alias prince-dev-proxy \
    "$ALPINE_IMAGE" sh -c 'while true; do sleep 3600 | nc -l -p 80 >/dev/null 2>&1; done' >/dev/null 2>&1 || bad "#75-AC3.4" "the hanging upstream did not start"
sleep 11 # the resolver's cached address of the stopped stub expires
(
    start="$(now_ms)"
    code="$(curl -s -o /dev/null --max-time 45 -w '%{http_code}' -H 'Host: prince.dev.localhost' http://127.0.0.1:80/hang 2>/dev/null)"
    echo "$code $(($(now_ms) - start))" >"$work/t-read"
) &
# client_header_timeout 10 s: a request whose headers never finish is closed (408) after about 10 s
(
    start="$(now_ms)"
    out="$( ( exec 3<>/dev/tcp/127.0.0.1/80; printf 'GET / HTTP/1.1\r\nHost: prince.localhost\r\n' >&3; timeout 20 cat <&3 ) 2>/dev/null | head -1)"
    echo "$(awk '{print ($2 == "" ? "closed" : $2)}' <<<"$out") $(($(now_ms) - start))" >"$work/t-header"
) &
# client_body_timeout 10 s: a body that never arrives
(
    start="$(now_ms)"
    out="$( ( exec 3<>/dev/tcp/127.0.0.1/80; printf 'POST /x HTTP/1.1\r\nHost: prince.localhost\r\nContent-Length: 100\r\n\r\nab' >&3; timeout 20 cat <&3 ) 2>/dev/null | head -1)"
    echo "$(awk '{print ($2 == "" ? "closed" : $2)}' <<<"$out") $(($(now_ms) - start))" >"$work/t-body"
) &
wait
read -r code ms <"$work/t-read"
if [ "$code" = 504 ] && [ "$ms" -ge 28000 ] && [ "$ms" -le 32000 ]; then ok; else bad "#75-AC3.4" "an upstream that never answers: expected 504 after 30 s +-2 s, got ${code:-nothing} after ${ms:-?} ms"; fi
read -r code ms <"$work/t-header"
if { [ "$code" = 408 ] || [ "$code" = closed ]; } && [ "$ms" -ge 9000 ] && [ "$ms" -le 12000 ]; then ok; else bad "#75-AC3.4" "client_header_timeout: expected 408 or a closed connection after about 10 s, got ${code:-nothing} after ${ms:-?} ms"; fi
read -r code ms <"$work/t-body"
if { [ "$code" = 408 ] || [ "$code" = closed ]; } && [ "$ms" -ge 9000 ] && [ "$ms" -le 12000 ]; then ok; else bad "#75-AC3.4" "client_body_timeout: expected 408 or a closed connection after about 10 s, got ${code:-nothing} after ${ms:-?} ms"; fi
docker rm -f "${tag}-hang" >/dev/null 2>&1
sdc start dev >/dev/null 2>&1
poll_status prince.dev.localhost /x 200 14 && ok || bad "#75-AC3.3" "the dev stack is not back within 12 s"

# === lifecycle: idempotence, down, a taken port (#75-AC1.7, AC2.3, AC2.6, AC2.10) ===================================

echo "== #75-AC1.7, AC2.3, AC2.6: lifecycle"
sdc down -v --timeout 2 >/dev/null 2>&1
edc up -d >/dev/null 2>&1
eq "#75-AC1.7" "up -d twice leaves one container" "1" "$(docker ps -q --filter 'label=com.docker.compose.project=elysium-edge' | wc -l)"
eq "#75-AC1.7" "and one network" "1" "$(docker network ls -q --filter name='^elysium-edge$' | wc -l)"
edc down --timeout 2 >/dev/null 2>&1 && ok || bad "#75-AC1.7" "the first down did not exit 0"
edc down --timeout 2 >/dev/null 2>&1 && ok || bad "#75-AC1.7" "the second down did not exit 0"
# #75-AC2.3: after down nothing listens on port 80, after up both listeners are back
check "#75-AC2.3" "after down nothing listens on port 80" bash -c '[ -z "$(ss -ltn "sport = :80" | tail -n +2)" ]'
edc up -d --wait >/dev/null 2>&1
listeners="$(ss -ltn 'sport = :80' | awk 'NR > 1 {print $4}' | sort -u | tr '\n' ' ')"
if ip -6 addr show dev lo 2>/dev/null | grep -q ' ::1/'; then
    eq "#75-AC2.3" "after up both listeners are back" "127.0.0.1:80 [::1]:80 " "$listeners"
else
    eq "#75-AC2.3" "after up the IPv4 listener is back" "127.0.0.1:80 " "$listeners"
fi
# #75-AC2.6 partial failure: port 80 taken: up fails and names the port and the address, not a timeout, and nothing of the .env
edc down --timeout 2 >/dev/null 2>&1
if docker run -d --rm --name "${tag}-port80" --label "edgetest=$tag" -p 127.0.0.1:80:80 "$ECHO_IMAGE" >/dev/null 2>&1; then
    start="$(now_ms)"
    out="$(timeout 60 docker compose -f "$edge_dir/docker-compose.yml" up -d 2>&1)" && rc=0 || rc=$?
    took=$(($(now_ms) - start))
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ok || bad "#75-AC2.6" "up with port 80 taken did not fail (exit $rc)" "$out"
    check "#75-AC2.6" "the failure names port 80 and the address" bash -c 'grep -Eq "127\.0\.0\.1:80|127\.0\.0\.1.*80|port.*80" <<<"$1"' _ "$out"
    [ "$took" -le 20000 ] && ok || bad "#75-AC2.6" "the failure took ${took} ms: a timeout, not an error"
    check "#75-AC2.10" "the failure message holds nothing from the .env" bash -c '! grep -q "$1" <<<"$2"' _ "$env_marker" "$out"
    docker rm -f "${tag}-port80" >/dev/null 2>&1
    edc down -v --timeout 2 >/dev/null 2>&1
else
    skip "#75-AC2.6" "port 80 could not be taken by a throwaway listener"
fi

# === smoke against the real Prince stack (#75-AC6, AC7.9): EDGE_SMOKE=1 ==============================================

if [ "${EDGE_SMOKE:-0}" = 1 ]; then
    echo "== smoke: the real Prince stack behind the edge (#75-AC6, AC7.9)"
    pproj="${tag}-prince"
    pass_="Zq$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' POSTGRES_USER=prince "POSTGRES_PASSWORD=$pass_" POSTGRES_DB=prince JOBS_ADMIN_EMAIL=admin@prince.local 'JOBS_ADMIN_PASSWORD=ChangeMe123!' \
        FILE_STORAGE_ROOT_USER=prince-admin 'FILE_STORAGE_ROOT_PASSWORD=ChangeMe123!' FILE_STORAGE_BUCKET=product-files >"$work/prince.env"
    pdc() { docker compose -p "$pproj" --env-file "$work/prince.env" -f "$root/Prince/docker-compose.yml" -f "$fixture/prince-override.yml" "$@"; }
    edc up -d --wait >/dev/null 2>&1 || bad "#75-AC6" "the edge did not start for the smoke"
    pdc build >"$work/prince-build.log" 2>&1 || { bad "#75-AC6" "the Prince stack does not build" "$(tail -5 "$work/prince-build.log")"; }
    start="$(now_ms)"
    out="$(pdc up -d --wait 2>&1)" && ok || bad "#75-AC6" "the Prince stack did not become healthy" "$(tail -8 <<<"$out")"
    echo "note: Prince up --wait took $(($(now_ms) - start)) ms"
    pcid="$(pdc ps -q reverse-proxy)"
    # the stack answers on the alias, from the edge's side
    direct() { # path: status, Location and a body hash as the stack's own proxy answers them (nothing in front)
        local o
        o="$(docker exec "$pcid" wget -q -S -O - --header 'Host: prince.localhost' "http://127.0.0.1$1" 2>"$work/derr" | sha256sum | cut -c1-16)"
        printf '%s %s %s' "$(sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$work/derr" | head -1)" "$(sed -n 's/^ *Location: *//Ip' "$work/derr" | tr -d '\r' | head -1)" "$o"
    }
    via_edge() { # path
        get prince.localhost "$1"
        printf '%s %s %s' "$status" "$(header location)" "$(sha256sum <"$work/body" | cut -c1-16)"
    }
    for r in /vue/ /vue/checkout/ /react/ /react/checkout/ /api/ /api/checkout/ /jobs/ /admin/ /api/health '/api/health?x=1' /api/%2F /vue /api/checkout/health; do
        d="$(direct "$r")"
        e="$(via_edge "$r")"
        # a redirect's body is nginx's page, and wget follows the redirect: compare status and Location only
        case "$d" in 3*) d="${d% *}" e="${e% *}" ;; esac
        eq "#75-AC6" "$r through the edge equals the stack's own answer (status, Location, body)" "$d" "$e"
    done
    get prince.localhost /api/health
    eq "#75-AC6" "/api/health answers 200" "200" "$status"
    get prince.localhost /api/
    eq "#75-AC6" "/api/ answers 404" "404" "$status"
    # #75-AC6.1 (spec change 2026-11-23): the encoded slash is decoded once at the edge as in the stack's own proxy (the loop above
    # compares both; the stub test pins what the upstream receives); a trailing-slash redirect stays relative
    get prince.localhost /vue
    eq "#75-AC6.1" "/vue redirects to a relative /vue/" "/vue/" "$(header location)"
    # #75-AC7.9: the raw-character cases on every real route get the status of the encoded form
    for r in /vue/ /vue/checkout/ /react/ /react/checkout/ /api/ /api/checkout/ /jobs/ /admin/; do
        for ch in "${!enc[@]}"; do
            get prince.localhost "${r}a${ch}b"
            s1="$status"
            get prince.localhost "${r}a${enc[$ch]}b"
            eq "#75-AC7.9" "${r}a${ch}b: the raw and the encoded form get the same status" "$s1" "$status"
        done
    done
    # #75-AC6.4: recorded, not gated. The p95 of /api/health through the edge and straight to the stack's proxy (its address on
    # elysium-edge), 100 sequential requests each with the same curl, and the difference; then a warm `up --wait` of the stack
    # started again after `stop` (stopped, not removed, images cached).
    pip="$(docker inspect -f '{{(index .NetworkSettings.Networks "elysium-edge").IPAddress}}' "$pcid" 2>/dev/null)"
    p95_ms() { # url: p95 of 100 sequential requests, in ms (the 95th of the sorted times)
        local i
        for i in $(seq 1 100); do curl -s -o /dev/null -w '%{time_total}\n' -H 'Host: prince.localhost' "$1"; done | sort -n | awk 'NR == 95 {printf "%.1f", $1 * 1000}'
    }
    p95_edge="$(p95_ms http://127.0.0.1:80/api/health)"
    p95_direct="$(p95_ms "http://$pip/api/health")"
    echo "note: /api/health p95 of 100 sequential requests: ${p95_edge} ms through the edge, ${p95_direct} ms straight to the stack's proxy, the edge adds $(awk -v a="$p95_edge" -v b="$p95_direct" 'BEGIN {printf "%.1f", a - b}') ms"
    pdc stop >/dev/null 2>&1
    start="$(now_ms)"
    out="$(pdc up -d --wait 2>&1)" && ok || bad "#75-AC6.4" "the warm up --wait after stop failed" "$(tail -5 <<<"$out")"
    echo "note: warm Prince up --wait (stopped, not removed, images cached) took $(($(now_ms) - start)) ms (budget 25000)"
    # #75-AC6.6: with the stack's reverse-proxy stopped, prince.localhost gives 502 and prince.dev.localhost never gives prod content
    pdc stop reverse-proxy >/dev/null 2>&1
    sleep 11
    get prince.localhost /api/health
    eq "#75-AC6.6" "the stopped stack's proxy: prince.localhost gives 502" "502" "$status"
    get prince.dev.localhost /api/health
    check "#75-AC6.6" "prince.dev.localhost gives 421 or 502 and never prod content (got $status)" bash -c '[ "$1" = 421 ] || [ "$1" = 502 ]' _ "$status"
    get prince.localhost '/api/a\b'
    eq "#75-AC7.6" "a raw-character request with the proxy stopped gets 502" "502" "$status"
    pdc down -v --timeout 5 >/dev/null 2>&1
fi

echo
echo "$pass passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
