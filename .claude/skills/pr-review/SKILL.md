---
name: pr-review
description: Review an Elysium pull request against the project's workflow, roadmap, design and security rules, then post the findings on the PR. Use for every PR before it merges (tickets, releases, hotfixes) and for phase checkpoints, when asked to "review PR #n", or when acting as the review agent. Takes the PR number as its argument.
---

# Elysium PR review

Review one pull request and post the result on it, the same way every time. The argument is the PR number. The repo is `rodgallert/Elysium`. gh's active account belongs to another project: start every shell command that runs `gh` with `export GH_TOKEN=$(gh auth token --user rodgallert);` and never switch accounts.

**Who runs this:** someone other than the PR's author.

**You only review.** Never merge, approve, close, push, edit a branch, change repo settings or run `gh auth`. Only report what you verified; anything you couldn't check goes under "Not checked", never as a guess.

## 1. Gather

```
gh pr view <n> -R rodgallert/Elysium --json number,title,body,baseRefName,headRefName,headRefOid,files,commits,url
gh pr diff <n> -R rodgallert/Elysium
gh pr checks <n> -R rodgallert/Elysium
tools/pr.sh status <pr>
```

`tools/pr.sh status <pr>` prints the PR's facts (state, branches, head SHA, whether the head equals the branch tip, whether it is up to date with its base, the `gate` conclusion on that SHA, the `Closes` line) and exits 0 only when all are in order; to find a PR from a branch name use `tools/pr.sh status --branch <name>`, which matches the exact head branch of this repository (never a prefix or a similar name).

Then work out the **review level** from the branches (`Docs/workflow.md`):

| Head | Base | Level |
|---|---|---|
| `<type>/p<n>-<slug>` or `<type>/<slug>` | `main` | **Ticket** |
| `chore/release-<part>-<x.y.z>` | `main` | **Release** (one release part; several when they must ship together) |
| `hotfix/<part>-<x.y.z>` | `release/<part>-<x.y>` | **Hotfix** (release-level checks for the fix; the same fix must already be on `main`) |

All merges are squash merges.

A **phase checkpoint** has no PR: when the phase's last ticket is done, review everything `main` gained since the previous `phase-*-done` tag at phase level, and post the result on the phase's epic issue.

Anything else (wrong base, a ticket into a release branch, `main` or a release branch as the head) is a **Must fix**.

A PR is **docs-only** when every changed file is Markdown (`.md`), wherever it lives. Anything else under `.claude/` (settings, hooks, scripts) is code. Docs-only PRs skip the worktree build (section 2), the build and boundary lines of section 3, and the code review (section 5), and get a read-through instead. The build jobs don't run on Markdown-only changes, so a docs-only PR has no build to wait for (its `gate` check still reports and passes): don't list the missing build jobs as a finding. Every other check still applies: title, branch, issue link, roadmap boxes and repo hygiene, and the read-through checks that the PR meets its issue's numbered criteria.

Read the rules **from the PR's own head branch**, since PRs can change them: `CLAUDE.md`, `ROADMAP.md`, `Docs/workflow.md`, `Docs/platform-design.md`, and the `CLAUDE.md` and decision log of every service the PR touches. If the PR depends on a rule that only exists on another unmerged branch, that's a finding (merge order), not something to assume.

Find the linked issue(s): the `Closes #n` lines in the body. Read each with `gh issue view <n> -R rodgallert/Elysium`. The issue body holds the roadmap task the ticket implements.

## 2. Check out, build and test

Never switch branches in the main working copy: another session uses it. Use a scratch worktree under `.claude/worktrees/`, made with `tools/wt.sh` (the PR's own branch is usually checked out in its author's worktree, so the scratch one is a new branch of its own, detached at the reviewed commit):

```
REPO=$(git rev-parse --show-toplevel)    # run from inside the main working copy
git -C $REPO fetch -q origin
WT=$($REPO/tools/wt.sh add --new review-pr<n>)
git -C $WT checkout -q --detach <headRefOid>
cd $WT
tools/check-boundaries.sh
```

For each .NET solution the PR touches, build and run its tests. The projects target .NET 10; if the local SDK is older (`dotnet --list-sdks`), use the SDK container:

