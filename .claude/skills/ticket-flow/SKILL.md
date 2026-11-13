---
name: ticket-flow
description: Keep Elysium's GitHub issues and project board in step with the work. Use at every step of implementing the roadmap - starting a ticket or a phase, opening a PR, merging it, a phase checkpoint, a release or a hotfix - so the related issue moves to the right board column and gets the right branch, links and comments. Arguments are the step and the issue number, e.g. "start 20", "review 20", "done 20".
---

# Elysium ticket flow

Every piece of roadmap work has a GitHub issue: a **ticket** (one roadmap task), grouped under an **epic** (one phase), inside a **GitHub milestone** (one service release, e.g. "Masquerade v0.1"). The project board **"Elysium"** shows where each one is. Whoever does the work follows these steps so the issue and the board always match reality. The branch and review rules are in `Docs/workflow.md`; this skill only adds the issue and board side.

**gh account:** the repo is `rodgallert/Elysium`, but gh's active account belongs to another project and must not be switched. Start every shell command that runs `gh` for this repo with `export GH_TOKEN=$(gh auth token --user rodgallert);` (the board scripts do this themselves). If that fails, gh has no login for rodgallert: stop and ask the PO to run `gh auth login --skip-ssh-key -s project`.

Board columns: **Backlog** → **Ready** → **In progress** → **In review** → **Ready to Merge** → **Done**.

- **In review**: the PR is open and the review is running, or its findings are being fixed.
- **Ready to Merge**: the review is clean (no must-fix or should-fix left, CI green when the PR has a build check) and the PR waits for the PO's approval.

**Every piece of work has an issue, a branch and a PR, linked both ways.** No branch or PR without its issue (create one first, under the right epic, even for workflow and tooling work: those go under the "Workflow and tooling" epic). A release PR belongs to its release ticket. An issue in **In progress** has its branch; an issue in **In review** or later has its PR. The issue body ends with `Branch:` and `PR:` lines, and the PR body starts with `Closes #<issue>`.

