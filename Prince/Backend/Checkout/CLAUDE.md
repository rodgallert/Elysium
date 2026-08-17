# Prince.Checkout — AI guidelines

Checkout is a standalone, independently-scalable microservice handling cart/checkout/payment orchestration only. It's deliberately lean — a single project, not a clean-architecture split — because it doesn't own domain modeling; Core does.

## Project structure

`Prince.Checkout.Api` is the only project. It carries a project reference on Core's `Prince.Domain` and `Prince.Data` (`../Core/Prince.Domain`, `../Core/Prince.Data`) instead of defining its own entities or `DbContext`. Use those existing entities/repositories for anything touching the shared database — don't redefine or duplicate them here.

**Do not add EF Core migrations in this project.** Core's `Prince.Data` is the single owner of schema for the shared `prince` database (see repo-root `CLAUDE.md`). If Checkout needs a schema change, that change belongs in Core's `Prince.Domain`/`Prince.Data`.

## Scope discipline

Keep this service focused on checkout/cart/payment orchestration. If it starts needing to model its own domain concepts Core doesn't have (e.g. cart-only state that doesn't belong in Core's domain), that's worth raising explicitly with the user rather than quietly growing this project into its own Domain/Services/Data split — see repo-root `CLAUDE.md` on when that split is actually warranted.

## Current state (2026-08-17)

Fresh scaffold. Still serves the default template weather-forecast endpoint; no real checkout logic yet. `net10.0`, `Microsoft.AspNetCore.OpenApi` package present (same known advisory as the other services — see repo-root `CLAUDE.md`).
