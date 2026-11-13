# Branching, release and review workflow

Elysium uses **trunk-based development with per-service releases**. `main` holds everything that's done and is always buildable; every piece of work happens on its own short-lived branch and squash-merges into `main`. Each service is released on its own, and one file, `docker-compose.prod.yml`, lists the released version of every service.

```
main                              trunk: every finished ticket; publishes the development version
├─ feat/p2-password-sign-in       one ticket = one task, squash-merged into main
└─ release/masquerade-0.1         only when a released version needs a hotfix after main moved on
```

## Two published versions

| Version | What it is | Where it comes from | Images |
|---|---|---|---|
| **Development** | Every service at the latest `main` | Every merge into `main` builds and publishes every image (see Development images) | `ghcr.io/rodgallert/elysium-<service>-<component>:main` and `:main-<short sha>` |
| **Production** | Every service at its released version | `docker-compose.prod.yml`, which pins each service's image to a version | `ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>` |

- **`docker-compose.prod.yml` is the list of what's in production.** Reading it answers "which version of each service is released"; its history is the release history. Nobody needs to browse tags to find out.
- `docker-compose.yml` runs the development version (built from source locally).
- Git tags (`<service>-v<x.y.z>`) exist so every release points at an exact commit, but **CI creates them**, never a person (see Releases).

## Development images

The `publish` job in `.github/workflows/build.yml` publishes the development version. It runs on every push to `main` that changes more than Markdown, after the boundary check, every build and every test have passed, and never on pull requests or manual runs.

- **What it builds:** every Compose service with a `build` section in a service's `docker-compose.yml` is one image. `tools/list-images.sh` reads the list, with each image's build context and Dockerfile, so a new image only needs its Compose service. Every build fails when a Dockerfile in the repo is built by no Compose service. Every image is built on every merge for now; building only what changed comes later, once build timings are known, because a wrong path filter leaves `:main` stale.
- **Names:** flat, one package per image: `ghcr.io/rodgallert/elysium-<service>-<component>`, where `<service>` is the service's folder and `<component>` its Compose service name, in lower case. Prince today:

  | Image | Built from |
  |---|---|
  | `elysium-prince-core-api` | `Prince/Backend/Core/Dockerfile` |
  | `elysium-prince-checkout-api` | `Prince/Backend/Checkout/Dockerfile` |
  | `elysium-prince-jobs-api` | `Prince/Backend/Jobs/Dockerfile` |
  | `elysium-prince-core-web-vue` | `Prince/Frontend/prince-core-vue` |
  | `elysium-prince-checkout-web-vue` | `Prince/Frontend/prince-checkout-vue` |
  | `elysium-prince-core-web-react` | `Prince/Frontend/prince-core-react` |
  | `elysium-prince-checkout-web-react` | `Prince/Frontend/prince-checkout-react` |
  | `elysium-prince-reverse-proxy` | `Prince/reverse-proxy` |

- **Tags:** `:main` moves with every merge; `:main-<short sha>` (7 characters of the merge commit) never moves, for rolling back and for pinning a test to one build.
- **Provenance:** each image carries the OCI labels linking it to this repository (`org.opencontainers.image.source`, `.revision`) and a signed build-provenance attestation, checked with `gh attestation verify oci://ghcr.io/rodgallert/<image>:main -R rodgallert/Elysium`.
- **Permissions:** only the `publish` job can write packages (`packages: write`, plus `id-token: write` and `attestations: write` for the attestation); it logs in to GHCR with the workflow's own `GITHUB_TOKEN`. Every other job is read-only.
- **Who can publish:** the job's condition only keeps ordinary runs from publishing; it is not the security boundary. A pull request from a fork gets a read-only token and no secrets, so it can't publish. A pull request from a branch in this repository runs that branch's own `build.yml`, so whoever can push a branch here can change the workflow and give a run `packages: write`, which is enough to overwrite `:main`. The real boundary is write access to the repository plus review of every change under `.github/workflows/`: a PR that touches a workflow gets a reviewer who reads that diff for permission and trigger changes before it merges.
- **Re-running:** only re-run the latest run on `main`. Re-running an older run's `publish` job pushes that older commit as `:main` again, which moves development back.
- **One-time step for each new image (PO):** the first publish of an image creates its package as private. In the package's settings on GitHub (profile, Packages, the package, Package settings): check that it is linked to `rodgallert/Elysium` (the `source` label links it; if not, "Connect repository"), and under "Danger Zone" change the visibility to **Public**. Until then, pulling it needs a login.

## Branches

| Branch | Created from | Merges into | Merge type | Lives until |
|---|---|---|---|---|
| `main` | | | | always |
| Ticket: `<type>/p<n>-<slug>` for roadmap tasks (e.g. `feat/p2-password-sign-in`), `<type>/<slug>` for other work (e.g. `ci/publish-images`) | `main` | `main` | squash | merged |
| Release: `release/<service>-<x.y>` | the service's release tag | itself (hotfix PRs merge into it) | squash | the minor version is no longer in production |

