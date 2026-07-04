# ADR-0007 — Nginx edge gateway with path-based routing

Status: Accepted
Date: (fill in)

## Context

Boon has two separate SPAs (producer, buyer) and two APIs (core, checkout). We want a
production-like experience where a single entry point (as if `elysium.com`) serves everything, and
`docker compose up` brings the whole system up behind one address — no juggling ports.

## Decision

Put an **Nginx reverse proxy** in front of all HTTP services and route by path:

- `/`                     → core-frontend (SPA)
- `/checkout`             → checkout-frontend (SPA, served under the sub-path)
- `/api`                  → Swagger UI (docs)
- `/api/checkout/{stub}`, `POST /api/checkout` → checkout API
- `/api/*` (everything else, e.g. `/api/products/{id}`) → core API (unprefixed)

Workers (`sales`, `notifications`) are background processes and sit **outside** Nginx.

## Consequences

- **Precedence matters:** `/api/checkout` must be matched before `/api`/`/api/` or checkout requests
  fall through to core. The config declares the checkout location first / more specifically.
- **SPA under a sub-path:** checkout-frontend must set Vite `base: '/checkout/'` (and its router base)
  or its assets 404. core-frontend stays at `/`.
- Adds one service (nginx) and one config file (`docker/nginx/nginx.conf`), which also gives the
  `docker/` folder a clear purpose.
- Demonstrates edge routing / API-gateway patterns — a deliberate senior-level signal.
- Trade-off: the unprefixed-core scheme (`/api/...` = core) is slightly more fragile to route than
  giving every service its own prefix, but yields cleaner URLs. Accepted.

## Notes

If frontends are built to static assets, serve them with `root` + `try_files $uri /index.html`
instead of proxying to a dev server.
