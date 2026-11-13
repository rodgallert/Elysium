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
```

Then work out the **review level** from the branches (`Docs/workflow.md`):

| Head | Base | Level |
|---|---|---|
| `<type>/p<n>-<slug>` or `<type>/<slug>` | `main` | **Ticket** |
| `chore/release-<service>-<x.y.z>` | `main` | **Release** (one service; several when they must ship together) |
| `hotfix/<service>-<x.y.z>` | `release/<service>-<x.y>` | **Hotfix** (release-level checks for the fix; the same fix must already be on `main`) |

All merges are squash merges.

A **phase checkpoint** has no PR: when the phase's last ticket is done, review everything `main` gained since the previous `phase-*-done` tag at phase level, and post the result on the phase's epic issue.

Anything else (wrong base, a ticket into a release branch, `main` or a release branch as the head) is a **Must fix**.

A PR is **docs-only** when every changed file is Markdown (`.md`), wherever it lives. Anything else under `.claude/` (settings, hooks, scripts) is code. Docs-only PRs skip the worktree build (section 2), the build and boundary lines of section 3, and the code review (section 5), and get a read-through instead. The build workflow doesn't run on Markdown-only changes, so a docs-only PR has no build check: don't wait for one and don't list its absence as a finding. Every other check still applies: title, branch, issue link, roadmap boxes and repo hygiene.

Read the rules **from the PR's own head branch**, since PRs can change them: `CLAUDE.md`, `ROADMAP.md`, `Docs/workflow.md`, `Docs/platform-design.md`, and the `CLAUDE.md` and decision log of every service the PR touches. If the PR depends on a rule that only exists on another unmerged branch, that's a finding (merge order), not something to assume.

Find the linked issue(s): the `Closes #n` lines in the body. Read each with `gh issue view <n> -R rodgallert/Elysium`. The issue body holds the roadmap task the ticket implements.

## 2. Check out, build and test

Never switch branches in the main working copy: another session uses it. Use a scratch worktree:

```
REPO=$(git rev-parse --show-toplevel)    # run from inside the main working copy
WT=${CLAUDE_JOB_DIR:-/tmp}/tmp/review-pr<n>
git -C $REPO fetch -q origin
git -C $REPO worktree add --detach $WT <headRefOid>
cd $WT
tools/check-boundaries.sh
```

For each .NET solution the PR touches, build and run its tests. The projects target .NET 10; if the local SDK is older (`dotnet --list-sdks`), use the SDK container:

```
docker run --rm -v "$WT":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test <path to .sln> -c Release
```

Tests that need Postgres, RabbitMQ or Redis start them themselves (containers); if they can't run here, say so under "Not checked". For each frontend the PR touches: `npm ci && npm run build`, plus `npm run lint` when the app has a lint script.

A known warning that the service's `CLAUDE.md` already lists is not a finding; any other new warning is. When done: `git -C $REPO worktree remove --force $WT`.

## 3. Mechanical checks

Each failure is a **Must fix** unless noted.

- **Build:** 0 errors. **Tests:** all pass. **Boundary check:** passes. **CI:** every check on the PR is green (a check still running goes under "Not checked"). Docs-only PRs have no build check; say so under "Checked" instead.
- **PR title** is a Conventional Commit, because it becomes the commit title (every merge is a squash): `^(feat|fix|docs|refactor|test|chore|ci|perf|build)(\([a-z0-9.-]+\))?!?: [a-z]`, imperative, no full stop.
- **Branch name** follows `Docs/workflow.md` for its level. Type in the branch matches the type in the title.
- **Issue link:** tickets say `Closes #<issue>` for every roadmap task they complete (Should fix if missing). Merges into `main` close them automatically; the reviewer only checks the links are there and point at the right tickets.
- **Roadmap boxes:** the tasks the PR completes are ticked in `ROADMAP.md`; nothing is ticked that the code doesn't actually do yet.
- **Breaking changes:** if the change forces a consumer of a service to change (an endpoint, field, status code or message contract changed or removed, token claims changed, a migration that drops or rewrites data, a renamed or removed config key or environment variable, a removed login method or permission), or rewrites code a finished scenario relies on (`Docs/workflow.md`, "Breaking changes"), the PR has a "## Breaking change" section and the linked issue a "Breaking change" note, both saying what can break and what to do, and the title and commit carry `!` and `BREAKING CHANGE:`. Anything missing is a **Must fix**.
- **Repo hygiene:** no build output, no `.env` or other secrets, no credentials or tokens in code, tests or fixtures, no personal data in fixtures beyond obviously fake values.

## 4. Roadmap and design check

`ROADMAP.md` decides what is built; `Docs/platform-design.md` and the services' decision logs decide how.

- The change does what its roadmap task and linked issue say: same names, rules, limits and defaults.
- If the code changes a documented rule, the document changes in the same PR.
- **Decided values:** any security or business number added or changed (token lifetimes, password rules, rate limits, lockout timings, fee percentages, retention periods) is listed under **Needs the PO's confirmation**, quoting old and new. You can't know whether it was approved, so don't call it a defect; just make it impossible to miss. The PR description must call out every such change, since squash merging folds it into one commit with everything else (Should fix if it doesn't).
- **Phase level:** every task in the phase is ticked, and the phase's **Done when** is met. **Release level:** every ticket of the service's milestone is in; the version in the project file, the new `CHANGELOG.md` section and the image pin in `docker-compose.prod.yml` all agree; the changelog has a "Breaking changes" heading that lists every breaking change since the service's last release with what can break and what to do (check the milestone for `BREAKING CHANGE:` commits and issues with a breaking-change note; a missing one is a **Must fix**); the smoke, security and performance results are in the PR; a breaking change bumps the major version (minor below 1.0).

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
- Build: ... · Tests: ... · Boundary check: ... · CI: ... · Title and branch: ... · Issue link: ... · Roadmap: ... · Security: ...

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
