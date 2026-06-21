# Engine robustness: exit-status-based evidence matching (drop byte-exact command match)

**Date:** 2026-06-21
**Status:** approved (design), pending implementation
**Repo:** engine (`~/work`, `VyseClown/night-shift-engine`)
**Implementation:** by hand (the night-shift cannot safely self-target the engine repo); verified by deterministic fixtures.

## Problem

A real run (optional-persona toggles) completed plan ✅, implementation ✅ (16/16
personas, 83+29 tests green), produced candidate `2acc09e`, then **blocked at the
final verify gate** with `primary baseline evidence does not match wrapper-owned
baseline`.

## Root cause (confirmed)

`verify_candidate` cross-checks the primary's `execution-evidence.json` against the
wrapper-owned `validated/*.json` by **byte-exact command-string match**. The primary
re-types the validation commands into its evidence JSON, and an escaped character did
not survive transcription:

| Source | Baseline command | exit |
|---|---|---|
| wrapper `validated/baseline.json` | `find … -exec node --check {} `**`\;`** | 0 |
| primary `execution-evidence.json` | `find … -exec node --check {} `**`;`** | 0 |

Both commands ran identically (exit 0); only the `\;`→`;` transcription differed. The
guard is byte-exact, so it blocked. This is non-deterministic — it depends on whether
the LLM reproduces escape characters verbatim.

There are **four** byte-exact command comparisons with this fragility, all in
`verify_candidate`:

1. `test-first command differs from wrapper-owned failing command` — `[ "$test_command" = … ]`, where `test_command` is read **from the evidence** and then used to run the passing test.
2. `primary test-first evidence does not match wrapper-owned executions` — includes `.test_first.command == $failing[0].command`.
3. `primary baseline evidence does not match wrapper-owned baseline` — `[.baseline[] | {command,exit_status}] == …` (the trigger).
4. `primary final evidence does not match wrapper-owned validation` — `[.final_validation[] | {command,exit_status}] == …`.

For (3) and (4) the wrapper **owns** the commands (it ran the spec's commands itself);
the primary's echoed strings are pure redundancy. For (1)/(2) the wrapper currently
**uses the primary's echoed command** to run the passing test — which is the only
place a command string has teeth.

## Decision

**Compare `exit_status` only; never trust or match the primary's echoed command
strings.** The wrapper runs and owns every validation command, so the integrity
signal that matters — "the same commands produced the same exit statuses the wrapper
recorded" — is fully preserved. Escape-character transcription can no longer block a
correct run.

## Design

In `verify_candidate`:

1. **Run the passing test with the wrapper's own command**, not the primary's. Read
   `test_command` from `validated/test-first-failing.json` (wrapper-owned) instead of
   from the evidence. This removes the only place a primary-supplied command string
   drives control flow.
2. **Remove** the byte-exact `test-first command differs …` equality (guard 1).
3. **Relax guard 2** to compare exit statuses only:
   `.test_first.failing_exit_status == $failing[0].exit_status and
    .test_first.passing_exit_status == $passing[0].exit_status` (drop the
   `.test_first.command == …` term).
4. **Relax guards 3 and 4** to compare exit-status arrays (order + length preserved),
   dropping `command` from the projection:
   `[.baseline[] | .exit_status] == [$baseline[0][] | .exit_status]` and the analogous
   `final_validation` form.

No change to the `execution-evidence` schema (the primary may still include `command`
fields; they are simply no longer matched). `validation_not_regressed` (the
wrapper-vs-wrapper baseline/final comparison) is unchanged and remains the substantive
correctness gate.

## Acceptance criteria

- [ ] AC1: `verify_candidate` reads the passing-test command from
  `validated/test-first-failing.json`, not from the primary's evidence.
- [ ] AC2: All four command comparisons listed above are exit-status-only; no
  `block_run` fires on a command-string difference when the exit statuses match in
  order.
- [ ] AC3: A run whose primary echoes `find … {} ;` while the wrapper recorded
  `find … {} \;` (identical exit statuses) **passes** verification.
- [ ] AC4: A genuine mismatch still blocks — e.g. a primary-claimed `exit_status` that
  differs from the wrapper's recorded value, or a differing number of commands.
- [ ] AC5: `scripts/night-shift.sh --fixture-test --dry-run` stays green; a new
  fixture covers AC3 (escape-char difference passes) and AC4 (exit-status mismatch and
  count mismatch block).

## Test plan (fixtures)

Add `fixture_evidence_exit_status_match`:
- Build an `execution-evidence` JSON and matching wrapper `baseline.json`/`final.json`
  where the command strings differ only by `\;`↔`;` but exit statuses match →
  the comparison predicate returns true.
- Same exit statuses but a flipped value (0 vs 1) → predicate false (would block).
- Different command **count** → predicate false (would block).

Extract the comparison into a small pure helper (e.g. `evidence_exit_status_matches`)
so the fixture can exercise it directly without a full run, mirroring the existing
observer/verdict fixtures.

## Out of scope

- Removing `command` from the `execution-evidence` schema (kept for human readability;
  just not matched).
- The resume/recovery of blocked runs — see the companion spec
  `2026-06-21-engine-resume-blocked-run-design.md`.
