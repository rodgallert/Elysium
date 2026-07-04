# Producer — domain reference

Snapshot of what has been defined for `Producer` (`core/domain`): fields, relations, and the
login-lockout business rule. Documentation of decisions already made — not a spec for Claude to
implement (see `CLAUDE.md`: models/migrations are the author's territory).

## Fields

| Field | Type | Notes |
|---|---|---|
| `name` | `string` | not null |
| `email` | `string` | not null, unique |
| `password_digest` | `string` | not null — via `has_secure_password` (bcrypt) |
| `document` | `string` | not null, unique — CPF (11) or CNPJ (14), digits only |
| `phone` | `string` | not null |
| `street` | `string` | not null |
| `number` | `string` | not null |
| `city` | `string` | not null |
| `state` | `string` | not null |
| `zip_code` | `string` | not null |
| `complement` | `string` | nullable |
| `status` | `string` (enum) | not null, default `active` — see `Statusable` below |
| `birth_date` | `date` | not null |
| `failed_login_attempts` | `smallint` | not null, default `0` |
| `login_blocked_count` | `smallint` | not null, default `0` — which lockout tier has been reached |
| `last_failed_login_at` | `datetime` | nullable |
| `login_blocked_until` | `datetime` | nullable — source of truth for "currently locked" |
| `created_at` / `updated_at` | `datetime` | automatic (`t.timestamps`) |

## Relations

- `has_many :products` (via `Product#belongs_to :producer`)

## Concerns / mixins

- `has_secure_password` — provides the virtual `password`/`password_confirmation` attributes
  (never persisted; only the bcrypt hash is stored in `password_digest`).
- `include Statusable` — concern shared with `Product`/`Offer` (`app/models/concerns/statusable.rb`).

## Status (enum, via `Statusable`, shared)

`pending`, `active`, `suspended`, `blocked`, `deleted`, `pending_deletion` (a producer may only
request deletion — `pending_deletion` — if they have no sales tied to their account).

This field is about **account moderation** — separate from the login-lockout mechanism below,
which is a security mechanism, not an editorial one.

## Login-lockout policy (business rule — not yet implemented in code)

**Eligible to log in**: correct password **and** `status == active` **and** `login_blocked_until`
is nil or already expired.

**Failed attempt with wrong password**:
1. If `last_failed_login_at` was more than 1h ago, reset `failed_login_attempts` to `0` before
   incrementing (unrelated, isolated attempts shouldn't accumulate together).
2. Increment `failed_login_attempts`.
3. Once the current tier's threshold is reached (table below), set `login_blocked_until` and
   increment `login_blocked_count`.

| Tier (`login_blocked_count`) | Attempt threshold | Lockout duration |
|---|---|---|
| 0 → 1 | 3 wrong attempts | 5 minutes |
| 1 → 2 | 3 more attempts (within the next 1h) | 30 minutes |
| 2 → 3 | 5 more attempts (within the next 1h) | Full lockout — support-only resolution (sets `status`, e.g. `suspended`; no longer a timestamp) |

**Attempt made during an active lockout** (`login_blocked_until` in the future): rejected
immediately, without validating the password and without touching any counter.

**Reset of `failed_login_attempts` and `login_blocked_count`** (together, always):
- A successful login, or
- 1h after `login_blocked_until` expires with no further attempt.

All of this is checked lazily — evaluated on the next login attempt, in the session service. No
worker/job involved.
