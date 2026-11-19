---
name: Ticket
about: One task with its spec. The PO approves the spec before the ticket starts (Docs/workflow.md, "Specs and tests").
title: "<type>(<scope>): <summary>"
labels: ticket
---
Epic: #<n>

<!-- Tickets only: epics and releases are filed by hand.
     Keep the first line as it is: `Epic: #<n>` names the epic the ticket belongs to.
     Replace every placeholder. A section that doesn't apply says "None." and why; it is never deleted.
     Also add the `type: <type>` label and the milestone (Docs/workflow.md, "Issues, epics and milestones").
     Don't add a `Branch:` line: the start step adds it when the work starts, and `PR:` follows it. -->

## Goal
One or two sentences: what is different when this ticket is done, and why it matters.

## Context and decisions relied on
What a reader needs before the criteria, and a link to where each decision this ticket relies on is written: a tracked document (`Docs/`, `ROADMAP.md`, a service's decision log) or this issue. A decision that isn't written in one of those yet is recorded there first. Untracked notes are never the source.

## Acceptance criteria
Numbered, each one checkable by a test or by a step the PO can run. No "works correctly". The ids are what tests and the PR cite: `#<issue>-AC<n>` for a criterion and `#<issue>-AC<n>.<m>` for an edge case under it.

1. **#<issue>-AC1:** <observable behaviour, with exact values: limits, status codes, timings>
   - **Edge cases and failure paths.** One line per category, each a case with an id or `n/a: <reason>`; "covered elsewhere" names the test. The reviewer judges the reasons.
     - **#<issue>-AC1.1 inputs:** <invalid, missing, malformed, oversized, hostile>
     - **#<issue>-AC1.2 boundaries:** <empty, one, maximum, just over the limit>
     - **#<issue>-AC1.3 state and lifecycle:** <wrong state: already deleted, confirmed or revoked; out-of-order messages>
     - **#<issue>-AC1.4 time:** <expiry, clock skew, "+4:59 / +5:01" boundaries; a movable clock>
     - **#<issue>-AC1.5 concurrency:** <two requests or messages for the same thing at once>
     - **#<issue>-AC1.6 partial failure:** <a dependency down or slow, a crash between two steps>
     - **#<issue>-AC1.7 retries and idempotence:** <the same request or message twice: the effect happens once, asserted on the resulting rows or messages>
     - **#<issue>-AC1.8 permissions:** <wrong account, wrong product, expired or revoked token>
     - **#<issue>-AC1.9 environment differences:** <missing or invalid config or env var, Development vs production, container start order>
     - **#<issue>-AC1.10 observability:** <the log or audit line expected on the failure path, with no secrets or personal data>
2. **#<issue>-AC2:** ...

Each listed case gets a test, and the PR maps every criterion and every listed case to its tests.

## Contracts
For an HTTP API or message change: the OpenAPI document or message schema (path or link), merged before the tests and handlers, and the contract tests that check against it. "None." for other tickets.

## Test plan
One row per criterion; the tests cite the ids above (xUnit: the method name or `[Trait("Spec", "#<issue>-AC2.1")]`, a `[Theory]` row or `DisplayName` per case; shell tests: the function name or a comment line; frontend tests: the `describe`/`it` title).

| Criterion | Level (unit, integration, contract, smoke or lint) | Needs (real containers, movable clock, fixtures, fault injection and its tool) |
|---|---|---|
| #<issue>-AC1 | | |

A code ticket's first commit adds these tests failing, with the minimal stubs so they compile (workflow, "Specs and tests"). A spike or docs-only ticket says it is exempt.

## Manual check for the PO
Numbered steps on the running stack and what to expect (exact status code or screen text), including at least one failure path (wrong input, expired session). "None." when nothing changes behaviour.

## Out of scope
What this ticket deliberately doesn't do, and where that work is tracked (issue or roadmap task).

## Spec approval
The PO approves this spec; an `Approved: <link to the approval comment>` line is added here when they do. The `Epic:`, `Estimate:`, `Approved:`, `Branch:` and `PR:` lines are bookkeeping; an edit to any section from Goal to Out of scope after approval needs approval again, and every change to the criteria is also recorded as a `Spec change:` comment.
