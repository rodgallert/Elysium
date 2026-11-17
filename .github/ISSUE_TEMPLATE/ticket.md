---
name: Ticket
about: One task with its spec. The PO approves the spec before the ticket starts (Docs/workflow.md, "Specs and tests").
title: "<type>(<scope>): <summary>"
labels: ticket
---
Epic: #<n>

<!-- Keep the first line as it is: `Epic: #<n>` names the epic (phase or sprint group) the ticket belongs to.
     Replace every placeholder. A section that doesn't apply says "None." and why; it is never deleted.
     Also add the `type: <type>` label and the milestone (Docs/workflow.md, "Issues, epics and milestones"). -->

## Goal
One or two sentences: what is different when this ticket is done, and why it matters.

## Context and decisions relied on
What a reader needs to know before the criteria, and links to the tracked documents (or issue comments) holding each decision this ticket relies on, such as `Docs/platform-design.md` sections, decision logs, roadmap tasks. A decision that isn't in a tracked document yet is recorded there first; the issue never points at untracked notes.

## Acceptance criteria
Numbered, each one checkable by a test or by a step the PO can run. No "works correctly".

1. **AC1:** <observable behaviour, with exact values: limits, status codes, timings>
   - Edge cases and failure paths:
     - <invalid or missing input>
     - <boundaries: empty, one, maximum, just over the limit>
     - <concurrency: two requests or messages for the same thing at once>
     - <partial failure: a dependency down or slow, a crash between two steps>
     - <retries and duplicates: the same message or request twice>
     - <permissions: wrong account, wrong product, expired or revoked token>
2. **AC2:** ...
   - Edge cases and failure paths: ...

Every criterion has an "Edge cases and failure paths" list. Cover the categories above that apply and say which don't. Each listed case gets a test, and the PR maps every criterion and listed case to its tests.

## Contracts
For a ticket that adds or changes an HTTP API or a message: the OpenAPI document or message schema (path or link), merged before the handlers, and the contract tests that check against it. "None." for other tickets.

## Test plan
Which tests prove the criteria and at which level (unit, integration against real containers, contract, smoke or lint check for compose and infrastructure). A code ticket's first commit adds these tests failing. A spike or docs-only ticket says it is exempt. Each test's name or description carries the criterion it covers (`AC1`, `AC2`, ...).

## Manual check for the PO
Numbered steps on the running stack and what to expect, or "None." when nothing changes behaviour.

## Out of scope
What this ticket deliberately doesn't do, and where that work is tracked (issue or roadmap task).

## Spec approval
The PO approves this spec on the issue before the ticket starts. Changes to the criteria after approval are made on the issue and re-approved.

Branch:
