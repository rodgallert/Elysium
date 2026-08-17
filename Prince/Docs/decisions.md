# Prince — Decision log

Chronological record of architectural decisions and why they were made. Add an entry whenever a non-obvious decision is made — the reasoning matters more than the decision itself, since it's what lets a later decision be revisited correctly instead of by guesswork.

## 2026-08-17 — Reverse proxy: nginx

Chosen over YARP and Traefik. YARP would have been the more "native" choice given the rest of the stack is .NET, but nginx is what a real production stack — and anyone reviewing this project — would most expect to see doing this job.

## 2026-08-17 — Jobs dashboard auth: separate Identity store (planned, not yet built)

The Hangfire dashboard is admin-only and will use its own ASP.NET Core Identity store, fully independent from Core's user auth — separate cookie scheme, separate `DbContext`, separate `AspNetUsers` table, no bridge to Core's users. Demonstrates isolated per-service auth rather than one shared identity system doing everything.

Status: not implemented yet. The dashboard currently relies on Hangfire's default local-requests-only filter.

## 2026-08-17 — Single shared Postgres database, not per-service databases

Originally proposed one Postgres container with separate logical databases per service (or even separate containers per service) for stronger service isolation. Overridden: the platform uses **one single shared database**, no per-service schemas either. Core's `Prince.Data` is the single owner of EF Core migrations against it.

Reasoning: this repo models one product with several deployable processes around a shared domain, not truly independent bounded-context microservices — Checkout and Jobs orchestrate against Core's data rather than owning their own. A shared database is the honest reflection of that, and it avoids the complexity of keeping schemas or databases in sync across services that all need the same entities.

## 2026-08-17 — Code-first EF Core only

No hand-written SQL scripts for schema or database creation (e.g. no `init-databases.sql`). EF Core migrations, generated from `Prince.Domain`/`Prince.Data`, are the only mechanism that creates or evolves the schema.

## 2026-08-17 — Checkout and Jobs reference Core's Domain/Data instead of owning their own

Both `Prince.Checkout.Api` and `Prince.Jobs.Api` are single-project services that take a project reference on Core's `Prince.Domain` and `Prince.Data`, rather than each defining their own entities/DbContext. Core is the single source of truth for what the shared database looks like.

This keeps both services intentionally lean — no Domain/Services/Data split for either, since neither owns new domain modeling, they orchestrate against domain Core already owns. Default to this pattern for any future backend service unless its scope genuinely requires modeling new domain concepts Core doesn't have — treat that as a decision to raise explicitly, not something to assume.

## 2026-08-17 — Repo/folder structure: `Prince/Backend/<Service>/`, not `services/`/`clients/` at repo root

An earlier proposal put every service under repo-root `services/` and `clients/` directories (`Elysium/services/core-api`, etc.), moving the .NET solution out from under a `Prince/` folder entirely. Superseded: the top-level project directory stays `Prince/`, and backend services nest under `Prince/Backend/<ServiceName>/` (`Backend/Core`, `Backend/Checkout`, `Backend/Jobs`). Frontend apps will likely follow the same convention under `Prince/Frontend/` once that work starts, but that placement isn't confirmed yet.

## 2026-08-17 — .NET naming keeps the `Prince.*` theme regardless of folder names

Folders are named generically/structurally (`Backend/Core`, `Backend/Checkout`, `Backend/Jobs`), but the actual .NET solutions and namespaces keep the WoD-themed `Prince.*` prefix (`Prince.App`, `Prince.Checkout.Api`, `Prince.Jobs.Api`, etc.) rather than switching to generic names like `CoreApi.*`. Preserves the project's naming identity in the code itself, not just at the folder level.

## 2026-08-17 — Container structure wired up, frontends deferred

Dockerized all three backend services (Core, Checkout, Jobs) plus Postgres and nginx, orchestrated via a root `docker-compose.yml`. Frontends explicitly deferred — Vue apps don't exist yet, so nginx currently only routes to the three APIs, not to any UI.

Key implementation details:
- Checkout and Jobs project-reference Core's `Prince.Domain`/`Prince.Data` via relative paths (`../Core/...`), so their Docker build context is set to `Backend/` (not their own service folder) — otherwise the build can't see the Core projects it needs to restore against. One shared `.dockerignore` lives at `Backend/` for the same reason.
- Added a lightweight `/health` liveness endpoint (`AddHealthChecks()`/`MapHealthChecks("/health")`, no DB dependency) to all three services — not a DB-connectivity check, since Core/Checkout don't touch Postgres for real work yet. Used to gate `docker-compose` startup ordering (`depends_on: condition: service_healthy`) and as the container `HEALTHCHECK`.
- nginx routes: `/api/checkout/` → checkout-api (declared before the broader `/api/` rule so it isn't swallowed), `/api/` → core-api, `/jobs/` → jobs-api's `/hangfire/` (path rewritten, since the app itself mounts the dashboard at `/hangfire`).
- `.env`/`.env.example` added at `Prince/` root for Postgres credentials and the reverse-proxy host port; `.gitignore` added (not yet meaningful since git isn't initialized, but ready for when it is).

**Important finding from testing this end-to-end:** the Hangfire dashboard's default `LocalRequestsOnlyAuthorizationFilter` blocks requests that don't originate from literal loopback — which includes requests from the nginx container. Verified directly: hitting `/hangfire/` from inside the jobs-api container itself returns `200`, but the identical request from the reverse-proxy container (i.e. the path any real user would take through `/jobs`) returns `401`. **This means the previously-deferred separate-Identity-store auth work is no longer just a hardening nice-to-have — it's now the blocker preventing `/jobs` from working at all through the intended path.** Prioritize it before relying on `/jobs` being reachable for anything other than local debugging.

## 2026-08-17 — Jobs admin auth implemented, unblocking `/jobs`

Built the separate ASP.NET Core Identity store that had been deferred: `Prince.Jobs.Api` now has its own `JobsIdentityDbContext` (`IdentityDbContext<IdentityUser>`), its own cookie scheme (`Prince.Jobs.Admin`), a hand-rolled `/admin/login` + `/admin/logout` (plain HTML form + `SignInManager`, no Identity UI/Razor Pages package — kept lean since a full scaffolded UI wasn't needed for one login form), and an admin user seeded at startup from `JobsAdmin:Email`/`JobsAdmin:Password` config (env vars `JOBS_ADMIN_EMAIL`/`JOBS_ADMIN_PASSWORD`, defaulting to `admin@prince.local` / `ChangeMe123!` for local dev — change these before this is ever exposed beyond a dev machine).

Gating mechanism: rather than fighting Hangfire's own `IDashboardAuthorizationFilter` (redirecting manually from inside a filter is fragile — Hangfire's dashboard middleware overwrites the response status code after the filter returns, clobbering a manual redirect), the dashboard's `Authorization` list is set to empty and the endpoint is gated with the standard ASP.NET Core `.RequireAuthorization()` instead, backed by the Identity cookie above. This is the standard, documented-safe pattern and gets automatic redirect-to-login for free from the cookie auth middleware.

**Exception to "only Core owns EF Core migrations":** `JobsIdentityDbContext` has its own migrations (`Backend/Jobs/Prince.Jobs.Api/Identity/Migrations/`), applied via `Database.MigrateAsync()` at startup. This does not violate the single-schema-owner rule in `CLAUDE.md` — that rule is about the shared *domain* data (products, orders, etc.), which only Core models. Jobs' Identity tables are service-local authentication infrastructure that happens to live in the same physical `prince` database (per the single-shared-database decision), tracked by their own independent EF Core migration history. Any future service adding its own service-local infrastructure tables (not domain data) may follow this same pattern.

**Also had to fix nginx**: the reverse proxy only had routes for `/api/`, `/api/checkout/`, and `/jobs/` (→ `/hangfire/`) — nothing routed `/admin/login`/`/admin/logout`, so the login page 404'd through the proxy even though the code was correct. Added a `/admin/` passthrough location (no path rewrite, since the internal route is also `/admin/*`).

## 2026-08-17 — Frontends wired into routing and containers

Wired the two already-scaffolded Vue apps (`Frontend/prince-core`, `Frontend/prince-checkout` — both Vue 3 + Vite + Vuetify + TypeScript) into the reverse proxy and `docker-compose.yml`. Same build+serve-via-nginx pattern as the rest of the stack: multi-stage Dockerfile (`node:22-alpine` build → `nginx:1.27-alpine` static serve with SPA `try_files` fallback), no dev-server container.

**Key detail — `base` path for the checkout app.** Since `prince-checkout` is served under `/checkout` rather than root, Vite's `base` config was set to `/checkout/`. `prince-checkout`'s router already used `createWebHistory(import.meta.env.BASE_URL)`, so it picked up the correct history base automatically — no router code changes needed, just the one Vite config line. Without this, the browser would request assets from `/assets/...` (root-relative) instead of `/checkout/assets/...`, which would hit nginx's `/` catch-all (core-web) instead of checkout-web.

**Routing shape:** the outer reverse-proxy strips the `/checkout/` prefix before forwarding to the checkout-web container (`location /checkout/ { proxy_pass http://checkout_web/; }`, trailing slashes on both), so the container itself is a plain root-relative static server, identical in shape to core-web's. Both the SPA shell and every asset request under `/checkout/*` go through the same location block, so this stripping is consistent for the whole app, not just the initial page load. `core-web` is the `/` catch-all — declared last in `nginx.conf` (nginx's longest-prefix matching already gives more specific locations priority regardless of file order, but keeping the catch-all visually last matches its actual role).

Verified end-to-end: `/` and `/checkout/` both return the correct app shell, checkout's asset paths correctly carry the `/checkout/` prefix, a deep link to a non-existent checkout route falls back to `index.html` (200, not 404) as expected for client-side routing, and none of the existing `/api/*`/`/jobs/*`/`/admin/*` routes were disturbed.

Minor cleanup while in there: `prince-core`'s `package.json` still had the scaffold tool's default name (`vuetify-project`) — renamed to `prince-core` to match `prince-checkout`'s convention. Also added a `.gitignore` to `prince-core` (it was missing one that `prince-checkout` already had).

## 2026-08-17 — First real domain model: how the platform makes money

Replaced `Prince.Domain`'s stub with the platform's actual revenue model, built around two distinct fee types the user described from real Brazilian payment gateway behavior (Pagar.me, Mercado Pago):

- **Withdrawal fee** — charged by the gateway when a producer cashes out their balance (~R$10 flat, per withdrawal request, not per sale). This is a **pass-through cost**: the platform pays the gateway the same amount, so it is *not* company revenue — it just reduces what the producer receives (`Withdrawal.GatewayFee`/`NetAmountPaidOut`).
- **Credit card / installment fee** — when a buyer pays via credit card, the platform's markup on that payment method **is** company revenue (`Sale.PlatformFee`/`ProducerNetAmount`). Modeled as a percentage of the sale, scaling with installment count (1x lower rate, 2-6x mid, 7-12x higher — matches how real Brazilian gateways tier installment pricing), rather than a flat fee, per the user's explicit call.

Domain types added under `Prince.Domain/Payments/`:
- `Money` — value object wrapping a non-negative BRL `decimal`, arithmetic operators, `Percentage()` helper. Negative results throw, which doubles as the "can't withdraw less than the fee" guard.
- `PaymentMethod` — abstract record with nested closed variants (`Pix`, `Boleto`, `DebitCard`, `CreditCard(installments)`), modeling "any other form that would result in additional charges" as an extensible closed set rather than hardcoding only credit cards.
- `CreditCardFeeSchedule` — the rate table/calculator embodying the "card fees are company income" rule. Rates (2.99% / 3.99% / 4.99%) are an **illustrative example schedule, not verified real gateway pricing** — flagged in code comments, swap in real numbers when available.
- `PaymentGateway` (`PagarMe`, `MercadoPago`) + `PaymentGatewayFees` — the withdrawal-fee side, same "illustrative, not verified" caveat on the ~R$10 default.
- `Sale` and `Withdrawal` entities — the two places these rules actually apply, each exposing the fee amount and the resulting net amount so the split between "producer gets" and "company keeps/passes through" is explicit and testable.

**Scope note:** `ProducerId` is a bare `Guid` on both entities — there's no `Producer` or `Product` entity yet. Deliberately out of scope for this pass (the ask was specifically the fee/revenue rules); building out the producer/product/catalog side of the domain is a separate future step.

Added `Prince.Domain.Tests` (Core's first test project, xUnit) with 23 tests directly proving both rules — e.g. a Pix sale has zero platform fee and full producer payout, a 3x credit card sale's platform fee + producer net always sums back to the gross amount, a withdrawal below the gateway fee throws. This is the payoff of Domain having zero infrastructure dependencies (see `CLAUDE.md`): these are pure unit tests, no database or mocking required.

Not touched in this pass: `Prince.Services` (use-cases), `Prince.Data` (persistence/EF Core), `Prince.App` (endpoints). This is domain modeling only — wiring it into the database and an actual API is a natural next step.

## 2026-08-17 — Producer modeled as the aggregate root over the fee model

Added `Producer` (`Prince.Domain/Producers/`), the platform's creator/seller. Guiding business rule from the user: this should be a **quick-to-join, fast-to-start-selling platform** — so `Producer` can list products and receive sales immediately after signing up (just name + email). **Verification (a tax ID / CPF-CNPJ on file) is only required before the first withdrawal**, not before selling — this mirrors reality: Brazilian payment gateways refuse payouts without a registered tax ID, but nothing stops a seller from listing products or accepting sales before that's on file.

`Producer` is the aggregate root for the balance the fee model (`Sale`/`Withdrawal`, added earlier this session) computes splits for: `Producer.RecordSale(...)` credits the balance with `Sale.ProducerNetAmount`, `Producer.RequestWithdrawal(...)` checks verification status and sufficient balance before debiting it and creating a `Withdrawal`. **`Sale` and `Withdrawal` constructors were changed from `public` to `internal`** so they can only be created through these `Producer` methods — otherwise a `Sale` or `Withdrawal` could exist without ever touching a producer's balance, silently corrupting it. Since both types were added this same session with no real callers yet, this cost nothing to tighten now. `Prince.Domain.csproj` got an `<InternalsVisibleTo Include="Prince.Domain.Tests" />` item so the existing fee-math tests (`SaleTests`, `WithdrawalTests`) can keep constructing them directly — they're testing fee arithmetic in isolation, not producer orchestration, so routing them through a verified `Producer` for every case would blur what's actually being tested.

Added `ProducerTests` (9 tests) covering: zero balance/pending verification on creation, blank name/email/tax-ID rejection, selling before verification succeeding, withdrawal before verification throwing, withdrawal exceeding balance throwing, and a verified withdrawal correctly debiting the balance. All 32 `Prince.Domain.Tests` pass; Checkout and Jobs (which reference `Prince.Domain` directly) still build unaffected, since neither had constructed `Sale`/`Withdrawal` yet.

**Deferred, as before:** no `Product` entity yet — `RecordSale` takes a raw `Money` amount and `PaymentMethod`, not a product reference. CPF/CNPJ format validation is not implemented (`TaxId` is just a non-empty string) — real validation is a natural follow-up whenever this is wired to an actual signup flow.

## 2026-08-17 — Domain model types consolidated under `Prince.Domain/Models/`

Moved `Payments/` and `Producers/` (previously loose at the `Prince.Domain` project root) under a new `Models/` folder — `Prince.Domain/Models/Payments/`, `Prince.Domain/Models/Producers/`. Namespaces updated to match (`Prince.Domain.Models.Payments`, `Prince.Domain.Models.Producers`), keeping the folder-mirrors-namespace convention used throughout this project. Gives `Prince.Domain` a single, obvious place for all entities/value objects as more get added, rather than an ever-growing flat list of top-level folders next to the project's own scaffolding files. Earlier decision-log entries above this one still reference the old `Prince.Domain/Payments/`/`Prince.Domain/Producers/` paths — left as historical record of what was true when written, not corrected retroactively.

All 32 `Prince.Domain.Tests` pass unchanged after the move (just `using` updates); Checkout and Jobs, which reference `Prince.Domain` by project file rather than namespace, were unaffected and needed no changes.

## 2026-08-17 — Producer expanded: CPF, password/login, full address

Refined the withdrawal-gating rule from a generic `string TaxId` to a real, validated `Cpf` value object (`Prince.Domain/Models/Producers/Cpf.cs`) — implements the actual Brazilian CPF checksum algorithm (mod-11 over weighted digits, rejecting both malformed input and all-repeated-digit sequences like `111.111.111-11`), not just a length check. `Producer.Verify(string)` was renamed `RegisterCpf(Cpf)` accordingly, to avoid reading as generic/ambiguous "verification" once password-based auth also exists on the same entity.

Also added, per the user's direction — a producer needs to be able to log in, so needs a password and a full address, both now required at signup (unlike CPF, which stays deferred to withdrawal time, preserving the "quick to get into, fast to start selling" rule — password/address are ordinary signup fields, CPF is the one deliberately gated field):
- `PasswordHash` (`PasswordHash.cs`) — salted PBKDF2-HMAC-SHA256, 210,000 iterations (current OWASP recommendation), using only `System.Security.Cryptography` from the BCL — no hashing library dependency, keeping `Prince.Domain` package-free. `Producer.Authenticate(password)` checks a login attempt; `ChangePassword` rotates it. Minimum 8 characters enforced.
- `Address` (`Address.cs`) — Brazilian-format value object (street/number/complement/neighborhood/city/state/CEP), validates the state against the real 27 UF codes and the postal code as 8 digits.

`Producer`'s constructor now requires `(name, email, password, address)` — a real signup needs all four to actually create a working account (someone who can log in and has a registered address), whereas CPF still isn't asked for until `RequestWithdrawal` is attempted without one.

23 new tests (55 total in `Prince.Domain.Tests`) — CPF checksum validity/invalidity/repeated-digit rejection, password hash round-tripping and per-call salt uniqueness (two hashes of the same password never produce the same stored value), address field/state/postal-code validation and value equality, plus updated `ProducerTests` for the new constructor shape and `Authenticate`/`ChangePassword`.

## 2026-08-17 — Address removed from signup, made optional

Corrected the previous entry: `Producer`'s constructor no longer requires `Address`. Signup is just `(name, email, password)` — `Address` is now `Address?`, `null` until `UpdateAddress(...)` is called separately. Kept consistent with the "quick to get into" rule more strictly than the prior pass did: only name/email/password gate account creation; address (like CPF) is deferred, just not yet wired to gate anything specific (unlike CPF, `RequestWithdrawal` doesn't currently check `Address` is set — flag if it should, since real payouts likely need it too).

## 2026-08-17 — Product modeled as its own aggregate, not nested under Producer

Added `Product` (`Prince.Domain/Models/Products/`) — name, short description, image URL, a closed-set `ProductType` (`DigitalDownload`, `ContentPlatformAccess`, `Course`), and a `ProductStatus` (`Active`/`Blocked`/`Deleted`).

**Design call: `Product` references `ProducerId` as a plain identifier, the same way `Sale`/`Withdrawal` do — it is NOT nested inside `Producer`'s aggregate (no `Producer.CreateProduct(...)`, no `Producer.Products` collection), and its constructor is public, not `internal`-locked-to-Producer like `Sale`/`Withdrawal` are.** The reasoning differs from the fee model: `Sale`/`Withdrawal` were locked behind `Producer` because they mutate a balance invariant that must never drift. Creating a product touches no such invariant — there's nothing for `Producer` to protect. Loading a producer also shouldn't force loading every product they've ever listed; that's a query concern for whatever repository/service layer gets built later, not something the aggregate root should own. Products are significant enough (their own status lifecycle, content type, editable details) to be a peer aggregate, not a child collection.

**Status lifecycle:** starts `Active` on creation — no approval queue, consistent with "quick to get into, fast to start selling." `Block()`/`Activate()` toggle freely between `Active`/`Blocked`; `Delete()` is terminal — once `Deleted`, `Block()`/`Activate()` both throw. `Type` is immutable after creation (no `UpdateType`) — changing a product from a `Course` to a `DigitalDownload` post-creation is a different-enough operation that it wasn't modeled as a simple field update; revisit explicitly if that's actually needed. `Name`/`ShortDescription`/`ImageUrl` are editable via `UpdateDetails(...)`, matching the same "mutable profile fields get an update method" pattern used on `Producer`.

Validation: `Name` ≤ 200 chars, `ShortDescription` ("short" per the user) ≤ 500 chars, `ImageUrl` must be an absolute `http`/`https` URL (not just "any absolute URI" — `Uri.TryCreate` with `UriKind.Absolute` alone accepts more than expected, caught by a failing test during this pass; scoping to `http`/`https` schemes specifically is both stricter and more correct for an image URL).

13 new tests (69 total in `Prince.Domain.Tests`).

**Deferred, flagged not silently dropped:** `Sale` doesn't yet reference a `Product` — `RecordSale` still takes a raw `Money` amount, not a product to sell. Wiring `Product` into the actual purchase flow (and deciding whether a `Sale` should require the product be `Active`) is a natural next step once that's the ask.

## 2026-08-17 — File storage: MinIO instead of AWS S3

`ProductType.DigitalDownload` needed to represent an actual uploaded file, not just a marker variant. Added `ProductFile` (`Prince.Domain/Models/Products/ProductFile.cs`) — `StorageKey`, `FileName`, `SizeInBytes` (must be > 0), `ContentType`; `DigitalDownload` now carries one (`DigitalDownload(ProductFile File) : ProductType`). `StorageKey` is deliberately just the object's key/path within storage, not a public URL — Domain shouldn't know how to construct a presigned/download URL, that's an App/Services concern once upload/download endpoints actually exist. 7 new tests (76 total in `Prince.Domain.Tests`).

For where that file actually lives — user explicitly wanted to avoid depending on AWS S3 — added **MinIO** to `docker-compose.yml` as the `file-storage` service: it's S3-API-compatible object storage that runs as a container, so the app can eventually use standard S3 client code pointed at a local endpoint instead of real AWS, without giving up that compatibility if a real S3-compatible provider is ever wanted later.

- `file-storage`: `minio/minio:latest`, ports `9000` (S3 API) and `9001` (web console), persisted via a named volume, healthcheck against MinIO's own `/minio/health/live`.
- `file-storage-init`: a one-shot `minio/mc` (MinIO Client) service that creates the default bucket (`product-files`) and exits — same pattern as the Postgres migrator services (`service_completed_successfully` gate), not a manual script baked into an image.
- `core-api` now depends on `file-storage-init` completing before it starts, anticipating it'll need object storage once uploads are actually built — nothing in the app calls MinIO yet.
- New env vars: `FILE_STORAGE_ROOT_USER`, `FILE_STORAGE_ROOT_PASSWORD`, `FILE_STORAGE_BUCKET`.

Verified end-to-end: `docker compose up --build` brings up `file-storage` healthy, `file-storage-init` exits 0 having created the bucket (confirmed both from its logs and by listing buckets from a separate throwaway `mc` container), and both the S3 API port and the web console respond.

**Deferred:** no actual upload/download code exists yet — `Prince.Services`/`Prince.Data`/`Prince.App` don't reference MinIO at all. Building the actual upload flow (likely an S3-compatible client SDK in `Prince.Data`, an upload endpoint in `Prince.App`) is a separate future step.

## 2026-08-17 — Offer modeled; caught and fixed an atomicity bug in UpdateDetails

Added `Offer` (`Prince.Domain/Models/Products/Offer.cs`) — `Name`, `RealPrice`, `DiscountPrice`, `Description`. One product can have many offers; an offer references a single `ProductId`. Same structural call as `Product` vs `Producer`: `Offer` is a peer entity with a plain `ProductId` reference (public constructor, not nested/locked under `Product`) — there's no invariant on `Product` that offer-creation needs to protect, unlike `Sale`/`Withdrawal`'s balance guard on `Producer`. Business rule enforced: `DiscountPrice` cannot exceed `RealPrice` (equal is fine — represents "no discount currently active"); violating it throws on both construction and `UpdateDetails`.

**User's framing — "this is what will actually link to a sale"**: noted, but not wired in this pass. `Sale` still takes a raw `Money` amount, not a reference to an `Offer`. Flagging this explicitly as deferred, not silently dropped — connecting `Sale` to `Offer` (and deciding whether a sale should snapshot the offer's price at purchase time, since prices can change after) is the natural next step.

