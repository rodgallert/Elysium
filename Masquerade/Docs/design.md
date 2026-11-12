# Masquerade — detailed design

> **Status: detailed design complete (2026-11-12)** — flows, data model, endpoints, screens,
> revocation store and threat model. Next: implementation (Phase 2), through tickets.
> The ecosystem-level decisions this builds on are in `../../Docs/platform-design.md`, sections 5–8.

Masquerade is Elysium's accounts service: one account per person across every product, signed in
with a password, Google or a passkey, and each product **activated** on the account. It is an
OpenID Connect provider built on ASP.NET Core Identity + OpenIddict, and hosts its own screens on
`accounts.localhost`.

## 1. Scope of v1

| # | Flow | v1 |
|---|---|---|
| 1 | Sign-up (password, Google, passkey) | Yes |
| 2 | Email verification | Yes |
| 3 | Sign-in, including passkey autofill | Yes |
| 4 | Linking Google; adding and removing login methods | Yes, minimal |
| 5 | Password reset and change | Yes |
| 6 | Product activation and deactivation | Yes |
| 7 | Single sign-on and token refresh for product backends | Yes |
| 8 | Sign-out (this session, everywhere), admin termination, account disabled | Yes |
| 9 | Account manager (devices, products, sign-in methods, personal data) | Yes |
| 10 | Personal data updates (only email is verified in v1) | Yes |
| 11 | Account deletion | **No** — manual procedure (section 6) |
| 12 | Step-up re-authentication | Yes |
| 13 | Security notifications | Yes |
| 14 | Recovery when every login method is lost | **No** — manual procedure (section 6) |

Also not in v1: signing out of one product only (deactivation covers the real need), admin
impersonation, TOTP, recovery codes, data export, a permanent admin UI, and **sender-constrained
tokens (DPoP)** (section 6).

## 2. Concepts

- **Masquerade session (`sid`).** Created at every sign-in (a new id each time) and held in a
  `__Host-` cookie on `accounts.localhost`. Every token issued to a product while this session lives
  carries its `sid`. Ending the session ends every product's access that came from it.
- **Product session.** Each product backend (BFF) keeps its own cookie session with the browser and
  holds the tokens; the browser never sees a token. One OpenIddict authorization exists per
  (`sid`, product), not one long-lived authorization per user, so ending one session never touches
  another device. OpenIddict 7.x would otherwise create an ad-hoc authorization per issuance, so
  Masquerade creates a **permanent authorization explicitly** (get-or-create keyed by `sid` and
  product) and attaches its id to the principal; ending the session revokes that authorization and
  every token issued under it.
- **Device binding.** A Masquerade session and each product session are bound to the device they
  were created on (browser and device type). A request from a different device **ends the session**.
  A major network or location change on the same device asks for step-up re-authentication instead,
  since IP addresses change legitimately (mobile networks, VPNs, IPv6).
- **No limit on sessions.** An account may be signed in on any number of devices; every session is
  visible and can be ended from the account manager (3.9).
- **Verified email.** Set **only** by proving control of the mailbox. An account with an unverified
  email has a Masquerade-only session: it can sign in, manage its passkeys, fix a typo in its
  address and ask for the verification mail again — nothing else (section 3.2).
- **Activation.** A persistent record that a product may use the account, with the scopes it was
  granted (scopes map to groups of fields: `profile`, `cpf`, `address`, ...) and the version of the
  product's field requirements it was granted against.
- **Step-up.** Sensitive actions need `auth_time` within the last **5 minutes**. A sign-in that just
  happened counts. Re-authentication uses a method at least as strong as the one being changed.

## 3. Flows

Each flow lists what happens, the rules that make it safe, and how it's checked. "PO checks" means a
numbered manual session on the running stack (Mailpit for mail, Chrome DevTools' virtual
authenticator for passkeys); everything else is automated.

### 3.1 Sign-up
- One screen: **"Continue with passkey"** first, **Google** beneath it, **email + password** below a
  divider. The email field offers saved passkeys through browser autofill.
- The reply is always neutral ("Check your inbox, we sent you the next step"), whether or not the
  address already has an account. An existing verified account instead receives a calm mail
  ("Someone started a sign-up with this email. Nothing happened to your account", with Sign in and
  Reset password buttons; at most 3 per hour per address).
- **Pre-registration takeover:** a new sign-up on an address whose account is **still unverified
  replaces that account** — its credentials and sessions are deleted — in one transaction with a
  row lock (the unique index on the normalised email arbitrates). The address gets the same calm
  mail as above ("A new sign-up started with this email. Nothing else changed"). The replaced party
  is told nothing else, and the screens never say "replaced".
- Passkey sign-up creates the account at once (the user record first, then the passkey) and goes
  straight to "Confirm your email", saying the passkey is saved. It never merges into an existing
  account at the same address.
- Passwords: 8+ characters (15+ suggested, 64+ accepted), no composition rules, local blocklist,
  breached-password check (see 4.3), Argon2id (19 MiB, 2 iterations, parallelism 1).
- **Checks:** a double submit gives one account; parallel sign-ups on one address give one account.
  *PO checks:* two browsers sign up with the same address; only the second can verify, the first's
  password fails and its session is gone.

### 3.2 Email verification
- Single-use link, stored hashed, valid about **24 hours**. Opening the link shows a confirm button
  (POST), so mail scanners that prefetch links can't use it up.
- Verifying invalidates every session and credential created **before the link was issued**; the
  owner's own sign-up passkey (bound to the link's issue time) survives.
- Until verified, the account sees only the "Confirm your email" screen: the address, Resend (with a
  visible cooldown), "Wrong address? Change it" (a typo fix before verification: re-sends to the new
  address, needs re-authentication, no revert link since nothing was verified) and Sign out.
