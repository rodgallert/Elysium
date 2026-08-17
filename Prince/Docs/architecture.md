# Prince — Architecture

## What this is

Prince is a payment and content delivery platform — comparable to Hotmart or Udemy: creators publish products (courses/content), buyers pay and get delivery/access. It's a portfolio project, built to demonstrate production-realistic architecture and engineering practices rather than to run a real business.

The name follows a World of Darkness theme: the repo root `Elysium` is WoD terminology for neutral ground where vampires may not fight; "Prince" is the Camarilla's title for the vampire who governs a city — the authority figure. Future services/sub-projects may continue the theme.

## Target topology

The end goal is a monorepo that stands up a full, production-shaped stack with a single `docker compose up` — clone and go, no manual setup. Services, with their intended path if fronted by one domain (e.g. `prince.com`) behind nginx:

| Service | Tech | Path | Role |
|---|---|---|---|
| core-web | Vue.js | `/` | Producer/product/offers browsing, sign up, sign in |
| checkout-web | Vue.js | `/checkout` | Purchase flow only, separate SPA |
| Core API | .NET (`Prince.*`) | `/api` | Source of truth for domain data; clean-architecture layered |
| Checkout API | .NET (`Prince.Checkout.*`) | `/api/checkout` | Independently scalable checkout/purchase orchestration |
| Jobs | .NET (`Prince.Jobs.*`) + Hangfire | `/hangfire` (behind `/jobs` once proxied) | Background processing, admin-only dashboard |
| reverse-proxy | nginx | — | Path-routes all of the above to simulate one domain |
| file-storage | MinIO (S3-compatible) | — | Self-hosted object storage for product files, instead of depending on AWS S3 |

All of the above is actually built and running — see `Docs/decisions.md` for the full history. What's real vs. still ahead: see "Current implementation status" below.

## Data

**One single shared Postgres database** for the whole platform (database name `prince`), not per-service databases or schemas. Core's `Prince.Data` project is the only place that owns EF Core migrations for the shared domain schema (`Producer`/`Product`/`Offer`/`Transaction`/`Withdrawal`) — it's the single source of schema truth. Checkout and Jobs reference `Prince.Domain`/`Prince.Data` directly rather than defining their own copies, though neither actually queries `PrinceDbContext` yet (Jobs has a separate, narrowly-scoped `JobsIdentityDbContext` for its own admin auth — see `Docs/decisions.md`, "Jobs admin auth implemented"). **Code-first EF Core only** — no hand-written SQL init/schema scripts. Migrations run automatically on every `core-api` container startup (idempotent — a no-op once the schema is already current).

All services share the same `ConnectionStrings:Prince` configuration key pointing at this one database.

## Backend structure

```
Prince/
├── Docs/                  # you are here
├── CLAUDE.md              # repo-wide AI/dev conventions
└── Backend/
    ├── Core/               # Prince.sln — Prince.App / Domain / Services / Data
    ├── Checkout/           # Prince.Checkout.sln — Prince.Checkout.Api (references Core's Domain+Data)
    └── Jobs/               # Prince.Jobs.sln — Prince.Jobs.Api (references Core's Domain+Data, hosts Hangfire)
```

**Core** is the only service with full clean-architecture layering (`App → {Services, Data} → Domain`), because it's the only service that owns domain modeling and persistence. **Checkout** and **Jobs** are deliberately lean — a single API project each — because their job is orchestration/processing against data Core already owns, not modeling new domain concepts. New backend services should default to the Checkout/Jobs pattern (reference Core's Domain/Data) unless their scope genuinely requires owning new domain concepts, in which case that's a decision to raise explicitly rather than assume.

See `Backend/Core/CLAUDE.md`, `Backend/Checkout/CLAUDE.md`, and `Backend/Jobs/CLAUDE.md` for project-specific rules, and the repo-root `CLAUDE.md` for conventions that apply everywhere.

## Current implementation status

