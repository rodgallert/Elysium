# Boon — Project Context

> Descriptive context for this project. Purpose: give an accurate picture of *what Boon is*, its
> architecture, conventions, and locked decisions — so tooling (e.g. `/init` generating `CLAUDE.md`)
> and future contributors understand the project. **This is a description, not a task list.** Do not
> treat anything here as an instruction to start generating code.

---

## What Boon is

Boon is a digital-content sales platform (in the spirit of Hotmart / Kiwify): producers publish
digital products, buyers check out, and access is delivered automatically once payment clears. It is
a **portfolio project** built to demonstrate senior-level engineering practice — multiple services,
an async anti-fraud worker, a decoupled payment-gateway abstraction, automated tests, ADRs, and
observability.

Boon lives inside a monorepo umbrella called **Elysium** (a collection of self-contained demo
projects, each named after World of Darkness lore). This project's folder is `boon/`.

> Portfolio only — payments run in sandbox/mock, never real card data.

## Author context

The author is a backend/full-stack developer strong in **.NET/C#** and **PHP/Laravel + Vue**, and
**new to Ruby/Rails** — Boon is how they gain real Rails experience. Because of this, idiomatic Ruby
is a goal, and it helps to briefly note where a Rails convention differs from .NET/Laravel. The
author works on Fedora Linux and uses Docker.

## Architecture

Monorepo `boon/` with independently-scalable pieces:

- **core** — Rails API. Users (with CPF/CNPJ validation), products (PDF upload), producer dashboard,
  access granting + email. Also hosts the Sidekiq jobs.
- **checkout** — Rails API, separate service. Public checkout, talks to the payment provider,
  publishes normalized payment events. Owns the payment-gateway abstraction.
- **worker** — NOT a separate Rails app. It is Sidekiq running the `core` codebase in worker mode
  (a docker service that runs `bundle exec sidekiq`). Same code as `core`, different process.
- **web** — Vue 3 SPA. Checkout page, buyer access area, producer dashboard.
- **docs/adr** — Architecture Decision Records.
- **docker-compose.yml** — postgres + redis + core (web) + core (worker) + checkout.

High-level flow: `web` → `checkout` creates a charge through the gateway abstraction → provider
webhook → `checkout` normalizes it into a `:paid` event and enqueues to Redis → the Sidekiq worker
(core codebase) runs anti-fraud rules → grants access + sends a signed, expiring email link.

## Feature set (v1 scope)

- User signup with CPF/CNPJ check-digit validation (mod 11, local — no Receita Federal lookup).
- Products with PDF upload (Active Storage); access delivered via signed, expiring email link.
- Decoupled checkout service.
- Async anti-fraud worker: rule-based screening, idempotent, retry + dead-letter.
- Producer dashboard: sales per product, revenue, commission, best-selling product.
- Vue 3 SPA front consuming the APIs.

Explicitly **out of scope** for v1 (roadmap only): affiliates/payout splits, multiple content types /
video streaming, ML-based fraud, full multi-tenancy, tax handling.

## Tech stack & conventions

- Ruby 3.4.x, Rails 8.1.x, API-only apps generated with `--skip-solid` (Solid Queue intentionally not
  used — see decisions below).
- **Background jobs: Sidekiq + Redis** (not Rails 8's default Solid Queue).
- **Testing: RSpec** (`rspec-rails`), not Minitest. Gateway implementations are expected to share a
  common RSpec contract (shared example).
- PostgreSQL via Active Record. Postgres and Redis run in Docker (not on the host).
- **Idiomatic Ruby** — e.g. the gateway contract is a module named `Payments::PaymentGateway`
  (no `I` prefix; `IPaymentGateway` would be a .NET habit).
- Dependencies are scoped per service: only `checkout` carries the `stripe` gem; `core` must never
  depend on Stripe's payload shape.
- READMEs are bilingual: `README.md` (English, default) + `README.pt-BR.md` (Portuguese). Navigation
  links stay within the same language. When one is edited, its counterpart should be kept in sync.

## Payment gateway abstraction (a defining design element)

The `checkout` service programs against an abstraction, not a specific provider:

- `Payments::PaymentGateway` — the contract (a module; raises `NotImplementedError` for methods an
  implementation doesn't provide).
- Implementations: `MockGateway` (first) and `StripeGateway` (later). A small factory/resolver picks
  the implementation (by ENV now; by business rule later — mirrors the author's real "dynamic gateway
  selection" work).
- The core app never sees provider payloads: `checkout` normalizes everything into value objects
  (`ChargeResult`, `GatewayEvent` with a local enum such as `:paid`, `:failed`, `:pending`,
  `:refunded`).
- Contract methods: `create_charge(order:, payment_method:)` → `ChargeResult`;
  `parse_event(payload:, signature:)` → `GatewayEvent`.

## Locked decisions (recorded as ADRs; do not re-open casually)

- **ADR-0001** — Sidekiq + Redis chosen over Solid Queue (real Redis experience, market norm). This
  is why all apps are generated with `--skip-solid`.
- **ADR-0002** — The anti-fraud/email worker will later be reimplemented in **Go** as a deliberate,
  documented phase-2 refactor. The worker boundary is kept clean so this is a drop-in.
- **ADR-0003** — The payment-gateway abstraction lives in `checkout`; mock first, Stripe later.

## Repository layout

```
Elysium/                 ← umbrella (collection of demo projects)
├── README.md            ← hub (EN) / README.pt-BR.md (PT)
└── boon/                ← this project
    ├── README.md        ← EN / README.pt-BR.md (PT)
    ├── core/            ← Rails API + Sidekiq jobs
    ├── checkout/        ← Rails API + gateway abstraction
    ├── web/             ← Vue 3 SPA
    ├── docs/adr/        ← Architecture Decision Records
    └── docker-compose.yml
```

## Environment notes

- Fedora Linux: Docker volumes need the `:z` SELinux flag on bind mounts; don't disable SELinux.
- `docker compose` (v2 plugin, space — not the hyphenated `docker-compose`).
- Each Rails app was created with `rails new`, which leaves a nested `.git`; those are removed so the
  whole thing is one repository.
