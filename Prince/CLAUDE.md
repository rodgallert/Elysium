# Prince — repo-wide guidelines

Prince is a payment and content delivery platform (Hotmart/Udemy-like) built as a portfolio piece — it's meant to showcase clean architecture and production-realistic engineering practices, not to ship fast. Full context: `Docs/architecture.md` (system design) and `Docs/decisions.md` (why things are the way they are, chronologically). Read both before making structural changes — check whether something you're about to decide has already been decided and reasoned through.

## Repo structure

```
Prince/
├── docker-compose.yml      # orchestrates every service below
├── reverse-proxy/          # nginx — path-routes everything to simulate one domain
├── Docs/                   # architecture.md, decisions.md
├── Backend/
│   ├── Core/                # Prince.sln — full clean-architecture layering
│   ├── Checkout/             # Prince.Checkout.sln — lean, single project
│   └── Jobs/                 # Prince.Jobs.sln — lean, single project, hosts Hangfire
└── Frontend/
    ├── prince-core/          # Vue 3 + Vite + Vuetify + TS — served at /
    └── prince-checkout/      # Vue 3 + Vite + Vuetify + TS — served at /checkout
```

Each backend service is its own `.sln` under `Backend/<ServiceName>/`. Each frontend app is its own Vite project under `Frontend/<app-name>/`. Every service (backend and frontend) has a `Dockerfile` and is wired into the root `docker-compose.yml` and `reverse-proxy/nginx.conf`.

**If a frontend app is served under a non-root path** (like `prince-checkout` at `/checkout`), its Vite `base` config must match that path — otherwise built asset URLs resolve against the wrong root and get swallowed by another route. Check whether the app's router reads `import.meta.env.BASE_URL` (Vite sets this from `base` automatically) before adding manual base-path wiring elsewhere.

Each service directory has its own `CLAUDE.md` with rules specific to that project. This file covers what applies everywhere.

## Reference rules — read before scaffolding a new service

**Core owns the domain.** `Prince.Domain` (entities, value objects, repository interfaces) and `Prince.Data` (EF Core `DbContext`, migrations, repository implementations) under `Backend/Core/` are the single source of truth for the shared *domain* schema (`Producer`/`Product`/`Offer`/`Transaction`/`Withdrawal`). Only Core's `Prince.Data` should add migrations for that domain schema. The one deliberate exception: Jobs' `JobsIdentityDbContext` has its own narrowly-scoped migrations for service-local admin-auth infrastructure (not domain data) — see `Backend/Jobs/CLAUDE.md`.

**Default a new backend service to referencing Core's `Prince.Domain`/`Prince.Data` directly**, the way `Prince.Checkout.Api` and `Prince.Jobs.Api` already do, instead of defining its own entities or `DbContext`. Only give a new service its own Domain/Data layer if its scope genuinely requires modeling concepts Core doesn't have — and treat that as a decision to raise with the user explicitly, not something to infer and just do.

**Only Core gets the full 4-project clean-architecture split** (`Prince.App → {Prince.Services, Prince.Data} → Prince.Domain`, dependencies pointing inward, `Domain` has zero package/project dependencies). Other services stay as a single lean API project unless there's a concrete reason to split — don't cargo-cult Core's layering onto a service that doesn't need it.

## Data conventions

- **One single shared Postgres database** (`prince`) for the whole platform. No per-service databases, no per-service schemas.
- **Code-first EF Core only.** No hand-written SQL for schema/database creation. Migrations run automatically at each service's own startup (`Database.MigrateAsync()` before `app.Run()`), not via a separate migrator step — idempotent, safe to run on every boot.
- All services read the connection string from the same config key: `ConnectionStrings:Prince`.
- **Any `DbContext` added against this shared database needs its own explicitly-named migrations history table** (`MigrationsHistoryTable(...)`), not EF's default `__EFMigrationsHistory`. Multiple `DbContext`s (currently `PrinceDbContext` in Core, `JobsIdentityDbContext` in Jobs) sharing one physical database will collide on that table otherwise — hit this exact bug wiring up `PrinceDbContext`, see `Docs/decisions.md` ("EF Core wired up").
- **File/object storage is MinIO** (`file-storage` service in `docker-compose.yml`), not AWS S3 — chosen specifically to avoid depending on a real AWS account for a portfolio project. It's S3-API-compatible, so any standard S3 client SDK works against it. Buckets are created via the one-shot `file-storage-init` service (`minio/mc`, same `service_completed_successfully` pattern as the DB migrators), not a manual script. Nothing in the app talks to it yet — see `Docs/decisions.md` ("File storage: MinIO instead of AWS S3").

## Naming

- Folder names are generic/structural (`Backend/Core`, `Backend/Checkout`, `Backend/Jobs`).
- .NET solutions/namespaces keep the `Prince.*` WoD-themed prefix regardless of folder name (`Prince.App`, `Prince.Checkout.Api`, `Prince.Jobs.Api`, ...). Don't rename these to generic names like `CoreApi.*`.

## How to work in this repo

- **Scope work to what's actually asked.** This repo has a large end-state vision (see `Docs/architecture.md`), but plan and build one concrete piece at a time — don't front-load unrelated future work into a single change just because it's part of the eventual vision. Confirm bigger architectural calls (data topology, service boundaries, auth strategy, etc.) at the point they're actually being built, not all at once up front.
- **Record non-obvious decisions in `Docs/decisions.md`** as they're made, with the reasoning, not just the outcome.
- Git is intentionally not initialized yet as of 2026-08-17 — don't run `git init` unless asked.
- Known pending cleanup: `Microsoft.AspNetCore.OpenApi` 2.0.0 (in all three services' templates) has a known high-severity NuGet advisory (GHSA-v5pm-xwqc-g5wc) — bump it opportunistically or when asked.
