# Branching, release and review workflow

Elysium uses **trunk-based development with per-release-part releases**. `main` holds everything that's done and is always buildable; every piece of work happens on its own short-lived branch and squash-merges into `main`. Each release part (a service, or one of the parts it declares) is released on its own, and one file, `docker-compose.prod.yml`, lists the released version of every part.

```
main                              trunk: every finished ticket; publishes the development version
├─ feat/p2-password-sign-in       one ticket = one task, squash-merged into main
└─ release/masquerade-0.1         only when a released version needs a hotfix after main moved on
```

## Two published versions

| Version | What it is | Where it comes from | Images |
|---|---|---|---|
| **Development** | Every service at the latest `main` | Every merge into `main` builds and publishes every image (see Development images) | `ghcr.io/rodgallert/elysium-<service>-<component>:main` and `:main-<short sha>` |
| **Production** | Every service at its released version | `docker-compose.prod.yml`, which pins each image to a version and digest | `ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>@sha256:<digest>` |

- **`docker-compose.prod.yml` is the list of what's in production.** Reading it answers "which version of each service is released"; its history is the release history. Nobody needs to browse tags to find out.
- `docker-compose.yml` runs the development version (built from source locally).
- Git tags (`<part>-v<x.y.z>`, see Releases) exist so every release points at an exact commit, but **CI creates them**, never a person.

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
| Release: `release/<part>-<x.y>` | the part's release tag | itself (hotfix PRs merge into it) | squash | the minor version is no longer in production |

- **Nobody commits directly to `main`.** It only receives squash merges of reviewed PRs. All commits happen on ticket and hotfix branches.
- `main` is never the head (source) of a pull request.
- Branches are deleted automatically when their PR merges (repo setting). A branch is never reused after it merges: start a new ticket instead.
- **Unfinished features** that land on `main` stay switched off behind a configuration flag, because `main` is always the published development version.

## Issues, epics and milestones

- **A ticket is one task from `ROADMAP.md`**: one checkbox, or a checkbox plus its sub-items when they only make sense together. Work that isn't a roadmap task (CI, tooling, workflow docs) is a ticket too, under the "Workflow and tooling" epic. The branch type is the Conventional Commit type of the work (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`).
- **Every ticket has a GitHub issue** (label `ticket`), grouped under an **epic** issue (see the next bullet). **There is one milestone per release of a release part**, because each part has its own version, tag and GitHub Release (see "Versions and release parts"). A milestone is named after its part and version: "Masquerade v0.1" for a service that is one part, "Prince API v0.1" for one of the parts a service declares. A ticket belongs to the milestone of the part release it ships in. **Work that changes more than one release part is split into one ticket per part**, each in its own part's milestone: an issue has only one milestone, and the split keeps one ticket = one task and each part's milestone and changelog accurate. A ticket's PR description says `Closes #<issue>` for each task it completes; merges into `main` close them automatically.
- **An epic is either a roadmap phase or a standing epic.** A phase epic is one phase of `ROADMAP.md`: it has a checkpoint and a `phase-<n>-done` tag (see "Phases"). A standing epic (for example "Hardening" or "Workflow and tooling") groups ongoing work that isn't a roadmap phase: it never reaches a checkpoint, gets no tag, and closes only when the PO closes it. An epic can span several sprints (see "Sprints").
- The milestone table in `ROADMAP.md` decides which phases and tickets belong to which part release.
- **Every ticket is filed from the issue template** (`.github/ISSUE_TEMPLATE/ticket.md`) and carries its spec (see "Specs and tests"). Its first line is `Epic: #<n>`; the start step adds `Branch: <branch>` and the review step `PR: #<n>` at the end. A ticket's acceptance criteria take the place of a "Done when"; only phases and the roadmap keep a **Done when**.

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

## Specs and tests

Every ticket is specified before it starts and built test-first, with edge cases and failure paths tested, not only the happy path. The rules, in the order a ticket meets them:

1. **Decisions live in tracked documents or in the issue.** Notes that aren't committed (meeting notes, chats, local files) are never the source of a decision. A ticket that relies on a decision not yet written in a tracked document (`Docs/`, `ROADMAP.md`, a service's decision log) or on an issue records it there first, and its spec links to it.
2. **Planning names the edge cases.** Whoever plans tickets (the planning step of a sprint or phase, in the plan's own text) lists each ticket's likely edge cases and production failure modes before the ticket is filed, using the categories in rule 3. They go into its spec.
3. **The spec is the issue body**, from the template `.github/ISSUE_TEMPLATE/ticket.md` (tickets only; epics and releases are filed by hand): goal; context and the decisions relied on (links); numbered acceptance criteria, each testable with exact values; contracts; a test plan table (criterion, level, what it needs); the PO's manual check, with at least one failure-path step; and out of scope. Under **each** criterion sits one line per edge-case category, and the list is the same everywhere (template, this document, the review): inputs, boundaries, state and lifecycle (including out-of-order messages), time, concurrency, partial failure, retries and idempotence, permissions, environment differences, observability. Each category gets a case or `n/a: <reason>`; "covered elsewhere" names the test. The reviewer judges the reasons.
4. **The PO approves the spec before the ticket starts.** Only the PO approves, and agents and the PO share one GitHub account, so an agent records the approval only after the PO has said so in the session, as a comment "Issue last edited <time>" (the body's last edit time, taken from the last edit to a spec section), and then adds an `Approved: <link to that comment>` line to the body; that line is what marks the approval, and adding it needs no new approval. The `Epic:`, `Estimate:`, `Approved:`, `Branch:` and `PR:` lines are bookkeeping, not spec edits: approval covers the spec sections (Goal through Out of scope), and only an edit to those afterwards (a roadmap update at `start` included) needs approval again. A change to the criteria is recorded as a `Spec change:` comment and approved again. An edge case found during the work that falls inside an existing criterion amends the spec this way; new behaviour becomes its own ticket. The approval time and the spec gate are computed by `tools/ticket.sh start`, the only place that does (it reads the body's edit history, never `updatedAt`), and the other bookkeeping steps run through `tools/ticket.sh` too (`file`, `review`, `ready`, `done`; see the `ticket-flow` skill); if it fails, stop and report, never switch accounts. The gate checks consistency (the approval comment is the owner account's, its stated time is not later than the comment itself, and no spec text changed after it), not who approved: the PO and the tooling share one account. Tooling retries a transient failure (a 5xx, a timeout) with a 2 s, 4 s, 8 s backoff, and a rate limit without a readable wait time with 60 s, until the real limits are measured. The review checks that the approval predates the first commit authored on the branch (for a hotfix, a cherry-pick's original date doesn't count) and that no `Spec change:` is missing its approval.
5. **Traceability.** Every criterion and edge case has an id with the ticket number: `#<issue>-AC<n>` and `#<issue>-AC<n>.<m>`, greppable across the repository (search with `grep -F` and a closing delimiter or a non-digit after the id, so `AC2.1` doesn't match `AC2.10`; the issue number replaces the template's `<issue>` placeholders right after the issue is created, before approval). Each test cites the id it covers: xUnit in the method name or `[Trait("Spec", "#64-AC2.1")]`, with a `[Theory]` row or `DisplayName` per case; shell tests in the function name or a comment line; frontend tests in the `describe`/`it` title. The PR description maps every criterion and every listed case to its tests. A criterion or case with no test and no accepted `n/a` is a **blocking** finding.
6. **Contract-first for APIs and messages.** The OpenAPI document or message schema is merged before the handlers that implement it (an earlier commit in the PR, or an earlier PR), with contract tests against it. The order on a branch is: schema, then the failing tests (contract tests included), then the handlers. A contract change follows "Breaking changes" below.
7. **Test-first for code tickets** (the PO asked for TDD). The branch's first commit after the schema adds the tests with the minimal stubs that let them compile, and they fail on an assertion, not on a compile error. Later commits make them pass. For compose, CI and other infrastructure the failing check comes first: a smoke test, lint rule or port check that fails on the old configuration. A bug fix and a hotfix start with a failing test that reproduces the bug. The review reads the order with `git log --reverse --no-merges origin/main..HEAD`, checks out the first test commit, runs the tests and records the failure it saw. CI on the branch will be red until the implementation lands; the `gate` check on the tip is what counts, so don't reorder commits to keep CI green. Commit order can't be repaired afterwards (no force-push, and the squash hides it), so a missed order is a **blocking** finding that only the PO's explicit acknowledgement on the PR lifts.
8. **Failure paths are tested, and the check is per listed case.** A criterion's happy path with some of its listed cases untested is as blocking as a happy-path-only test set, which is the extreme of the same rule.
9. **The review breaks a rule on purpose.** In a scratch worktree the reviewer loosens one rule the change implements (removes a validation, widens a limit, drops a check or a unique constraint; for compose and infrastructure, drops a flag or a host binding) and confirms a test or check fails, then discards the change; it never commits or pushes. A change the tests don't notice means they don't pin the rule: a **blocking** finding. When no rule can be loosened (a visual rule, a CI setting), the review says why and names the check that would catch it.
10. **Exemptions and special cases.**
    - Spikes (timeboxed, nothing merged) and releases need no spec; the PO can exempt another ticket, and the exemption is recorded on the issue.
    - A docs-only ticket has a spec with goal, numbered criteria and out of scope, approved by the PO; its edge-case categories may be `n/a`, and there is no test-first order. The review is a read-through of each criterion.
    - A hotfix has a short spec (goal, the failing behaviour as AC1 with its cases, out of scope), approved in the same comment that asks the PO for the release branch, and the regression test comes first.
    - Tickets filed before these rules aren't exempt: they get a spec and approval before they start.

## Merges

Every merge is a GitHub pull request, and every merge is a **squash**: one commit per PR, so `main` reads as a list of finished tasks and releases. The commit title is the PR title and the body is the PR description:
- **The PR title follows Conventional Commits**: a ticket's change (`feat(masquerade): sign in with email and password`), a release (`chore(release): masquerade 0.1.0`), a hotfix (`fix(masquerade): …`).
- **The PR description** lists what changed and the review results (see Reviews). It becomes the commit body, so keep it current after every fix commit.
- After a merge on GitHub, update the local `main` (`git pull`) before starting the next piece of work from it.
- If `main` moved on, merge `origin/main` into the ticket branch ("Update branch" or a normal merge; no rebase, no force-push): the rulesets require branches to be up to date, so this is needed for every open PR when the base moves, not only on conflicts (see Required check).

## Phases

A phase has no branch: its tickets merge into `main` like any other. A phase is its **epic** (a phase epic; standing epics have no checkpoint) on the project board, plus a **checkpoint** when its last ticket is done:
1. Review the phase as a whole: everything that changed in `main` since the previous checkpoint tag, against the phase's roadmap section.
2. The PO checks the phase's **Done when** on a running stack (`docker compose up`), on a specific `main` commit. Note that commit's hash when asking for the check, because `main` keeps moving.
3. Tag **the commit that was checked** `phase-<n>-done` (an annotated tag) and close the epic.

## Sprints

A sprint is a goal-based commitment of tickets, separate from epics: it can take tickets from several epics, and an epic can span several sprints. Phases, epics and milestones work as described above and don't change.

- **Planning.** A planning meeting sets the sprint's **goal**, its **commitment list** (what the sprint promises) and its **stretch list** (what is done only if the commitment finishes early), and names each ticket's edge cases before the ticket is filed (see "Specs and tests"). It also notes a **soft time box**. The sprint starts on the PO's go, and only then.
- **Sprint issue.** Each sprint has an issue (label `sprint`, filed by hand like epics) holding its goal, commitment, stretch and outcome. It is where the goal, every scope change and the outcome can be read later.
- **Board.** A ticket is in at most one sprint, shown by the board's **Sprint** field (a single-select field with one option per sprint; the sprint is goal-based, so it isn't an Iteration field). Stretch tickets also carry the `stretch` label. A ticket with no Sprint value is in no sprint and shows in neither sprint view. Two views show the current sprint: **Current sprint** (a table) and **Sprint board** (a kanban board grouped by Status). Both are filtered on the current sprint's value (`sprint:"Sprint 1"`). Only one sprint is current at a time. Both views sort by the board's **Priority** field (P0 highest to P3).
- **Priority.** Every sprint ticket has a Priority set at planning, and work takes the highest-priority **Ready** ticket first.
- **Next sprint.** To point the views at the next sprint, add its option to the Sprint field (follow the save/check procedure in the `ticket-flow` skill, so existing values aren't lost), then edit each view's filter to the new value. Do this when the next sprint starts.
- **Statuses within a sprint.** The board's Status column means:

  | Status | In a sprint |
  |---|---|
  | Backlog | Not in the current sprint |
  | Ready | In the current sprint, work not started (every committed and stretch ticket not yet started is moved here when the sprint starts) |
  | In progress | Active work |
  | In review | Finished, under review |
  | Ready to Merge | Approved, ready to merge |
  | Done | Merged |

  Only tickets with approved specs are committed. A sprint ticket that fails the spec gate when it starts stays in Ready with a comment saying what is missing (re-approval needed), so it isn't dropped from the sprint.
- **Time box.** Passing the soft time box triggers a check-in with the PO, never an automatic close.
- **Unplanned work.** Work that appears during a sprint (a hotfix, a bug found in a review) joins the current sprint only with the PO's OK, recorded on the sprint issue; otherwise it goes to Backlog.
- **Permissions.** Only the PO starts a sprint (the go), changes its commitment and closes it; the bookkeeping records each change on the sprint issue.
- **README check.** Before the sprint closes, the tech lead reads the README against what merged during the sprint. The bookkeeping records the outcome on the sprint issue: "README up to date" or a link to a docs ticket. A sprint doesn't close while the README states something untrue; missing new material may go to a docs ticket in the next sprint.
- **Closing.** The sprint closes at a **sprint review**: the PO's manual check of the sprint's goal, with every committed ticket done or carried over by the PO's decision. The outcome is written on the sprint issue, which is then closed.
  - A committed ticket that isn't done is carried over only by the PO's decision: its Sprint value changes to the next sprint, it keeps its Status, its Priority is raised one level at the next planning (P0 stays P0) unless the PO sets otherwise, and the sprint issue records it.
  - If the commitment is done while stretch tickets are still open, the sprint closes and each unfinished stretch ticket carries over to the next sprint by default (Sprint value changes, Status kept); the next planning decides again whether it is committed or stretch, and a ticket promoted to committed loses the `stretch` label.
  - Only the PO sends a sprint ticket back to Backlog. A ticket returned to Backlog has its Sprint value cleared and loses the `stretch` label.

## Reviews

Every pull request is reviewed before it merges. The checks get wider at each level:

| What | Build and checks | Code review | Roadmap check | Manual check |
|---|---|---|---|---|
| Ticket → `main` | Every changed .NET solution builds with 0 errors and its tests pass; every changed frontend builds and lints; `tools/check-boundaries.sh` passes; the PR's GitHub Actions build is green | Reviewed by someone other than the author, following the review checklist (`.claude/skills/pr-review/SKILL.md`), which includes the spec checks: the approval predates the work, every criterion and listed edge case has a test, tests came first, and loosening a rule makes a test fail (see "Specs and tests"). **Security review as well** when the change touches authentication, sessions, tokens, cryptography, permissions or personal data | The ticket does what its spec and roadmap task say, with the rules in `ROADMAP.md` and the design docs. Rules changed in code are changed in the docs too. The task's checkbox is ticked | When the task changes behaviour: what the PO can try on the running stack (requests, screens) and what to expect |
| Phase checkpoint | Same, on `main` | Reviewed by someone other than the author: everything the phase changed. Performance and security review of the phase | Every task in the phase is ticked, and the phase's **Done when** is met | Required: the phase's **Done when** |
| Release → `main` | Same, on the release PR's head | Release-level review of the part: everything it gained since its last release | Everything listed for the milestone is in; version, changelog and the production pin agree | Required: the part's smoke test, security pass and performance pass (release step 3), with the results in the PR |
| Hotfix → `release/<part>-<x.y>` | Same, on the hotfix branch | Release-level review of the fix | Version and changelog updated; the same fix is on `main` | The fix checked on the running stack |

A ticket that only changes docs skips the build, the boundary check, the code review and the test-first rules. Its review is a read-through checking that it meets each numbered criterion of its spec and agrees with the roadmap and the other docs. The build jobs don't run on Markdown-only changes, but the `gate` check does and passes (see "Required check" below), so such a PR still shows a check; there is just no build to wait for.

The review results go in the PR description. A review that finds problems sends the work back to the ticket (fix it on the same branch before merging, or open a new `fix/` ticket after). The merge only happens once the review is clean **and the PO has approved it**.

**Ready to merge** means all of these, checked right before saying so: nobody is still working on the PR, the PR's head on GitHub equals the branch tip, CI is green on that commit (`tools/pr.sh status <pr>` checks the head, the tip, up to date, the `gate` check and the `Closes` line in one run), and the description has been re-read.

## Before you open a PR

Check these on your own branch first; the review checks them again. Items that don't apply to the change can be skipped.

- [ ] **Spec approved:** the ticket has its spec and the PO's approval is recorded on the issue before the work started; the PR description maps every criterion id and every edge-case id to the tests that cover it.
- [ ] **Test-first:** the first commit (after the schema) adds the failing tests with minimal stubs so they compile; for compose and infrastructure, the failing smoke, lint or port check; later commits make them pass. Spikes, docs-only tickets and releases are exempt.
- [ ] **Contracts first:** an API or message change has its OpenAPI document or schema merged before the handlers, with contract tests against it.
- [ ] **Tests:** new rules have unit tests; new endpoints, handlers and migrations have integration tests against a real Postgres/RabbitMQ (containers), not mocks of them.
- [ ] **Failure paths:** every edge-case category of the spec has a tested case or an accepted `n/a`, not only the happy path, including what happens when the database, the broker, Redis or another service is down or slow.
- [ ] **Security:** no secrets in tracked files; no passwords, tokens or personal data in logs or error messages; input validated at the boundary; authentication and authorisation changes follow the OWASP rules in `Docs/platform-design.md`.
- [ ] **Contracts:** API and message changes are additive, or versioned, or flagged as breaking.
- [ ] **Messaging:** published messages go through the outbox; handlers are idempotent.
- [ ] **Migrations:** apply cleanly to an empty database and to the current one; anything that drops or rewrites data is flagged as breaking.
- [ ] **Unfinished features** are behind a flag that is off by default.
- [ ] **Decisions recorded:** any decision the ticket needed (a number, a rule, a choice between options) is written in a tracked document (the relevant decision log, `Docs/` or `ROADMAP.md`) or on the issue, and linked from the spec, before the work relies on it; never only in the PR or in untracked notes.
- [ ] **Deferred work tracked:** work you chose not to do in this PR is a task in `ROADMAP.md` or a GitHub issue, not a comment in the code.

## Pinned actions, default permissions and runners

Workflows run with the repository's credentials and can attest and publish, so what they pull in and what they may do is fixed in the files and checked on every change (the Hardening epic, #63; threat: a compromised or retagged action reaching CI). The rules, for every file under `.github/workflows/` and `.github/actions/`:

1. **Every action is pinned to a full commit SHA, with its version as a comment:** `uses: actions/checkout@<40 lowercase hex> # v4.4.0`. A local action (`uses: ./.github/actions/<name>`) needs neither. No tag, branch, short or uppercase SHA, `docker://` reference, quoted value or `uses:` split over lines.
2. **`permissions: {}` at the top of each workflow, and a `permissions:` block on every job** with only the grants that job uses (`contents: read` for a checkout, `packages: write`, `id-token: write` and `attestations: write` only where something is pushed or signed; `permissions: {}` is a valid job block). A new job that forgets its block fails the check, so it never inherits more than it asks for. `checks: write` and `statuses: write` are granted nowhere: they are what would let a workflow post a `gate` result of its own (see "Required check").
3. **Every `runs-on:` is `ubuntu-24.04`**: not `ubuntu-latest` (GitHub moves it to a newer image, as it did to 26.04 in November 2026, and a moved label changes the toolchain under every job), no other label, no list, no expression.

`tools/check-action-pins.sh` checks rules 1 and 3 and `tools/check-workflow-permissions.sh` rule 2; both read files only (no network, so they cannot see an action commit deleted upstream, which fails the job at the download), run under `/bin/sh` (dash on Ubuntu) and print one line per offender, `<file>:<line>: <ref>` or `<file>: job <name>: <problem>`. They read the layout the workflows use, and **fail on any form they do not read**: a quoted `"uses"` or `"runs-on"` key, a space before the colon, a step or job written as a `{ ... }` or `[ ... ]` flow mapping, a job with a value after its id and `jobs:` with an inline value are offenders (`<unrecognised: uses>`, `not a plain job key`), never skipped (a quoted job id with its block below is read as the job it names), so a spelling that GitHub accepts cannot hide a line. Every `action.yml` in the repository is scanned, not only those under `.github/actions/`, because `uses: ./tools/x` is a local action wherever it lives (`node_modules`, `.git` and `.claude` excepted), and a `./` path with no `action.yml` is an offender. `tools/check-workflow-crosscheck.sh` then asks `yq` for every `uses`, every `runs-on` and every job's permissions and compares them with what the two checks listed (`--list`): a difference is printed as `only in yq: ...` and fails the job. The `action-pins` job of `build.yml` runs both on every change that touches more than Markdown (it checks the whole tree, not only the files the change touches), and `gate` requires it: a Markdown-only change skips the job like the other build jobs and `gate` accepts that skip (`tools/ci-gate.sh`), while a code change where it fails, was skipped or didn't run fails the gate. Their fixture tests are in `tools/tests/ci-tools.sh`, which the gate job runs.

**Repository setting (the PO sets it once):** Settings → Actions → General → "Require actions to be pinned to a full-length commit SHA" on. Then a workflow that references an unpinned action fails when it starts, on every branch, so a branch that still has a tag reference fails even if nobody runs `action-pins`; and a tag named like a 40-character hex, which the offline check cannot tell from a commit, is refused at run time. Read it with `gh api repos/rodgallert/Elysium/actions/permissions` (`sha_pinning_required: true`). Neither the setting nor the checks prove that a pinned SHA is the commit of the tag in its comment: GitHub also resolves a commit that exists only in a fork of the action's repository (an impostor commit), and the setting accepts any full SHA. So a pin change (a Dependabot PR or a bump by hand) is reviewed for it: the version tag in the comment must resolve, in the official repository, to the pinned SHA (`.claude/skills/pr-review/SKILL.md`, "Pinned actions"; step 2 below is the command). An online check that does this on every pin is a separate ticket. Turn it on only once `main` has the pins, and update open branches afterwards, since a branch's run uses its own workflow files.

**Updates:** `.github/dependabot.yml` has the `github-actions` ecosystem: one pull request a week for all action updates (a group), at most 5 open, and a 14-day cooldown on new versions (security updates skip the cooldown); nothing is merged automatically, and a Dependabot PR gets a read-only token and no secrets. It reads `.github/workflows/` and the composite actions under `.github/actions/` (`directories: ["/", "/.github/actions/*"]`), so a pin shared by a workflow and an action moves in one pull request; the other ecosystems join the same file in #34.

**Bumping a pin by hand** (a Dependabot PR is the normal way; do this when one is not enough):
1. Pick the release tag, preferably one at least 14 days old, and read its changes.
2. Resolve the commit it points to: `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.type, .object.sha'`. If the type is `tag` (an annotated tag), the SHA is the tag object: follow it with `gh api repos/<owner>/<repo>/git/tags/<sha> --jq .object.sha` until the type is `commit`. A tag object's SHA is not a commit, so pinning it makes the run fail when it downloads the action.
3. Replace the old SHA and the version comment everywhere the action is used (`grep -rn '<owner>/<repo>@' .github`); an action used in several files moves together.
4. Run `tools/check-action-pins.sh` and `tools/check-workflow-permissions.sh` (no output, exit 0), and the PR's own run is the proof the new version works.

**The runner image has an end date.** GitHub supports two GA Ubuntu images at a time and begins deprecating the oldest one when a new LTS image reaches GA: an announcement with the retirement date, scheduled brownouts (jobs on the image fail on set days), then removal; `ubuntu-22.04` is on that path now (deprecation from 2026-09-17, unsupported from 2027-04-17). No date has been announced for `ubuntu-24.04` (checked 2026-11-24). It is tracked by reading the image list and the announcements of `actions/runner-images` (the README's deprecation policy and the pinned announcements) whenever a new Ubuntu image appears and when jobs fail on the label; Dependabot's cooldown does not cover runner labels. Moving to the next image is one change of every `runs-on:` and of the label in `tools/check-action-pins.sh`, with the PR's run on the new image as the proof.

## Releases (per release part)

### Versions and release parts

- A **release part** is what gets one version, one git tag `<part>-v<x.y.z>` and one GitHub Release. Every image of a part is released at the part's version.
- By default a **service is one part**, named after it (`masquerade`), and its version lives where its stack keeps it, at the service's root: `<VersionPrefix>` in `Directory.Build.props` for .NET (a `.sln` can't hold build properties), else `version` in `package.json`. Every release bumps it (major, minor or patch). Its changelog is the `CHANGELOG.md` next to that file. A service without a version file has no part yet and can't be released; its first release PR adds the file.
- A service that releases **several parts** (for example an API and an app, each with its own version) declares them in its `docker-compose.yml`, and every image belongs to exactly one part:

  ```yaml
  x-release-parts:
    prince-api:                               # starts with the service's name
      version: Backend/Directory.Build.props  # relative to the service folder; its CHANGELOG.md sits next to it
      images: [core-api, checkout-api, jobs-api]
  ```
- `tools/release-parts.sh` lists every part with its version, changelog and images.

### Releasing

A part is released when its milestone's tickets are on `main` and its phase checkpoint (if any) has passed:
1. **Release ticket and PR** (`chore/release-<part>-<x.y.z>` → `main`, title `chore(release): <part> <x.y.z>`), changing together:
   - the part's version (its version file);
   - its `CHANGELOG.md`: the "Unreleased" entries move under a `## <x.y.z>` heading, with a "Breaking changes" heading (every breaking change since its last release, with what can break and what to do, or "None") and a "Known issues" line;
   - for a service's first release, its blocks in `docker-compose.prod.yml`, with `image: ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>` (tag only).
2. **Prepare run:** Actions → Release → Run workflow, on the release PR's branch, mode `prepare`, the part's name. It builds every image of the part from the branch, pushes it by digest (no tag yet), attaches a signed SBOM and build provenance, writes `<image>:<x.y.z>@sha256:<digest>` into `docker-compose.prod.yml`, commits that to the branch ("chore(release): pin ...") and starts the branch's build. **Any change after this to the service folder (`CHANGELOG.md` included) or to the release tooling (`.github/workflows/release.yml`, `.github/actions/release-image/`, `tools/`), on the branch or merged into `main` meanwhile, needs another prepare run.** The release PR's build checks this from the images' revision label, and the release job again from the provenance certificate; a PR that changes a part's version gets these release checks whatever its title, and its title must be `chore(release): …` (or `chore(release)!: …`).
3. **Smoke test, security pass and performance pass** for that part, on the release PR's head, **with the prepared images** (the same digests that ship):
   - **Migrating from the previous version:** start the current production list from `main` (`git show origin/main:docker-compose.prod.yml > /tmp/prev.yml`, then `docker compose -p elysium-release -f /tmp/prev.yml up -d`), use it until it has data, then switch to the release PR's file (`docker compose -p elysium-release -f docker-compose.prod.yml up -d`): the new images start on the previous version's database, so their migrations run against real data. A first release has no previous version and skips this.
   - Then every shipped **Done when** of the part once; the security checklist for what the release touches; response times and resource use against the roadmap's budgets.
   - Anything found is fixed by a `fix/` ticket before the release PR merges, then prepare again. The release PR records the results, and it isn't approved without them.
4. **The PO approves and merges** the release PR. That merge is the release.
5. **CI does the rest** from the merge commit (the `release` job in `.github/workflows/release.yml`, `tools/release-publish.sh`):
   - it checks every pinned digest carries SBOM and provenance attestations signed by this repository's release workflow on a GitHub-hosted runner;
   - it takes the commit the images were built from out of the verified provenance certificate (`sourceRepositoryDigest`; the image's revision label must agree) and checks that commit's service folder and release tooling are identical to the merge commit's, so the images come from the reviewed code and the reviewed workflow (`tools/release-check-source.sh`);
   - tags each prepared image `<x.y.z>` (the same digest; nothing is rebuilt);
   - creates the annotated git tag `<part>-v<x.y.z>` on the merge commit and a GitHub Release (not marked "latest") with the changelog section and the SBOMs.

   Then close the milestone. If the job fails, tell the PO what failed; never create the tag by hand. Check that the Release workflow's `push` run on the merge commit concluded `success`: a `cancelled` run isn't shown as a failure but released nothing.

   The `release` job's concurrency group is named after the merge commit (`release-<sha>`), not the branch. GitHub keeps only one pending run per group and cancels the older one when a newer run queues, so a per-branch group would drop the middle one of three quick release merges without any failure. With a group per commit nothing queues and nothing is cancelled: releases are independent, since each has its own tags and pinned digests and every step is safe to re-run, so the group is not a no-op: a `release/<part>-<x.y>` branch created from the release tag while main's run on that commit is still going starts a second run on the same commit, which waits for the first and then takes the "already released" path, so the two never race on tags. Merges that release nothing never enter a group.

   Two release runs for the same part and version can still overlap (a hotfix copied back to `main` racing its own release run, or a version bumped, bumped down and bumped again within one run). So `tools/release-publish.sh` claims the version with the git tag first: after the attestation and source checks pass it pushes `<part>-v<x.y.z>` on the merge commit, and only then tags the images and creates the Release. The server accepts a tag push once, and the "Release tags" ruleset blocks moving it, so one run wins. A run that loses the push, or that finds the tag on another commit, fails without touching an image tag; a tag already on the merge commit is an earlier run of the same merge, and the run carries on with what is left. A version that `tools/release-state.sh` proves already released is still skipped before any of this.

Several parts can be released in one PR when they must ship together (a coordinated breaking change); each still gets its own version, changelog section and tag. CI finds them as the parts whose version file the merge commit changed, and both signals must agree: a changed version outside a `chore(release):` commit, or a `chore(release):` commit that changes no version, fails the release workflow.

### Checks on the production list

`tools/check-prod-pins.sh` runs in every build (`release-checks` in `build.yml`):
- **Every pull request, offline:** every service runs a published image (no `build`), pinned as `<name>:<tag>@sha256:<digest>`, from an allowed registry (`docker.io`, `ghcr.io`, `mcr.microsoft.com`). Our images are tagged with their part's version. Third-party tags are full versions: no `latest`, `stable` and the like, no bare major version (`17-alpine`).
- **Our images, online:** the digest exists, and the version tag, once it exists, points at it. Version tags never move.
- **A pull request that adds or changes a third-party line:** its tag must resolve to the pinned digest now (the multi-arch index digest, as `docker buildx imagetools inspect` shows it).
- **A release PR** (title `chore(release): ...`, and the build the prepare run starts): every pinned digest, ours and third-party, must be pullable.
- Otherwise third-party drift (upstream rebuilt a tag, or dropped an old digest) is a warning: production keeps running the pinned digest. Bumping third-party pins is #34's scheduled job.
- **Accepted risk:** upstream signatures of third-party images (Postgres, Silo, Redis, ...) are not verified; the pinned digest is what we trust. There are few third-party images for now; revisit when that changes.

### Dry runs

Actions → Release → Run workflow, mode `dry-run`, any part and branch (a service without a version file can be rehearsed at a given version). It goes through every step: the plan, each image built (not pushed), its SBOM, signed SBOM and provenance attestations (for a digest that is never pushed), the release notes, the production pin as a diff, and the image tag, git tag and Release commands. It pushes no image and creates no tag or Release; the result is the run's summary. Every pull request that changes the release tooling runs the same dry run without signing. Anyone with write access can start either manual run.

### Version tags and release branches (repository settings)

**Version tags:** a tag ruleset, Settings → Rules → Rulesets → New tag ruleset, named "Release tags", enforcement **Active**, target tags matching `*-v*` (include by pattern `refs/tags/*-v*`), rules **Restrict creations**, **Restrict updates**, **Restrict deletions**, bypass list: the **GitHub Actions** app (always). `phase-*-done` tags don't match. If GitHub doesn't accept the app as a bypass actor, use the fallback: the same ruleset with only **Restrict updates** and **Restrict deletions** and no bypass. What either gives: a version tag can't be moved or deleted, and only someone with push access (or a workflow run in this repository) can create one. A tag made by hand doesn't make a release: the release job requires the part's tag on the merge commit and fails when it exists anywhere else. Making CI on a protected branch the only possible creator needs a dedicated credential (#38). Optionally also turn on Settings → General → **Immutable releases**, so a published Release and its tag can't be changed.

**Release branches:** a push to `release/**` runs the release job, so these branches change only through reviewed PRs, like `main`, and only the PO creates them. Two branch rulesets (Settings → Rules → Rulesets → New branch ruleset), both enforcement **Active**, targeting branches matching `release/**`:
- "Release branches": **Require a pull request before merging**, **Block force pushes**, **Restrict deletions**, no bypass. Nobody pushes to a release branch directly, the PO included.
- "Release branch creation": **Restrict creations**, bypass list: the **Repository admin** role (always). Only the PO creates a release branch (Hotfixes, step 3). It's a separate ruleset so the admin bypass covers creation only, not direct pushes.

### Required check

`main` and `release/**` require one status check, `gate` (the last job of `.github/workflows/build.yml`), so a PR with red CI can't be merged. It's one job with one name because no build job could be the required check: the `frontends (<path>)` jobs change name whenever an app is added, renamed or removed, and GitHub counts a skipped required check as passing, so a build job skipped on a Markdown-only change (or because a job it needs failed) would let the PR through. The gate runs on every change (`if: always()`), so a failed or cancelled job is reported as a failed gate rather than left pending.

What `gate` checks (`tools/ci-gate.sh`; its fixture tests, `tools/tests/ci-tools.sh`, the Prince `.env` check's tests, `tools/tests/env-check.sh`, the ticket script's tests, `tools/tests/ticket-tools.sh`, and the PR script's tests, `tools/tests/pr-tools.sh`, run in the gate job first). The `changes` job (`tools/ci-code-changed.sh`) decides whether the change touches anything besides Markdown; there is no `paths-ignore` filter, because a filtered workflow never reports:

| Case | Gate result |
|---|---|
| Code PR, every job green | Passes. `frontends` may be skipped only when the repository has no app; `publish` is skipped on pull requests (it runs, and must succeed, only on a push to `main` with images to publish) |
| Markdown-only PR | Passes: `changes` ran, every build job was skipped as it should be, and the Release workflow's run on the PR is green |
| Any job failed or was cancelled | Fails |
| A job skipped that should have run (for example because a job it needs failed) | Fails |
| A job ran that shouldn't have (`publish` on a pull request, a build job on a Markdown-only change) | Fails |

The gate can't `needs` a job of another workflow, so for the Release workflow's pull request jobs (the dry run, run for every PR that changes the release tooling) it waits: after the checks above, on a pull request, `tools/ci-release-run.sh` lists the Release workflow's `pull_request` runs on the PR's head commit and waits for them (up to 5 minutes for one to appear, 40 for them to finish). Every such run on that commit must be green, not only "this PR's": another pull request can share the commit (the same branch into another base, a fork), the run list can't tell them apart reliably, and a green run of another PR must not cover this PR's red one. The price is that a red run of an unrelated PR on the same commit blocks this one, which is rare and safe. `release.yml` starts a run on every PR, with no path filter, so there is always one to find; its `plan` job skips the dry run unless the PR changes the release tooling (`.github/workflows/release.yml`, `.github/actions/release-image/`, `tools/release-*.sh`, `tools/check-prod-pins.sh`, `tools/list-images.sh`), so on most PRs the wait lasts seconds. A failed Release run is fixed by re-running it (a new attempt of the same run, which replaces the earlier result) and then re-running the gate. Nothing can pass early: the gate only finishes once the Release run has. Skipped matrix jobs have no `name:` of their own, so they show as `publish`, `dry-run-pr` and so on instead of an unrendered `${{ matrix.image.image }}`; nothing but `gate` is ever required.

**Repository setting (the PO sets it once, and again if the check is ever renamed):** Settings → Rules → Rulesets, in both "Protect main" and "Release branches":
- turn on **Require status checks to pass**, then **Add checks** and pick `gate` with source **GitHub Actions** (it shows in the list after the first run on a PR, so add it after the PR that introduces it has been through CI). Keep the source: it stops a plain commit status named `gate` posted with a personal token. After saving, confirm with `gh api repos/rodgallert/Elysium/rulesets/<id>`: the rule must read `{"context": "gate", "integration_id": 15368}`; a check added as "any source" has no `integration_id`;
- turn **Require branches to be up to date before merging** on (the PO's decision, 2026-11-15), so a PR can't merge on a green `gate` from a run against an older base. The cost: whenever the base moves, each open PR needs "Update branch" (a merge of the base into the branch, a merge commit, consistent with the no-rebase rule in Branches) and a CI re-run before it can merge. Keep **Do not require status checks on creation** off.

**What the gate guarantees, and what it doesn't:** it catches honest mistakes (red or unbuilt CI, a forgotten check) and fork PRs. It is only as strong as the review of changes to `.github/workflows/` and `tools/ci-*.sh` (and `tools/tests/ci-tools.sh`): a pull request from a branch of this repository runs its own versions of them, so a PR can change the gate that judges it, and that change is in the reviewed diff. The GitHub Actions source pin does not stop a workflow on any branch that asks for `checks: write` or `statuses: write` and posts a `gate` result, so someone with push access can still forge it. Fine for a single-collaborator repository; revisit it when that changes.

Since 2026-11-15 `gate` is required in both rulesets, so a PR can't merge without it; "Ready to merge" (see Reviews) still means the checks were read on the PR's current head.

### Production

Production runs only what `docker-compose.prod.yml` pins, never `:main`, and changes only by a deliberate, manual update after a release PR merges:

```
git pull
docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d
```

## Hotfixes

An urgent fix to a released version:
1. Fix it on `main` first, as a normal `fix/` ticket.
2. If `main` holds nothing else for that part since its release, release it normally as a patch version.
3. Otherwise, the PO creates `release/<part>-<x.y>` from the part's release tag (once per minor version: `git push origin <part>-v<x.y.z>^{commit}:refs/heads/release/<part>-<x.y>`; only the repository admin may create release branches). Then cherry-pick the fix onto a `hotfix/<part>-<x.y.z>` branch from it, bump the patch version and the changelog, open the PR into the release branch, and run the prepare run on the hotfix branch. Its merge releases the patch like a release PR into `main`. Then a PR into `main` (`chore(release): ...`) copies the version, the changelog and the production pin; CI sees that version is already released and does nothing. Its build skips the release PR's source check for that version, and the release job skips releasing it again, only when `tools/release-state.sh` proves it was really released. That means all of these hold:
   - the git tag, the GitHub Release and every image tag exist and match the pins;
   - every pinned digest has provenance and SBOM attestations signed by the release workflow for the commit it was built from;
   - that commit's service folder and release tooling equal the tagged commit's;
   - the tagged commit is on `main` or a `release/**` branch.

   Anyone with push access can create a tag, a Release or an image tag, so those alone prove nothing. A lookup that errors, a release that is only partly done, or a state that can't be proven fails the check instead.

## Pushing

The ticket checklist (`.claude/skills/ticket-flow/SKILL.md`) pushes as part of its steps, without asking each time: creating a ticket branch from its issue, creating hotfix branches, pushing phase tags, and pushing a working branch's commits while its PR is open. It never force-pushes, and never pushes commits to `main` or a release branch: those only change through merged PRs, and merging is the PO's call. Release branches are created by the PO only. Release tags are created by CI only. GitHub Actions builds every pull request (and pushes to `main` and `release/**`), except changes that only touch Markdown; the result shows on the PR.