```
docker run --rm -v "$WT":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test <path to .sln> -c Release
```

Tests that need Postgres, RabbitMQ or Redis start them themselves (containers); if they can't run here, say so under "Not checked". For each frontend the PR touches: `npm ci && npm run build`, plus `npm run lint` when the app has a lint script.

A known warning that the service's `CLAUDE.md` already lists is not a finding; any other new warning is. Keep the worktree until the loosen-a-rule step in section 3 is done. When done: `cd $REPO && tools/wt.sh rm review-pr<n> --force && git branch -D review-pr<n>` (`--force` because the scratch worktree is detached and the loosened rule was discarded, never committed).

## 3. Mechanical checks

Each failure is a **Must fix** unless noted.

- **Build:** 0 errors. **Tests:** all pass. **Boundary check:** passes. **CI:** every check on the PR is green (a check still running goes under "Not checked"). Docs-only PRs have no build jobs, only the `gate` check (it passes); say so under "Checked" instead.
- **PR title** is a Conventional Commit, because it becomes the commit title (every merge is a squash): `^(feat|fix|docs|refactor|test|chore|ci|perf|build)(\([a-z0-9.-]+\))?!?: [a-z]`, imperative, no full stop.
- **Branch name** follows `Docs/workflow.md` for its level. Type in the branch matches the type in the title.
- **Issue link:** tickets say `Closes #<issue>` for every roadmap task they complete (Should fix if missing). Merges into `main` close them automatically; the reviewer only checks the links are there and point at the right tickets.
- **Roadmap boxes:** the tasks the PR completes are ticked in `ROADMAP.md`; nothing is ticked that the code doesn't actually do yet.
- **Spec and approval** (`Docs/workflow.md`, "Specs and tests"; spikes and releases are exempt, as are tickets the PO exempted on the issue; a docs-only ticket is read through against each numbered criterion; hotfixes and tickets filed before the rules need a spec too): the issue holds the spec with ids `#<issue>-AC<n>`, a per-category edge-case list (a case or `n/a: <reason>` each; you judge the reasons, and "covered elsewhere" must name the test), and an `Approved: <comment link>` line. Check that the approval comment predates the first commit authored on the branch (for a hotfix, a cherry-pick's original commit date doesn't count; use the date it was committed on the hotfix branch) and that no `Spec change:` comment lacks a later approval. Missing or late approval is a **Must fix**.
- **Traceability:** the PR description maps every criterion id and every edge-case id to tests, and the tests cite their ids (`grep -rnF` with a closing delimiter so `AC2.1` doesn't match `AC2.10`, e.g. `grep -rnF '#64-AC2.1"'` for a quoted id, or a pattern ending in a non-digit). Any criterion or listed case with no test and no accepted `n/a` is a **Must fix**, per case: "happy path only" is the extreme of this, not a separate threshold. Without ids to map (a ticket exempted or filed before the rules), apply the same check against the PR's own description and the "Failure paths" item of "Before you open a PR".
- **Test-first order:** run `git log --reverse --no-merges origin/main..HEAD`. The order is schema (when there is a contract), then the first test commit, then the implementation. Check out the first test commit in the scratch worktree, run the tests and record the failure message under "Checked": it must be an assertion failing, not a compile error or a missing stub; for compose and infrastructure, the smoke, lint or port check that fails on the old configuration; a bug fix starts with its reproduction test. CI on the branch tip (`gate`) is what counts, not CI on the first commit. A missed order is a **Must fix** that can't be repaired (no force-push, squash hides history): it is lifted only by the PO's explicit acknowledgement recorded on the PR. An API or message change without its schema before the handlers, or without contract tests, is a **Must fix** too.
- **Breaking changes:** if the change forces a consumer of a service to change (an endpoint, field, status code or message contract changed or removed, token claims changed, a migration that drops or rewrites data, a renamed or removed config key or environment variable, a removed login method or permission), or rewrites code a finished scenario relies on (`Docs/workflow.md`, "Breaking changes"), the PR has a "## Breaking change" section and the linked issue a "Breaking change" note, both saying what can break and what to do, and the title and commit carry `!` and `BREAKING CHANGE:`. Anything missing is a **Must fix**.
- **Repo hygiene:** no build output, no `.env` or other secrets, no credentials or tokens in code, tests or fixtures, no personal data in fixtures beyond obviously fake values.

**Loosen a rule and see a test fail** (code, compose and infrastructure tickets): in the scratch worktree, pick one rule the change implements (remove a validation, widen a limit, drop an ownership or permission check, remove a unique constraint or idempotency guard; for compose and infrastructure drop a flag or a host binding), change it, run the tests or the check and confirm one fails, then discard the change (`git checkout -- .`). Never commit or push from the scratch worktree. Name the rule you loosened under "Checked". If everything still passes, the tests don't pin the rule: a **Must fix**. If no rule can be loosened (a visual rule, a CI setting), say why and name the check that would catch it. Docs-only PRs skip this.

## 4. Roadmap and design check

`ROADMAP.md` decides what is built; `Docs/platform-design.md` and the services' decision logs decide how.

- The change does what its roadmap task and linked issue say: same names, rules, limits and defaults.
- If the code changes a documented rule, the document changes in the same PR.
- **Decided values:** any security or business number added or changed (token lifetimes, password rules, rate limits, lockout timings, fee percentages, retention periods) is listed under **Needs the PO's confirmation**, quoting old and new. You can't know whether it was approved, so don't call it a defect; just make it impossible to miss. The PR description must call out every such change, since squash merging folds it into one commit with everything else (Should fix if it doesn't).
- **Phase level:** every task in the phase is ticked, and the phase's **Done when** is met. **Release level:** every ticket of the part's milestone is in; the version in the part's version file, the new `CHANGELOG.md` section and the image pins in `docker-compose.prod.yml` (written by the prepare run, after the last change to the service folder) all agree; the changelog has a "Breaking changes" heading that lists every breaking change since the part's last release with what can break and what to do (check the milestone for `BREAKING CHANGE:` commits and issues with a breaking-change note; a missing one is a **Must fix**); the smoke, security and performance results are in the PR; a breaking change bumps the major version (minor below 1.0).

