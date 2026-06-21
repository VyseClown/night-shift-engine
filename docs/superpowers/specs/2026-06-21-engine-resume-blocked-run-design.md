# Engine robustness: explicit `--resume` for logic-blocked runs

**Date:** 2026-06-21
**Status:** approved (design), pending implementation
**Repo:** engine (`~/work`, `VyseClown/night-shift-engine`)
**Implementation:** by hand (the night-shift cannot safely self-target the engine repo); verified by deterministic fixtures.
**Related:** `2026-06-21-engine-robust-evidence-match-design.md` (fixes the trigger; this spec salvages the work when a block does happen).

## Problem

When a run blocks on a *logic* error (e.g. the baseline-evidence mismatch above), all
of its work is discarded. The optional-persona run had `plan_approved: true`,
`implementation_approved: true`, a finished candidate commit, and 16/16 persona
approvals — yet a re-invocation would start a **fresh run** (re-plan, re-implement),
throwing away ~20 minutes of paid work.

## Root cause (confirmed)

`recover_run` only resumes a run when `status == "running"` **or** the block is a
recoverable rate-limit block:

```sh
if [ "$status" != "running" ]; then
  recoverable_rate_limit_state "$STATE" "$recovery_raw" || return 1
fi
```

A logic block (`status: "blocked"`, no `rate_limit_reset_at`) is neither, so
`recover_run` returns 1. The caller then falls through to `initialize_run` (a brand-new
run). There is **deliberately** no auto-resume for logic blocks: auto-resuming a block
that recurs every time would create a sleep-and-retry spiral (the exact failure mode
the rate-limit code guards against).

## Decision

Add an **explicit operator `--resume` flag**. The operator — not the engine — decides
to retry a preserved blocked run. With the flag, `recover_run` accepts a logic-blocked
state (guarded by a session match), clears the block, and re-enters at the recorded
stage with approvals intact, so the primary retries only the failed step. Without the
flag, behaviour is unchanged (fresh run). Explicit invocation removes the
infinite-loop risk while preserving the expensive plan + implementation work.

## Design

1. **New flag** `--resume` → `RESUME=1` (default 0), parsed alongside the existing
   flags. Documented in `usage`.
2. **`recover_run` accepts a flagged logic block.** When `RESUME=1` and
   `status == "blocked"` and it is **not** a rate-limit block:
   - require a present, well-formed `session_id` and that `.primary` matches the
     current primary (mirror the rate-limit recovery's session guard); otherwise
     `die` with a clear message rather than guessing.
   - clear the block: `state_set '.status="running" | del(.block_reason) | …'` and
     rebase the stage/task clocks to now (as the normal running-resume path does).
   - leave `plan_approved` / `implementation_approved` / `baseline_complete` / the
     recorded stage untouched, so the run re-enters at the stage it blocked in and the
     primary retries the failed transition (e.g. re-issue `CREATE_CANDIDATE`).
3. **`--resume` with nothing to resume** (no state, or a `running`/non-blocked state,
   or a session mismatch) → `die` with an actionable message; never silently start a
   fresh run under `--resume`.
4. **No auto-resume.** Without `--resume`, a logic-blocked state still yields a fresh
   run exactly as today (no behavioural change to existing invocations).

## Interaction with the companion spec

Resuming the optional-persona block only *passes* once the evidence-match guard is
fixed (companion spec). The two are complementary: (a) stops correct runs from blocking
on transcription; (b) recovers the work cheaply if any future block occurs.

## Acceptance criteria

- [ ] AC1: `--resume` is parsed, defaults off, and documented in `usage`.
- [ ] AC2: With `--resume` on a preserved logic-blocked state whose `session_id` is
  present and `primary` matches, `recover_run` returns success, sets `status` back to
  `running`, removes `block_reason`, and preserves `plan_approved` /
  `implementation_approved` / `stage`.
- [ ] AC3: Without `--resume`, a logic-blocked state still produces a fresh run
  (`recover_run` returns non-zero) — no behavioural change to existing runs.
- [ ] AC4: `--resume` with no resumable state (missing/`running`/session-mismatch)
  `die`s with a clear message and does **not** initialize a fresh run.
- [ ] AC5: No auto-resume path is introduced; a recurring block cannot loop without the
  operator re-passing `--resume`.
- [ ] AC6: `scripts/night-shift.sh --fixture-test --dry-run` stays green with new
  fixtures for AC2/AC3/AC4.

## Test plan (fixtures)

Extend the existing recovery fixtures (`fixture_state_recovery`,
`fixture_cleanup_recovery`) with `fixture_resume_blocked`:
- blocked state + matching session + `RESUME=1` → recoverable (status flips to
  running, block_reason cleared, approvals preserved).
- same state + `RESUME=0` → not recoverable (returns 1 → fresh-run path).
- blocked state + session mismatch + `RESUME=1` → `die`/reject (not silently fresh).

Drive `recover_run`'s decision through the same state-file harness the rate-limit
fixtures use, asserting the resulting `state.json` fields.

## Out of scope

- A re-verify-only fast path that skips re-entering the stage (the recorded stage
  re-entry already retries just the failed step; a dedicated re-verify path is a
  possible future optimization).
- Resuming across a different primary or a changed spec (rejected by the session /
  primary guard).
- The evidence-match fix itself (companion spec).
