# Elysium roadmap

> **Draft.** Phases 0 and 1 are concrete; later phases are an outline from `Docs/platform-design.md`
> ("Next steps") and get their tasks at the planning meeting before each one starts. The PO decides
> scope and order; this file records it.

The design lives in `Docs/platform-design.md`. This file says what gets built, in which order, and
when each phase counts as done. Tick a box when its ticket merges into `main`.

## Milestones (per-service releases)

Each service is released on its own (`Docs/workflow.md`, "Releases"). A GitHub milestone is one
service release; `docker-compose.prod.yml` lists what's in production.

| Milestone | Comes from | What it gives |
|---|---|---|
| Masquerade v0.1 | Phase 2 | Sign up and sign in once (password, Google or passkey), product activation, sign out everywhere on demand |
| Keeper v0.1 | Phase 3 | One entry point for every API, with token and revocation checks |
| Prince v0.1 | Phases 0 and 3 | Prince's existing APIs and frontends, signing in through Masquerade |
| Harpy v0.1 | Phase 4 | Producer balances and withdrawals on a double-entry ledger |
| later | 5+ | Haven (files), Vitae (payments), Tithe (billing), a second product |

## Phase 0: Workflow and foundations

The repo runs on the ticket workflow, and the work already done locally is landed through it.

- [x] Workflow and tooling: `CLAUDE.md`, `Docs/workflow.md`, ticket and review checklists, board scripts, boundary check
- [x] CI: build and test every .NET solution, build and lint every frontend, run the boundary check, skip Markdown-only changes
- [x] Repository settings: squash merges only, branches deleted on merge, `main` protected (changes only through pull requests; required checks once a check runs on every PR, Markdown-only included), labels, the "Elysium" project board, milestones
- [x] Prince infrastructure fixes: frontend healthchecks, proxy redirects keeping the port, Postgres reachable from the host
- [x] Prince frontends restructured onto `/vue`, `/vue/checkout`, `/react`, `/react/checkout`
- [x] File storage on Silo (`pgsty/silo`, pinned release) instead of MinIO, with the bucket created by its bundled client
- [ ] Publish development images: every merge into `main` builds and pushes the changed services to `ghcr.io/rodgallert/elysium-<service>:main`
- [ ] Release automation: `docker-compose.prod.yml` as the list of what's in production; merging a release PR tags `<service>-v<x.y.z>`, publishes the versioned image and creates the GitHub Release
- [x] Platform design document (`Docs/platform-design.md`)
- [ ] README: what Elysium is now, and a "How this is built" section (AI-assisted development, with the architecture, reviews and decisions owned by the author)

**Done when:** a clean clone, `docker compose up` in `Prince/`, and every route answers, file storage included; a ticket PR shows a green CI build, goes through review on the board, and its merge publishes development images.

## Phase 1: Masquerade (accounts) — detailed design

- [x] Data model: accounts, login methods, shared personal data with verification status, product activations, sessions
- [x] Endpoints and flows: OIDC endpoints, sign-up, sign-in per method, password reset, activation, session list, sign-out (one / everywhere / per product)
- [x] Sign-in and activation screens (hosted by Masquerade on `accounts.localhost`)
- [x] Revocation store layout and Keeper's check
- [ ] Moving to the agreed repository layout (`Docs/platform-design.md`, section 17): the root `docker-compose.yml`, hostnames (section 18), and which parts of Prince's code move to which service
- [x] Threat model for the first version, mapped to the OWASP requirements in the design
- [ ] Design tokens and the Elysium palette (dark and light), the component spec, the token generator and its drift check
- [ ] React Material 3 library evaluation (time-boxed)

**Done when:** the PO approves the detailed design; every open question in it is answered or parked with a reason.

## Phase 2: Masquerade v1 (outline)

Email + password, Google, passkeys; account activation per product; email sending for verification
and reset (Herald basics); token issuing with revocation; security notifications; session list.

## Phase 3: Keeper and Prince sign-in (outline)

The YARP gateway with token validation and the revocation check, replacing Prince's nginx; hostnames
per app; Prince's backend-for-frontend signs users in through Masquerade; Prince's frontends use it.
Prince's frontends move to Material 3 (Vuetify 4; the chosen React library), themed from the shared
design tokens, with i18n catalogues and the account preferences (theme, language).

## Phase 4: Harpy (ledger) (outline)

Double-entry ledger with holds and idempotent writes; Prince's producer balance and withdrawals
move onto it; RabbitMQ and Wolverine introduced with the first events.

## Later (outline)

Haven (files), Vitae (payments), Tithe (billing), TOTP as a second factor, the colour-vision mode, a
second product.

**No single point of failure** — no one component may take every product down: Redis with replicas and
automatic failover (writes waiting for a replica), several instances of Keeper and Masquerade, Postgres
high availability, and a test that each component can fail without a full outage.

**Elysium on Kubernetes: zero-trust networking** — a service mesh with automatic mutual TLS between
every service, network policies, service identities on every internal call, and revocation checkable
by any service (`Docs/platform-design.md`, section 20).