## 5. Code review

Read every changed line and enough of the surrounding code to understand it.

**Correctness**
- Bugs, wrong conditions, off-by-one, null handling, culture-sensitive parsing or formatting.
- Async: no `.Result`/`.Wait()`, cancellation tokens passed through, no fire-and-forget work without error handling.
- Transactions: a command's state changes and its outgoing messages commit together (outbox); no partial writes on failure.
- Concurrency: two requests or two messages for the same thing at once (optimistic concurrency, unique constraints, idempotency keys).
- HTTP: correct status codes, validation at the boundary with consistent error responses, no internal details leaked in errors.
- Migrations: apply to an empty and to the current database; no data loss without a breaking-change flag; indexes for new query paths.

**Security** (`Docs/platform-design.md`, sections 7 and 8, OWASP ASVS 5.0 Level 2)
- Authentication and session code meets the written rules for its login method; no undocumented sign-in path.
- Every endpoint states its authorisation; the caller's product and account come from the token, never from the request body.
- Tokens: signature, issuer, audience, expiry and revocation checked; nothing accepts an unsigned or wrongly signed token.
- No passwords, tokens, codes or personal data in logs, exceptions, URLs or analytics; no user enumeration through messages, status codes or timing.
- Secrets come from configuration, never code; cryptography uses the platform's vetted APIs, never home-made schemes.
- Frontends never store tokens in browser storage; cookies are `Secure`, `HttpOnly`, `SameSite`.
- Git refs are matched by their full name: `git ls-remote` patterns match the end of a name (`refs/tags/<t>` also matches `x/refs/tags/<t>`), and short names given to `rev-parse`/`show`/`describe`/`--base` resolve tags before remote branches. Any lookup that decides what is released, protected or compared filters output by the exact refname (or passes `refs/heads/…`, `refs/remotes/…`, `refs/tags/…`, or a checked 40-hex commit), and has a fixture with a decoy tag or branch.