**Bug caught while writing `Offer.UpdateDetails`, and found again in the already-shipped `Product.UpdateDetails`**: both methods validated and mutated fields one at a time (`Name = Validate(...); Description = Validate(...); ...`), so if a later field's validation threw, earlier fields were already mutated — an update that's supposed to be all-or-nothing left the entity in a partially-changed state instead. Fixed both to validate every field first, then assign all of them only once every validation has passed. Added a regression test to `ProductTests` for the same fix (`UpdateDetails_WithInvalidImageUrl_ThrowsAndLeavesProductUnchanged`) alongside the new `Offer` coverage. 10 new tests, 86 total in `Prince.Domain.Tests`.

## 2026-08-17 — Sale renamed to Transaction; wired to Offer and Buyer

Renamed `Sale` → `Transaction` throughout (`Prince.Domain/Models/Payments/Transaction.cs`, `Producer.RecordSale` → `Producer.RecordTransaction`). `GrossAmount` renamed `AmountPaid` to match the user's framing.

**Wired the previously-deferred integration:** `Transaction` now carries `OfferId` (a plain `Guid`, same loose-reference pattern as `ProducerId` — not a live navigation to the `Offer` object) and a new `Buyer` value object (`Name`, `Cpf`, `Email`). `Buyer` has no independent identity/account — the platform doesn't maintain buyer accounts, it's just a snapshot of who paid, captured directly on the transaction, consistent with everything else built so far having no speculative accounts system beyond `Producer`.

