# Masquerade — decisions

Why Masquerade is the way it is, in order. Ecosystem-wide decisions live in
`../../Docs/platform-design.md`.

## 2026-11-12 — v1 flows agreed

Designed in a team review covering architecture, security, testing, reliability and screens; the PO
accepted every recommendation. Full detail in `design.md`, sections 1–6. The calls that weren't
obvious:

- **Deletion and lost-everything recovery are not in v1.** Covered by documented, audited operator
  procedures; v1 never lets an account reach zero login methods. Parking deletion is a legal
  exposure under LGPD, accepted knowingly, to revisit at v0.2.
- **Unverified email:** sign-in is allowed, but the account sees only "Confirm your email" and the
  server blocks activation, linking, email changes, reset-as-proof, recovery and non-verification
  mail. Blocking sign-in entirely would make passkey-first sign-up impossible.
- **Pre-registration takeover** is handled by two rules together: a new sign-up on a still-unverified
  address replaces that account (one locked transaction), and verifying invalidates everything
  created before the link was issued. Wiping every credential on verification was rejected because
  it would delete the real owner's own sign-up passkey.
- **Passkey first** on the sign-in screen, Google beneath, email + password below a divider.
- **CPF is never "verified" in v1** (nothing can verify it yet), so Prince withdrawals stay blocked;
  Prince owns its withdrawal rule.
- **Refresh-token reuse leeway: 10 seconds,** set explicitly instead of OpenIddict's 30-second
  default; a replay from a different client is treated as theft.
- **Breached-password check fails open** when the service is unavailable — the only fail-open on a
  security path — because it's a blocklist, not an authenticator; the skip is logged, counted and
  re-checked at the next sign-in.
- **Revocation write order:** database (with an outbox row) → Redis → reply; a reconciler re-applies
  within ~5 s and Redis is rebuilt from the database after a restart. A 503 "try again" on sign-out
  when Redis is down is acceptable.
- **Step-up window: 5 minutes,** a fresh sign-in counts.
- **New-device sign-in mail** is mandatory in v1.
- **Screens:** neutral Elysium look showing the product's name and logo; pt-BR first, English later;
  "Not now" allowed on activation.
- **Google testing:** a fake OpenID provider in the local stack (refused outside Development) plus
  one manual run against real Google.
- **Admin session termination** exists in production (ASVS 7.4.5); the wider debug view is
  development-only.
- **Scale:** small in v1, one instance per service.

## 2026-11-12 — Refresh reuse, device binding and session limit

A check of OpenIddict 7.8's source showed that inside the reuse leeway it mints a second, independent
token pair, so a stolen refresh token replayed within the window would fork the session without
ever being detected. Options were to accept that (A), build "return the already-issued successor"
ourselves (B), or allow no reuse at all (C). **Chose B**, the closest to industry practice; C was
simpler but signs people out whenever a refresh response is lost.

Sessions are bound to their device: a request from a different device ends the session; a major
network or location change on the same device asks for re-authentication (hard IP binding would
sign out mobile and VPN users). A limit of 2 active sessions per account was
considered and then dropped the same day (see the next entries).

## 2026-11-12 — DPoP not in v1

Sender-constrained tokens were checked as protection against a token stolen and replayed elsewhere.
OpenIddict has no DPoP support (server, client or validation) and its maintainer has no plans for
it; .NET 10's JwtBearer has none either. Building it would cost 2–3 weeks plus a per-request
signature check and replay-cache write at Keeper, to protect tokens that in v1 live only inside
server-side product backends, already covered by short lifetimes, immediate revocation, client
authentication and reuse detection. Revisit when a client that can't keep a secret (a native mobile
app) arrives; mutual TLS is OpenIddict's supported route if binding is needed between our servers.

## 2026-11-12 — No session limit; an account manager instead

The PO replaced the 2-session limit with an **account manager**: every active session is listed
with its device, place, creation time and last activity, and can be ended individually or all at
once, alongside connected products, sign-in methods and personal data — the model large account
providers use. Limiting sessions mostly inconvenienced legitimate people (work PC, phone, a third
place) while visibility plus one-click sign-out, device binding and new-device emails address the
actual risk.

## 2026-11-12 — Logical data model

Designed in a team review (data, architecture, security, testing); the PO accepted the
recommendations. Details in `design.md`, section 7. The calls that weren't obvious:

- **Alongside Identity, not inheriting it.** Identity keeps credential material; our `accounts`
  shares its id. Making the domain's Account the Identity user would need custom stores for
  passwords, passkeys and external logins, and would put library types in the domain.
- **Last-method rule twice:** the aggregate under a row lock is the rule; a deferred trigger is a
  tested safety net, so a future code path or script can't break it silently.
- **Ids from the application,** `sid` as UUID v4 and everything else v7, because Postgres 17 has no
  built-in v7 and several ids are needed before commit; a conscious exception to Prince's
  database-generated ids.
- **Encryption scope:** phone, birth date, address and CPF encrypted per column; name and email
  readable (email is the login key). Encryption protects a stolen dump or backup, which access
  control doesn't. Decryption happens only inside Masquerade.
- **One account per CPF,** via a keyed hash with a unique index.
- **Audit:** 12 months, monthly partitions, append-only, no foreign key so it survives deletion,
  truncated IP plus a 90-day keyed hash; raw IPs never stored.
- **Ended sessions kept 7 days;** session history comes from the audit log.
- **Operators** are Masquerade accounts with a role, passkey required, first one created by a
  one-time setup command. Disabling is reversible, with reason and operator recorded.

## 2026-11-12 — Who can see and change personal data

