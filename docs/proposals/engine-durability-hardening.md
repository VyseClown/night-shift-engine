# Spec: Harden durability/concurrency edges

> Engine self-improvement issue-spec. Target repo: **this repo**.
> Priority: **MEDIUM**. Four independent low-probability edges; can land as
> separate commits.

---

## Status

- [x] Draft
- [x] Ready for implementation
- [x] In progress
- [x] Done (3 of 4) — branch: `claude/recent-changes-open-prs-6yzp7h` (142 fixtures pass, shellcheck clean)

Implemented:
1. **Trap gap** — `initialize_run` now arms the `HUP/INT/TERM → block_run` trap
   immediately after `state.json` is written, before the minutes-long baseline
   validation, so an early signal records a resumable block instead of leaving
   `status=running` for the supervisor to escalate. `main_run` re-arms it for the
   recovery path (harmless).
2. **PID reuse** — `lock_is_stale` (`locking.sh`) now compares the holder's
   recorded process start time (`proc_start_time`: `/proc/<pid>/stat` field 22 on
   Linux, `ps -o lstart=` on BSD) against the live PID's; a mismatch ⇒ reused PID ⇒
   reclaimable. Falls back to liveness-only when start time is unrecorded/unreadable
   (backward compatible — the device-registry "reclaim stale" fixture still passes).
3. **Worktree orphan** — `verify_candidate` records the intended worktree path
   *before* creating it, and `prepare_validation_worktree` prunes a pre-existing
   orphan at that exact (RUN_ID+candidate-unique) path on re-entry instead of
   blocking.

Deferred:
4. **fsync** — not implemented. Portable per-file fsync from bash is awkward
   (`sync` is global/heavy), `tmp+mv` already gives crash-atomicity (old-or-new,
   never torn), and power-loss during an overnight workstation run is low-impact.
   Left as a knob-gated follow-up if power-loss durability is ever required.

Tests: `fixture_lock_pid_reuse` (alive+match=live, alive+mismatch=stale,
no-start=fallback-live, dead=stale) and `fixture_worktree_reentry` (orphan pruned
and recreated, no wedge).

---

## Repository

- Project path: `night-shift-engine/`
- Base branch: `main`
- Feature branch: `feat/engine-durability-hardening`
- Track: node (bash; shellcheck + `--fixture-test`)
- Files: `scripts/night-shift.sh`, `scripts/lib/locking.sh`,
  `scripts/night-shift-supervised.sh`

---

## Problem

Error recovery is the engine's strongest area, but the audit (verified against
source) confirmed four real edges. None fails *open* to acceptance; all are
low-probability or low-impact, but each is a genuine hole.

### 1. Early-signal trap gap

The `HUP/INT/TERM → block_run` trap is installed only **after**
`recover_run`/`initialize_run` (`scripts/night-shift.sh:1823`). Baseline validation
runs inside `initialize_run`, before the trap exists. A signal during that
minutes-long phase frees the lock (EXIT trap) but leaves `status=running` with no
`block_reason`. The supervisor then treats an empty `block_reason` as a hard error
and **escalates** instead of auto-resuming
(`scripts/night-shift-supervised.sh:~85-86`).

### 2. Orphan-worktree window

`verify_candidate` runs `git worktree add --detach` (`~1298`) and records
`validation_worktree` in state on the next line (`~1300`). A crash between them
leaves an orphan worktree. Narrowed impact: the path embeds `RUN_ID`, so it only
bites a `--resume` of the **same** run (`verify_candidate` then blocks at
`~1296-1297` "worktree already exists"); a fresh run gets a new path.

### 3. Lock PID-reuse false-live window

`lock_is_stale` (`scripts/lib/locking.sh:~20`) reclaims a lock only when the stored
PID is dead (`kill -0`). It does not compare the process **start time**, so on a
busy host a reused PID makes a stale lock look live, and a legitimate new run is
refused.

### 4. No fsync on state.json

`state_set` (`scripts/night-shift.sh:473`) writes `jq > tmp && mv tmp state` —
atomic against a crash (rename), but **not** crash-consistent against power loss
(the rename may not be durable). For the stated overnight-on-a-workstation use this
is acceptable, but a power-loss window exists.

---

## Proposed approach

1. **Trap gap:** install an interim `HUP/INT/TERM` handler **before** the long
   baseline-validation phase that records a resumable status — either set the
   trap earlier so `block_run` runs, or write `status=initializing` that the
   supervisor treats as resumable (not a hard error). Move the full trap to its
   current spot once state exists.
2. **Worktree orphan:** record the intended `validation_worktree` path in state
   **before** `git worktree add` (so recovery knows to prune it), or on re-entry
   detect-and-prune an orphan whose path matches before blocking.
3. **PID reuse:** store the lock holder's process start time alongside its PID
   (e.g. from `/proc/<pid>/stat` field 22 on Linux, `ps -o lstart= -p` on BSD) and
   require both PID-alive **and** start-time-match for "live"; mismatch → stale →
   reclaim. Keep the existing portable fallback when start time is unavailable.
4. **fsync (optional):** after writing the tmp file and before/after the rename,
   `sync` the tmp file and its parent directory at critical transitions (stage
   advance, candidate creation, completion). Gate behind a knob if the perf cost
   matters; default on only for the most critical writes.

## Acceptance criteria

- [ ] AC1: A signal delivered during baseline validation leaves the run in a state
  the supervisor **resumes**, not escalates (covered by a fixture).
- [ ] AC2: A crash simulated between `git worktree add` and the state write does
  not wedge a later `--resume` (orphan is pruned or pre-recorded).
- [ ] AC3: A stale lock whose PID has been reused by an unrelated process is
  correctly reclaimed (start-time mismatch), and a genuinely live holder is still
  respected.
- [ ] AC4 (if fsync done): state.json survives a simulated power-loss at a critical
  transition with either the old or new complete content.

## Validation

- `shellcheck` clean across changed files.
- `--fixture-test --dry-run` passes; extend the lock and recovery fixtures to
  cover the trap-gap and PID-reuse cases.

## Out of scope

- The persona/observer gate hardening (separate specs).
- Reducing hand-synced config duplication (separate spec).

## Related

- Audit recommendation #4 (MEDIUM).