**Messaging and CQRS** (`Docs/platform-design.md`, section 10)
- Commands and queries are separate handlers; queries change nothing.
- Messages are published through the outbox; handlers are idempotent and tolerate out-of-order delivery; failures retry and then dead-letter.
- Message contracts change additively or get a new version.

**Architecture**
- Service isolation: no references to another service's projects or database; shared services contain no product concepts.
- Layers: dependencies point inward; Domain is plain C# with no packages; entities enforce their own invariants; value objects for quantities with rules (money as integer minor units plus currency).
- No speculative code: interfaces are ports or have a real second use; nothing is added "for later" without a consumer in the same PR (Should fix).

**Performance**
- No N+1 queries, unbounded result sets or missing pagination; no synchronous I/O on request paths; no per-request work that could be cached safely.

**Style**
- Matches the surrounding code: naming, comment density, file layout.

## 6. Classify

- **Must fix before merge:** bugs, security problems, build, test or CI failures, broken project rules (`CLAUDE.md`, workflow, service boundaries), code that contradicts the roadmap or design, wrong branch or base.
- **Should fix:** design and architecture deviations, missing tests of a risky path, unclear names, docs that disagree with each other, missing issue links. Fix in this PR unless the PO says otherwise.
- **Needs the PO's confirmation:** security and business numbers or design rules that were added or changed (section 4).
- **Later:** real improvements outside this PR's scope. Each becomes a `tech-debt` issue (section 7).

Each finding names the file and line, says what is wrong, and why it matters. One finding per problem; merge duplicates.

## 7. Post

1. **Tech-debt issues** for the "Later" items. First search for duplicates (`gh issue list -R rodgallert/Elysium --label tech-debt --state all --search "<keywords>"`). Create the missing ones: `gh issue create -R rodgallert/Elysium --label tech-debt --label "type: <type>" --milestone <current milestone> --title "<short summary>" --body "<what, why, link to this PR>"`. If a "Later" item duplicates an existing roadmap ticket, link that issue instead.
2. **One review comment** with `gh pr review <n> -R rodgallert/Elysium --comment --body-file <file>` (the author is the same account, so approve and request-changes aren't available). Exactly this structure:

```
**Verdict:** <Ready to merge | Ready after the should-fix items | Not ready> (<Ticket | Release | Hotfix> review)

**Must fix before merge**
- `path:line`: what is wrong, and why it matters.
(or "None.")

**Should fix**
- ...

**Needs the PO's confirmation**
- ...

**Later** (tracked as issues)
- #<issue>: summary

**Checked**
- Build: ... · Tests: ... · Spec and approval: ... · Traceability: ... · Test-first order (first test commit and its failure): ... · Loosened rule: ... · Boundary check: ... · CI: ... · Title and branch: ... · Issue link: ... · Roadmap: ... · Security: ...

**Not checked**
- ... (e.g. behaviour on the running stack, with what to try and what to expect)

**Resolved since the last review** (re-reviews only)
- finding: how it was fixed (commit)
```

3. **Inline comments** (at most 5, only where a line-level note helps): `gh api repos/rodgallert/Elysium/pulls/<n>/comments -f commit_id=<headRefOid> -f path=<file> -F line=<line> -f side=RIGHT -f body="<note>"`.

On a **re-review** after fixes: read the previous review and the replies first, list the earlier findings that are resolved under "Resolved since the last review", and only list what's still open or new in the other sections.

4. **The PR description:** the workflow puts the review results in the PR description, because it becomes the commit's body. The reviewer only comments; the session that owns the PR copies the verdict and the "Checked" line into the description's **Review** section before asking the PO to merge.

Comments, inline notes, issues and the PR description read like plain project text: no tool attribution, and no mention of agents, skills, personas or how the review was produced (`CLAUDE.md`). Also check the PR's commits: any tool `Co-Authored-By` trailer is a **Must fix**, because the squash merge copies it into the target branch's history. Don't mention that check in the review when it passes.

## 8. Report back

Return: the verdict, the must-fix and should-fix findings (one line each), the items needing confirmation, the tech-debt issues created, the review comment's URL, and confirmation that the worktree was removed.
