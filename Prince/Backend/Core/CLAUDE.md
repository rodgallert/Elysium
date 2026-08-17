# Prince.Core — AI guidelines

Core is the platform's source of truth: producer/product/offers management, sign up/sign in, content access, and the domain data every other service reads or writes through. It's the only service with full clean-architecture layering — see repo-root `CLAUDE.md` for why other services stay lean instead of mirroring this.

## Project structure and dependency direction

```
Prince.App        (ASP.NET Core Web API — composition root)
   │
   ├──▶ Prince.Services   (use-cases / application logic)
   │        │
   │        ▼
   └──▶ Prince.Data ──────▶ Prince.Domain   (entities, value objects, repository interfaces)
```

- **`Prince.Domain`** — zero dependencies on anything else in the solution, and no infrastructure package references (no EF Core, no ASP.NET). Pure entities, value objects, domain logic/invariants, and the interfaces (`IProductRepository`, etc.) that `Prince.Data` implements. This is what keeps it trivially unit-testable.
- **`Prince.Services`** — references `Prince.Domain` only. Application/use-case logic, DTOs, orchestration. Must never reference `Prince.Data` or take an EF Core dependency directly — it depends on `Domain`'s interfaces, not on how persistence is actually implemented. This is what makes it testable without a real database.
- **`Prince.Data`** — references `Prince.Domain`. Owns the EF Core `DbContext`, all migrations, and the concrete repository implementations. **This is the only project in the entire platform that should add EF Core migrations** — Checkout and Jobs reference this project directly rather than owning their own persistence.
- **`Prince.App`** — references both `Prince.Services` and `Prince.Data`. Composition root: DI wiring, controllers/endpoints, auth, config. Nothing else should reference `Prince.App`.

## Data

Single shared Postgres database (`prince`), code-first EF Core, connection string key `ConnectionStrings:Prince`. See repo-root `CLAUDE.md` for the full rationale.

## Current state (2026-08-17)

All domain model types live under `Prince.Domain/Models/` (folder mirrors namespace, e.g. `Models/Payments/Money.cs` → `Prince.Domain.Models.Payments`) — put new entities/value objects there, not loose in the project root.

`Prince.Domain/Models/Payments/` has real business logic — the platform's revenue model (`Money`, `PaymentMethod`, `Transaction`, `Buyer`, `Withdrawal`, `CreditCardFeeSchedule`, `PaymentGatewayFees`). See `Docs/decisions.md` (2026-08-17, "First real domain model") for the two fee rules this encodes — the illustrative fee rates in `CreditCardFeeSchedule`/`PaymentGatewayFees` are explicitly flagged as example numbers, not verified real gateway pricing; swap them when real figures are available. `Transaction` (renamed from `Sale`) carries `OfferId` (plain `Guid`, not a live `Offer` reference — see the dependency-direction note in `Docs/decisions.md`, "Sale renamed to Transaction") and a `Buyer` (`Name`/`Cpf`/`Email`, no account of its own — captured per-transaction, not a persistent buyer identity). `AmountPaid` is a snapshot the caller supplies (e.g. the offer's current `DiscountPrice`), not something `Transaction` reads live — offer prices can change after the fact and a completed transaction must not follow.

`Prince.Domain/Models/Shared/Cpf.cs` — moved here from `Producers/` since `Buyer` needs the same validated-CPF concept `Producer` does; it's a general value object, not producer-specific. `tests/.../Shared/CpfTests.cs` moved to match.

`Prince.Domain/Models/Producers/Producer.cs` is the aggregate root over that balance — sell immediately, a registered `Cpf` (real checksum-validated, not just a string) is only required before withdrawing (see `Docs/decisions.md`, "Producer modeled as the aggregate root" and "Producer expanded"). Signup requires only name, email, and password — `Address` is `Address?`, optional, set later via `UpdateAddress` (not required at signup, and not currently checked by `RequestWithdrawal` either — only `Cpf` gates withdrawal right now). `PasswordHash` is salted PBKDF2 (BCL-only, no package dependency); `Producer.Authenticate`/`ChangePassword` are the login/rotation entry points. **`Transaction` and `Withdrawal` constructors are `internal`** — only `Producer.RecordTransaction`/`RequestWithdrawal` can create them, so the balance can't drift out of sync. If you add a new way to create a `Transaction`/`Withdrawal`, it needs to go through `Producer`, not a new public constructor. `Prince.Domain.Tests` is granted `InternalsVisibleTo` for the handful of tests that exercise `Transaction`/`Withdrawal` fee math directly, in isolation from producer orchestration.

