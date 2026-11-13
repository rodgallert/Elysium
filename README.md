# Elysium

In the World of Darkness, Elysium is neutral ground — a place where vampires of rival clans and courts set their politics aside and coexist, if only for a night, under a shared roof.

This repository borrows the name for an ecosystem of microservices that share one roof. Each service is named after something from the World of Darkness, owns its data, and talks to the others only through versioned APIs and messages.

## What this is

A portfolio project: a production-shaped ecosystem of **shared services** — accounts, a ledger, file storage, notifications — that any **product** can build on. Prince, a payment and content-delivery platform, is the first product. The goal is that a new product idea (say, property management) starts with sign-in, balances and files already done, so most of the new work is its own domain and screens.

It's not a business. It exists to show how I design, build and run a system like this: service boundaries, security, reliability, and the engineering process around them.

## The services

| Service | Role | Status |
|---|---|---|
| **Masquerade** | Accounts: one account across every product, sign-in by password, Google or passkey, per-product activation, immediate sign-out everywhere | Designed; implementation next |
| **Keeper** | Gateway (YARP): single entry point, token and revocation checks | Designed |
| **Harpy** | Ledger: double-entry balances, holds and withdrawals | Sketched |
| **Herald** | Notifications (email first) | Planned |
| **Haven** | File storage (S3-compatible, on Silo) | Planned |
| **Vitae** · **Tithe** | Payments · recurring billing | Planned |
| [**Prince**](Prince/) | Product: creators sell courses, downloads and content access | Running (APIs and Vue frontends; React frontends scaffolded) |

## Architecture at a glance

- **Isolated services.** Each service has its own database and never reads another's; shared services know nothing about the products using them.
- **One account, many products.** A person signs up once; each product is *activated* on that account, reuses what it already knows, and sees only the data it was granted.
- **OpenID Connect** on ASP.NET Core Identity + OpenIddict, targeting **OWASP ASVS 5.0 Level 2**, with tokens revocable on the very next request.
- **CQRS and messaging** with RabbitMQ and Wolverine; language-neutral message contracts, so a future service can use another framework.
- **Trunk-based development with per-service releases**: every merge publishes development images, and one file lists what's in production (being set up).

The full design, with the reasoning behind each decision:

- [`Docs/platform-design.md`](Docs/platform-design.md) — the ecosystem: services, accounts, security, revocation, messaging, layout.
- [`Masquerade/Docs/design.md`](Masquerade/Docs/design.md) — the accounts service in detail; [`decisions.md`](Masquerade/Docs/decisions.md) beside it.
- [`Docs/workflow.md`](Docs/workflow.md) — branches, reviews, releases.
- [`ROADMAP.md`](ROADMAP.md) — what gets built, in which order.

## How this is built

Elysium is built with AI coding agents, deliberately and in the open. I own the architecture, the scope and every decision; the agents do much of the drafting, coding and reviewing, inside a process designed to keep quality high:

- **Design reviews before code.** Each significant piece of design goes through a structured review in which agents argue it from separate angles — architecture, security, testing, reliability and performance, data, user experience — over several rounds. Disagreements and open questions come to me; I decide, and the outcome lands in the design documents and decision logs.
- **One ticket, one branch, one pull request.** Every change is a GitHub issue with its own branch and PR, tracked on a project board.
- **Independent review.** Every PR is reviewed by an agent other than its author against a written checklist (correctness, security, messaging, contracts, migrations, performance), plus a dedicated security review for anything touching authentication or personal data. I approve and merge.
- **Written rules.** The conventions the agents follow live in the repository: [`CLAUDE.md`](CLAUDE.md), [`Docs/workflow.md`](Docs/workflow.md) and the checklists in [`.claude/skills/`](.claude/skills/).
- **Machine checks.** CI builds and tests every service and frontend and enforces the service boundaries ([`tools/check-boundaries.sh`](tools/check-boundaries.sh)).

## Running it

Today the runnable part is Prince. With Docker and Docker Compose installed:

```bash
cd Prince
cp .env.example .env
docker compose up --build
```

See [Prince's README](Prince/README.md) for what comes up and where. A single root `docker-compose.yml` for the whole ecosystem, with one hostname per app (`accounts.localhost`, `prince.localhost`, `api.localhost`), arrives with Masquerade and Keeper.
