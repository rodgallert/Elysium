# Elysium

In the World of Darkness, Elysium is neutral ground — a place where vampires of rival clans and courts set their politics aside and coexist, if only for a night, under a shared roof.

This repository borrows the name for an ecosystem of microservices that share one roof. Each service is named after something from the World of Darkness, owns its data, and talks to the others only through versioned APIs and messages.

## What this is

A portfolio project: a production-shaped ecosystem of **shared services** — accounts, a ledger, file storage, notifications — that any **product** can build on. Prince, a payment and content-delivery platform, is the first product. The goal is that a new product idea (say, property management) starts with sign-in, balances and files already done, so most of the new work is its own domain and screens.

It's a work in progress that I build in the open to show how I design, build and run a system like this: service boundaries, security, reliability, and the engineering process around them.

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

**Built and merged**

- **Isolated services.** Each service has its own database and never reads another's; shared services know nothing about the products using them. CI enforces the project boundaries.
- **Per-part releases are set up.** Each service, or each part it declares, has its own version, changelog, git tag and GitHub Release; each release gets signed build provenance and an SBOM, and `docker-compose.prod.yml` pins its production images by digest. No service has been released yet. Every merge into `main` publishes development images.
- **One required check.** A single `gate` check must pass before anything merges into `main`, and Markdown-only changes still get it.
- **An edge proxy with strict rules.** The reverse proxy re-resolves its backends after a restart, never sends an unknown name to the host's resolver, and normalises request paths before any service sees them.

**Designed, not built yet**

- **One account, many products.** A person signs up once; each product is *activated* on that account, reuses what it already knows, and sees only the data it was granted.
- **OpenID Connect** on ASP.NET Core Identity + OpenIddict, targeting **OWASP ASVS 5.0 Level 2**, with tokens revocable on the very next request.
- **CQRS and messaging** with RabbitMQ and Wolverine; language-neutral message contracts, so a future service can use another framework.

The full design, with the reasoning behind each decision:

- [`Docs/platform-design.md`](Docs/platform-design.md) — the ecosystem: services, accounts, security, revocation, messaging, layout.
- [`Masquerade/Docs/design.md`](Masquerade/Docs/design.md) — the accounts service in detail; [`decisions.md`](Masquerade/Docs/decisions.md) beside it.
- [`Docs/environments-design.md`](Docs/environments-design.md) — the production and development environments on one machine (in progress).
- [`Docs/workflow.md`](Docs/workflow.md) — branches, reviews, specs and tests, sprints, releases.
- [`ROADMAP.md`](ROADMAP.md) — what gets built, in which order.

## How this is built

Elysium is built in the open. I design it and write code myself, alongside AI coding agents that also draft, code and review, inside a process designed to keep quality high:

- **Design reviews before code.** Each significant piece of design goes through a structured review in which agents argue it from separate angles — architecture, security, testing, reliability and performance, data, user experience — over several rounds. Disagreements and open questions come to me; I decide, and the outcome lands in the design documents and decision logs.
- **Specs before code.** Every ticket starts as a written spec: numbered acceptance criteria, each with its edge cases and failure paths named, approved by me before work starts.
- **Test-first.** Failing tests come first and the code makes them pass. As part of the review, the reviewer loosens one rule the change implements and confirms a test fails, which shows the tests pin the rule.
- **One ticket, one branch, one pull request.** Every change is a GitHub issue with its own branch and PR, tracked on a project board. Work is planned in goal-based sprints: a goal, a commitment and a stretch list, started on my go.
- **Independent review.** Every PR is reviewed by an agent other than its author against a written checklist (correctness, security, messaging, contracts, migrations, performance), plus a dedicated security review for anything touching authentication or personal data. I approve and merge.
- **Written rules.** The conventions the agents follow live in the repository: [`CLAUDE.md`](CLAUDE.md), [`Docs/workflow.md`](Docs/workflow.md) and the checklists in [`.claude/skills/`](.claude/skills/).
- **Machine checks.** CI builds and tests every service and frontend and enforces the service boundaries ([`tools/check-boundaries.sh`](tools/check-boundaries.sh)).

## Running it

Today the runnable part is Prince. With Docker and Docker Compose installed:

```bash
docker compose -f Edge/docker-compose.yml up -d --wait
cd Prince
cp .env.example .env
docker compose up -d --wait
```

A one-shot `env-check` refuses invalid `.env` values before the services that need the secrets start; `docker compose logs env-check` names the variable. See [Prince's README](Prince/README.md) for what comes up and where.

Prince is reached through the edge proxy, the only thing that publishes a host port (`127.0.0.1` and `[::1]`, port 80), which the first command above starts before the stack. Open `http://prince.localhost/vue/`.

Next in the Environments plan: separate production and development stacks behind that edge, at `prince.localhost` and `prince.dev.localhost` (and later one hostname per app). The design is in [`Docs/environments-design.md`](Docs/environments-design.md); the edge itself is in [`Edge/`](Edge/README.md).

## Status

Elysium is a portfolio and learning project, not production-ready. There are no support, stability or compatibility commitments, and anything in it may change or break at any time. The [MIT License](LICENSE) provides the software "as is", without warranty.

## License

Elysium is released under the [MIT License](LICENSE).
