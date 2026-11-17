# Environments design

How Elysium runs as two isolated environments on one machine, production and development, and the
names later work must keep. This is the record the Environments tickets cite
(`ROADMAP.md`, "Environments"); it narrows `Docs/platform-design.md` §17 (layout), §18 (hostnames)
and §20 (zero trust) for local running and does not replace them. Where this record is stricter than
those sections it says so.

Status: **Decided** by the PO (2026-11-13 to 2026-11-17; epic #62). Production is local-only, probably
for good; TLS and real-domain naming are deferred.

## 1. Stacks and isolation

**Decision.** There are two full stacks, one Compose project each: `elysium-prod` and `elysium-dev`.
The project names are fixed in the Compose files (`name:`), never derived from the folder name, and
service names stay unchanged between the two. Which files define the two
projects is left to the prod/dev stacks ticket (#76); `docker-compose.prod.yml` keeps meaning the
list of production image pins.

**Why.** One project per environment gives each its own containers, networks and volumes by
construction, so "dev can't touch prod" is a property of Compose, not of a naming habit. Fixed names
make the project name the same on every machine and in every script.

**Never shared between the two stacks:**
- data stores and their volumes (Postgres, Silo, and later Redis and RabbitMQ);
- secrets and credentials (every password, key and secret has a separate value per environment);
- token issuers and signing keys (each environment has its own `iss`, `aud` and keys);
- networks other than the edge network (section 3);
- images' tags: development and production run different tags (section 5).

**Never in development:** production data. Development starts empty or from fixtures.

**What happens when something is down (#69-AC1.6).**
- One stack down: its hostnames answer `502` from the edge proxy; the other stack keeps answering
  `200`. Stopping dev leaves production answering.
- The edge proxy down: both stacks are unreachable from the browser. Accepted locally: the proxy is
  the only entry point, and restarting it restores both.

**A compromised dev stack gives nothing in production (#69-AC1.8).** There is no shared credential,
key, Redis, RabbitMQ, Postgres or Silo, and the edge proxy never joins a data-store network
(section 3). A token issued by dev is rejected by production: production checks `iss` and `aud`
against its own values (`Docs/platform-design.md` §20: every service validates tokens itself).

**Production is the default (#69-AC1.9).** When the environment setting is unset (`ASPNETCORE_ENVIRONMENT`, its own variable per
environment, and likewise `ENVIRONMENT_NAME`), a service behaves as production. `Development`
behaviour (developer error pages, relaxed settings) only ever runs behind loopback, on the dev stack.

## 2. Hostnames

**Decision.** Production uses `<app>.localhost`; development uses `<app>.dev.localhost` (one extra
label, so one wildcard covers proxy, certificate and cookies). The same rule applies to every app.

| Production | Development | Serves |
|---|---|---|
| `prince.localhost` | `prince.dev.localhost` | Prince's frontends |
| `accounts.localhost` | `accounts.dev.localhost` | Masquerade's screens |
| `api.localhost` | `api.dev.localhost` | Keeper, in front of every API |

**Why.** Browsers resolve `*.localhost`, including nested names, to loopback without setup, so no
`hosts` file is needed (the edge/hostname spike, #68, checks `prince.dev.localhost` on `127.0.0.1`
and `[::1]`). Cookies are host-only (no `Domain=` attribute) so a dev cookie is never sent to
production and the other way round. Frontends are host-relative and hard-code nothing to
`localhost:8080`.

This narrows `Docs/platform-design.md` §18, which lists the production names only; the dev names are
added here. Masquerade and Keeper adopt the names with #27 (section 9); Prince gets its two now.

## 3. Edge proxy

**Decision.** One edge proxy, the only piece shared between the environments. It lives in its own
folder outside `Prince/` (`Edge/`, the location in the approved spec of #75), owns the host ports, and each stack's entry proxy joins the
external Docker network `elysium-edge`; stacks publish no host ports of their own.

- It binds `127.0.0.1` and `[::1]` explicitly, never `0.0.0.0` or `::`.
- It routes by `Host` with a per-environment allow-list: a production hostname reaches only the
  production stack, a development hostname only the development stack, and any other `Host` is
  refused. Host-header handling is specified by the edge ticket (#75).
- It reaches each stack through that stack's entry proxy, on a per-environment alias on
  `elysium-edge` (`<app>-<env>-proxy`, section 9).
- It never joins a data-store network.
- Its access log never records query strings, `Authorization` or `Cookie`; this rule is specified in
  the edge ticket (#75) and cited here.

**Why.** One loopback-only entry point is one place to harden and one place to look. Because it is
the only shared piece and sees no data store, the blast radius of a bug in it is a refused or
misrouted request, not a data leak. This agrees with `Docs/platform-design.md` §20 (segmented
networks, no network-location trust): the proxy is a perimeter, and every service still validates
tokens itself.

## 4. Configuration

**Decision.** Everything that differs per environment is a variable, read from one untracked env file
per environment: `.env.prod` and `.env.dev`. The examples (`.env.prod.example`, `.env.dev.example`)
are committed with safe local defaults. **No value is shared between the two files**: every password,
secret and key is different, and the example files say so.

Keys are platform-named (`ENVIRONMENT_NAME`, `PUBLIC_HOST`, `PUBLIC_URL`, `POSTGRES_PASSWORD`,
`SILO_ROOT_PASSWORD`, the image tag or digest); per-app keys are prefixed (`PRINCE_`).
`ASPNETCORE_ENVIRONMENT` is its own variable per environment, not derived from another key; when it is unset a service behaves as production. A missing or malformed key is refused by `env-check`
before any container starts.

**Why.** One file per environment makes "which values does this stack run with" one answer, and
keeping secrets in untracked files follows `CLAUDE.md` (secrets live in untracked `.env` files).

## 5. Images and updates

**Decision.**
- **Development** runs the development images, `ghcr.io/rodgallert/elysium-<service>-<component>:main`,
  built on every merge into `main` (`Docs/workflow.md`, "Development images"). It is updated by a
  command (`make dev-update`); automatic polling is not part of this epic.
- **Production** runs exactly the pins in `docker-compose.prod.yml` (tag plus digest, written by CI),
  the list of what is in production (`Docs/workflow.md`, "Releases"). It is updated by
  `make prod-update`, which verifies the attestation of every pinned image of ours before `up -d`
  (#91).

**Why.** Production changes only through a release PR that a person merges; development follows
`main` so a merged change can be seen running.

## 6. Runtime baseline

**Decision.** Every service of both stacks meets this baseline, enforced by the compose baseline
ticket (#78) as a lint on the output of `docker compose config`:

- `security_opt: [no-new-privileges:true]`;
- `cap_drop: [ALL]`, with the add-backs listed per service;
- a non-root user;
- `read_only: true` where the smoke test passes (writable paths as `tmpfs` or volumes);
- `pids_limit` set;
- no Docker socket mounted;
- published ports bind a host address (`127.0.0.1` and `[::1]`), and only the edge proxy publishes.

**Documented relaxation: no `mem_limit` yet.** `pids_limit` is set now. `mem_limit` keys are
**absent** until measured; the memory-limits ticket (#81) sets each at twice the measured peak. The
lint records their absence as a documented relaxation, not an omission, and the relaxation is removed
when #81 merges.

**Why.** A limit set before measuring is a guess that kills a healthy container; a fork bomb needs no
measurement to stop.

## 7. Reliability budgets

Measured on the PO's machine and checked by the end-of-sprint manual check; numbers are the sprint
plan's (2026-11-17).

| Budget | Value |
|---|---|
| Memory per Prince stack | 450 MiB |
| Two stacks plus the edge proxy, idle | under 1 GiB |
| Cold `up --wait` per stack | 45 s |
| Both stacks plus the edge proxy, cold | 60 s |

## 8. Shared-service reference counting

Status: **designed now, built later.** The per-app `up` ticket (#77) ships the label parser (tested)
and a no-op reference-count hook. The real implementation (locking, concurrency) is **blocked on the
first shared-service compose**, the ticket that adds the first shared service (Phase 1) as a Compose
file of its own; that ticket's Done-when is the acceptance list at the end of this section.

**Why.** Shared services (accounts, ledger, files) are used by several apps, so starting an app must
start what it needs and stopping an app must stop a shared service only when nobody else needs it.

### 8.1 The label

(a) Key `elysium.needs`. Value: a comma-separated list of shared-service names. Each name matches
`^[a-z][a-z0-9-]{0,62}$` (1 to 63 characters), at most 32 items, at most 1024 bytes in total. An
absent label means "needs nothing".

| Limit | Accepted edge | Rejected edge |
|---|---|---|
| Items | 32 | 33 |
| Name length | 63 characters | 64 characters |
| Total size | 1024 bytes | 1025 bytes |

### 8.2 The parse rule

(b) These are a **hard parse failure**: non-zero exit and a one-line message naming the problem and
the offending value; never silently dropped or corrected:

an empty value; an empty item (`a,,b`); a trailing or leading comma; whitespace anywhere; an
uppercase letter; a duplicate item; a non-ASCII character; a value over the limits above.

Parser test cases (the exact inputs; every one fails except the rows marked accepted):

| Input | Outcome | Reason |
|---|---|---|
| (label absent) | accepted: needs nothing | absent label |
| `a` | accepted: `[a]` | valid |
| `a,b` | accepted: `[a, b]` | valid |
| a 32-item list of valid names | accepted | accepted edge |
| a name of 63 characters | accepted | accepted edge |
| a 1024-byte value of valid names | accepted | accepted edge |
| `""` | fails | empty value |
| `a,` | fails | trailing comma (empty item) |
| `,a` | fails | leading comma (empty item) |
| `a,,b` | fails | empty item |
| `a, b` | fails | whitespace |
| `A` | fails | uppercase letter |
| `a,a` | fails | duplicate item |
| `é` | fails | non-ASCII character |
| a 33-item list (`a1,a2,...,a33`) | fails | over 32 items |
| a name of 64 characters | fails | over 63 characters |
| a 1025-byte value of otherwise valid names | fails | over 1024 bytes |
| `a;rm` | fails | `;` is outside the name pattern |

The parser must not use `flock` (see 8.4) and does not depend on a shell: it reads the value as data.

### 8.3 Who sets it

(c) Only the Compose file sets `elysium.needs`. The parser's input comes from `docker inspect` and is
treated as **untrusted** input: it is validated by 8.2 like any other, and a container cannot
influence its own label (labels are fixed at creation; the container has no Docker socket).

### 8.4 The lock

(d) `flock` on a file descriptor of a lock file, never on a pid file, so a SIGKILL leaves no stale
lock (the kernel releases the lock when the process dies). Every `up` and `down` of an app that
touches a shared service acquires it, with a **30 s timeout**, after which the command fails
non-zero, so a hung `up` can't block `down` forever. A lock timeout names the lock path in one line.

`flock` is util-linux: it is absent on macOS and behaves differently under busybox. The lock code
states this Linux-only assumption, and the label parser does not use `flock`, so it can be tested
anywhere.

### 8.5 The stop rule

(e) `down` of an app stops a shared service only when, **under the lock**, no other running
container in any project lists it in `elysium.needs`. A shared service nobody needs (left behind by a
crash between reading the labels and stopping) is stopped by the next `down`.

### 8.6 Failure behaviour

(f) An unknown service name in `elysium.needs` fails loudly **before anything starts**. A second
`down` and a second `up` exit 0 and change nothing. After a failed `up` (including a partial start),
`down` still works and leaves nothing behind. Parse failures and lock timeouts name the offending
value or the lock path in one line; no secrets or personal data are involved.

### 8.7 Acceptance list for the first shared-service compose

This list is the Done-when of "the first shared-service compose". Every entry must pass there.

1. **R1** app A up starts the shared service.
2. **R2** app B up (same need) starts nothing more.
3. **R3** A down keeps the shared service.
4. **R4** B down removes it.
5. **R5** a second `down` of either app exits 0 and changes nothing.
6. **R6** two concurrent `up` start the shared service once.
7. **R7** an `up` killed with SIGKILL leaves no stale lock.
8. **R8** an unknown service name in `elysium.needs` fails loudly before anything starts.
9. **R9** a crash between the label read and the stop leaves an ownerless service that the next `down` reaps.
10. **R10** every malformed value in 8.2's table (every row marked "fails") fails the parser.

## 9. Names that must survive #27

Ticket #27 (the root `docker-compose.yml` and hostnames) must not contradict these. Each name is
either **fixed now** (#27 keeps it) or **may change with #27** (#27 may change it deliberately, with a
breaking-change note in its issue and PR, `Docs/workflow.md`, "Breaking changes"). Today every row is
fixed; the second category is kept for names added later.

| Name | Status | Note |
|---|---|---|
| Compose project names `elysium-prod`, `elysium-dev` | fixed now | set with `name:` in the Compose files, never derived from the folder name |
| External network `elysium-edge` | fixed now | |
| Edge alias `<app>-<env>-proxy`, for example `prince-prod-proxy` | fixed now | one per app and environment |
| Env files `.env.prod`, `.env.dev` | fixed now | examples committed |
| Hostnames in section 2 | fixed now | #27 adopts them for Masquerade and Keeper |
| Label `elysium.needs` | fixed now | format in section 8 |
| Image names `elysium-<service>-<component>` | fixed now | today's names (the table in `Docs/workflow.md`, "Development images") stay byte for byte when #27 adds the root compose file. `tools/list-images.sh`, `tools/release-parts.sh` and `tools/check-prod-pins.sh` are extended to produce them from a root file (service = the first folder of each build context; an `include:`d service counts once; today `list-images.sh` refuses a root file). A rename is out of scope for #27: it would be its own breaking change and would redo the make-public-and-link step for each package |
| Prince's Compose service names: `core-api`, `checkout-api`, `jobs-api`, `core-web-vue`, `checkout-web-vue`, `core-web-react`, `checkout-web-react`, `postgres`, `file-storage`, `file-storage-init`, `env-check`, `reverse-proxy` | fixed now | the image name's `<component>` is the Compose service name, so a rename breaks the pins in `docker-compose.prod.yml`. To rename one, first decouple the image name from the service name and keep the image names |

## 10. Test debt moved out

These are not tested in the Environments phase. Each is written as skipped cases that name their
precondition, and recorded in the "Moved out" paragraph of the Environments phase in `ROADMAP.md` (the Phase 1 section gets its own entry with the Phase 1 tickets):

- token rejected across environments (a dev token gets `401` from production), CORS and sign-in
  isolation: **Phase 1** test debt; the precondition is a running Masquerade with sign-in, which
  doesn't exist yet;
- `/ready` endpoints and the Prince carry-over list: the **Prince design sprint**;
- the real reference counting (section 8): the **first shared-service compose**.