- Server-side gated until verified: activating a product, linking Google, changing a verified
  email, using reset as proof of ownership, recovery, deletion, and any mail other than
  verification.
- An already-used link says "Already confirmed"; an old link after a newer one says "This link is no
  longer valid. Send a new one."
- *PO checks:* sign up, open the mail in Mailpit, confirm, continue to the product.

### 3.3 Sign-in
- Password, Google or passkey (with browser autofill). A new `sid` on every sign-in.
- Every failure gives the same message, status and timing ("We couldn't sign you in with those
  details. Try again, use another method, or reset your password"); an unknown address still costs
  a hash with the same parameters.
- Rate limits are applied **before** hashing: 5 password attempts per 15 minutes per account, 20 per
  minute per IP; lockout is temporary and shows a countdown and the other methods.
- Google: authorization code with PKCE, `state` and `nonce` checked, ID token signature, issuer,
  audience and expiry validated, identity keyed by Google's user id (never the email).
- **New-device sign-in mail** is sent in v1.
- *PO checks:* each method; a second passkey device via the virtual authenticator; lockout after 5
  wrong passwords.

### 3.4 Login methods and linking
- Linking Google needs a verified email, a fresh sign-in with an existing method and step-up.
- A passkey can be named, added and removed; adding or removing any method sends a notification.
- Passkeys use ASP.NET Core Identity's .NET 10 support (several per user, each with a name; list,
  rename, remove), with user verification **required** and the relying-party domain set explicitly
  to `accounts.localhost` (never taken from the request's host). Masquerade uses the assertion API
  directly and creates its own session, instead of Identity's sign-in helper that sets Identity's
  own cookie. The browser side of passkey autofill (conditional mediation) and a per-user passkey
  limit are built by us.
- **The last login method can never be removed** (the UI disables it and explains why; the server
  answers 409). A verified email is not a login method.
- At sign-up, a person with a single method is prompted to add a second (a passkey or a password),
  since lost-everything recovery isn't in v1.
- *PO checks:* link Google, add and remove a passkey, try to remove the last method.

### 3.5 Password reset and change
- Reset: single-use link, stored hashed, valid about **30 minutes**, invalidated by a newer request;
  the reply is neutral whether or not the address exists. Reset doesn't sign the person in and never
  changes passkeys. It sets the account's revocation cutoff (every existing session ends) and then
  offers "Sign out everywhere" — already done — as confirmation.
- Change (signed in): current password plus new password; offers to sign out every other session.
- *PO checks:* reset in browser A while signed in on browser B; B's next request is signed out.

### 3.6 Product activation
- A custom step inside the OIDC `/authorize` flow (not OpenIddict's consent screen):
  signed in? → email verified? → activation exists and covers the product's current required
  fields? → issue the code. Otherwise show the activation screen and come back.
- The screen says what the product will receive, with a plain reason per field ("CPF: to pay out
  your earnings"), and asks only for **missing** required fields, prefilled where known. "Allow and
  continue" or **"Not now"** (back to the product, which explains what needs activation).
- No code or token is issued before "Allow". A double submit gives one activation.
- **A product that later needs a new field** keeps its old scope until the person agrees; the next
  visit shows the same screen with a banner ("Prince now also needs your phone number").
- Deactivation by the person ends that product's access on its next request (activation
  revocation entry) and leaves the account and other products untouched.
- *PO checks:* first visit from Prince (sign-up, activation, back to the original page); a second
  product shows "Welcome back" with no sign-up; deactivate and watch the product's next request fail.

### 3.7 Single sign-on and refresh
- A live Masquerade session plus an existing activation means a product gets a code with no screen
  at all.
- Product backends are confidential clients using code + PKCE; access tokens live 10 minutes;
  refresh tokens rotate and are tied to (`sid`, product).
- Every refresh re-checks that the session is alive, the account isn't disabled and the activation
  is active. If Masquerade or its database is unavailable, refresh answers **503 with Retry-After,
  never 401**, so the backend keeps the person signed in and retries.
- Backends refresh at about 80% of the lifetime with jitter, one refresh at a time per session.
- **Reuse:** the refresh-token reuse leeway is set explicitly to **10 seconds**. Inside it, a replay
  from the same client returns the already-issued successor (never a new one), only while that
  successor is unused. A replay from a different client, or after the window, revokes the whole
  session and writes its revocation entry.
  - **Built by us.** OpenIddict 7.8 inside the leeway mints a *second* token pair (two live chains,
    so a theft inside the window would never be detected), and outside it revokes the tokens but
    not the authorization, with no event to hook. Masquerade adds its own handlers to OpenIddict's
    token pipeline that return the cached successor, refuse when it was already used, revoke the
    authorization and write `session:{sid}`.
  - **How:** the token endpoint takes an atomic claim on the redeemed token's id (Redis `SET NX`);
    the winner refreshes normally and stores the issued response, encrypted with a purpose-bound
    Data Protection key, for the leeway plus a small margin. A loser inside the window gets that
    stored response — but only if its refresh token is still unused and the session, account and
    activation still pass the refresh re-checks. Otherwise: theft (revoke, write `session:{sid}`,
    `invalid_grant`). Replays outside the window are caught by a handler after OpenIddict's own
    token validation. OpenIddict's own `RefreshTokenReuseLeeway` must equal our window (checked at
    startup), rolling refresh tokens stay on, and Redis down means 503 before anything is minted.
  - **Required tests:** replay at +1 s returns byte-identical tokens and creates no new token;
    replay at +11 s, and replay after the successor was used, revoke everything; ten parallel
    refreshes produce exactly one pair, returned to all ten; a different client is refused and
    revokes the session; no stored response is returned after sign-out, account disable or
    deactivation; Redis down gives 503 and mints nothing; the stored value is encrypted; edges at
    9.9 s and 10.1 s; the startup leeway check; no token strings in logs.
- *Automated:* reuse at +5 s and +11 s, parallel refreshes through the backend lock.

### 3.8 Sign-out, admin termination, disabled accounts
- Sign out of this session, or **everywhere** (step-up). The order is always: commit to the
  database (with a revocation outbox row) → write Redis → reply. If Redis fails, the reply is **503
  "try again"** and a reconciler re-applies pending revocations within about 5 seconds. On a Redis
  restart, entries revoked in the last 15 minutes are rebuilt from the database (section 10).
- Takes effect on the **next request** through Keeper. Product backends also get an OIDC
  back-channel logout call, plus an event for catch-up if they were down. **Back-channel logout is
  built by us** (OpenIddict 7.x doesn't send logout tokens): a signed `logout_token` posted to each
  product's registered `backchannel_logout_uri` through the outbox, with retries.
- **Admin termination** (one account's sessions, or everyone's) exists in production as an
  authenticated, audited operator action. Disabling an account ends all its sessions.
- *PO checks:* two browsers, sign out everywhere in one, the other is signed out on its next
  request; disable an account with the admin command.

### 3.9 Account manager
The person's own space on `accounts.localhost`: one place to see and control everything attached to
their Elysium account.
- **Devices:** every active session with its device (browser, operating system, device type),
  approximate place, **when it was created** and when it was last active; the current one marked
  "This device". End one session, or all others, or all (ending all needs step-up). There's no limit
  on how many devices can be signed in.
- **Connected products:** each activated product, what data it was granted and since when;
  deactivate from here (3.6).
- **Sign-in methods:** password, Google, passkeys — add, rename, remove (3.4).
- **Personal data:** view and update (3.10).
- **Recent security activity:** a read-only list of the account's security events (sign-ins with
  device and place, password changes, methods added or removed, email changes, products activated or
  deactivated, sessions ended), read from the audit log.
- *PO checks:* sign in on two browsers, both appear with their device and creation time; end one,
  it's signed out on its next request; deactivate a product from here.

### 3.10 Personal data
- Name, phone, birth date, CPF, addresses are stored; **only email is verified in v1**. CPF is
  checked for validity (checksum) but never "verified" in v1, so **Prince withdrawals stay blocked**
  until a later verification exists (Prince decides its own withdrawal rule).
- **Email change:** step-up, then the new address must be confirmed; until then the person still
  signs in with the old one. The old address is notified at request and completion and gets a
  **revert link valid for 7 days**.
- **Who can change what** (in the account manager, decrypted by Masquerade for the owner):

  | Field | Owner sees | Owner can change |
  |---|---|---|
  | Name, phone, address | in full | yes, directly |
  | Email | in full | only through the email-change flow above |
  | CPF | masked (`***.***.789-01`); "Show" reveals it after step-up | no — set once, then read-only |
  | Birth date | in full | no — set once, then read-only |

- CPF and birth date are entered once, when first needed (usually at a product's activation), and
  are read-only afterwards. A mistake is corrected only by an operator, audited — CPF ties to payouts,
  so letting the owner change it would be a fraud path.
- *PO checks:* change email, confirm from Mailpit, revert from the old address's mail; edit phone and
  address; CPF and birth date show no edit control; revealing CPF asks for re-authentication.

### 3.11 Step-up re-authentication
- An inline sheet over the page ("For your security, confirm it's you"), offering the strongest
  available method first; on success the original action continues by itself; what was typed is kept.
- Required for: email change, adding or removing a login method, setting a password, enrolling a
  passkey, revealing the full CPF, signing out everywhere, deletion (when it exists).
- *Automated:* every sensitive action × {no `auth_time`, 4:59, 5:01} × {weaker method, equal method}.

### 3.12 Security notifications (email)
Password changed or reset · login method added or removed · passkey added or removed · email change
requested and completed (to the old address) · new-device sign-in · signed out everywhere · product
activated or deactivated · sign-up attempt on an existing address. One mail and one audit row per
event, sent through the outbox. *PO checks:* each appears in Mailpit.

## 4. Cross-cutting rules

### 4.1 Budgets and limits (to be confirmed by load tests)

| Item | Budget |
|---|---|
| Revocation check at Keeper | p99 under 2 ms; Redis timeout 50 ms; no caching; circuit breaker fails closed |
| Revoke (database + Redis + reply) | p95 under 100 ms; reconciler lag under 5 s |
| Refresh | p95 under 150 ms |
| Password sign-in | p95 under 400 ms (under 1 s with Google or the breached-password check) |
| Password hashing | at most one hash per CPU core at a time, queue twice that, then 429 |
| Password attempts | 5 per 15 min per account; 20 per min per IP |
| Mails | 3 per hour per address |

Expected v1 scale is small: one instance of each service.

### 4.2 Failure modes
- **Postgres down:** every flow answers 503; nothing partial (transactions).
- **Redis down:** authenticated traffic through Keeper fails closed; sign-out answers 503 "try
  again"; sign-in can still create sessions.
- **Mail down:** actions commit and mail waits in the outbox; alert when the oldest message is
  over 5 minutes old; the person can resend after a cooldown.
- **Google down or slow:** 3-second timeout; password and passkey sign-in are unaffected.

### 4.3 Breached-password check
Calls the Have I Been Pwned range API (only a hash prefix leaves the server) with a 1–2 second
timeout and no retries. If it's unavailable, the password is **accepted** (the only fail-open on a
security path), the skip is logged and counted, an alert watches the skip rate, and the password is
re-checked at the next sign-in. The local blocklist always runs first and never skips.

### 4.4 Observability
- A structured log line per authentication event (`event`, `sub`, `sid`, `client_id`, `method`,
  `result`, `correlation_id`), never an email or token.
- An audit row per security event.
- A read-only **debug view** (sessions, revocation entries, audit rows; emails masked; labelled as a
  development tool) only in the development profile, plus a documented runbook of Redis and SQL
  commands as the fallback.

### 4.5 Testing Google
A fake OpenID provider in the local stack signs real tokens, so every check (signature, issuer,
audience, `nonce`, `state`) runs; Masquerade refuses to start with it outside Development. One
documented manual run against real Google before release.

## 5. Events and commands (JSON, documented schemas)

| Message | Kind | To | Purpose |
|---|---|---|---|
| `SendEmail` | command | Herald | every mail above |
| `EmailVerified` | event | products | |
| `ProductActivated` / `ProductDeactivated` | event | the product | |
| `SessionsRevoked` | event | products | catch-up for back-channel logout |
| `ProfileFieldChanged` | event | products with that scope | field name and verification status only, never the value |
| `AccountDisabled` | event | products | |
| `AccountDeleted` | event | products | when deletion exists |

Revocation itself is never an event: it is a direct, reconciled Redis write (3.8). Events are for
cleanup and catch-up, not enforcement.

## 6. Not in v1, and what happens instead

- **Account deletion (LGPD).** A documented, audited operator procedure handles erasure requests
  until the flow is built; revisit when Masquerade v0.2 is planned. Grace period (7–15 days) and the
  retention of financial records and audit rows are decided then.
- **Lost-everything recovery.** v1 never lets an account reach zero methods and prompts for a second
  method; a documented, audited operator procedure covers the remaining case (a lost passkey on a
  passkey-only account). No ad-hoc support bypass.

- **Sender-constrained tokens (DPoP, RFC 9449)** — *decided: not in v1*. OpenIddict supports DPoP in none of its server,
  client or validation stacks (its maintainer calls it "not a priority", June 2026), and .NET 10's
  JwtBearer doesn't validate DPoP proofs. Building it all would take 2–3 weeks and add a signature
  check plus a replay-cache write to every request at Keeper. In v1 only server-side product
  backends hold tokens, and they're already covered by 10-minute tokens, immediate revocation,
  authenticated confidential clients and reuse detection. **Revisit when a client that can't keep a
  secret appears** (a native mobile app or a public client), or if binding is needed sooner between
  our own servers — then mutual TLS, which OpenIddict does support, is the first option.

## 7. Data model (logical)

Masquerade has its own database (Postgres 17). Our tables sit **alongside** ASP.NET Core Identity's
and OpenIddict's, never inheriting from them: an account's id is the same value as its Identity user
id, Identity holds only credential material, and the domain model has no library types.

| Table | Holds | Rule it enforces |
|---|---|---|
| `accounts` | id (= Identity user id), normalised email (unique), email verified at, status (active / disabled, with reason and operator), revocation cutoff, breach-check-pending flag, concurrency token | One account per address. Replacing an unverified account runs in one transaction under a row or advisory lock; the unique index decides any race and the loser gets the neutral reply. |
| `login_methods` | account, kind (password / Google / passkey), credential reference, label, created at | One row per credential. **The last method can't be removed:** the account row is locked (`FOR UPDATE`) while counting; a deferred constraint trigger backs the rule up and fails only on a bug (the business answer, 409, never comes from it). Account replacement is the trigger's one exception. |
| `personal_data` (1:1 with the account) | name; **encrypted:** phone, birth date, address, CPF; verification status per field; CPF blind index | Sign-in, session, activation and token handling never load it. One table to walk for a future erasure. |
| `account_tokens` | purpose (verify, reset, email-change confirm, revert), SHA-256 hash (unique), issued, expires, consumed, superseded, target email (cleared on use or expiry) | Single use: one atomic update that only succeeds on a live token. A partial unique index allows one live token per account and purpose, so a newer one supersedes. |
| `pending_email_changes` | account (unique), new address, old address, revert deadline | The old address is kept only until the 7-day deadline, then purged. |
| `sessions` | id = `sid`, device (browser, OS, type, binding id), approximate place, created, last active, `auth_time`, ended at, end reason (required once ended), ended by | Ends once and never reactivates. Ended rows are purged after **7 days**; history in the account manager comes from the audit log. |
| `session_authorizations` | session, product, OpenIddict authorization | One authorization per (`sid`, product), enforced by unique keys and a composite foreign key. |
| `product_requirements` | product, version, required fields | The product owns its requirements version. |
| `activations` | account, product, granted scopes, requirements version granted, activated at, deactivated at | One activation per account and product; re-activating reuses the row. The activation decides whether it covers the product's current requirements. |
| `revocations` + `revocation_outbox` | kind (session / account / activation), subject, created at, reason; applied at | Written in the same transaction as the change. Redis is rebuilt from the last 15 minutes (section 10); the reconciler applies anything unapplied. Kept at least 24 hours. |
| `audit_events` | partitioned by month; occurred at, account id (no foreign key), `sid`, event (a closed list), result, actor, truncated IP, keyed IP hash, correlation id, details (no personal data) | Append-only: the application can't update or delete rows; only a maintenance role drops expired partitions. Survives account deletion. |
| Identity's tables | users, external logins, passkeys | Credential material only; no roles. |
| OpenIddict's tables | applications, authorizations, scopes, tokens | Never edited by hand; its own cleanup job. |
| Wolverine's tables | outbox, inbox | Revocation never goes through them. |

### 7.1 Rules
- **Ids are generated by the application** (Postgres 17 has no built-in UUID v7): `sid` is a random
  UUID v4; every other id is a UUID v7. This is a deliberate exception to Prince's
  database-generated ids.
- **One clock:** every expiry, cutoff and `auth_time` comparison uses the application's clock,
  passed into queries as a parameter, so tests can move time.
- **No personal data** in logs, events or audit details. Tokens are looked up only by their hash;
  raw tokens exist nowhere in the database or logs.
- **The session cookie** is its own random secret, independent of `sid`; knowing a `sid` grants
  nothing.

### 7.2 Encryption and keys
- Phone, birth date, address and CPF are encrypted per column with ASP.NET Data Protection
  (a purpose per field). Name and email stay readable, protected by database encryption at rest
  and access control: a documented, accepted risk.
- **Decryption happens only in Masquerade**, for the account's owner (account manager) or for a
  product whose granted scopes include that field. Keys never reach a browser or a product.
- **One account per CPF:** a keyed hash (HMAC) of the normalised CPF, with a unique index, makes it
  unique and searchable without decrypting.
- Each keyed hash has **its own key** (CPF, IP, unknown-address correlation), separate from the
  encryption keys.
- The key ring lives in Masquerade's database, protected by a **master key held in the deployment's
  secret store**, apart from backups. Backups are encrypted, and restoring one without the master key
  must fail.
- A key-rotation runbook is written before CPF goes live.

### 7.3 Retention

| Data | Kept |
|---|---|
| Audit rows | **12 months** (monthly partitions dropped); after deletion exists, rows keep a pseudonymous account id |
| Truncated IP (display) | with the audit row |
| Keyed hash of the full IP (correlating attacks) | 90 days; raw IPs are never stored |
| Ended sessions, consumed or expired tokens | 7 days |
| Old address of an email change | until the revert deadline (7 days) |
| Revocations | at least 24 hours |
| Backups | an expiry is set and stated, since erased data lives in them until then |

Every purge job has an automated test.

### 7.4 Operators
Operators are Masquerade accounts with an operator role, which never appears in product tokens.
They must sign in with a passkey (the v1 MFA relaxation doesn't apply to them), pass step-up for
every operator action, and every action is audited with the operator's id. The first operator is
created by a one-time setup command at deploy; there's no seeded or shared admin outside
development. A disabled account can be re-enabled by an operator; the reason and operator are
recorded.

### 7.5 What the views show
- **Recent security activity** shows only events tied to the account, never other people's failed
  attempts against its address.
- **The debug view** reads the audit log only through a view that masks emails.
- **The account manager** shows the owner their decrypted data, with CPF masked until revealed
  after step-up (3.10). Operators correct CPF and birth date; the owner can't.

## 8. Endpoints

Every path is set explicitly (OpenIddict has no defaults beyond discovery). `accounts.localhost`
goes straight to Masquerade; Keeper fronts only `api.localhost`.

### 8.1 OpenID Connect (on `accounts.localhost`, unversioned, standard OAuth errors)

| Endpoint | Caller | Notes |
|---|---|---|
| GET `/.well-known/openid-configuration`, `/.well-known/jwks` | product backends, Keeper | public, cacheable; discovery advertises the end-session endpoint |
| GET/POST `/connect/authorize` | browser | Masquerade session cookie; PKCE (S256) required, exact `redirect_uri`; runs sign-in → verified email → activation (3.6); "Not now" returns `access_denied` with the original `state`; `prompt=none` not supported in v1 |
| POST `/connect/token` | product backends | confidential clients only (client secrets in v1; signed-key authentication later); code and refresh grants with our reuse handling (3.7); 429; **503 + Retry-After, never 401**, when a dependency is down |
| GET/POST `/connect/logout` | browser, sent by a product | needs `id_token_hint` and a registered `post_logout_redirect_uri`; confirm page; ends **this device's** Masquerade session, so every product on the device signs out |

**Off:** userinfo, introspection, token revocation (RFC 7009), device flow, pushed authorization
requests, token exchange. Introspection and userinfo would read token state without Keeper's
revocation check; revocation would be a second way to end sessions that skips 3.8's order. If the
OIDC conformance suite turns out to need userinfo, a minimal one (identity claims only) is exposed
**only through Keeper**; a test proves `/connect/userinfo` is never reachable on `accounts.localhost`.

### 8.2 Masquerade's pages (on `accounts.localhost`)
Server-rendered **Razor Pages** (section 9), anti-forgery token on every POST, no state change on GET, no
CORS, strict security headers (CSP without inline script, `frame-ancestors 'none'`, HSTS in
production, `nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store` on auth pages),
rate limits applied before any password hash.

| Area | Paths | Flow |
|---|---|---|
| Sign-up | `/sign-up`, `/sign-up/passkey/options`, `/sign-up/passkey` | 3.1 |
| Verification | `/verify-email` (GET shows a button, POST consumes), `/verify-email/resend`, `/verify-email/change-address` | 3.2 |
| Sign-in | `/sign-in`, `/sign-in/passkey/options`, `/sign-in/passkey`, `/sign-in/google`, `/sign-in/google/callback` | 3.3 |
| Sign-out | `/sign-out`, `/sign-out/all` (step-up) | 3.8 |
| Password reset | `/forgot-password`, `/reset-password` | 3.5 |
| Step-up | `/step-up`, `/step-up/passkey/options` | 3.11 |
| Activation | `/activate` | 3.6 |
| Account manager | `/account`, `/account/devices` (end one, end others), `/account/products` (deactivate), `/account/methods` (password, passkeys add / rename / remove, Google link / unlink — 409 for the last method), `/account/activity`, `/account/profile` (CPF reveal needs step-up), `/account/email`, `/email-change/confirm`, `/email-change/revert` | 3.4–3.10 |

Neutral pages (sign-up, sign-in, reset, resend) return the same status, redirect and page —
identical after normalising per-request values — whatever the account's state.

### 8.3 Operators
Pages under `/operator` on `accounts.localhost`: account search, disable and enable, end sessions
(one account or everyone), correct CPF or birth date. Operator role, passkey sign-in and step-up for
every action; every action audited with the operator's id. A **command-line tool** is a thin client of
these same endpoints: the operator signs in through OIDC (browser with a local redirect), passkey and
step-up included, so it has no authority of its own. The only exception is the one-time **first
operator** command at deploy (audited as `bootstrap`, refuses to run if any operator exists). When
the pages or Redis are down, the runbook covers it. Network allowlisting of the operator pages is
not done (`decisions.md`).

### 8.4 Development only
GET `/_debug/sessions`, `/_debug/revocations`, `/_debug/audit` (emails masked). Not mapped outside
Development; a startup test asserts a 404 in Production.

### 8.5 Product API (on `api.localhost`, through Keeper)
GET `/v1/profile` — the **only** way a product reads personal data. Bearer token, revocation checked
by Keeper; returns the granted field groups with each field's verification status and a list of
required fields still missing; `Cache-Control: no-store`; rate limited per product and per account.
401 = session or token revoked, 403 = scope not granted, 503 + Retry-After when Masquerade is down.
Errors use RFC 9457 problem details. Personal data is never put in ID or access tokens; the ID token
carries `sub`, `sid` and the display name.

### 8.6 Outbound and health
- POST to each product's registered `backchannel_logout_uri`: a signed `logout_token` (`iss`, `aud`,
  `iat`, `jti`, `sid`, `events`), sent through the outbox with retries.
- `SendEmail` to Herald and every event (section 5) go through RabbitMQ.
- GET `/health/live`, `/health/ready` (ready fails when Postgres is down); internal only.

### 8.7 What every product backend implements
Masquerade publishes a **versioned contract file** (discovery shape, token claims, the
`/v1/profile` response, `logout_token` claims, event schemas). Products build against it:
- A sign-in callback: PKCE, `state` checked **before** any error is trusted, `nonce`; a loop guard
  if `access_denied` repeats.
- A back-channel logout receiver: verify signature, `iss`, `aud`, `sid`; delete its own sessions for
  that `sid` (it keeps a `sid` → session index); idempotent; 204 even when nothing matched.
- Sign-out: drop its own session first, then send the browser to `/connect/logout`; the button reads
  **"Sign out of Elysium on this device"**.
- Refresh at about 80% of the token lifetime with jitter, one at a time per session; 503 means retry
  and keep the person signed in.
- Consumers for deactivation and disabled-account events; unknown fields ignored (additive changes
  are non-breaking).
- A "not activated" page with an **Activate** button (not a generic sign-in); a "signed out" page that
  never says why, except after the person's own sign-out.

### 8.8 Testing the endpoints
- A **fake product client** in Masquerade's tests exercises the protocol end to end, including the
  attacks (wrong `redirect_uri`, missing PKCE, refresh replay); it's kept separate from Prince's real
  sign-in module, which must never be able to misbehave on purpose.
- **`.http` files** per flow in the repository for the PO's manual protocol and operator checks;
  user flows are checked through the screens. A **Postman** collection and API documentation come
  later.
- The **OpenID Foundation conformance suite** (Basic and Config OP plans) runs once at the Phase 2
  checkpoint, and again when OpenIddict moves to 8.x.
- Identical neutral responses are gated by a test that proves the same code path ran (including the
  dummy hash); a statistical timing comparison runs before releases, not on every pull request.

## 9. Screens: technology and look

### 9.1 Razor Pages
Masquerade's screens are **Razor Pages**, server-rendered, with two small JavaScript files of our own
(passkeys with browser autofill, and the step-up sheet as a `<dialog>`). Anti-forgery is built in, no
inline script or style is needed, so the strict CSP holds as written, and pages are tested through
real form posts.
- **Blazor static rendering** was the runner-up: it still loads Blazor's script, whose template needs
  hashes or nonces for inline pieces, and its enhanced navigation can disturb autofill and dialogs.
- **Interactive Blazor (Server)** is ruled out: a live connection and server memory per visitor,
  including anonymous ones; events travel over the socket where anti-forgery doesn't apply; a revoked
  session could keep driving a live connection; and the session cookie can't be set mid-connection.
- **Blazor WebAssembly** is ruled out: it needs the JSON API we decided not to have.
- .NET 10's passkey screens ship only with the Blazor template; they're a reference for our script,
  not a reason to adopt Blazor.

### 9.2 Look
- **Material 3 wherever possible**, as the shared design language for every Elysium UI (see
  `Docs/platform-design.md`, "Shared look"). Masquerade's pages implement it as closely as possible
  with **plain CSS driven by the shared design tokens** and a handful of hand-written components
  (button, text field, password field with show toggle, alert, error summary, dialog, list, chip).
- **No component library, runtime npm package, CDN script or inline style on Masquerade's pages**,
  so nothing but our own two scripts can run where passwords and passkeys are typed (defence against
  script injection and supply-chain attacks).
- **Branding:** every page carries the **Elysium logo** (Masquerade is Elysium's own front door), and
  the product being signed in to appears in the header by name and logo, with its registered
  hostname on the activation screen ("Signing in to Prince", `prince.localhost`). Products can't
  restyle these screens or supply anything at request time, which also helps against phishing.
- **Logos are local files versioned with the frontend that shows them:** the Elysium logo with
  Masquerade's pages, each product's logo with that product's frontend. The product logos Masquerade
  displays are committed copies kept beside each product's registration in Masquerade — never fetched
  from the product. SVG is allowed since we author them; CI rejects any script or external reference
  inside an SVG.
- **Themes:** dark and light both ship. A first visit **follows the device's setting**
  (`prefers-color-scheme`, in plain CSS), falling back to dark when the device has none; once signed
  in, the account preference wins.
- **Typography:** **Cinzel** for titles, **Inter** for everything else (forms keep body text at 16 px
  or more). Both bundled, never fetched from a third party.
- **Contrast: WCAG 2.2 AA**, enforced by tests on every declared colour pair in both themes.
- **Operator pages** have their own look (a persistent "Operator" band) and don't need a mobile
  layout.

### 9.3 Preferences that follow the person
Theme (dark / light), **language** and, later, a **colour-vision mode** are account preferences,
edited in the account manager and stored in Masquerade. Every product applies them, so a change made
once shows everywhere. Products read them from `/v1/profile` (a low-sensitivity `preferences` group
granted to every activated product). Before sign-in, Masquerade's pages use the dark theme and the
browser's language.

### 9.4 Screens
Mobile first, one column, a ~420 px card inside a fixed shell (Elysium logo, product line, language
and theme links). Every screen lists its states (default, submitting, field error, rate-limited,
locked out with countdown, expired or used link, success), each reachable in tests by URL or a
development-only switch.

| Screen | Content |
|---|---|
| Sign-up | passkey first, Google second, email and password below a divider; neutral "check your inbox" for every outcome |
| Confirm your email | the address (masked unless just typed), Resend with a visible cooldown, "Wrong address? Change it", Sign out |
| Sign-in | email with passkey autofill, password, Google, "Forgot your password?"; one generic failure message |
| Step-up sheet | a `<dialog>` saying in words what is being confirmed; strongest method first; the original action resumes, typed text kept |
| Forgot / reset | neutral confirmation; new password form; expired or used link; offer to sign out everywhere |
| Activation | "Prince will receive" (each field with a reason) and "We still need" (missing fields only); Allow / Not now; new-field banner |
| Account manager | Devices, Connected products, Sign-in methods, Personal data, Recent security activity, Preferences (theme, language) |
| Email change / revert | confirm, success, expired, already used |
| Operator | dense tables, "Operator" band, masked emails, the target account on every action, typed confirmation for destructive actions |
| Global | 403 / 404 / 500 / offline, each with a next step |

What screens never show: whether an address has an account (neutral screens); a full CPF without
step-up (and then only in a no-store response); IP addresses, user-agent strings, `sid` or token
values; other people's attempts against the account; the operator's name — activity shows
**"Elysium support"**, while the audit log records the operator's id.

### 9.5 Components
Button (filled, tonal, outlined, text, destructive outlined), text field, password field with a Show
toggle, passkey and Google buttons, alert (info, success, warning, error — always icon plus text),
error summary, dialog/sheet, list and list item, chip, banner, countdown, table (operator),
theme/language switcher, loading skeleton. Each has every state (default, hover, focus-visible,
pressed, disabled, loading, error) and a stable test id shared with the product frontends.
Consistency across stacks is checked on numbers (box sizes, font sizes, computed colours) and
component screenshots, not whole-page equality; the PO signs off screenshot baselines.

## 10. Revocation store and Keeper's check

### 10.1 Keys (on the revocation Redis instance)

| Key | Value | Meaning |
|---|---|---|
| `rev:s:{sid}` | revoked-at | the session is dead |
| `rev:a:{sub}` | cutoff | every token of the account with `iat` at or before the cutoff is dead |
| `rev:p:{sub}:{client_id}` | cutoff | the same, for one product activation |
| `rev:g` | cutoff | everyone's tokens before the cutoff are dead (operator "end all sessions"; also for testing and breach drills) |
| `rev:ready` | store generation id, no expiry | the store is complete |

- Values are epoch seconds from **Masquerade's clock**; Keeper never compares them with its own.
- Every entry expires **15 minutes** after the revocation (10-minute tokens + clock tolerance +
  reconciler lag + margin), written with a relative expiry so a re-apply never extends it.
- **Cutoffs only move forward:** Masquerade writes through a small script that sets a cutoff only if
  the key is missing or the new value is later, so a late retry can never un-revoke.
- Keys hold only random ids and timestamps — never personal data or tokens.

### 10.2 Keeper's check
- Global middleware after token validation (signature, issuer, **per-service audience**, expiry with
  a **30-second** clock tolerance instead of .NET's 5-minute default), before the proxy. Only
  health is exempt; a startup test fails if any route is neither protected nor explicitly exempt.
- One `MGET` per request of `rev:ready`, `rev:g`, `rev:s:{sid}`, `rev:a:{sub}`,
  `rev:p:{sub}:{client_id}`. Revoked if the session key exists or `iat` is at or before any cutoff
  (equal counts as revoked) → **401**. A token missing `sid`, `sub`, `client_id` or `iat` → 401.
- `rev:ready` missing, a timeout (50 ms), a partial failure or an open circuit breaker → **503 with
  `Retry-After: 2`**, never 401 (a 401 would sign everyone out of every product). No retries, no
  caching. The breaker opens after 5 consecutive failures or more than half of at least 20 calls in
  10 s, for 5 s.
- Metrics per result (ok, session, account, activation, global, unavailable, malformed), latency and
  breaker state; logs carry `sid`, `client_id`, the result and the correlation id — never token values.

### 10.3 Writer, reconciler, rebuild, integrity
- Masquerade commits the change with a revocation-outbox row, writes Redis, then replies. A
  background reconciler re-applies unapplied rows every 1–2 s (idempotent, audited).
- Masquerade checks `rev:ready` every 5 s; if it's missing (restart with data loss, a flush), it
  rebuilds every revocation of the last 15 minutes, then sets `rev:ready`. Keeper answers 503 until
  then — never silently un-revoked.
- **Integrity check** about once a minute: the database and Redis are compared for the last 15
  minutes; missing entries are re-applied, entries the database doesn't know are removed and
  alerted. Alerts also on flushes, mass key creation and access-control denials.
- The key layout, value format, expiry rule, ready marker and decision rule are part of Masquerade's
  **contract file**, with shared test fixtures: Masquerade asserts what it writes, Keeper asserts its
  decisions — no shared code. Any service can later use the same contract to check revocation itself.

### 10.4 Redis setup
- **Two instances:** **revocation** (never evicts; append-only file synced every second; 64 MB) and
  **rate limiting** (also holds the 10-second refresh-retry cache; evicts only keys with an expiry;
  no persistence). An attacker-driven flood of rate-limit keys can't push out revocations.
- No default user; one access-control user per purpose (Keeper read-only on `rev:*`; Masquerade's
  writer; rate limiting). Dangerous commands disabled (`FLUSHALL`, `FLUSHDB`, `CONFIG`, `DEBUG`,
  `KEYS`, `SHUTDOWN`, `MODULE`, `REPLICAOF`); scripting only for the writer. Internal network only,
  no host port. TLS in production; the local stack runs without TLS but with passwords and
  access control.
- No replicas in v1 (reads from the primary only). **While Redis is down, every product answers
  "try again"** — accepted for v1, with removing this single point of failure on the roadmap.

## 11. Security rules from the threat model

The v1 threat model (STRIDE across every trust boundary, mapped to OWASP ASVS 5.0 Level 2) added
these rules:
- **Links in emails** are built from a configured base address, never the request's `Host` header;
  header injection through names or addresses is refused.
- **Every service validates tokens itself** (signature, audience, expiry), even behind Keeper; a
  product A token fails at product B.
- **No trust in network location:** no route skips authentication because it's "internal" and no IP
  address counts as identity; only health checks are exempt. A test walks every service's routes.
  Code is written as production code, as if behind a VPN that's already breached.
- **Back-channel sign-out targets:** https only, never private or loopback addresses outside
  development, no redirects followed, short timeout, size cap.
- **Keys and secrets:** signing keys rotate **every quarter** with old and new published during the
  overlap; runbooks for signing-key compromise and client-secret leaks; keyed-hash keys differ from
  encryption keys; nothing secret in committed files, images, build arguments, logs or error pages;
  each service has its own database, Redis and broker credentials.
- **Startup self-check:** Masquerade and Keeper refuse to start in production on insecure
  configuration — missing or development signing keys, a Data Protection key ring that can't decrypt
  its sentinel, empty audiences, non-exact or non-https redirect URIs, Redis without its own user,
  passkey domain unset, development credentials or debug routes present. It reports which checks
  passed, never values; each check has a test.
- **Dependencies:** exact versions with lock files and a single package source; OpenIddict pinned,
  with handler-order tests and the conformance run on every upgrade; Identity's default endpoints and
  UI never mapped; explicit message types and System.Text.Json for messages; parameterised SQL only;
  a separate role for migrations; container images pinned by digest and non-root. **Critical
  dependency advisories are never applied automatically** — they become a ticket the PO handles the
  next working day.
- **TLS between every service in production**, including Postgres, Redis and RabbitMQ.
- **Tests added:** key rotation; passkey negative cases (wrong origin or relying party, replayed
  challenge, no user verification); malicious Google tokens (wrong `nonce`, `aud`, `iss`, expired,
  unsigned); a spoofed `Host` in emails; mail volume across addresses from one IP; rate-limit keys
  not evicted under a flood. Hostile inputs exist only in the development stack, to validate before
  production.
- **Security tooling in CI:** a ZAP baseline scan of the running stack (**a release gate**, findings
  triaged by the security reviewer), dependency, secret and container scanning, an SBOM per release,
  and the OIDC conformance run before each release.
- **Alerts** (Redis integrity, every operator action, every CPF correction) go to recipients set in
  Elysium's root `.env`. The committed example has none — the repository is public, so a clone only
  logs alerts and never emails anyone.

### 11.1 Accepted risks

| Risk | Revisit when |
|---|---|
| Password-only accounts (no second factor) | TOTP, right after v1 |
| No self-service deletion or lost-everything recovery | Masquerade v0.2, or the first erasure request |
| No sender-constrained tokens (DPoP) | a native or public client appears |
| Name and email stored readable | an auditor or the PO asks |
| No TLS in the local stack | never in production |
| Device binding by browser and device type | the first reported cookie theft |
| Every product down while Redis is down | the single-point-of-failure work on the roadmap |
| No network allowlist for operators | more than one operator |
| No second approver for CPF corrections | a second operator |
| Breached-password check fails open | the skip-rate alert fires |
| Redis cutoffs unsigned | any exposure of Redis |
| OpenIddict has essentially one maintainer | inactivity or a licence change |
| Repeated replacement of someone's unverified sign-up (nuisance) | it's reported |
| Services trust that traffic came through Keeper; no per-service identity between services; revocation checked only at Keeper | the zero-trust phase (`Docs/platform-design.md` §20); service identities with the first service-to-service call |

## 12. Next

Implementation (Phase 2), through tickets.

Checked against OpenIddict 7.8 and the .NET 10 docs (2026-11-12): reuse leeway, one authorization
per session, back-channel logout and passkeys — results folded in above. DPoP and the reuse
handling were checked afterwards (section 6 and 3.7). Still to confirm when the first migration is generated: Identity's passkey tables and the
default user-verification setting.
