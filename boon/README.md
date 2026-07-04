# Boon

**English** · [Português](./README.pt-BR.md)

> *A boon is a formal debt or favor traded between Kindred — the currency of prestige and obligation in Vampire: The Masquerade. Fitting for a platform built on transactions of value.*

[← Back to Elysium](../README.md)

**Boon** is a digital-content sales platform (in the spirit of Hotmart / Kiwify): producers publish
digital products, buyers check out via a specific **offer**, and access is delivered automatically
once payment clears. An Nginx edge gateway fronts two SPAs and two APIs; background work runs in
segregated Sidekiq workers.

> ⚠️ Portfolio + learning project — not a real payment product. Payments run in sandbox/mock; do not use with real card data.

## Why this project

It mirrors real production work I did on payment platforms (dynamic gateway selection, fraud
detection, background jobs, checkout performance) and demonstrates leading technical work across
**multiple services and codebases** — edge routing, architecture decisions, testing, and observability.

## Architecture

Monorepo of independently-deployable services behind an Nginx edge gateway, sharing one database
whose schema is owned by a `domain` gem inside `core`.

```
                         ┌───────────────────────────┐
   elysium.com  ────────▶│   nginx (edge gateway)    │
                         └──────────────┬────────────┘
     /            ┌──────────────┬──────┴──────┬──────────────────┐
     │            ▼              ▼             ▼                  ▼
  core-frontend   checkout-frontend    /api (Swagger)      /api/products/{id} → core (API)
  (Vue+Vuetify)   (/checkout, Vue)                         /api/checkout/{stub}, POST /api/checkout → checkout (API)

  core ──┐                                   ┌── worker (Sidekiq)
         ├─ share ─▶ core/domain (gem) ◀─────┤     queue `sales`         → payments/refunds (+gateway)
  checkout ┘         models + migrations     │     queue `notifications` → email/push/sms
         │                                    │
         └──────────▶ Redis (queues) ◀────────┘        all services ─▶ PostgreSQL (shared)
```

- **core** — Rails API: producer signup, products, reports, orders, refund/chargeback requests. Uses the `domain` gem.
- **core/domain** — gem (Rails engine): ActiveRecord models + migrations. Single source of truth for the schema.
- **checkout** — minimal Rails API: `GET /api/checkout/{stub}` (product under an offer), `POST /api/checkout` (create purchase). Records + enqueues only.
- **worker** — Sidekiq, one codebase, two queues as separate processes/containers: `sales` (payment validation, **gateway selection**, charge, order state, refunds; owns the gateway abstraction; Sequel for DB access) and `notifications` (email/push/sms). *(Planned rewrite in Go — see ADR-0002.)*
- **core-frontend / checkout-frontend** — Vue 3 + Vuetify SPAs.
- **nginx** — edge gateway, path-based routing (see below).

## Routing (production-like)

```
elysium.com                    → core-frontend
elysium.com/checkout           → checkout-frontend
elysium.com/api                → Swagger UI (core + checkout)
elysium.com/api/products/{id}  → core API (get product)
elysium.com/api/checkout/{stub}→ checkout API (product under an offer)
POST elysium.com/api/checkout  → checkout API (create purchase)
```

## Features (v1)

- Producer signup with **CPF/CNPJ** check-digit validation (mod 11, local — no Receita Federal lookup).
- Products + **offers**; **PDF upload** (Active Storage); access via **signed, expiring email link**.
- Minimal decoupled **checkout**.
- **Segregated async workers** (`sales` / `notifications`) with independent retry + fault isolation.
- **Producer dashboard**: sales per product, revenue, commission, best-selling product.

## Tech stack

Ruby on Rails (API-only) · Vue 3 + Vuetify · Sidekiq + Redis · PostgreSQL · Sequel (worker) · Nginx · RSpec · Docker Compose

## Getting started

```bash
docker compose up
```

(Wiring — database, Sidekiq/Redis, domain migrations, Vite base for /checkout, nginx.conf — documented in PROJECT.md.)

## Documentation

- [Architecture Decision Records](./docs/adr/) — Sidekiq vs Solid Queue, worker→Go, gateway abstraction, shared DB, worker segregation, SPA vs SSR, edge gateway, queue contract.

## Roadmap (out of scope for v1)

Affiliates & payout splits · video streaming · ML fraud · multi-tenancy · taxes. Swagger and the Go
worker are increments, not MVP blockers.

---

[← Back to Elysium](../README.md)
