# Edge proxy

One small nginx that is the only thing in the repository publishing a host port. It binds `127.0.0.1:80` and `[::1]:80` (nginx itself listens on 8080 inside the container, as user 101), and routes by `Host` to each stack's entry proxy over the external network `elysium-edge`, which `Edge/docker-compose.yml` creates. The design is `Docs/environments-design.md`, section 3.

```bash
docker compose -f Edge/docker-compose.yml up -d --wait   # start it before any stack
docker compose -f Edge/docker-compose.yml down           # stop it (the stacks keep running, unreachable)
```

## What it does

- **Host allow-list.** Exactly `prince.localhost` (to `prince-prod-proxy:80`) and `prince.dev.localhost` (to `prince-dev-proxy:80`); case, a trailing dot and `:80` are accepted. Anything else (an empty or missing Host, `localhost`, an IP address, another port, a longer name that merely starts with an allowed one) gets `421` with an empty body. Two `Host` headers get `400`. A production name never reaches the dev proxy and the other way round.
- **Paths.** Request paths are normalised for every service: `\ " < > ` | ^` reach the stack percent-encoded (`/a\b` as `/a%5Cb`), an already encoded `%5C` stays one, and `//` is merged, so no service depends on its own framework's URL parsing.
- **Headers.** It sets `Host` (the matched name), `X-Forwarded-For` (the client address only), `X-Forwarded-Proto: http` and `X-Forwarded-Host`, and removes `X-Real-IP` and `Forwarded`; whatever the client sent is replaced. Every response, errors included, carries `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: same-origin` and a report-only CSP (enforcing waits for a UI without inline scripts); a stack's own copies of these headers are dropped, so none is doubled. Cookies pass untouched (host-only).
- **Limits.** Header lines and the request line 8 KiB, body 10 MiB (`413` above), `Upgrade: websocket` passes, connect timeout 3 s, read and send timeouts 30 s, client header and body timeouts 10 s.
- **Name lookup.** Upstream names are looked up per request through Docker's embedded DNS (`valid=10s`), so the edge starts with no stack running (every known host answers `502`) and finds a stack that starts or is recreated within 10 s, with no restart.
- **Log.** One JSON line per request on stdout: UTC time, host, method, path without the query string, status, upstream address, request time. Never the query string, `Authorization`, `Cookie` or a body; a newline or control byte in a path is escaped. nginx's error log is limited to `crit`, because its lines quote the request (query string included).
- **Hardening.** Non-root, `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, tmpfs for the pid file and temporary files, no Docker socket, no network but `elysium-edge`. It never joins a data-store network.

A stack joins with `networks: elysium-edge: {external: true}` and the alias `<app>-<env>-proxy`, publishing nothing.

## Test

`tools/tests/edge.sh` (Docker, about 3 minutes, real ports and network names: stop a running edge first). `EDGE_SMOKE=1` adds the smoke against the real Prince stack. CI runs it with stub upstreams.
