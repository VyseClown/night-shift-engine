# Changelog

Completed work is recorded here only after validation, six persona approvals,
and observer approval.

## Unreleased

- Per-spec **review profiles**: specs declare a `Review Profile`
  (`full`/`frontend`/`logic`/`native`) that selects which personas review the
  work, cutting cost on focused tasks. A mandatory floor (React Native Architect,
  TypeScript & Code Quality Expert, Human Advocate) plus the observer always run;
  the resolver asserts the floor independently so the table can't drop a safety
  reviewer. Spec validation requires a valid profile and only demands
  documentation ownership for active personas; the persona gate now enforces the
  active set and count instead of a hardcoded six. Two new deterministic
  fixtures cover profile resolution and the gate.
- Night-shift workflow upgrade pending final validation and review.
- Default `--primary` to `claude` (observer becomes `codex`).
- Primary prompt now states the per-action contract (RUN_PERSONAS six-file
  output, CREATE_CANDIDATE evidence, NEXT_TASK TODO check-off) and schema paths.
- Block runs when a validation/test-first command exits 127, so missing tooling
  cannot pass the regression gate silently.
- Add three-round stall detection to persona review loops (was observer-only);
  finding history is now keyed per task.
- `state_set` and `record_findings` now fail loudly instead of leaving stale
  state on `jq` errors.
- Two new deterministic fixtures: missing-tool detection and stall counter.
- Claude-only flow: Claude is the primary, the six persona sub-agents, and the
  observer (a fresh, independent Claude session — no shared context). Removed the
  Codex primary/observer/persona code paths, the `--output-schema`/session
  extraction helpers, and the cross-model observer-review schema constraint.
  Observer output is parsed from the result text (tolerating a code fence) and
  validated against the schema with one retry, instead of an unverified
  structured-output flag.
- Observer is now context-isolated: launched as a fresh independent session (no
  `--resume`) from a neutral empty temporary directory in the default
  (non-bypass) permission mode, so tool use is not auto-approved and the observer
  cannot inspect the repository — it reviews only the supplied evidence passed in
  the prompt (was: ran inside the project with full tool access). Note: `--allowedTools`
  is not passed because it is variadic and would swallow the prompt argument.
- Isolated validation worktree now symlinks ignored dependency dirs
  (`node_modules`, `ios/Pods`, override via `NIGHT_SHIFT_DEPENDENCY_LINKS`) from
  the project, so RN type-check/lint/test run without reinstalling or triggering
  npx downloads.
- Stall fingerprints now fold in a material token (full diff vs base) plus
  test-first evidence, so changed code/tests/evidence reset the three-round
  counter and legitimate resolution attempts are not falsely blocked.
- New fixture: validation worktree dependency linking (23 deterministic checks).