**Price snapshotting, resolving the question flagged in the "Offer modeled" entry above:** since `Offer.RealPrice`/`DiscountPrice` can change after the fact via `UpdateDetails`, a `Transaction` must not retroactively change if the offer's price changes later. Resolved the same way `RecordSale` already worked before this change: `Producer.RecordTransaction(Guid offerId, Money amountPaid, Buyer buyer, PaymentMethod paymentMethod)` takes `amountPaid` as a plain value the caller supplies (read the offer's current `DiscountPrice` and pass it in) rather than `Transaction` reading it live off an `Offer` reference — this is what actually makes it a snapshot, not a computed/live value.

**`Cpf` relocated** from `Prince.Domain/Models/Producers/` to `Prince.Domain/Models/Shared/` (namespace `Prince.Domain.Models.Shared`), since `Buyer` now needs the same validated-CPF concept `Producer` already had — a general Brazilian tax-ID value object living under `Producers/` specifically would have been an awkward cross-domain dependency (`Payments.Buyer` importing `Producers` just for `Cpf`). Cheap to do now since `Cpf` had exactly one existing dependent.

**Dependency-direction note for future work**: `Transaction` (in `Payments`) intentionally does NOT take a live `Offer` reference (which lives in `Products`) — only its `Guid` Id and a plain snapshotted `Money` amount. Taking a live `Offer` would have created a circular namespace dependency, since `Products` (via `Offer`) already depends on `Payments` (for `Money`). Keep this direction in mind if `Transaction` needs more from `Offer`/`Product` later — pass primitives/snapshots in from the caller (eventually `Prince.Services`) rather than reaching across.

