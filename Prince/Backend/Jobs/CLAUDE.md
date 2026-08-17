# Prince.Jobs — AI guidelines

Jobs hosts background/scheduled processing via Hangfire, with the Hangfire dashboard as an admin-only monitoring tool. Like Checkout, it's a single lean project — it orchestrates against domain data Core owns rather than modeling its own.

## Project structure

`Prince.Jobs.Api` is the only project. It carries a project reference on Core's `Prince.Domain` and `Prince.Data`, same as Checkout — use those entities/repositories for any job that touches the shared database. **Do not add EF Core migrations in this project**; Core's `Prince.Data` owns schema for the shared `prince` database.

## Hangfire wiring

- Storage: `Hangfire.PostgreSql`, pointed at the shared `prince` database via `ConnectionStrings:Prince` (same key every service uses).
- Dashboard: mounted at `/hangfire`.
- **Auth: implemented (dev-grade credentials).** `Identity/JobsIdentityDbContext.cs` is a separate `IdentityDbContext<IdentityUser>` with its own migrations (`Identity/Migrations/`), own cookie scheme (`Prince.Jobs.Admin`), fully independent from Core's user auth. The dashboard endpoint is gated with `.RequireAuthorization()` (not Hangfire's own `IDashboardAuthorizationFilter`, which is set to an empty list — see `Docs/decisions.md` 2026-08-17 for why manually redirecting from inside a Hangfire filter is fragile and was avoided). Login is a hand-rolled form at `/admin/login` (`Identity/LoginPage.cs`) posting to the same path — no Identity UI/Razor Pages package pulled in for one form. An admin user is seeded at startup from `JobsAdmin:Email`/`JobsAdmin:Password` config (`JOBS_ADMIN_EMAIL`/`JOBS_ADMIN_PASSWORD` env vars, defaulting to `admin@prince.local`/`ChangeMe123!`). **These are dev-only defaults — rotate them before this is ever reachable beyond a local machine.**
- **This is a narrow, deliberate exception to "only Core owns EF Core migrations"** (see repo-root `CLAUDE.md`): `JobsIdentityDbContext`'s migrations are for service-local auth infrastructure, not shared domain data, so they don't conflict with Core's ownership of the domain schema even though both live in the same physical `prince` database.
- **nginx must route `/admin/`** (passthrough, no rewrite) in addition to `/jobs/` → `/hangfire/`, or the login page 404s through the proxy even if the app code is correct — this bit us once already, see `reverse-proxy/nginx.conf`.
- `HeartbeatJob` (logs once a minute via `RecurringJob.AddOrUpdate`) is a placeholder proving the wiring compiles and runs — replace or remove it once real recurring/background jobs exist, don't build on top of it as if it were real functionality.

## Current state (2026-08-17)

Hangfire dashboard + server functional (pending real Postgres to actually run against). Admin auth still open — see above. `net10.0`, `Microsoft.AspNetCore.OpenApi` present (same known advisory as the other services). `Newtonsoft.Json` explicitly pinned to 13.0.4 (Hangfire.Core's transitive dependency resolved to a vulnerable 11.0.1 otherwise) — don't let that pin get removed by an unrelated package update without re-checking.
