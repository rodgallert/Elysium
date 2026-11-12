# Elysium platform design (DRAFT)

> **Status: design draft, nothing built.** Masquerade's detailed design: `Masquerade/Docs/design.md`. Started 2026-11-12. Items are marked **Decided**,
> **Proposed** (recommendation, not yet agreed) or **Open** (needs a call before building).
> Once something is agreed and built, record it in the owning project's decision log.

## 1. Goal

Elysium stops being "a shelf of unrelated projects" and becomes **an ecosystem of microservices,
each named after something in the World of Darkness**. Some services are **shared building
blocks** (accounts, money, files, ...) that any product can use; others are **products** (Prince,
a future property-management app, ...) that combine those blocks with their own domain and UI.

A new product idea should start with identity, balances and file storage already done, so most
of the new work is the product's own domain and frontend.

**Decided (2026-11-12):**
- Elysium becomes a microservice ecosystem; every service gets a World of Darkness name.
- Design first, then build one piece at a time.
- One account across all products, with each product activated on it (section 5).
- Accounts is built on ASP.NET Core Identity + OpenIddict (section 6).
- First login methods: email + password, one social provider, passkeys — each meeting the
  relevant OWASP requirements (section 7).
- Any token can be invalidated at any time, taking effect on the user's next request (section 8).
- Service names as listed in section 4; the same user id in every product; Google as the first
  social provider; password-only accounts allowed in v1 under a documented MFA relaxation;
  10-minute access tokens.
- CQRS and asynchronous messaging across the ecosystem (section 10), with RabbitMQ as the broker
  and Wolverine as the library for both.
- Repository layout with one top-level folder per service and per product (section 17), and one
  hostname per app (section 18).
- Keeper (the gateway) is built on **YARP**, Microsoft's reverse-proxy toolkit: the most used .NET
  gateway, and the revocation check is ordinary ASP.NET Core middleware. Revocation is checked
  **only at Keeper**, so services in other languages get it without a shared library; services are
  reachable only through Keeper.
- Message contracts are **language-neutral** (JSON with a documented schema), so services in other
  frameworks can publish and consume them.
- **Per-service releases** on a trunk-based workflow: every merge into `main` publishes development
  images; `docker-compose.prod.yml` lists the released version of every service (`Docs/workflow.md`).
- The repository is a **public portfolio**, open about being AI-assisted: the README's "How this is built"
  describes the process; design outcomes and decision logs are public, while review transcripts and
  agent profiles stay private.
- Object storage runs on **Silo** (`pgsty/silo`), a maintained MinIO fork: same S3 API, same
  `MINIO_*` settings, bundled `mcli` client. MinIO's own images are no longer published.

## 2. The rule that decides what is shared

> A service is shared only if its concept **means the same thing in every product**.

| Concept | Same meaning everywhere? | Verdict |
|---|---|---|
| Account / identity / personal data | Yes | Shared (**Accounts**) |
| Balance | Yes, if modelled as a **ledger** (money owed, paid, held, withdrawn) | Shared (**Ledger**) |
| Stored file | Yes | Shared (**Files**) |
| Recurring charge | Yes | Shared (**Billing**, later) |
| Product, Offer | No — a course and a property share only id/owner/name | Product-specific |

Shared services are **capabilities that know nothing about the business using them**. Domain
concepts (Product, Offer, Property, Lease) stay inside each product.

## 3. Layers

```
  Browser / mobile
        │
  ┌─────▼──────────────┐
  │ Product frontend   │  Vue / React apps — UI only, no business rules, never holds tokens
  └─────┬──────────────┘
        │ session cookie
  ┌─────▼──────────────┐
  │ Gateway            │  routing, token validation, revocation check, rate limits, tracing
  └─────┬──────────────┘
        │
  ┌─────▼──────────────┐
  │ Product backend    │  one per product ("BFF"): owns the product's domain and rules,
  │ (e.g. Prince)      │  holds the user's tokens, calls shared services
  └─────┬──────────────┘
        │
  ┌─────▼─────────────────────────────────────────────┐
  │ Shared services: Accounts · Ledger · Files · ...   │
  └────────────────────────────────────────────────────┘
```

