---
name: ticket-flow
description: Keep Elysium's GitHub issues and project board in step with the work. Use at every step of implementing the roadmap - starting a ticket or a phase, opening a PR, merging it, a phase checkpoint, a release or a hotfix - so the related issue moves to the right board column and gets the right branch, links and comments. Arguments are the step and the issue number, e.g. "start 20", "review 20", "done 20".
---

# Elysium ticket flow

Every piece of roadmap work has a GitHub issue: a **ticket** (one roadmap task), grouped under an **epic** (a roadmap phase or a standing epic; see `Docs/workflow.md`, "Issues, epics and milestones"), and committed to a **sprint** (see "Sprints" there) once planned, inside a **GitHub milestone** (one release of one release part, e.g. "Masquerade v0.1"; see `Docs/workflow.md`, "Issues, epics and milestones"). The project board **"Elysium"** shows where each one is. Whoever does the work follows these steps so the issue and the board always match reality. The branch and review rules are in `Docs/workflow.md`; this skill only adds the issue and board side.

**gh account:** the repo is `rodgallert/Elysium`, but gh's active account belongs to another project and must not be switched. Start every shell command that runs `gh` for this repo with `export GH_TOKEN=$(gh auth token --user rodgallert);` (the board scripts do this themselves). If that fails, gh has no login for rodgallert: stop and ask the PO to run `gh auth login --skip-ssh-key -s project`.

Board columns: **Backlog** → **Ready** → **In progress** → **In review** → **Ready to Merge** → **Done**.

- **In review**: the PR is open and the review is running, or its findings are being fixed.
- **Ready to Merge**: the review is clean (no must-fix or should-fix left, CI green when the PR has a build check) and the PR waits for the PO's approval.

**Every piece of work has an issue, a branch and a PR, linked both ways.** No branch or PR without its issue (create one first, under the right epic, even for workflow and tooling work: those go under the "Workflow and tooling" epic). A release PR belongs to its release ticket. An issue in **In progress** has its branch; an issue in **In review** or later has its PR. The issue body ends with `Branch:` and `PR:` lines, and the PR body starts with `Closes #<issue>`.

