# AGENT_LOOP.md — Overnight Execution Instructions

> This file is loaded by the main implementation agent before starting a night-shift run. Follow every step in order. Do not skip steps. Do not reorder steps.

> **Unattended operation.** No human is present during the run. Never ask a
> question, request confirmation, or wait for input — there is no one to answer.
> Make reasonable decisions autonomously; when you genuinely cannot proceed
> safely, emit a `BLOCKED` next-action with the question in `reason` and stop, so
> the human can resolve it in the morning. The human validates everything then.

---

## Before You Start

1. Read `AGENTS.md` — the workspace router.
2. Identify the target spec from `--spec` or `TODO.md`. Select unfinished bugs
   before features, then preserve file order.
3. Validate all required spec fields. If fields are missing, stop and list each
   missing field. Migrate the spec by copying the corresponding sections from
   `specs/_template.md`; do not infer answers.
4. Resolve the spec's project path. Confirm it is a Git repository and that the
   current branch is the named feature branch, not the base branch.
5. Run `git worktree list --porcelain` and reject a conflicting branch checkout.
6. Capture `git status --porcelain=v1`, HEAD, branch, and worktree list as the
   immutable baseline. A dirty tree is allowed. Preserve all existing changes,
   and never stage or amend files that the run did not change.
7. Read every documentation reference in the spec.
8. Run every baseline validation command from the spec before editing. Record
   failures as baseline evidence; do not hide or silently repair unrelated
   failures.

---

## Phase 1 — Understand

1. Read the full spec file from `specs/`.
2. Read any files the spec references.
3. Map which existing source files will be touched. Do not guess — use `rg` (or
   `grep`/`find` when unavailable) to confirm.
4. If the spec is ambiguous on any acceptance criterion: stop, list the ambiguities in a `BLOCKED` block, and wait.
5. Write the plan-review packets and obtain approvals from every persona active
   in the spec's review profile (the mandatory floor always runs; `full` runs all
   six).

---

## Phase 2 — Implement

1. Add a failing test or executable check for the next acceptance criterion.
   Record its command, exit status, and relevant output before implementation.
2. Make the smallest change that makes that evidence pass.
3. Work one criterion at a time. After each criterion, run the type checker:
   ```bash
   npx tsc --noEmit
   ```
   Fix any new errors before moving to the next criterion.
3. Do not add features not in the spec. Do not refactor code outside the spec's scope.
5. If a dependency or native module change is required, verify that the spec
   explicitly permits it before touching manifests or native files.

---

## Phase 3 — Test

1. Write or update tests for every new exported function or component.
2. Run the full test suite:
   ```bash
   npm test -- --watchAll=false
   ```
3. If tests fail: fix the implementation (not the test) unless the test itself is wrong per the spec.
4. Run the linter:
   ```bash
   npx eslint . --max-warnings 0
   ```
5. Fix all warnings. Zero tolerance.
6. Compare failures with baseline evidence. New failures block the run.

---

## Phase 4 — Review

1. Run the implementation personas active in the spec's review profile using
   `schemas/persona-review.json`. Every finding is a blocker, and progress
   requires one `APPROVE` from each active persona. Personas judge from a
   primary-prepared review bundle (spec + plan + diff + test output) and launch
   on the cheaper reviewer model (`NIGHT_SHIFT_PERSONA_MODEL`, default `sonnet`).
2. Resolve findings in the current stage session, rerun tests, and review again.
   Re-review rounds re-run ONLY the personas with open findings — each verifies
   its own findings are resolved; approvals already earned carry forward. A stage
   scope boundary (plan → implement → observe, and observer-BLOCK → implement)
   starts a fresh session that picks up state from disk — the plan at
   `.night-shift/control/plan.md`, persona findings, evidence, and the working
   tree — instead of replaying one ever-growing session
   (`NIGHT_SHIFT_SESSION_SCOPE=run` restores the legacy single session).
3. A finding round changes materially only with relevant behavior, a test for
   the disputed behavior, or new executable/documented evidence. Three
   unchanged rounds for one finding ID block the task.
4. Create a local candidate commit containing only run-owned changes.
5. Send the candidate/base hashes, spec, persona summary, validation evidence,
   relevant tests, and documentation to a fresh, independent Claude observer session.
6. Validate observer output against `schemas/observer-review.json` and append
   it to `NIGHT_SHIFT_REVIEW.md`. Resolve every finding before another task.

---

## Phase 5 — Commit

1. Stage only the files changed for this feature:
   ```bash
   git add [specific files]
   ```
   Do not use `git add -A` or `git add .`.
2. Write the commit message:
   - First line: `feat(scope): short description` (≤ 72 chars)
   - Blank line
   - Body: what changed and why (not how — the diff shows how)
   - If there were review WARNINGs not fixed: list them under `Known warnings:`
3. Commit locally (or amend the current task's candidate only):
   ```bash
   git commit -m "..."
   ```

---

## Phase 6 — Report

Write a short summary to the human:

```
DONE: [feature name]
SPEC: specs/[filename].md
COMMIT: [commit hash] — [commit message first line]
TESTS: [N] passing, [0] failing
REVIEW: [N] blockers fixed, [N] warnings noted
WARNINGS NOT FIXED: [list or "none"]
BLOCKERS: none
```

If anything went wrong at any phase, replace `DONE` with `INCOMPLETE` and describe what was left and why.

On success, retain compact state and validated reviews in
`.night-shift/archive/<run-id>/`; remove raw prompts, streams, packets, and
transient logs. On block or failure, preserve complete state for exact-session
recovery.

---

## Abort Conditions

Stop immediately and report if:
- You are about to modify `main` or a shared branch directly
- A test that was passing before your changes now fails and you cannot determine why
- A native file needs to change but the spec does not mention native changes
- You have been iterating on the same fix for more than 3 attempts without progress
- The spec contradicts the existing codebase in a way that requires an architectural decision
- An explicit primary session ID is missing, changes, or cannot resume (within a stage)
- A stage reaches 12 primary turns or 60 minutes
- A task reaches 36 primary turns or three hours
- A reviewer remains missing or malformed after one retry
- The wrapper cannot prove candidate commits exclude pre-existing work