- **Nobody commits directly to `main`.** It only receives squash merges of reviewed PRs. All commits happen on ticket and hotfix branches.
- `main` is never the head (source) of a pull request.
- Branches are deleted automatically when their PR merges (repo setting). A branch is never reused after it merges: start a new ticket instead.
- **Unfinished features** that land on `main` stay switched off behind a configuration flag, because `main` is always the published development version.

## Issues, epics and milestones

- **A ticket is one task from `ROADMAP.md`**: one checkbox, or a checkbox plus its sub-items when they only make sense together. Work that isn't a roadmap task (CI, tooling, workflow docs) is a ticket too, under the "Workflow and tooling" epic. The branch type is the Conventional Commit type of the work (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`).
- **Every ticket has a GitHub issue** (label `ticket`), grouped under an **epic** issue per phase. **Milestones are per-service releases** (e.g. "Masquerade v0.1"); a ticket belongs to the milestone of the service release it ships in. A ticket's PR description says `Closes #<issue>` for each task it completes; merges into `main` close them automatically.
- The milestone table in `ROADMAP.md` decides which phases and tickets belong to which service release.

## Commits: Conventional Commits

```
<type>(<scope>): <summary in the imperative, lower case, no full stop>

<optional body: what and why>
```

- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `build`.
- Scope: the service or area, e.g. `masquerade`, `keeper`, `harpy`, `prince`, `prince-web`, `docs`, `ci`, `compose`. Each service's changelog is built from the commits with its scope.
- A breaking change adds `!` after the scope (`feat(masquerade)!: ...`) and a `BREAKING CHANGE:` line in the body (see Breaking changes below).
- Example: `feat(masquerade): sign in with email and password`

## Breaking changes

A change is breaking when it does either of these:
- **Forces someone who depends on a service to change.** For example: an HTTP endpoint, field or status code is removed, renamed or changes meaning; a message contract (command or event) changes incompatibly; token claims or their meaning change; a database migration drops or rewrites data in a way that can't be undone; a configuration key or environment variable is renamed or removed; a login method or permission is removed or locked behind something new.
- **Rewrites code that a finished scenario relies on.** When code is rewritten that's used by a feature already considered done (its phase checkpoint passed, or a release shipped), the change is breaking even if nothing should look different, because that finished behaviour has to be re-verified.

Build, CI and workflow changes are not breaking by themselves.

A breaking change is flagged in **both** places people look:
- **The issue** gets a "Breaking change" note as soon as it's known, ideally when the work starts.
- **The pull request** gets a "## Breaking change" section.

Both say what can break and what consumers need to do (move to the new endpoint version, release two services together, re-run a migration, re-authenticate) or which finished scenarios must be tested again. The PR title and the commit carry the `!` marker and a `BREAKING CHANGE:` line, so they're easy to find when the release is written up. A breaking change bumps the service's **major** version at its next release (minor while the service is below 1.0).

**Versioned contracts soften breaks:** a new API version (`/v2/...`) or message version next to the old one, kept until no consumer uses the old one, is not breaking. Removing the old one later is.

## Merges

Every merge is a GitHub pull request, and every merge is a **squash**: one commit per PR, so `main` reads as a list of finished tasks and releases. The commit title is the PR title and the body is the PR description:
- **The PR title follows Conventional Commits**: a ticket's change (`feat(masquerade): sign in with email and password`), a release (`chore(release): masquerade 0.1.0`), a hotfix (`fix(masquerade): …`).
- **The PR description** lists what changed and the review results (see Reviews). It becomes the commit body, so keep it current after every fix commit.
- After a merge on GitHub, update the local `main` (`git pull`) before starting the next piece of work from it.
- If `main` moved on and a PR conflicts, merge `origin/main` into the ticket branch (a normal merge; no rebase, no force-push).

## Phases

A phase has no branch: its tickets merge into `main` like any other. A phase is its **epic** on the project board, plus a **checkpoint** when its last ticket is done:
1. Review the phase as a whole: everything that changed in `main` since the previous checkpoint tag, against the phase's roadmap section.
2. The PO checks the phase's **Done when** on a running stack (`docker compose up`), on a specific `main` commit. Note that commit's hash when asking for the check, because `main` keeps moving.
3. Tag **the commit that was checked** `phase-<n>-done` (an annotated tag) and close the epic.

## Reviews

Every pull request is reviewed before it merges. The checks get wider at each level:

| What | Build and checks | Code review | Roadmap check | Manual check |
|---|---|---|---|---|
| Ticket → `main` | Every changed .NET solution builds with 0 errors and its tests pass; every changed frontend builds and lints; `tools/check-boundaries.sh` passes; the PR's GitHub Actions build is green | Reviewed by someone other than the author, following the review checklist (`.claude/skills/pr-review/SKILL.md`). **Security review as well** when the change touches authentication, sessions, tokens, cryptography, permissions or personal data | The ticket does what its roadmap task says, with the rules in `ROADMAP.md` and the design docs. Rules changed in code are changed in the docs too. The task's checkbox is ticked | When the task changes behaviour: what the PO can try on the running stack (requests, screens) and what to expect |
| Phase checkpoint | Same, on `main` | Reviewed by someone other than the author: everything the phase changed. Performance and security review of the phase | Every task in the phase is ticked, and the phase's **Done when** is met | Required: the phase's **Done when** |
| Release → `main` | Same, on the release PR's head | Release-level review of the service: everything it gained since its last release | Everything listed for the milestone is in; version, changelog and the production pin agree | Required: the service's smoke test, security pass and performance pass (release step 2), with the results in the PR |
| Hotfix → `release/<service>-<x.y>` | Same, on the hotfix branch | Release-level review of the fix | Version and changelog updated; the same fix is on `main` | The fix checked on the running stack |

A ticket that only changes docs skips the build, the boundary check and the code review. Its review is a read-through checking that it agrees with the roadmap and the other docs. The GitHub Actions build doesn't run on Markdown-only changes, so such a PR shows no build check and none is required.

The review results go in the PR description. A review that finds problems sends the work back to the ticket (fix it on the same branch before merging, or open a new `fix/` ticket after). The merge only happens once the review is clean **and the PO has approved it**.

**Ready to merge** means all of these, checked right before saying so: nobody is still working on the PR, the PR's head on GitHub equals the branch tip, CI is green on that commit, and the description has been re-read.

## Before you open a PR

Check these on your own branch first; the review checks them again. Items that don't apply to the change can be skipped.

- [ ] **Tests:** new rules have unit tests; new endpoints, handlers and migrations have integration tests against a real Postgres/RabbitMQ (containers), not mocks of them.
- [ ] **Failure paths:** what happens when the database, the broker, Redis or another service is down or slow is handled and tested, not only the happy path.
- [ ] **Security:** no secrets in tracked files; no passwords, tokens or personal data in logs or error messages; input validated at the boundary; authentication and authorisation changes follow the OWASP rules in `Docs/platform-design.md`.
- [ ] **Contracts:** API and message changes are additive, or versioned, or flagged as breaking.
- [ ] **Messaging:** published messages go through the outbox; handlers are idempotent.
- [ ] **Migrations:** apply cleanly to an empty database and to the current one; anything that drops or rewrites data is flagged as breaking.
- [ ] **Unfinished features** are behind a flag that is off by default.
- [ ] **Decisions recorded:** any decision the ticket needed (a number, a rule, a choice between options) is written on the issue and in the relevant decision log before it closes, not only in the PR.
- [ ] **Deferred work tracked:** work you chose not to do in this PR is a task in `ROADMAP.md` or a GitHub issue, not a comment in the code.

## Releases (per service)

A service is released when its milestone's tickets are on `main` and its phase checkpoint (if any) has passed:
1. **Release ticket and PR** (`chore/release-<service>-<x.y.z>` → `main`, title `chore(release): <service> <x.y.z>`), changing three things together:
   - the service's version (its project file);
   - its `CHANGELOG.md` (in the service's folder): the "Unreleased" entries move under the new version, with a "Breaking changes" heading (every breaking change since its last release, with what can break and what to do, or "None") and a "Known issues" line;
   - its pinned image version in `docker-compose.prod.yml`.
2. **Smoke test, security pass and performance pass** for that service, on the release PR's head: a clean `docker compose up` with every shipped **Done when** of the service once; the security checklist for what the release touches; response times and resource use against the roadmap's budgets. Anything found is fixed by a `fix/` ticket before the release PR merges. The release PR records the results, and it isn't approved without them.
3. **The PO approves and merges** the release PR. That merge is the release.
4. **CI does the rest** from that merge commit: creates the tag `<service>-v<x.y.z>`, builds and publishes the service's images (`ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>`), and creates a GitHub Release with the changelog section. Then close the service's milestone.

Several services can be released in one PR when they must ship together (a coordinated breaking change); each still gets its own version, changelog section and tag.

## Hotfixes

An urgent fix to a released version:
1. Fix it on `main` first, as a normal `fix/` ticket.
2. If `main` holds nothing else for that service since its release, release it normally as a patch version.
3. Otherwise, create `release/<service>-<x.y>` from the service's release tag (once per minor version), cherry-pick the fix onto a `hotfix/<service>-<x.y.z>` branch from it, and open the PR into the release branch with the patch version and changelog entry. CI publishes the image from that merge; then a PR into `main` updates the production pin and the changelog.

## Pushing

The ticket checklist (`.claude/skills/ticket-flow/SKILL.md`) pushes as part of its steps, without asking each time: creating a ticket branch from its issue, creating release and hotfix branches, pushing phase tags, and pushing a working branch's commits while its PR is open. It never force-pushes, and never pushes commits to `main` or a release branch: those only change through merged PRs, and merging is the PO's call. Release tags are created by CI only. GitHub Actions builds every pull request (and pushes to `main` and `release/**`), except changes that only touch Markdown; the result shows on the PR.