**Proposed — every product keeps a backend of its own.** Business rules can't live in the
frontend: anything in the browser can be bypassed (prices, fees, access checks). Browser apps
also shouldn't hold tokens; the product backend keeps them and gives the browser an HTTP-only
cookie (OWASP/IETF guidance for browser-based OAuth apps).

## 4. Service catalogue and names

**Decided — names**, each picked so the WoD role matches the job:

| Service | Job | Name | Why |
|---|---|---|---|
| Accounts | identity, login, personal data, sessions | **Masquerade** | the identity Kindred present to the world |
| Gateway | single entry point, checks every request | **Keeper** | the Keeper of Elysium guards the neutral ground and who may enter |
| Ledger | balances, entries, holds | **Harpy** | Harpies keep the record of boons and debts |
| Notifications | email / SMS / push | **Herald** | announces the court's news |
| Files | object storage | **Haven** | where Kindred keep what's theirs |
| Billing | recurring charges | **Tithe** | the recurring payment owed to the Prince |
| Payments | real payment providers | **Vitae** | the currency everything runs on |
| Product: payments & content | (existing) | **Prince** | — |

Build order: Accounts first (with the email sending it needs from Notifications), then Gateway,
then Ledger. Files / Payments / Billing when a product needs them.

## 5. One account across products — **Decided**

A person has **one Elysium account**, and each product is **activated** on it. Data already on the
account is reused; activation only asks for what's missing.

### 5.1 What lives where

