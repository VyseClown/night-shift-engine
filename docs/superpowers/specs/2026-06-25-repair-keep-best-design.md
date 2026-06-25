# Repair "keep-best + converge" — design

Date: 2026-06-25. Repo: `night-shift-engine`. Makes the design-review auto-fix bring a
screen **as close as possible** to its Figma design by changing the repair loop's
convergence policy — it already feeds the agent the Figma design (Dev Mode specs +
tokens via `mcp__figma__get_figma_data`, the reference image, and the diff).

## 1. Problem

`visual_repair_screen` (`scripts/lib/visual-repair.sh`) stops at a fixed tolerance or
a small `max` attempts and **ends on the last attempt's code** — so it can leave the
screen *worse* than an earlier attempt or worse than the starting point. Observed in a
live demo: attempts went `0.090` then `0.100` and the loop **kept `0.100`**. The agent
already has the Figma design; the limiter is the loop policy, not the design data.

## 2. Goal / non-goals

**Goal:** the loop keeps the **best-scoring** attempt and **always ends on it**
(never worse than the starting point), and **iterates until improvement stalls**
(diminishing returns) within a hard cap — pushing each screen as close to the design
as the agent can get.

**Non-goals (explicitly out of scope this increment):** widening the edit scope for
structural redesign; richer design grounding / plan-first passes; a new per-screen
fidelity report format. (These were considered and deferred.) No change to *what* the
agent is fed or *which* files it may touch.

## 3. Convergence policy (the change)

Rewrite the body of `visual_repair_screen`'s attempt loop to track a **best** result:

- **Seed best with the pre-repair baseline.** Before the loop, diff the incoming
  (pre-repair) `shot` against `ref`; that is `best_pct`. Snapshot the baseline code
  (the allowed paths) into `$tmpbase/best`, and copy the baseline `shot`/`diff_img`
  to `best_shot`/`best_diff`. This is the "do nothing" floor: if no attempt beats it,
  the loop restores the baseline (no change), never a worse edit. (If the baseline
  diff computation fails, leave best unset; the first successful attempt seeds it.)
- **Per attempt** (after the existing snapshot → agent → scope/validate gate →
  capture+diff that yields `cur`):
  - **Improved?** `cur` beats `best_pct` by at least `EPSILON`
    (`best_pct` unset, or `cur <= best_pct - EPSILON`). On improvement: set
    `best_pct=cur`; snapshot the **current** code into `$tmpbase/best`; copy the
    current `shot`/`diff_img` to `best_shot`/`best_diff`; reset `stall=0`.
  - Else: `stall=stall+1`.
  - Record the attempt in `attempts[]` (unchanged shape).
  - **Stop** when: `cur <= tol` (good enough → `passed`); or `stall >= PATIENCE`
    (diminishing returns); or the hard cap `max` is reached.
- **End on the best.** After the loop, restore `$tmpbase/best` into the project (the
  allowed paths), set `cur=best_pct`, and copy `best_shot`/`best_diff` back to
  `shot`/`diff_img` so the assembled report references the best attempt's images.
  Return success iff `best_pct <= tol`.

The per-attempt revert-on-scope/validation-failure behavior (the existing `$snap`
snapshot + `visual_repair_restore`) is unchanged and independent of best-tracking.

### Float comparison

All diff_pct comparisons use `awk` (as the loop already does for `pass`), e.g.
`improved = (best unset) || (cur <= best - EPSILON)`; never shell numeric `[ ]`
(diffs are fractions like `0.0903`).

## 4. Knobs / defaults

- `NIGHT_SHIFT_VISUAL_REPAIR_EPSILON` — min meaningful improvement. Default **0.005**.
- `NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE` — consecutive non-improving attempts tolerated
  before stopping. Default **2**.
- Hard cap = the existing `max` arg (the 11th param). Its callers' default rises
  **3 → 6** (`scripts/visual-review.sh`, `visual_repair_for_spec`, and the in-loop
  `run_visual` in `night-shift.sh` — wherever `${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}`
  appears). Patience usually stops earlier, so the higher cap only spends attempts
  while the screen is still improving.

This is the **new default** behavior of the repair primitive (repair is itself opt-in
via `--repair` / `NIGHT_SHIFT_VISUAL_REPAIR`). It is strictly never-worse than today's
last-attempt behavior.

## 5. Interaction with the surfaces (no caller logic change beyond the cap default)

- **Standalone** (`visual-review.sh --repair`): the uncommitted edits left for review
  are now the best attempt's (or none, if nothing beat the baseline).
- **In-loop** (`run_visual` in `night-shift.sh`): the tree it commits as the repaired
  candidate is the best attempt's code; the refreshed report shows `best_pct`. Both
  already read whatever `visual_repair_screen` leaves on disk + in the report, so no
  in-loop logic changes — only the cap default.

## 6. Testing

Deterministic fixtures (model `fixture_visual_repair_loop`: a temp git project +
injected `agent_fn`/`capture_fn`/`validate_fn` + `NIGHT_SHIFT_VISUAL_DIFF_FN`). The
agent writes a distinguishable marker per attempt (e.g. the attempt number into a
file) so "ended on the best attempt's code" is checkable.

- **keep-best (non-last best):** diff sequence `0.30, 0.09, 0.12` (tol below all,
  patience high). Assert: report `diff_pct == 0.09`; the project file holds the
  **attempt-2** marker (restored to best), not attempt-3's.
- **never-worse than baseline:** baseline diff `0.10`, the only attempt yields `0.30`.
  Assert: report `diff_pct == 0.10`; the project file is the **baseline** content
  (best restored to baseline; the agent's worse edit discarded).
- **patience stop (diminishing returns):** sequence `0.30, 0.20, 0.205, 0.207` with
  `EPSILON=0.005, PATIENCE=2`, `max=6`. Assert: stops after the 2 non-improving
  attempts (≈4 total, not 6), report `diff_pct == 0.20`.
- **converge-on-pass unchanged:** the existing `fixture_visual_repair_loop` still
  passes (a passing attempt still ends the loop and returns success).

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 7. Risks

- **Snapshot cost:** snapshotting the allowed paths on each *improvement* (not every
  attempt) is a bounded file copy of `src/features/` (+ `src/ui/` with the shared
  flag) — small. The baseline snapshot adds one copy.
- **Higher cap = more paid attempts** when a screen keeps improving. Patience + the
  cap bound it; `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` still overrides.
- **A genuinely high but valid diff** (structurally divergent design) won't converge —
  the loop now ends on the best achievable (or no change), with `attempts[]` showing it
  plateaued. That is the honest, intended outcome for this scope.