- **Core**: `Prince.Domain` now has real business logic across three areas — the platform's revenue model (`Models/Payments/` — `Money`, `PaymentMethod`, `Transaction`, `Buyer`, `Withdrawal`, fee schedules), `Producer` (`Models/Producers/`), the aggregate root that owns a seller's balance, signs up with just name/email/password, and gates withdrawals on a validated CPF while allowing selling immediately, and `Product` (`Models/Products/`), a peer aggregate (not nested under `Producer`) with a `Active`/`Blocked`/`Deleted` status lifecycle and a closed `ProductType` set (`DigitalDownload`/`ContentPlatformAccess`/`Course`). See `Docs/decisions.md` for the full history and reasoning. `ProductType.DigitalDownload` carries a `ProductFile` (storage key/filename/size/content type — see `file-storage` below). `Offer` (name/real price/discount price/description) is a peer entity referencing `ProductId` — a product can have many offers. `Sale` was renamed `Transaction` and now references the purchased `Offer` (by Id) and a `Buyer` (name/CPF/email, no account of its own), with `AmountPaid` captured as a snapshot at purchase time so later `Offer` price changes don't retroactively affect it. 87 unit tests in `Prince.Domain.Tests`. `Transaction` still doesn't reference `Product` directly (only `Offer`, which itself references `Product`), and nothing in the app actually talks to MinIO yet — both deferred.

**Persistence**: `Prince.Data`/`Prince.App` are wired up for real now — the four Core projects' references were connected for the first time (`Prince.App → Prince.Data → Prince.Domain`), `PrinceDbContext` maps all five entities (code-first, `EFCore.NamingConventions` for snake_case), and migrations run automatically on every `core-api` startup (`db.Database.MigrateAsync()`, idempotent — a no-op when already up to date). `Prince.Services` is still an empty stub, not yet wired into `Prince.App`. See `Docs/decisions.md` ("EF Core wired up") for two real bugs caught during this pass: a latent identity-corruption risk from EF potentially picking domain constructors with internal `Guid.NewGuid()` calls (fixed with dedicated private EF constructors, verified empirically against the real container, not just reasoned about), and a migrations-history-table collision between `PrinceDbContext` and Jobs' `JobsIdentityDbContext` sharing one physical database (fixed by giving each its own history table name).
- **Checkout**: skeleton — `Prince.Checkout.Api` scaffolded and references Core's `Domain`/`Data`, still on the template weather-forecast demo endpoint plus `/health`.
- **Jobs**: Hangfire dashboard and server are live (`/hangfire`, proxied at `/jobs`), storage points at the shared `prince` database, a demo recurring job (`HeartbeatJob`) proves it compiles and runs, plus `/health`. **Admin auth is implemented** — a separate ASP.NET Core Identity store (`JobsIdentityDbContext`, its own cookie scheme) gates the dashboard via `.RequireAuthorization()`, with a hand-rolled `/admin/login` page and a seeded dev admin user (`JOBS_ADMIN_EMAIL`/`JOBS_ADMIN_PASSWORD` env vars). Verified end-to-end through nginx: unauthenticated `/jobs/` redirects to `/admin/login`, successful login redirects back, authenticated request returns the real dashboard.
- **Frontends**: both Vue apps (`Frontend/prince-core`, `Frontend/prince-checkout`) are scaffolded (Vue 3 + Vite + Vuetify + TypeScript) and wired into containers/routing — `core-web` at `/`, `checkout-web` at `/checkout` (Vite `base: '/checkout/'`, picked up automatically by vue-router's `BASE_URL`-driven history). Still just the Vuetify scaffold UI, no real pages/features built yet.
- **Containers**: all five app services (Core/Checkout/Jobs APIs + the two web apps), Postgres, MinIO (`file-storage` + a one-shot `file-storage-init` bucket-creation step), and nginx are Dockerized and wired together via a root `docker-compose.yml` — `docker compose up` brings up the entire stack with correct startup ordering. Verified end-to-end: `/`, `/checkout/*` (including asset requests and SPA deep-link fallback), `/api/*`, `/api/checkout/*`, `/jobs/*` (with login), and MinIO's API/console ports all work.
- **Git**: not started.
