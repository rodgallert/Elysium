# Prince

A payment and content delivery platform: creators register as producers, list digital products — downloadable files, access to a content platform, or courses — package them into offers, and sell to buyers. The platform takes a cut of card-based transactions while gateway pass-through costs (like withdrawal fees) are passed on to producers rather than absorbed as revenue.

This is a portfolio project built to demonstrate clean architecture, a realistic multi-service topology, and production-shaped engineering practices — not a real business.

The name follows a small World of Darkness theme: the repo root, `Elysium`, is WoD terminology for neutral ground where vampires may not fight; `Prince` is the Camarilla's title for the vampire who governs a city.

## Architecture at a glance

A monorepo of independently deployable services, orchestrated with Docker Compose and fronted by a single reverse proxy so the whole thing behaves like one application on one domain:

| Service | Stack | Path | Role |
|---|---|---|---|
| Core web | Vue 3 + Vite + Vuetify | `/` | Producer/product/offer browsing, sign up, sign in |
| Checkout web | Vue 3 + Vite + Vuetify | `/checkout` | Purchase flow, deployed separately |
| Core API | .NET 10, ASP.NET Core, EF Core | `/api` | Source of truth for domain data; full clean-architecture layering |
| Checkout API | .NET 10, ASP.NET Core | `/api/checkout` | Checkout/purchase orchestration, scalable independently of Core |
| Jobs | .NET 10, ASP.NET Core, Hangfire | `/jobs` | Background processing, admin-only dashboard with its own auth |
| Reverse proxy | nginx | — | Path-routes everything above to simulate a single domain |
| File storage | MinIO (S3-compatible) | — | Self-hosted object storage for uploaded product files |
| Database | PostgreSQL | — | One shared database across all backend services |

Full design rationale — including *why* things are shaped this way, not just what they are — lives in [`Docs/`](Docs/):

- **[`Docs/architecture.md`](Docs/architecture.md)** — the target system design and an honest snapshot of what's actually built today versus still ahead.
- **[`Docs/decisions.md`](Docs/decisions.md)** — a dated log of every non-obvious decision made along the way, with the reasoning behind it.

Each service also carries its own `CLAUDE.md` with conventions specific to that project (see [`Backend/Core/CLAUDE.md`](Backend/Core/CLAUDE.md), [`Backend/Checkout/CLAUDE.md`](Backend/Checkout/CLAUDE.md), [`Backend/Jobs/CLAUDE.md`](Backend/Jobs/CLAUDE.md)), and the repo-wide rules live in [`CLAUDE.md`](CLAUDE.md).

## Tech stack

- **Backend**: .NET 10, ASP.NET Core, Entity Framework Core (code-first, PostgreSQL), Hangfire, xUnit
- **Frontend**: Vue 3, Vite, Vuetify, TypeScript
- **Infrastructure**: Docker Compose, nginx, PostgreSQL, MinIO

## Getting started

**Prerequisites**: Docker and Docker Compose. Nothing else needs to be installed locally.

```bash
cp .env.example .env
docker compose up --build
```

That's it — Postgres and MinIO come up, database migrations run automatically, and every service starts in the right order. Once everything's healthy:

| What | URL |
|---|---|
| Core site | http://localhost:8080/ |
| Checkout | http://localhost:8080/checkout/ |
| Core API | http://localhost:8080/api/ |
| Checkout API | http://localhost:8080/api/checkout/ |
| Jobs dashboard | http://localhost:8080/jobs/ (login required — see `.env`) |
| MinIO console | http://localhost:9001/ |

`.env.example` documents every configurable value (database credentials, Jobs admin login, MinIO credentials) with safe local-dev defaults — review it before deploying this anywhere beyond your own machine.

## Project status

This is being built incrementally and in the open — the domain model (producers, products, offers, transactions, withdrawals), its persistence layer, and the full container topology are in place; the actual public API surface, purchase flow, and file upload/download endpoints are still being built out. [`Docs/decisions.md`](Docs/decisions.md) is the most current source of truth on what's done versus what's next.