The owner sees their own data in the account manager, decrypted by Masquerade (never in the
browser, which would mean shipping keys to it). Name, phone and address are editable directly;
email only through the email-change flow (re-authentication, confirmation, 7-day revert); **CPF and
birth date are set once and then read-only**, corrected only by an operator, because CPF ties to
payouts and a self-service change would be a fraud path. CPF is shown masked, revealed after
re-authentication, so a glance at an unlocked screen or a hijacked session doesn't expose it.

## 2026-11-12 — Endpoints

Designed in a team review (architecture, security, testing, product backend); details in
`design.md`, section 8. The calls that weren't obvious:

- **One door for personal data:** products read it only through `/v1/profile` behind Keeper, so
  every read gets the revocation check. OpenIddict's userinfo would validate tokens itself, blind to
  the revocation store; it stays off (a minimal Keeper-only userinfo only if conformance needs it).
- **Introspection and token revocation off:** both would be second paths around the revocation
  check or the revocation order.
- **Signing out of a product signs the device out of Elysium,** since per-product sign-out isn't in
  v1; the button says so.
- **Operator command-line tool is a thin client** of the operator pages, with the same passkey and
  step-up. A break-glass mode running directly on the server was rejected as a second privilege path
  that skips passkeys — and when Redis is down, Keeper already blocks all traffic. A help-desk /
  back-office process for account problems (like a large provider's support) is a later topic.
- **No network allowlist for operator pages** — for a portfolio project it would only be exercised
  by adding and removing it by hand; passkey plus step-up per action is the protection.
- **Client secrets for product backends in v1;** signed-key client authentication later.
- **`prompt=none` (silent sign-in checks) unsupported in v1.**
- **Manual checks:** screens for user flows, `.http` files for protocol and operator calls; a
  Postman collection and API documentation later.
- **Screen technology** (Razor Pages vs Blazor) and one shared look across every UI — Masquerade and
  the products — are being decided next.

## 2026-11-12 — Screen technology, look and preferences

- **Razor Pages** for Masquerade (team review, unanimous). Blazor static rendering adds a framework
  script for nothing these form screens need; interactive Blazor and WebAssembly conflict with the
  security and endpoint decisions (section 9.1).
- **Plain token CSS, no component library, on Masquerade's pages** — the PO's reason: avoid script
  injection. Only our own two scripts run where credentials are typed.
- **Material 3 wherever possible** across every UI, through one design-token source; Prince moves to
  Vuetify 4; a Material 3 React library is chosen after a short evaluation.
- **Dark theme first** (the PO's preference), light second.
- **"Same look" means as close as possible** — inputs, text size, spacing — not just the same palette.
- **World of Darkness palette** (dark blues, blood reds, purples), accessible in both themes; the error
  colour is distinct from the brand red and errors always carry an icon and text.
- **Internationalisation for every project** (PO requirement): catalogues per language, locale
  formatting.
- **Account preferences follow the person:** theme, language and later a colour-vision mode, stored in
  Masquerade and applied by every product.

## 2026-11-12 — Screens, palette and typography

Designed in a team review (design, frontend, security, testing) and checked by the PO in a
rendered preview of both themes.
- **Palette approved** (both themes), including the **amber-coral error colour** — deliberately not
  red, so errors never look like the brand. Contrast verified independently: every text and
  control-edge pair passes WCAG 2.2 AA.
- **First visit follows the device's light/dark setting** (dark if none), replacing "always dark":
  it costs nothing in CSS and respects the person's setting.
- **Cinzel for titles, Inter for body text,** bundled.
- **Logos are local files versioned with the frontend that shows them;** Masquerade's mark is the
  Elysium logo, and the product logos it shows are committed copies beside each product's
  registration — no upload feature, nothing fetched from a product.
- **Operator pages are exempt from mobile layouts.**
- **Operators appear as "Elysium support"** in a person's activity; the audit log keeps the
  operator's id.
- **WCAG AA** is the bar; **"same look" is checked on numbers plus component screenshots,** with
  baselines signed off by the PO.

## 2026-11-12 — Revocation store, threat model and zero trust

Designed in two team reviews (reliability; security, architecture and testing). Details in
`design.md`, sections 10 and 11. The calls that weren't obvious:

- **Fail closed means "try again", never "signed out":** if the revocation store is unavailable,
  Keeper answers 503; a 401 would sign everyone out of every product. A full outage while Redis is
  down is accepted for v1, and **removing single points of failure is on the roadmap** (PO: no single
  component should be able to break every application).
- **A global cutoff key** (`rev:g`) ends everyone's sessions in one write — for operators, for tests,
  and for simulating a breach.
- **Two Redis instances, revocation and rate limiting,** so a flood of attacker-chosen rate-limit
  keys can never evict revocations.
- **Cutoffs only move forward** and Keeper compares only Masquerade-issued times, so retries and
  clock differences can't un-revoke.
- **Keeper's clock tolerance is 30 seconds;** .NET's 5-minute default would stretch 10-minute tokens
  to 15.
- **TLS between every service in production;** the local stack runs without TLS but with passwords
  and access control.
- **Quarterly signing-key rotation; the ZAP scan is a release gate; hostile test inputs exist only
  in development.**
- **Alert recipients live in Elysium's root `.env`;** the public repository's example has none, so
  clones only log alerts.
- **Critical dependency advisories are never applied automatically** — the PO handles them.
- **Zero trust is the direction:** segmented networks, every service validating tokens itself, no
  network-location trust in code (written as production code, as if behind a breached VPN), and TLS
  everywhere, adopted now; service identities with the first service-to-service call; a service
  mesh and network policies in a later Kubernetes phase.