| Data | Owner |
|---|---|
| Login methods, sessions, security settings | Accounts |
| Shared personal data: name, email, phone, birth date, CPF, addresses — each with a verification status | Accounts |
| Which products the account has activated, and what each was allowed to see | Accounts |
| Product-specific data (producer profile, store name, a landlord's portfolio) | That product |

### 5.2 Activation flow

1. Each product is registered in Accounts as an OIDC client and declares the **profile fields it
   requires** (Prince sellers: CPF for withdrawals; a property app: phone and address).
2. The first time a signed-in person opens a product, Accounts shows an **activation screen**:
   which data the product will receive, plus a form for **only the required fields still missing**.
3. Accounts records the activation (account, product, date, data the product may see) and the
   product receives tokens.
4. Next time, sign-in is seamless (single sign-on): one Accounts session covers every activated
   product.

### 5.3 Rules

- **Products get only what they were allowed to see** (scopes/claims chosen at activation) —
  the data-minimisation principle LGPD expects. CPF is not handed to a product that didn't need it.
- **Products read current data from Accounts** instead of keeping their own copy, so an address
  changed once is changed everywhere. A short cache is fine.
- **Deactivating a product** removes its access and invalidates its sessions (section 8)
  without touching the account or other products.
- **"Verified" means verified:** a CPF passing the checksum is *valid*, not *verified*. Products
  that need real verification (e.g. withdrawals) check the verification status, not just presence.
- **Decided — the same user id in every product.** All products are first-party, so a
  per-product id would add complexity without protecting anyone.

## 6. Accounts — protocol and implementation — **Decided**

Accounts is an **OpenID Connect identity provider** built on **ASP.NET Core Identity**
(users, passwords, passkeys, social logins) + **OpenIddict** (the OAuth 2.1/OIDC protocol).
Products never see passwords; they redirect to Accounts and receive standard tokens.

| Consumer | Flow |
|---|---|
| Product backend for a browser app | Authorization code + PKCE |
| Service calling another service | Client credentials |
| Any "plain JWT" consumer | Either of the above — the result is always a JWT access token |

Accounts hosts the **login and activation UI itself**, so every product gets every login method
for free, and passkeys are bound to a single domain (theirs) instead of each product's domain.

**Accounts answers "who is this?"; each product answers "what may they do?".** Roles like
producer, buyer, landlord and tenant live in the product backend.

## 7. Login methods and OWASP compliance

**Proposed — target OWASP ASVS 5.0 Level 2** for Accounts, which is the level OWASP recommends
for applications handling personal or financial data. Requirement numbers below are ASVS 5.0.

### 7.1 Email + password

| Requirement | Rule we follow |
|---|---|
| Length (6.2.1, 6.2.9) | Minimum 8, recommend 15+; accept at least 64 characters |
| No composition rules (6.2.5) | No "must contain a symbol" — length and blocklists instead |
| Blocklists (6.2.4, 6.2.11, 6.2.12) | Reject the most common passwords, context words (e.g. "elysium", the user's name/email), and known breached passwords (Have I Been Pwned k-anonymity check — only a hash prefix leaves the server) |
| No forced rotation (6.2.10) | Passwords change only when the user wants or a breach is detected |
| Password managers (6.2.7) | Paste and autofill allowed |
| Exact comparison (6.2.8) | No truncation or case folding |
| Change requires current password (6.2.3) | Yes |
| Storage (OWASP Password Storage Cheat Sheet) | **Argon2id, 19 MiB memory, 2 iterations, parallelism 1.** Identity's default (PBKDF2-SHA512, 100k iterations) is below OWASP's 220k minimum, so we plug in our own hasher; existing hashes are upgraded on next login |
| No hints / secret questions (6.4.2) | None |
| Password reset (6.4.1, 6.4.3) | Emailed single-use link, short expiry, doesn't bypass a second factor; same response whether or not the email exists; after reset, offer to sign out everywhere (7.4.3) |

### 7.2 Social login (first provider: **Google** — decided)

| Requirement | Rule we follow |
|---|---|
| Flow | Authorization code + PKCE, `state` and `nonce` checked, exact redirect URI match |
| Signatures (6.8.2) | ID token signature, issuer, audience and expiry always validated |
| Identity spoofing (6.8.1) | A social identity is keyed by **(provider, provider's user id)**, never by email |
| Account linking | If a social login's email matches an existing account, **the person must sign in with an existing method before linking** — even if the provider says the email is verified. Prevents takeover through a provider with weak email checks |
| Strength (6.8.4) | Products needing strong authentication check the `amr`/`acr` claims Accounts issues |

### 7.3 Passkeys (WebAuthn)

| Requirement | Rule we follow |
|---|---|
| Implementation | ASP.NET Core Identity's built-in passkey support (.NET 10) |
| Checks | Single-use challenge, origin and relying-party id verified, signature verified |
| User verification | Required (PIN/biometric on the device), which makes a passkey alone multi-factor and phishing-resistant |
| Several passkeys | Allowed; each can be named and **revoked** (6.5.6) |
| Recovery | Losing every passkey needs recovery at the same strength as enrollment (6.4.4) |

### 7.4 Rules for every method

| Requirement | Rule we follow |
|---|---|
| Brute force / credential stuffing (6.3.1) | Rate limits per account and per IP, progressive delays; lockout is temporary so attackers can't lock people out deliberately |
| No user enumeration (6.3.8, L3 but cheap) | Same message, status code and timing whether or not an account exists — login, sign-up and reset |
| Default accounts (6.3.2) | No seeded admin outside development |
| Same strength on every path (6.3.4) | No hidden or legacy login endpoints |
| Security notifications (6.3.7, L3 but cheap) | Email on password change, new login method, new passkey |
| Session ids (7.2.4) | New session on every sign-in |
| Cookies | `__Host-` prefix, `Secure`, `HttpOnly`, `SameSite`, CSRF protection on form posts |
| Session list (7.5.2) | Users see their active sessions and can end any or all of them |
| Admin control (7.4.5) | Admins can end one user's sessions or everyone's |
| Audit log | Every sign-in, failure, factor change and session termination recorded |

### 7.5 Multi-factor authentication — **Decided: documented relaxation for v1**

ASVS 6.3.3 (Level 2) expects either multi-factor authentication or a documented reason for
relaxing it. Passkeys already satisfy it; **password-only accounts don't.** Options:
1. Add TOTP (authenticator app) as a second factor in the first version.
2. Ship password-only for the first version with this section as the documented relaxation, and
   strongly prompt password users to add a passkey.

**Decided: option 2.** This section is the documented relaxation ASVS 6.3.3 asks for: v1 allows
password-only accounts, mitigated by the breached-password check, rate limiting, security
notifications and prompts to add a passkey. TOTP is the next authentication feature after v1.

## 8. Immediate token invalidation — **Decided requirement, Proposed design**

**Requirement:** any token can be invalidated at any moment, and the user is signed out on their
**next request** — not when the token happens to expire. (ASVS 7.4.1 explicitly calls out that
self-contained tokens need extra measures for this.)

**The problem:** a JWT is checked by its signature alone, so a valid token keeps working until
it expires. Revocation needs some state that's checked on every request.

### 8.1 Design

- **Every access token carries** `jti` (token id), `sid` (session id), `sub` (account),
  `client_id` (product) and `iat` (issued at). Lifetime: **10 minutes** (decided) to keep the
  revocation data small.
- **Revocation store** (Redis), written by Accounts, read on every request. Three kinds of entry:

  | Entry | Revokes | Used for |
  |---|---|---|
  | `session:{sid}` | one sign-in session (one device/browser) | sign out, "end this session" |
  | `account:{sub}` → cutoff time | every token issued before the cutoff | sign out everywhere, password reset, account disabled or deleted (7.4.2) |
  | `activation:{sub}:{client_id}` → cutoff time | every token for one product | product deactivated |

  Each entry expires automatically after the maximum token lifetime — by then any token it
  revokes would have expired anyway — so the store never grows unbounded.
- **Accounts writes the entry before replying** to the logout/reset/disable request, so it's in
  effect from the next request onward. Refresh tokens for the same session are revoked at the
  same time, so no new access tokens can be minted.
- **The gateway checks every request:** signature, issuer, audience, expiry, then the revocation
  store. A revoked token gets `401`.
- **Services only accept traffic from the gateway** (network isolation), and still validate
  signature and audience themselves. The revocation check lives **only in the gateway**, so a
  service in another language needs no shared library; service-to-service calls that carry a
  user's token go through the gateway too.
- **If the revocation store is unreachable, requests are rejected** (fail closed). For
  authentication, a short outage is better than accepting revoked tokens.

### 8.2 What the user sees

The browser holds only a session cookie with the product backend. When a request comes back
`401`, the product backend ends that cookie session and sends the user to sign in. Accounts also
notifies product backends directly (OIDC back-channel logout) so they drop server-side sessions
even if the user isn't currently making requests.

### 8.3 Alternative considered

**Token introspection** (opaque tokens; every request asks Accounts whether the token is still
valid; OpenIddict supports it). Also immediate, but puts Accounts on the path of every request in
every product. The revocation store gives the same guarantee with a single fast lookup.

## 9. Rules for every shared service

1. **Serves many products at once.** Each record belongs to one product, determined from the
   caller's token, never from the request body.
2. **Opaque references.** Shared services store ids they don't interpret.
3. **Owns its data.** One database per service. **Proposed:** all on the same Postgres server to
   keep `docker compose up` light. No service reads another's tables.
4. **APIs and events.** HTTP for immediate answers; messages through the broker otherwise
   (section 10).
5. **Versioned API** (`/v1/...`).

## 10. CQRS and messaging — **Decided**

### 10.1 CQRS — how far to take it

CQRS means **writes (commands) and reads (queries) go through separate paths**. It comes in
degrees, and each service takes only the degree it needs:

| Level | What it means | Where |
|---|---|---|
| 1. Separate handlers | Every operation is a command handler or a query handler; queries never change state, commands return only what the caller needs. Same database. | **Every service** (convention) |
| 2. Separate read models | Commands write the normalised model; events update read-optimised tables (balances, statements, catalog listings). Reads may lag writes by a moment. | Where reads look very different from writes: **Ledger** (balances, statements), **Prince catalog** (browsing, search) |
| 3. Event sourcing | The event history *is* the source of truth; current state is rebuilt from it. | **Not by default.** Ledger entries are already append-only and auditable without it. Revisit per service if a real need appears. |

**Living with lag (level 2):** a command returns the data the UI needs to show the result
(e.g. the new balance) instead of the UI immediately re-reading a read model that may not have
caught up yet.

### 10.2 Messages

| Kind | Meaning | Recipients | Example |
|---|---|---|---|
| **Command** | "please do this" | exactly one service | `SendEmail` → Herald |
| **Event** | "this happened" (past tense) | any number of subscribers | `PaymentConfirmed` → Ledger credits the producer, Prince grants access, Herald sends a receipt |

- **Contracts:** each service publishes the message types it owns, as JSON with a documented schema
  (not shared .NET types), so services in other frameworks can take part. Changes are additive only (new
  optional fields); a breaking change is a new message version, with the old one kept until no
  consumer uses it.
- **Publishing — outbox:** the message is saved in the same database transaction as the state
  change and sent afterwards, so "saved but never announced" and "announced but never saved"
  can't happen.
- **Consuming — idempotent:** every message has an id; consumers record processed ids (inbox) and
  skip duplicates, since brokers deliver *at least once*.
- **Failures:** retries with increasing delays, then a dead-letter queue for inspection — a bad
  message never blocks the ones behind it.
- **Order isn't guaranteed** with several consumers; handlers tolerate out-of-order arrival
  (e.g. compare a version number before applying an update).
- **Tracing:** a correlation id travels from the original HTTP request through every message it
  causes (OpenTelemetry), so one purchase can be followed across all services.
- **Not everything goes through the broker.** Token revocation (section 8) is written straight to
  Redis because it must apply on the very next request; a queue could delay it.

### 10.3 RabbitMQ vs Kafka

| | RabbitMQ | Kafka |
|---|---|---|
| Model | Message broker: routes messages to queues, removes them once handled | Distributed log: keeps every message for a retention period; consumers track their own position |
| Commands / work queues (send this email) | Native: per-message acknowledgement, retries, dead-lettering, delayed delivery | Historically awkward; "share groups" (queue semantics) only reached production readiness in Kafka 4.2 |
| Events to many subscribers | Native (exchanges and routing keys) | Native (consumer groups) |
| Replaying old messages | No — once handled, gone | Yes — the main reason to choose Kafka |
| Ordering | Per queue, lost with several consumers | Per partition |
| Throughput | Tens of thousands of messages/s — far beyond this ecosystem's needs | Millions/s |
| Running it in `docker compose` | One light container, management UI included | Heavier (JVM, more memory); single node in KRaft mode is fine for dev |
| Where it fits best | Integration between microservices, task queues | Event streaming, analytics pipelines, event sourcing, very high volume |

### 10.4 Broker — **Decided: RabbitMQ**

Almost all of this ecosystem's messaging is **commands and integration events** that need
retries, dead-lettering and routing — RabbitMQ's home ground. Kafka's distinctive strength,
**replaying history**, would matter mainly with event sourcing (not planned, 10.1) or analytics
streaming. Rebuilding a read model can be done from the owning service's own database instead.

Choosing Kafka would be the right call if the portfolio goal shifts towards event streaming —
and the library choice below supports both, so switching later changes configuration, not
handler code.

### 10.5 .NET libraries — **Decided: Wolverine**

Several popular libraries changed licence in 2025, which affects the choice:

| Library | Status | Fit |
|---|---|---|
| **Wolverine** (JasperFx) | MIT licence | In-process command/query handlers **and** messaging with built-in outbox/inbox, retries, dead-lettering; RabbitMQ and Kafka transports. One library covers 10.1 and 10.2. |
| MassTransit | v9 is commercial; v8 stays open source but is only maintained through 2026 | Excellent, but building on an end-of-life version or paying for a licence |
| MediatR | v13+ under RPL-1.5 or a commercial licence (free community tier with registration) | In-process only — would still need a separate messaging library |
| Plain handler interfaces + raw `RabbitMQ.Client` | Free | Full control, but the outbox, retries and dead-lettering must all be built by hand |

**Wolverine** for both CQRS handling and messaging. Before relying on its Kafka transport
(if ever), confirm that package's licence too.

## 11. Ledger (sketch)

- **Double-entry:** every movement is a transaction of entries summing to zero, so balances are
  always re-derivable and auditable.
- **Ledger accounts, not users:** a product creates "producer 123 — available", "platform fees",
  "tenant 456 — rent owed"; the ledger only sees ids and labels.
- **Holds** for money reserved but not final (withdrawal requests, refund windows).
- **Idempotency keys** on every write, so retries never move money twice.
- **Integer minor units + currency** (centavos), never floating point.

## 12. Prince on the new model

| Today (Prince Core) | Moves to |
|---|---|
| Sign up / sign in (planned) | Accounts |
| `Producer` name/email/password | Accounts (shared personal data) |
| Producer CPF | Accounts (verification status checked by Prince before withdrawals; nothing verifies CPF in Masquerade v1, so withdrawals stay blocked until it does) |
| Producer profile | Prince backend |
| Producer balance, `Withdrawal` | Ledger (Prince keeps the withdrawal rules) |
| Fee schedules | Prince backend, recorded as Ledger entries |
| `Product`, `Offer`, `Transaction`, `Buyer` | Prince backend (`Buyer` personal data from Accounts once buyers have accounts) |
| `ProductFile` | Files (Prince keeps the reference) |
| Jobs admin login (own Identity store) | Accounts, eventually |

## 13. Paper test — property management

| Need | Covered by |
|---|---|
| Landlords and tenants sign in; same account as Prince | Accounts ✓ (activation asks only for missing data) |
| Rent owed and paid, landlord payouts | Ledger ✓ |
| Lease documents, photos | Files ✓ |
| Monthly rent charge | Billing — not built yet |
| Properties, units, leases | Property app's own backend |

## 14. What this overturns

- **Root `README.md`:** "no shared tooling, no shared dependencies" — replaced by the ecosystem
  model. README to be rewritten once the first shared service exists.
- **Prince's `CLAUDE.md` / `architecture.md`:** one shared database for everything, Core owns the
  whole domain, new services reference Core's projects.
- **Repository layout:** services become top-level folders in Elysium; Prince becomes one of them.

## 15. Open decisions

| # | Question | Leaning |
|---|---|---|
| — | None at the moment | |

## 16. Next steps

The phases and their tasks are in `ROADMAP.md`; this is the short version.

1. Detailed design of Accounts: data model, endpoints, activation screens, revocation store.
2. Build Accounts, plus the email sending it needs.
3. Gateway with the revocation check.
4. Prince's backend signs in through Accounts.
5. Ledger.

## 17. Repository layout — **Decided**

```
Elysium/
├── docker-compose.yml        # the whole ecosystem
├── Keeper/                   # gateway (replaces Prince's nginx)
├── Masquerade/               # accounts: own solution, Dockerfile, CLAUDE.md, CHANGELOG
├── Harpy/                    # ledger (later)
├── Prince/
│   ├── Backend/              # Prince's own domain + its backend-for-frontend
│   └── Frontend/             # the Vue and React apps
└── Docs/ · tools/ · ROADMAP.md
```

Each service folder is self-contained (solution, Dockerfile, `CLAUDE.md`, `CHANGELOG.md`). Prince's
sign-in, personal-data and balance code moves out to Masquerade and Harpy as those are built.

## 18. Hostnames — **Decided**

Each app gets its own hostname instead of a path prefix. Browsers resolve any `*.localhost` name to
the local machine without setup.

| Hostname | Serves |
|---|---|
| `accounts.localhost` | Masquerade's sign-in, sign-up and activation screens |
| `prince.localhost` | Prince's frontends (`/vue`, `/react`, each with `/checkout`) |
| `api.localhost` | Keeper, in front of every API |

Closer to production, and passkeys are bound to one domain (`accounts.localhost`), so they work for
every product. `/` on each hostname is that app's home page.

## 19. Shared look and internationalisation — **Decided**

Every Elysium UI — Masquerade's pages and every product's frontends, whatever the stack — looks and
feels the same, and is built for several languages from the start.

### 19.1 One look
- **Material 3 wherever possible**, as the design language (a specification, not one library).
- **One design-token source** (W3C design-tokens JSON, versioned, with a changelog) holds colour
  roles, type scale, shape, spacing, elevation and motion, for every theme. A generator produces a
  theme per stack — CSS variables for server-rendered pages, a Vuetify theme for Vue, a theme for the
  React library — and the outputs are committed; CI fails when a committed output differs from a
  fresh generation. It's shared **data**, not code, so it doesn't break "services share no code".
- **A library per stack:** Vuetify 4 (Material 3) for Vue — Prince moves from Vuetify 3; for React,
  a Material 3 library chosen after a short evaluation (MUI hasn't shipped Material 3; it stays the
  fallback, being MIT-licensed); plain CSS from the tokens for Masquerade (`Masquerade/Docs/design.md`,
  section 9).
- **As close as possible:** inputs, text sizes, spacing and behaviour must feel the same across
  stacks. Checked by a sample page per stack showing every component in every state (same test ids
  everywhere), token values read from the rendered pages, screenshot comparisons with a tight
  tolerance (the PO signs off the baselines), and accessibility scans in CI.
- **Themes:** dark and light both ship. A **colour-vision mode** (colour-blind-safe
  palette) comes later, as an account preference.
- **Palette (approved):** World of Darkness — dark blues, blood reds and purples — with every pair
  used for text or control edges meeting WCAG 2.2 AA in both themes. Errors use an amber-coral role,
  clearly distinct from the brand red, and always carry an icon and text.

  | Role | Dark | Light |
  |---|---|---|
  | background | `#0D1020` | `#F7F6FB` |
  | surface container / high | `#161A2E` / `#1F2440` | `#FFFFFF` / `#ECEAF4` |
  | on-surface / variant | `#E6E7F2` / `#B4B8D0` | `#17192B` / `#4A4E6B` |
  | outline / outline-variant (decorative only) | `#8A8FB0` / `#454A6B` | `#6F7394` / `#C5C8DA` |
  | primary — blood red / on | `#CC3340` / `#FFFFFF` | `#9B1B28` / `#FFFFFF` |
  | primary container / on | `#5C0F18` / `#FFD9DB` | `#FFD9DB` / `#4A0A12` |
  | link | `#FF8F99` | `#9B1B28` |
  | secondary — violet / on | `#B8A4F5` / `#2A1B5E` | `#5B3FB5` / `#FFFFFF` |
  | tertiary — blue / on | `#8FA8FF` / `#0F1F5C` | `#2F4FB0` / `#FFFFFF` |
  | error — amber-coral / on | `#FFB38A` / `#4A1800` | `#B3380A` / `#FFFFFF` |
  | error container / on | `#6B2A0A` / `#FFDBC8` | `#FFDBC8` / `#3A1100` |

- **Typography:** Cinzel for titles, Inter for body text, bundled with each frontend.
- **First visit follows the device's light/dark setting** (dark if none); the account preference wins
  after sign-in.

### 19.2 Internationalisation (all projects)
- Every user-facing string lives in a message catalogue per language; no text in code or templates.
  pt-BR first, English next; adding a language means adding a catalogue, nothing else.
- Dates, numbers and currency are formatted by locale; amounts stay integers in minor units plus a
  currency (`Money`), formatted only at display time. Documents like CPF keep their own formats.
- Emails are rendered in the person's language.
- Layouts tolerate longer text (no fixed-width buttons sized for one language).

### 19.3 Preferences that follow the person
Theme, language and colour-vision mode are account preferences stored in Masquerade, edited in its
account manager, and applied by every product, so a change made once shows everywhere.

## 20. Zero-trust direction — **Decided as a direction; adopted step by step**

Elysium is heading towards **zero trust**: nothing is trusted because of where it sits on the
network; every request — including calls between our own services — is authenticated and
authorised, with least privilege, as if an attacker were already inside.

**Already true by design:** every request through Keeper is checked (signature, audience, expiry,
revocation); short-lived tokens with reuse detection; per-device sessions and step-up; per-service
credentials for databases, Redis and the broker; encrypted personal data; append-only audit.

**Where v1 still trusts the network (accepted risks):**
- Services rely on being reachable only through Keeper (a perimeter).
- Calls between services aren't authenticated per service or encrypted in local development.
- Revocation is checked only at Keeper; services trust that traffic came through it.

**Adopted now (2026-11-12):**
- **Segmented networks:** frontends, Keeper, services and data stores each on their own Docker
  network, joined only where needed — a frontend can't reach a database.
- **Every service validates tokens itself** (signature, audience, expiry), never relying on Keeper
  having checked.
- **No network-location trust in code:** no "internal" route skips authentication, no IP address
  counts as identity; everything is written as production code, as if behind a VPN that's already
  been breached.
- **TLS between every service in production** (databases, Redis and the broker included), with
  services able to present client certificates later.
- **Revocation as a language-neutral contract** (Masquerade's contract file), so any service can
  check it itself later.
- **Service identities on internal calls** (short-lived client-credential tokens from Masquerade,
  checked by the callee) arrive with the **first service-to-service call**, likely Harpy.

**Later phase — "Elysium on Kubernetes: zero-trust networking":** a service mesh with automatic
mutual TLS between every service, network policies (segmentation), service identities on every
internal call, and revocation checkable by any service, not only Keeper.
