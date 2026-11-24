# Prince

A payment and content delivery platform: creators register as producers, list digital products — downloadable files, access to a content platform, or courses — package them into offers, and sell to buyers. The platform takes a cut of card-based transactions while gateway pass-through costs (like withdrawal fees) are passed on to producers rather than absorbed as revenue.

This is a portfolio project built to demonstrate clean architecture, a realistic multi-service topology, and production-shaped engineering practices — not a real business.

The name follows a small World of Darkness theme: the repo root, `Elysium`, is WoD terminology for neutral ground where vampires may not fight; `Prince` is the Camarilla's title for the vampire who governs a city.

## Architecture at a glance

A monorepo of independently deployable services, orchestrated with Docker Compose and fronted by a single reverse proxy so the whole thing behaves like one application on one domain:

| Service | Stack | Path | Role |
|---|---|---|---|
| Core web (Vue) | Vue 3 + Vite + Vuetify | `/vue` | Producer/product/offer browsing, sign up, sign in |
| Checkout web (Vue) | Vue 3 + Vite + Vuetify | `/vue/checkout` | Purchase flow, deployed separately |
| Core web (React) | React + Vite | `/react` | The core pages, to be built in React alongside Vue (scaffold today) |
| Checkout web (React) | React + Vite | `/react/checkout` | The purchase flow, to be built in React alongside Vue (scaffold today) |
| Core API | .NET 10, ASP.NET Core, EF Core | `/api` | Source of truth for domain data; full clean-architecture layering |
| Checkout API | .NET 10, ASP.NET Core | `/api/checkout` | Checkout/purchase orchestration, scalable independently of Core |
| Jobs | .NET 10, ASP.NET Core, Hangfire | `/jobs` | Background processing, admin-only dashboard with its own auth |
| Reverse proxy | nginx | — | Path-routes everything above inside the stack; reached through the edge proxy (`Edge/`) at `prince.localhost` |
| File storage | Silo (S3-compatible, a maintained MinIO fork) | — | Self-hosted object storage for uploaded product files |
| Database | PostgreSQL | — | One shared database across all backend services |

Full design rationale — including *why* things are shaped this way, not just what they are — lives in [`Docs/`](Docs/):

- **[`Docs/architecture.md`](Docs/architecture.md)** — the target system design and an honest snapshot of what's actually built today versus still ahead.
- **[`Docs/decisions.md`](Docs/decisions.md)** — a dated log of every non-obvious decision made along the way, with the reasoning behind it.

Each service also carries its own `CLAUDE.md` with conventions specific to that project (see [`Backend/Core/CLAUDE.md`](Backend/Core/CLAUDE.md), [`Backend/Checkout/CLAUDE.md`](Backend/Checkout/CLAUDE.md), [`Backend/Jobs/CLAUDE.md`](Backend/Jobs/CLAUDE.md)), and the repo-wide rules live in [`CLAUDE.md`](CLAUDE.md).

## Tech stack

- **Backend**: .NET 10, ASP.NET Core, Entity Framework Core (code-first, PostgreSQL), Hangfire, xUnit
- **Frontend**: Vue 3 with Vuetify, and React — the same pages to be built in both, side by side (the React apps are scaffolds today); Vite, TypeScript
- **Infrastructure**: Docker Compose, nginx, PostgreSQL, Silo

## Getting started

**Prerequisites**: Docker and Docker Compose. Nothing else needs to be installed locally.

```bash
# once per machine start: the edge proxy, the only thing that publishes a host port (127.0.0.1 and [::1], port 80)
docker compose -f ../Edge/docker-compose.yml up -d --wait
cp .env.example .env
docker compose up --build
```

That's it — Postgres and Silo come up, database migrations run automatically, and every service starts in the right order. Start the edge first: the stack joins its network `elysium-edge`, and without it `docker compose up` stops within seconds and names the network. Once everything's healthy, these answer on this machine only (the edge binds `127.0.0.1` and `[::1]`, so nothing is reachable from the network):

| What | URL |
|---|---|
| Core site (Vue / React) | http://prince.localhost/vue/ · http://prince.localhost/react/ |
| Checkout (Vue / React) | http://prince.localhost/vue/checkout/ · http://prince.localhost/react/checkout/ |
| Database (Postgres) | not published: `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"'` (credentials in `.env`) |
| Core API | http://prince.localhost/api/ |
| Checkout API | http://prince.localhost/api/checkout/ |
| Jobs dashboard | http://prince.localhost/jobs/ (login required — see `.env`) |
| File storage console | http://localhost:9001/ (credentials in `.env`; the S3 API isn't published, the services reach it inside Compose) |

`*.localhost` names resolve to this machine in browsers and in curl on most systems; where they don't, `curl --resolve prince.localhost:80:127.0.0.1 http://prince.localhost/` reaches the same place. The edge answers only to the exact host names it routes (`prince.localhost` and, for the development stack, `prince.dev.localhost`); any other `Host` gets `421`.

`.env.example` documents every configurable value (database credentials, Jobs admin login, file-storage credentials) with safe local-dev defaults — review it before deploying this anywhere beyond your own machine.

`.env.example` also states the rules the secrets must meet, and a one-shot `env-check` service checks them before anything else starts: `FILE_STORAGE_ROOT_PASSWORD` at least 8 characters (Silo exits otherwise), `FILE_STORAGE_ROOT_USER` at least 3, and `JOBS_ADMIN_PASSWORD` at least 6 characters with an uppercase letter, a lowercase letter, a digit and a symbol (ASP.NET Identity's default policy; otherwise the Jobs admin is never created). When a value breaks a rule, the services that need the secrets don't start (the frontends still do) and `env-check` exits with a line like `env-check: FILE_STORAGE_ROOT_PASSWORD must be at least 8 characters` (never the value). A plain `docker compose up` (attached, no service names) shows that line in its output; with `up -d` or `up <service names>`, Compose only says that `env-check` didn't complete successfully, so run `docker compose logs env-check` to see which value and rule failed. The rest of its rules are in `.env.example`. Compose reads a `$` in a `.env` value as a variable reference, so single-quote a value that contains one (`'Ab1$x'`), or write each `$` as `$$`. The check is [`env-check.sh`](env-check.sh).

Until 2026-11-14 the proxy and Silo (`9000`, `9001`) were published on every network interface, and Docker's published ports bypass the host firewall. If you ran the stack before then with the example passwords in your `.env`, change them (`POSTGRES_PASSWORD`, `JOBS_ADMIN_PASSWORD`, `FILE_STORAGE_ROOT_PASSWORD`) and recreate the volumes (`docker compose down -v`), since Postgres and Silo keep the credentials they were first started with.

**Breaking change (the edge proxy, #75):** `REVERSE_PROXY_PORT` is gone and `http://localhost:8080/...` no longer answers; use `http://prince.localhost/...` with the edge running. Remove the key from an existing `.env` (a leftover key is ignored, no error). Postgres is no longer published on `127.0.0.1:5432`: use `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"'`.

## Project status

This is being built incrementally and in the open — the domain model (producers, products, offers, transactions, withdrawals), its persistence layer, and the full container topology are in place; the actual public API surface, purchase flow, and file upload/download endpoints are still being built out. [`Docs/decisions.md`](Docs/decisions.md) is the most current source of truth on what's done versus what's next.