`Prince.Domain/Models/Products/Product.cs` — name/short description/image/type/status. Deliberately a **peer aggregate, not nested under `Producer`** (public constructor, plain `ProducerId` reference, no `Producer.Products` collection) — unlike `Transaction`/`Withdrawal`, creating a product touches no balance invariant for `Producer` to protect. `Status` starts `Active`; `Delete()` is terminal (`Block()`/`Activate()` both throw afterward). `Type` is immutable after creation. See `Docs/decisions.md` ("Product modeled as its own aggregate") for the full reasoning, including why the image URL check is scoped to `http`/`https` specifically rather than "any absolute URI."

`ProductType.DigitalDownload(ProductFile File)` — `ProductFile` is a validated storage key/filename/size/content-type, deliberately not a public URL (Domain shouldn't construct download URLs). The actual bytes live in MinIO (`file-storage` service, see repo-root `CLAUDE.md`) — nothing in this project talks to it yet.

`Offer` (`Models/Products/Offer.cs`) — name/real price/discount price/description, a peer entity referencing `ProductId` (same reasoning as `Product` vs `Producer`: no invariant to protect, so no aggregate nesting). `DiscountPrice` cannot exceed `RealPrice` (equal is valid). **When adding a multi-field update method (`UpdateDetails` style) on any entity, validate every field first and assign only after all validations pass** — `Product.UpdateDetails` and the first draft of `Offer.UpdateDetails` both had a bug where a later field's failed validation left earlier fields already mutated, breaking the "update is atomic" expectation. Caught and fixed 2026-08-17; don't reintroduce it on new entities.

87 tests total in `Prince.Domain.Tests` (xUnit). `Transaction` still doesn't reference `Product` directly (only `Offer`, which references `Product`) — whether a transaction should require `Product.Status == Active` is deferred.

**EF Core is wired up** (`Prince.Data`/`Prince.App`, project references connected for the first time this pass). `PrinceDbContext` (`Prince.Data/PrinceDbContext.cs`) maps all five entities via `Prince.Data/Configurations/*Configuration.cs` (one `IEntityTypeConfiguration<T>` per entity) and `Prince.Data/Conversions/*ValueConverter.cs` (one converter per value object — `Money`, `Cpf`, `PasswordHash`, `PaymentMethod` all single-column; `ProductType` is a hand-written `JsonConverter` → `jsonb`, kept in `Prince.Data` rather than `[JsonDerivedType]` attributes on the Domain type, since serialization strategy is a persistence concern; `Address` is the one genuine multi-column case, mapped via `OwnsOne`). Snake_case columns/tables via `EFCore.NamingConventions` (`.UseSnakeCaseNamingConvention()` in `Program.cs`) rather than hand-specifying every `.HasColumnName()`.

**Two things to know before touching this again:**
1. **Every entity needs a private parameterless constructor for EF materialization** (`Producer`, `Product`, `Offer`, `Transaction`, `Withdrawal` all have one, with `= null!;` defaults on non-nullable reference-type properties the constructor doesn't touch). Reason: their real constructors call `Id = Guid.NewGuid()` internally and don't take `Id` as a parameter — if EF picked one of those for materialization instead (which it's allowed to, since the *other* parameters do match property names), every read would silently generate a fresh random Id, corrupting identity. Verified empirically against the real container that EF actually uses the parameterless constructor (see `Docs/decisions.md`, "EF Core wired up"), but keep adding this constructor to any new entity with a similar "generate Id internally" pattern — don't assume EF will pick the safe one on its own.
2. **`PrinceDbContext` uses its own migrations history table** (`__ef_migrations_history_core`, set via `MigrationsHistoryTable(...)` in `Program.cs`), not EF's default `__EFMigrationsHistory`. Reason: Jobs' `JobsIdentityDbContext` already uses the default name against this same shared `prince` database — two `DbContext`s sharing one physical database will collide on that table if both use the default. Any future `DbContext` added against this shared database needs its own explicitly-named history table too.

Migrations run automatically at `core-api` startup (`db.Database.MigrateAsync()` in `Program.cs`, before `app.Run()`) — same inline pattern Jobs already used for its Identity migrations, kept consistent rather than introducing a separate one-shot migrator service. Idempotent: a no-op when the schema's already current. To add a migration: `dotnet ef migrations add <Name> --startup-project ../Prince.App -o Migrations` from `Prince.Data/` (the `dotnet-ef` global tool must be on `PATH`, or invoke it by full path).

`Prince.App` still serves the default template weather-forecast endpoint (real endpoints not built yet), and `Prince.Services` is still an empty `Class1.cs` stub, not referenced by `Prince.App` yet. Replace incrementally as real endpoints/use-cases are added.