10 changed/new tests (moved `CpfTests` to `tests/.../Shared/`, renamed `SaleTests` → `TransactionTests` with `Buyer`/`OfferId` coverage added, updated `ProducerTests`' `RecordSale` call sites). 87 total in `Prince.Domain.Tests`.

## 2026-08-17 — EF Core wired up: code-first, migrations on every startup

Wired `Prince.Data` and `Prince.App` together, giving the domain model real persistence for the first time. Also wired the four Core projects' project references for the first time (`Prince.Data → Prince.Domain`, `Prince.App → Prince.Data`) — they'd never actually been connected before this.

**`PrinceDbContext`** (`Prince.Data/PrinceDbContext.cs`) maps `Producer`, `Product`, `Offer`, `Transaction`, `Withdrawal` via per-entity `IEntityTypeConfiguration<T>` classes under `Prince.Data/Configurations/`. Value objects are mapped with `ValueConverter`s under `Prince.Data/Conversions/`, not owned-entity ceremony, since most of them wrap a single scalar:
- `Money → numeric(12,2)`, `PasswordHash`/`Cpf → text`, all straightforward single-column converters.
- `PaymentMethod` (a closed record hierarchy, e.g. `CreditCard(Installments)`) → a single encoded string column (`"Pix"`, `"CreditCard:3"`, etc.) rather than fighting EF's limited support for polymorphic owned/complex types.
- `ProductType` (also a closed hierarchy, carrying a nested `ProductFile` for `DigitalDownload`) → a hand-written `JsonConverter<ProductType>` serializing to a `jsonb` column. Deliberately **not** `[JsonDerivedType]` attributes on the Domain type itself — polymorphic-serialization strategy is a persistence concern, kept entirely in `Prince.Data` so Domain stays unannotated.
- `Address` (multi-property, no identity) → a genuine EF `OwnsOne` owned type, columns on the same `producers` table (`address_street`, `address_city`, etc.) — the one case that's actually a multi-column value object rather than a single wrapped scalar.
- Column/table names: added the `EFCore.NamingConventions` package and `.UseSnakeCaseNamingConvention()` rather than hand-specifying every `.HasColumnName()` — cleaner and matches Postgres convention. Kept explicit column names only on the two owned types (`Address`, `Buyer`), where trusting the convention's auto-derived prefix felt riskier than just being explicit.

**A real bug caught and fixed before it could cause silent data corruption**: several constructors (`Product`, `Offer`, `Transaction`, `Withdrawal`, `Producer`) generate `Id = Guid.NewGuid()` internally and don't take `Id` as a parameter. If EF Core had picked one of these constructors for materialization — which it's allowed to, since most of their *other* parameters do match property names — every read from the database would have invoked the real constructor with the *stored* field values but silently generated a **brand-new random Id each time**, corrupting identity on every single query. Added a private parameterless constructor to each of the five entities specifically for EF materialization (with `= null!;` defaults on the handful of non-nullable reference-type properties that constructor doesn't touch, since EF populates them via backing-field reflection immediately after construction). **This was verified empirically, not just reasoned about** — added a temporary round-trip check to `Program.cs` (create a `Producer`, save it, reload it via a fresh `DbContext`, assert the Id and Name survived), ran it against the real containerized Postgres, confirmed `idsMatch=True`, then removed the diagnostic code. Given the stakes (silently wrong data, not a crash), this was worth the extra step rather than trusting memory of EF's constructor-selection rules.

**A second real bug, only visible once actually run against the shared database**: Jobs' `JobsIdentityDbContext` already runs its own migrations against this same `prince` database (see the Jobs-auth entry above). By default, EF Core tracks applied migrations in a single well-known table, `__EFMigrationsHistory` — since both contexts share one physical database, they'd collide on that table. Discovered this the first time `core-api` actually ran migrations against the already-Jobs-migrated database (query failed: naming-convention-driven snake_case column lookup against Jobs' un-converted PascalCase history table). Fixed by giving `PrinceDbContext` its own explicitly-named history table (`__ef_migrations_history_core`) via `MigrationsHistoryTable(...)` — left Jobs' already-working setup untouched rather than risk it. This is the general fix whenever multiple `DbContext`s share one physical database: give each its own migrations history table name, don't rely on the default.

**Migration strategy: inline, not a separate one-shot migrator service.** `Program.cs` calls `db.Database.MigrateAsync()` at startup, before `app.Run()` — same pattern already used for Jobs' Identity migrations, kept consistent rather than introducing a second pattern. Verified idempotent: a second `docker compose up` against an already-migrated database logs "No migrations were applied. The database is already up to date." and starts normally. (The alternative — a dedicated one-shot migrator container gated via `service_completed_successfully`, matching the `file-storage-init` pattern — is more production-realistic for multi-replica deployments, but this project runs single-replica services; revisit if that ever changes.)

Verified end-to-end against the real Postgres container: `\dt` shows all five tables plus the two independent history tables (`__EFMigrationsHistory` for Jobs, `__ef_migrations_history_core` for Core) coexisting correctly; `\d producers` shows the expected snake_case columns including the owned `Address` columns; full `docker compose up --build` brings up all seven containers healthy.

## 2026-08-17 — BaseEntity and IRepository<T> introduced

Added the first pieces of a repository abstraction, per the user's direction:

- **`BaseEntity`** (`Prince.Domain/Models/Shared/BaseEntity.cs`) — `public abstract class BaseEntity { public Guid Id { get; protected set; } }`. `Id` was the only field genuinely duplicated across all five entities, so that's all it holds — not a speculative "audit fields" base class. **Deliberately has no constructor logic of its own** (no `Id = Guid.NewGuid()` in a base constructor): if it did, every derived entity's private EF-materialization constructor would implicitly invoke it too (C# calls the parameterless base constructor implicitly when a derived constructor doesn't specify one), silently regenerating a fresh Id on every read — exactly the bug fixed and verified earlier this session, just relocated to the base class instead of eliminated. Each entity still assigns `Id = Guid.NewGuid()` itself in its own real constructor, unchanged; `BaseEntity` only supplies the shared property declaration.
- **`IRepository<T>`** (`Prince.Domain/Interfaces/Repository/IRepository.cs`) — `where T : BaseEntity`, five methods: `GetAsync(Guid id)`, `ListAsync()`, `AddAsync(T)`, `UpdateAsync(T)`, `DeleteAsync(T)`, all async with an optional `CancellationToken`. This is the base contract only — entity-specific repository interfaces (e.g. an eventual `IProducerRepository`) are explicitly deferred ("later on," per the user), not built in this pass.

`Producer`, `Product`, `Offer`, `Transaction`, and `Withdrawal` all now inherit `BaseEntity` instead of declaring their own `Guid Id { get; }`.

**Verified this didn't silently change anything**: regenerating a migration against the refactored model produced an **empty migration** (confirmed byte-identical `PrinceDbContextModelSnapshot.cs` diff) — proof the mapped column shape is unaffected by moving `Id` to a base class, since EF Core's Fluent API (`builder.HasKey(p => p.Id)`, etc.) resolves inherited properties identically to properties declared directly on the entity. Beyond that, re-ran the same round-trip check used earlier for the original identity-corruption fix — create a `Producer`, save it, reload via a fresh `DbContext`, assert the `Id` survived — against the real containerized Postgres. `idsMatch=True`. Given `Id` moved across a class-hierarchy boundary, this was worth re-verifying empirically rather than assuming the earlier fix still holds.

All 87 `Prince.Domain.Tests` pass unchanged. Checkout and Jobs still build. Noticed (not caused by this change, not fixed here) a pre-existing `MSB3277` NuGet version-conflict warning on Checkout's build between two `Microsoft.EntityFrameworkCore` versions pulled in transitively via `Prince.Data` — Checkout has no direct EF Core package reference of its own to pin a consistent version, unlike `Prince.App`, which already needed (and got) one for the same underlying reason. Doesn't fail the build; flagged as a known pending cleanup alongside the `Microsoft.AspNetCore.OpenApi` advisory.

## 2026-08-17 — Id is database-generated, not client-generated

Fixed the identity-corruption risk at its root rather than only working around it. Previously, every entity generated its own `Id = Guid.NewGuid()` client-side at construction time; the private parameterless EF constructors existed specifically to stop EF Core from re-invoking that generation logic on reads. Per the user's direction, flipped the whole model: **Postgres now generates the Id**, via `gen_random_uuid()` (built into Postgres 13+, no extension needed) as a column default.

- Removed `Id = Guid.NewGuid();` from all five entities' real constructors — nothing in `Prince.Domain` assigns `Id` anymore.
- `PrinceDbContext.OnModelCreating` configures `HasDefaultValueSql("gen_random_uuid()")` on the `Id` property of every `BaseEntity`-derived type, in one loop over `modelBuilder.Model.GetEntityTypes()` — not repeated across all five `IEntityTypeConfiguration<T>` files, and automatically covers any future entity without remembering to add it per-entity.
- New migration (`DatabaseGeneratedIds`) alters all five tables' `id` columns to add the default.

**A newly-constructed, not-yet-persisted entity now has `Id == Guid.Empty` until `SaveChanges` actually runs.** Verified precisely this, empirically, against the real container: logged a `Producer`'s `Id` immediately after construction (`00000000-0000-0000-0000-000000000000`), then again after `SaveChangesAsync()` (a real generated UUID) — and confirmed the generated `INSERT` statement omits the `id` column entirely and uses `RETURNING id` to read the Postgres-generated value back into the tracked entity. Reloading via a fresh `DbContext` matched. This is the correct, verified DB-generation flow, not just a config change taken on faith.

The private parameterless EF constructors (`private Producer() { }`, etc.) are **still needed** — not for the original Id-corruption reason (structurally impossible now, since no constructor touches `Id` at all), but because letting EF invoke the real, validating constructor on every read would re-run each entity's validation logic against already-trusted stored data on every single query, which is wasteful and would make future *stricter* validation rules retroactively break reads of old, previously-valid rows.

## 2026-08-17 — Plan scope: one concrete step at a time, not the whole vision upfront

An early planning pass tried to lay out the entire multi-service/docker/database vision as one big plan before any code was written. Rejected in favor of building one small, concrete piece at a time (move the solution, then scaffold Checkout, then scaffold Jobs, ...), confirming architecture decisions at the point each piece is actually being built rather than pre-deciding everything up front. See the root `CLAUDE.md` for how this should shape future work in this repo.