Move an issue with `tools/board.sh <issue> "<column>"` (it adds the issue to the board if it isn't there yet).

Changing a board field's options (adding, renaming or removing a Status, Sprint or Priority option) can clear every item's value for that field. Before such a change, run `tools/board-field.sh save <field> <file>`; after it, `tools/board-field.sh check <field> <file>`, and put back any value it reports. Setting an item's value is safe and needs neither.

**Start only on the PO's go.** Answering questions, approving a plan or agreeing to a setup step is not a go: confirm and ask "should I start #n?" instead.

## Steps

### `file <ticket>`: write a ticket's issue
File every ticket (not epics or releases, which are filed by hand) from the issue template `.github/ISSUE_TEMPLATE/ticket.md` (`Docs/workflow.md`, "Specs and tests"): paste its sections into the issue body (`gh issue create --template` can't be combined with `--body`), keep `Epic: #<n>` as the first line, and add the `ticket` and `type: <type>` labels and the milestone. The issue number is only known once the issue exists, so create it first with the `<issue>` placeholders, then edit the body to replace every placeholder with the number (`#<issue>-AC1` becomes `#64-AC1`), then ask for approval: the number must be in the body before the approval time is taken. Planning has already named the ticket's likely edge cases and production failure modes; they go under each criterion, one line per category with a case id or `n/a: <reason>`. Every decision the spec relies on must already be written in a tracked document or on an issue, linked from the spec; record it there first when it isn't.

**Approval:** only the PO approves a spec, and agents share the PO's gh account, so ask the PO in the session and record the approval only after they say so: comment `Issue last edited <time>` and add an `Approved: <comment link>` line to the body (the line is what marks the approval, and that edit needs no new approval: take the time from the body before adding it). The ticket stays in **Backlog** until then and moves to **Ready** afterwards. A later change to the criteria is recorded as a `Spec change:` comment and needs approval again. A hotfix ticket gets a short spec, approved in the same comment that asks the PO for the release branch.

### `start <ticket>`: begin a ticket
1. Read the ticket: `gh issue view <n> -R rodgallert/Elysium --json title,body,labels,milestone`. Its body holds the roadmap task. Check it against the current `ROADMAP.md`; if they differ, the roadmap wins, so update the issue body first.
   **Spec gate:** the body must be a complete spec from the template (`Docs/workflow.md`, "Specs and tests"), with an `Approved: <comment link>` line pointing at an "Issue last edited <time>" comment made after the PO said so in the session, and no spec section (Goal through Out of scope) edited since that time (the `Epic:`, `Approved:`, `Branch:` and `PR:` lines are bookkeeping). Otherwise the ticket goes back to **Backlog** with a comment saying what is missing or that it needs approval again. If step 1's roadmap check changes a spec section, the spec needs approval again before the ticket starts. Only spikes, releases and tickets the PO exempted (recorded on the issue) have no spec; docs-only tickets and hotfixes have a short one. Tickets filed before the spec rules aren't exempt: they get a spec and approval before they start.
2. Find its epic (the `Epic: #n` line). If that epic is a phase that hasn't started yet, do `start-phase` first.
3. Update `main` (`git switch main && git pull --ff-only`), then create the ticket branch **from the issue**, so GitHub links them (it shows under the issue's Development section): `gh issue develop <n> -R rodgallert/Elysium --base main --name <type>/p<n>-<slug> --checkout` for a roadmap task, `<type>/<slug>` for other work. The type comes from the ticket's `type: …` label. (GitHub can only link a branch it creates this way; an existing branch can't be linked later.) Hotfixes for an older release follow `hotfix` below.
4. Add a `Branch: <branch>` line to the end of the issue body (`PR:` follows it later; the template has no such line), `tools/board.sh <n> "In progress"`, assign it (`gh issue edit <n> -R rodgallert/Elysium --add-assignee @me`), and comment: `Started on branch <branch>.`
5. If the planned change is breaking (`Docs/workflow.md`, "Breaking changes"), add a **Breaking change** note to the issue now: what it can break and what consumers need to do, or which finished scenarios must be tested again.
6. Code tickets are built test-first (`Docs/workflow.md`, rule 7): schema first when there is a contract, then the failing tests with minimal stubs so they compile, each citing its `#<issue>-AC<n>` or `#<issue>-AC<n>.<m>` id, then the implementation; for compose and infrastructure a failing smoke, lint or port check; a bug fix or hotfix starts with a failing reproduction test. An edge case found along the way that falls inside an existing criterion amends the spec (a `Spec change:` comment, approved again); new behaviour becomes its own ticket.
7. One ticket in progress at a time per engineer. If a ticket can't go on (blocked, needs a decision), comment why and move it back to **Ready**.

### `review <ticket>`: the PR is open
1. The PR (title in Conventional Commits, base = `main`, or the part's release branch for a hotfix) starts with `Closes #<n>` for each ticket it completes, and each ticket's body gets a `PR: #<pr>` line. For a code ticket the description maps every criterion id and every edge-case id to the tests that cover it. A ticket the PR only partly completes gets `PR: #<pr> (first part)` and stays open. If the change is breaking, the PR has a "## Breaking change" section and the issue's note is up to date.
2. `tools/board.sh <n> "In review"` for each of those tickets, and comment: `In review: #<pr>.`
3. Get the PR reviewed by **someone other than its author**, following the `pr-review` checklist. The PR description's Review section states the result and what was checked in plain project language, without mentioning agents, skills or how the review was done. When the review sends work back, move the ticket to **In progress** until the fixes are pushed, then back to **In review**. If `main` moved on, merge `origin/main` into the ticket branch ("Update branch" or a normal merge; no rebase, no force-push): the rulesets require up-to-date branches, so every open PR needs it when the base moves.
4. When the review is clean (no must-fix or should-fix items left, CI green when the PR has a build check), check that **nobody is still working on the PR**, that the PR's head on GitHub equals the branch tip, that CI ran on that commit, and re-read the description. Then `tools/board.sh <n> "Ready to Merge"` and ask the PO to approve the merge (**squash** for ticket PRs). Anything that needs the PO's confirmation (decided rules or numbers that changed) is in the PR description by then.

### `done <ticket>`: the PR merged (only after the PO approved it)
1. Merges into `main` close the PR's `Closes #n` issues automatically; check they closed (`gh issue view <n> -R rodgallert/Elysium --json state`) and close any that didn't: `gh issue close <n> -R rodgallert/Elysium --reason completed --comment "Done in #<pr>."` (hotfix PRs into a release branch never auto-close). For a release PR (`chore(release): ...`), also check the Release workflow's run on the merge commit: `gh run list -R rodgallert/Elysium --workflow release.yml --commit <merge commit> --json databaseId,event,conclusion`. The `push` run must show `success`, never `cancelled` (a cancelled run isn't a failure, but it released nothing); if it didn't, tell the PO and don't move the ticket to Done.
2. `tools/board.sh <n> "Done"`.
3. Update the local `main` (`git switch main && git pull --ff-only`) and delete the merged ticket branch (`git branch -D <branch>`; `-D`, because a squash merge isn't an ancestor).
4. Pick the next ticket of the phase and move it to **Ready**, unless the PO named another one.
5. If the ticket's epic is a phase epic and every sub-issue of it is now closed, the phase is ready for its checkpoint: go to `checkpoint`.

(Standing epics have no checkpoint: they close only when the PO closes them.)

### `start-phase <epic>`
A phase has no branch. `tools/board.sh <epic> "In progress"`, and move the phase's first tickets to **Ready**.

### `checkpoint <epic>`: a phase is done
1. Review the phase as a whole: everything that changed in `main` since the previous `phase-*-done` tag (`git log phase-<n-1>-done..origin/main`), by someone other than the engineers who wrote it, against the phase's roadmap section, including a security and performance look. Findings become `fix/` tickets.
2. Ask the PO to check the phase's **Done when** on a running stack, with exact steps (commands, requests, screens) and what to expect, on a named `main` commit (give its hash: `main` keeps moving). Move the epic to **In review** meanwhile.
3. When both pass: tag **that checked commit** (`git tag -a phase-<n>-done -m "Phase <n>: <name>" <checked-commit> && git push origin phase-<n>-done`), close the epic with a comment naming the tag, and `tools/board.sh <epic> "Done"`.

### `start-sprint <sprint issue>`: the PO gave the go for a planned sprint
1. File the sprint issue by hand (label `sprint`, like epics) with the goal, commitment list, stretch list, soft time box and an empty outcome, then `tools/board.sh <sprint issue> "In progress"`.
2. If the sprint's option isn't in the **Sprint** field yet, add it first: `tools/board-field.sh save Sprint <file>` before the change, `tools/board-field.sh check Sprint <file>` after it, and put back any value it reports, so existing values aren't lost. Then edit the filter of the **Current sprint** and **Sprint board** views to the new value (`sprint:"<name>"`).
3. Set the **Sprint** field on every planned ticket, and add the `stretch` label to the stretch tickets (`gh issue edit <n> -R rodgallert/Elysium --add-label stretch`). Look up the board number with `gh project list --owner rodgallert` (the "Elysium" board) and the ids with `gh project field-list <number> --owner rodgallert --format json` (field and option ids) and `gh project item-list <number> --owner rodgallert --format json` (item ids), then: `gh project item-edit --id <item id> --field-id <Sprint field id> --project-id <project id> --single-select-option-id <option id>`. A ticket filed without a Sprint value is in no sprint and shows in neither sprint view.
4. Move the first committed tickets to **Ready** (a ticket only moves once its spec is approved).

### `close-sprint <sprint issue>`: the sprint review
1. Ask the PO for the sprint review: the manual check of the sprint's goal, with exact steps and what to expect. Only the PO closes a sprint.
2. If any ticket is carried over and the next sprint's option isn't in the Sprint field yet, add it first with the save/check procedure from `start-sprint` step 2. For each committed ticket not done, the PO decides: carry it over (set its Sprint field to the next sprint's option with the `item-edit` command above, and record it on the sprint issue) or send it back to Backlog. For each open stretch ticket, the PO decides: next sprint or Backlog (a ticket sent to Backlog has its Sprint value cleared and loses the `stretch` label when it's no longer stretch).
3. Write the outcome on the sprint issue (goal met or not, done, carried over, moved to Backlog, scope changes), close it with `gh issue close <n> -R rodgallert/Elysium --reason completed`, and `tools/board.sh <sprint issue> "Done"`. The two views keep the closed sprint's filter until the next sprint starts (`start-sprint` step 2).

Unplanned work during a sprint (a hotfix, a bug found in a review) gets the current sprint's Sprint value only with the PO's OK, recorded on the sprint issue; otherwise it goes to Backlog.

### `release <part> <x.y.z>`: release one release part
A release part is a service, or one of the parts it declares (`Docs/workflow.md`, "Versions and release parts").
1. Check the part's milestone: every ticket is closed and on `main`, and the phase checkpoint it depends on (if any) has passed. Leftovers move to the next milestone only with the PO's OK.
2. Work the release ticket like any ticket (`start`), on `chore/release-<part>-<x.y.z>`: bump the part's version in its version file (`Docs/workflow.md`, "Versions and release parts"); in its `CHANGELOG.md` move the "Unreleased" entries under the new version with a "Breaking changes" heading (every breaking change since its last release, with what can break and what to do, or "None") and a "Known issues" line; for a first release, add the service's blocks to `docker-compose.prod.yml` (tag only). Then run the Release workflow's `prepare` run on the branch, which pins the image digests. Search the milestone for `BREAKING CHANGE:` commits and issues with a breaking-change note.
3. Run the part's smoke test, security pass and performance pass on the release PR's head (`Docs/workflow.md`, release step 3) and record the results in the PR. Fixes are separate `fix/` tickets merged first.
4. Open the PR (title `chore(release): <part> <x.y.z>`), get it reviewed at release level, and ask the PO to approve and merge it (**squash**, like every PR).
5. After the merge, check that CI created the tag `<part>-v<x.y.z>`, tagged the part's images (`ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>`) and created the GitHub Release. If it didn't, tell the PO what failed; never create the tag by hand. Check the Release workflow's `push` run on the merge commit concluded `success`, not `cancelled`.
6. Close the milestone (`gh api -X PATCH repos/rodgallert/Elysium/milestones/<number> -f state=closed`).

### `hotfix <ticket>`: fix a released version
1. Fix it on `main` first as a normal `fix/` ticket.
2. If `main` has nothing else for that part since its release, do `release` as a patch version. Otherwise:
3. If `release/<part>-<x.y>` doesn't exist, ask the PO to create it from the part's release tag (`git push origin <part>-v<x.y.z>^{commit}:refs/heads/release/<part>-<x.y>`; only the repository admin may create release branches, `Docs/workflow.md`, "Version tags and release branches"). Then branch `hotfix/<part>-<x.y.z+1>` from it (from the issue: `gh issue develop <n> -R rodgallert/Elysium --base release/<part>-<x.y> --name hotfix/<part>-<x.y.z+1>`), cherry-pick the fix, bump the patch version in the part's version file and the changelog, open the PR into the release branch, and run the Release workflow's `prepare` run on the hotfix branch.
4. After the PO merges it and CI releases it, open a PR into `main` (`chore(release): <part> <x.y.z+1>`) that copies the version, the changelog and the production pin; CI sees that version is already released.

## Rules
- **Pushing:** the flow's steps push without asking: creating ticket and hotfix branches, pushing phase tags, and pushing a working branch's commits while its PR is open. Never force-push, never push commits to `main` or a release branch, never create release tags (CI does) or release branches (the PO does), and never merge: the PO merges.
- The board follows the work, never the other way round: move an issue when its step actually happens, not ahead of time.
- New work found along the way (a bug, a "Later" item from a review) gets its own issue in **Backlog** with the right labels and milestone (one issue per release part when it changes several: `Docs/workflow.md`, "Issues, epics and milestones"). Never widen a ticket silently.
- If `tools/board.sh` fails (no `project` scope, board missing), still do the issue steps and tell the PO what failed.