Move an issue with `tools/board.sh <issue> "<column>"` (it adds the issue to the board if it isn't there yet).

Changing a board field's options (adding, renaming or removing a Status, Sprint or Priority option) can clear every item's value for that field. Before such a change, run `tools/board-field.sh save <field> <file>`; after it, `tools/board-field.sh check <field> <file>`, and put back any value it reports. Setting an item's value is safe and needs neither.

**Start only on the PO's go.** Answering questions, approving a plan or agreeing to a setup step is not a go: confirm and ask "should I start #n?" instead.

## Steps

### `start <ticket>`: begin a ticket
1. Read the ticket: `gh issue view <n> -R rodgallert/Elysium --json title,body,labels,milestone`. Its body holds the roadmap task. Check it against the current `ROADMAP.md`; if they differ, the roadmap wins, so update the issue body first.
2. Find its epic (the `Epic: #n` line). If that epic is a phase that hasn't started yet, do `start-phase` first.
3. Update `main` (`git switch main && git pull --ff-only`), then create the ticket branch **from the issue**, so GitHub links them (it shows under the issue's Development section): `gh issue develop <n> -R rodgallert/Elysium --base main --name <type>/p<n>-<slug> --checkout` for a roadmap task, `<type>/<slug>` for other work. The type comes from the ticket's `type: …` label. (GitHub can only link a branch it creates this way; an existing branch can't be linked later.) Hotfixes for an older release follow `hotfix` below.
4. Add a `Branch: <branch>` line to the end of the issue body, `tools/board.sh <n> "In progress"`, assign it (`gh issue edit <n> -R rodgallert/Elysium --add-assignee @me`), and comment: `Started on branch <branch>.`
5. If the planned change is breaking (`Docs/workflow.md`, "Breaking changes"), add a **Breaking change** note to the issue now: what it can break and what consumers need to do, or which finished scenarios must be tested again.
6. One ticket in progress at a time per engineer. If a ticket can't go on (blocked, needs a decision), comment why and move it back to **Ready**.

### `review <ticket>`: the PR is open
1. The PR (title in Conventional Commits, base = `main`, or the service's release branch for a hotfix) starts with `Closes #<n>` for each ticket it completes, and each ticket's body gets a `PR: #<pr>` line. A ticket the PR only partly completes gets `PR: #<pr> (first part)` and stays open. If the change is breaking, the PR has a "## Breaking change" section and the issue's note is up to date.
2. `tools/board.sh <n> "In review"` for each of those tickets, and comment: `In review: #<pr>.`
3. Get the PR reviewed by **someone other than its author**, following the `pr-review` checklist. The PR description's Review section states the result and what was checked in plain project language, without mentioning agents, skills or how the review was done. When the review sends work back, move the ticket to **In progress** until the fixes are pushed, then back to **In review**. If `main` moved on and the PR conflicts, merge `origin/main` into the ticket branch (a normal merge; no rebase, no force-push).
4. When the review is clean (no must-fix or should-fix items left, CI green when the PR has a build check), check that **nobody is still working on the PR**, that the PR's head on GitHub equals the branch tip, that CI ran on that commit, and re-read the description. Then `tools/board.sh <n> "Ready to Merge"` and ask the PO to approve the merge (**squash** for ticket PRs). Anything that needs the PO's confirmation (decided rules or numbers that changed) is in the PR description by then.

### `done <ticket>`: the PR merged (only after the PO approved it)
1. Merges into `main` close the PR's `Closes #n` issues automatically; check they closed (`gh issue view <n> -R rodgallert/Elysium --json state`) and close any that didn't: `gh issue close <n> -R rodgallert/Elysium --reason completed --comment "Done in #<pr>."` (hotfix PRs into a release branch never auto-close).
2. `tools/board.sh <n> "Done"`.
3. Update the local `main` (`git switch main && git pull --ff-only`) and delete the merged ticket branch (`git branch -D <branch>`; `-D`, because a squash merge isn't an ancestor).
4. Pick the next ticket of the phase and move it to **Ready**, unless the PO named another one.
5. If every sub-issue of the phase's epic is now closed, the phase is ready for its checkpoint: go to `checkpoint`.

### `start-phase <epic>`
A phase has no branch. `tools/board.sh <epic> "In progress"`, and move the phase's first tickets to **Ready**.

### `checkpoint <epic>`: a phase is done
1. Review the phase as a whole: everything that changed in `main` since the previous `phase-*-done` tag (`git log phase-<n-1>-done..origin/main`), by someone other than the engineers who wrote it, against the phase's roadmap section, including a security and performance look. Findings become `fix/` tickets.
2. Ask the PO to check the phase's **Done when** on a running stack, with exact steps (commands, requests, screens) and what to expect, on a named `main` commit (give its hash: `main` keeps moving). Move the epic to **In review** meanwhile.
3. When both pass: tag **that checked commit** (`git tag -a phase-<n>-done -m "Phase <n>: <name>" <checked-commit> && git push origin phase-<n>-done`), close the epic with a comment naming the tag, and `tools/board.sh <epic> "Done"`.

### `release <service> <x.y.z>`: release one service
1. Check the service's milestone: every ticket is closed and on `main`, and the phase checkpoint it depends on (if any) has passed. Leftovers move to the next milestone only with the PO's OK.
2. Work the release ticket like any ticket (`start`), on `chore/release-<service>-<x.y.z>`: bump the part's version in its version file (`Docs/workflow.md`, "Versions and release parts"); in its `CHANGELOG.md` move the "Unreleased" entries under the new version with a "Breaking changes" heading (every breaking change since its last release, with what can break and what to do, or "None") and a "Known issues" line; for a first release, add the service's blocks to `docker-compose.prod.yml` (tag only). Then run the Release workflow's `prepare` run on the branch, which pins the image digests. Search the milestone for `BREAKING CHANGE:` commits and issues with a breaking-change note.
3. Run the service's smoke test, security pass and performance pass on the release PR's head (`Docs/workflow.md`, release step 2) and record the results in the PR. Fixes are separate `fix/` tickets merged first.
4. Open the PR (title `chore(release): <service> <x.y.z>`), get it reviewed at release level, and ask the PO to approve and merge it (**squash**, like every PR).
5. After the merge, check that CI created the tag `<part>-v<x.y.z>`, tagged the part's images (`ghcr.io/rodgallert/elysium-<service>-<component>:<x.y.z>`) and created the GitHub Release. If it didn't, tell the PO what failed; never create the tag by hand.
6. Close the milestone (`gh api -X PATCH repos/rodgallert/Elysium/milestones/<number> -f state=closed`).

### `hotfix <ticket>`: fix a released version
1. Fix it on `main` first as a normal `fix/` ticket.
2. If `main` has nothing else for that service since its release, do `release` as a patch version. Otherwise:
3. Create `release/<service>-<x.y>` from the service's release tag if it doesn't exist (`git push origin <service>-v<x.y.z>^{commit}:refs/heads/release/<service>-<x.y>`), branch `hotfix/<service>-<x.y.z+1>` from it (from the issue: `gh issue develop <n> -R rodgallert/Elysium --base release/<service>-<x.y> --name hotfix/<service>-<x.y.z+1>`), cherry-pick the fix, bump the patch version and the changelog, open the PR into the release branch, and run the Release workflow's `prepare` run on the hotfix branch.
4. After the PO merges it and CI publishes the image, open a PR into `main` that updates the production pin and the changelog.

## Rules
- **Pushing:** the flow's steps push without asking: creating ticket, release and hotfix branches, pushing phase tags, and pushing a working branch's commits while its PR is open. Never force-push, never push commits to `main` or a release branch, never create release tags (CI does), and never merge: the PO merges.
- The board follows the work, never the other way round: move an issue when its step actually happens, not ahead of time.
- New work found along the way (a bug, a "Later" item from a review) gets its own issue in **Backlog** with the right labels and milestone. Never widen a ticket silently.
- If `tools/board.sh` fails (no `project` scope, board missing), still do the issue steps and tell the PO what failed.
