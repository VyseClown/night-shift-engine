# Visual-repair bundle freshness — design

Date: 2026-06-26. Repo: `night-shift-engine`. Fixes the **stale-bundle** convergence
blocker that PR #36 (Metro reuse, [[visual-repair-metro-collision]]) exposed: with one
engine-owned Metro, `visual-review.sh --repair` (and the in-loop repair) still re-capture
an **identical** screenshot every attempt, so the keep-best loop never sees the agent's
edits, stalls, and restores the baseline.

> **Revision (post-review, PR #37):** §4 reworked after code review caught three flaws in
> the first draft — a reset fallback that silently no-ops when Metro was reused, a fallback
> that could trigger a native rebuild, and Metro logic placed in the surface-agnostic
> `visual-capture.sh`. The mechanism below is the corrected design.

## 1. Problem (proven)

The repair loop (`scripts/lib/visual-repair.sh::visual_repair_screen`) is a bounded
keep-best loop: agent edits screen code → scope/validate gate → **re-capture** → re-diff →
keep only if it beats the running best by `epsilon`, else count a stall. The re-capture is
the injected `capture_fn` = `visual_recapture_screen`
(`scripts/lib/visual-capture.sh`), which in `--repair`'s **file-drive** mode writes
`screen:state` into the app's Documents, `simctl terminate`, `simctl launch`, sleeps, and
screenshots. The repair app is a **Debug dev client** loading JS from the **persistent
Metro** that `repair_metro_start` started once. **Nothing between the agent's edit and the
cold launch forces Metro to rebuild**, so a cold launch re-fetches the **cached** bundle —
every attempt screenshots identical pixels.

Consequence: `improved` is always "no" (`visual-repair.sh:351-358`) → `stall` reaches
`patience` → the loop stops and **restores the pre-repair baseline**
(`visual-repair.sh:363-367`). The agent's real, gate-passing edits are discarded. Keep-best
(PR `827b4e2`) made the loop *safe* (never worse than baseline) but **structurally unable to
show progress** until this is fixed.

Proven the agent + the rest of the engine are fine: a fresh `expo start --clear` on the
identical edited tree reflects the edit (**0.383 → 0.3645**); the persistent-Metro loop
stays flat at 0.383 across N attempts. The 2026-06-25 in-loop smoke "converged"
(0.1359 → 0.0004) only because it was a **single** edit→recapture on a fresh Metro — the
bug bites on the **2nd+ attempt within one Metro session**, the real autonomous case.

The "reliable refine" workaround (an external script that **restarts Metro per attempt**)
confirms the diagnosis: a full restart re-reads sources from disk, so the loop converges —
at the cost of a ~15-30s Metro cold-boot every attempt, and only as an external wrapper the
engine itself can't run.

## 2. Goal / non-goals

**Goal:** each re-capture inside `--repair` (and the in-loop repair) reads a bundle that
reflects the current on-disk sources, so the keep-best loop observes genuine diff
improvement and converges — **without** a per-attempt Metro restart in the common case.

**Non-goals:**
- Making any specific screen pass tolerance. The water-tracker **Home** screen has a
  structural diff-noise floor (debug banner; the Quick-Add row absent from Figma but locked
  by `HomeScreen.test.tsx`; 750×1624 frame vs the taller capture) — masking/cropping that
  floor is a **separate** follow-up. This fix only restores the loop's ability to *see and
  keep* improvement.
- Changing the repair agent, its prompt, the model tiering, or the Figma MCP path.
- The build path (`expo run:ios`) and the non-`--repair` capture path are unchanged.

## 3. Root-cause diagnosis FIRST (locks the reload trigger)

The right reload mechanism depends on **which** of three causes is real:
- **(a) Metro transform-cache** doesn't invalidate for the edited module on a normal
  bundle request;
- **(b) the file watcher** misses the agent's edits (atomic-rename writes, or watchman
  absent → Metro's fallback watcher misses them) so Metro never marks the module dirty;
- **(c) a launch-before-rebuild timing race** — the cold launch fetches before Metro has
  finished the incremental rebuild.

A bounded diagnostic isolates it before the mechanism is finalized: with a persistent
Metro, edit a screen source, then (i) read `GET /index.bundle?platform=ios&dev=true`
**without** any reload trigger and check whether the served bytes change; (ii) after a
packager reload trigger; (iii) after `touch`-ing the file. The combination that flips the
served bundle identifies the cause. Recorded in
`docs/2026-06-26-visual-repair-bundle-freshness-validation.md`.

This is *why* the chosen mechanism is **adaptive** (below): it is correct under all three
causes — the cheap path handles (a)/(c), the reset fallback handles (b).

## 4. Mechanism: adaptive poll-then-reset

All Metro-specific freshness logic lives in **`scripts/lib/visual-repair.sh`** — the same
file as `repair_metro_start`/`repair_metro_stop`/`metro_is_up` and the RN-specific
`repair_agent`/`_repair_one`. **`scripts/lib/visual-capture.sh` is NOT touched**: it stays
the surface-agnostic, directly-invokable capture scaffold whose `__visual_*` helpers
"return 2 when tooling is absent so run_visual_capture degrades cleanly". (This is the
correction to the first draft, which wrongly placed `__visual_bundle_hash`/
`__visual_force_fresh_bundle` in `visual-capture.sh` and had them call back into
`visual-repair.sh` — a reversed dependency that would crash `visual-capture.sh`'s standalone
`capture`/`diff` dispatch.)

The loop is reached through a **new injected `capture_fn`**, `repair_recapture_screen`,
instead of the bare `visual_recapture_screen`. So the surface-agnostic loop
(`visual_repair_screen`) is unchanged, the first-pass capture path is unchanged, and only
the *repair* re-capture gains freshness — no `NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE` guard
inside `visual_recapture_screen` is needed.

```
repair_recapture_screen(screen, state, device, out):     # injected as capture_fn (visual-repair.sh)
  __visual_force_fresh_bundle                              # 1. make Metro serve fresh JS
  visual_recapture_screen(screen, state, device, out)      # 2. the existing, untouched capture

__visual_force_fresh_bundle:                               # visual-repair.sh
  prev = read $PREVHASH_FILE
  touch the in-scope edited sources + GET :$PORT/reload    # cheap triggers
  poll GET :$PORT/index.bundle?platform=ios&dev=true, hashing the bytes,
       until hash != prev OR a wall-clock deadline ($POLL_TIMEOUT) passes
  if still unchanged -> repair_metro_reset                 # reliable fallback
  write the resulting hash back to $PREVHASH_FILE
```

### 4.1 The reset fallback that actually resets (fixes the no-op)

The first draft's fallback (`repair_metro_stop` + `repair_metro_start`) silently no-ops when
Metro was *reused*: PR #36's `repair_metro_stop` only kills an **engine-started** Metro
(`_REPAIR_METRO_STARTED=1`), and `repair_metro_start` early-returns when `metro_is_up`. So a
reused Metro is never stopped, stays up, and the restart reuses it again — `--reset-cache`
never runs.

The corrected fallback is a dedicated `repair_metro_reset` that **guarantees** a fresh,
cache-cleared Metro on **this run's port**, and is **parallel-safe** by being *port-scoped*
(never the blanket `pkill -f "expo start"` PR #36 deliberately removed — under
`NIGHT_SHIFT_DEVICE_REGISTRY` each worktree owns a distinct port, so a port-scoped kill
touches only this run's Metro):

```bash
repair_metro_reset() {
  local device="$1" port="${NIGHT_SHIFT_METRO_PORT:-8081}" pids i=0 _nb
  repair_metro_stop                                   # kill our tracked PID if we started it
  pids="$(lsof -ti "tcp:${port}" 2>/dev/null)"        # then any remaining listener on OUR port
  [ -n "$pids" ] && kill $pids 2>/dev/null || true    # (port-scoped: safe under registry mode)
  i=0; while metro_is_up && [ "$i" -lt 15 ]; do i=$((i+1)); sleep 1; done   # wait for the port to clear
  _nb="${NO_BUILD:-0}"; NO_BUILD=1                     # NEVER rebuild native on a reset (fixes #2)
  NIGHT_SHIFT_METRO_RESET_CACHE=1 repair_metro_start "$device"   # now metro_is_up is false -> starts fresh + --reset-cache
  NO_BUILD="$_nb"
}
```

`repair_metro_start` gains a one-line conditional to honor the flag (a real, intended
modification — not a pre-existing behavior):
`[ "${NIGHT_SHIFT_METRO_RESET_CACHE:-0}" = "1" ] && _extra="--reset-cache"`, appended to its
`expo start`. Because the port is cleared first, the reuse guard now passes through to the
fresh start. Forcing `NO_BUILD=1` for the reset means `repair_metro_start` never reaches its
`expo run:ios` build branch, so a poll timeout can **never** kick off a multi-minute native
rebuild (the first draft's second flaw), and an empty `device` is harmless (it is only read
by the build branch).

### New env knobs (all defaulted; documented in CLAUDE.md when implemented)
- `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT` — seconds to wait for the served bundle to
  change before the reset fallback (default 25).
- `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL` — poll cadence (default 2).
- `NIGHT_SHIFT_METRO_RESET_CACHE` — internal: makes `repair_metro_start` add `--reset-cache`
  (set only by `repair_metro_reset`).
- Reuses `NIGHT_SHIFT_METRO_PORT` (already referenced by `metro_is_up`, default 8081) and
  `NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE`.

## 5. Edge cases

- **Metro absent / not on the port** → `__visual_bundle_hash` returns empty/non-zero;
  `__visual_force_fresh_bundle` returns non-zero and `repair_recapture_screen` proceeds to
  the unchanged `visual_recapture_screen`, which clean-degrades exactly as today (no block).
- **Watcher genuinely misses the edit (cause b)** → poll times out → `repair_metro_reset`
  re-reads disk → correct. This is the fallback's whole reason to exist.
- **Agent made no real visual change** (valid: nothing to fix) → bundle hash never changes →
  after the deadline the reset still yields the same pixels → the loop correctly records a
  non-improvement and stalls (a true negative, not the bug).
- **Reset can't restart Metro** → `repair_recapture_screen` still calls the existing
  `visual_recapture_screen`, whose 2-try re-capture retry + clean degrade applies; the
  attempt records a non-improvement; the loop is never wedged.
- **Parallel worktrees** (`NIGHT_SHIFT_DEVICE_REGISTRY=1`) → each run has its own port, so
  the port-scoped kill in `repair_metro_reset` never touches a sibling run's Metro.
- Multiple screens / global cap 30 unchanged; freshness is per re-capture.

## 6. Testing

Deterministic fixtures (`scripts/test/fixtures.sh`, no simulator — stub `curl`/`lsof` on
PATH; stub `repair_metro_reset` to record a call):
- **fast path:** served-bundle hash changes within the deadline → assert `repair_metro_reset`
  is **not** invoked, capture proceeds.
- **fallback:** hash never changes → assert `repair_metro_reset` fires **exactly once**, then
  capture proceeds.
- **reset is parallel-safe + no rebuild:** `repair_metro_reset` with a stubbed `lsof`/`kill`
  + a fake reused Metro asserts (i) it kills the port listener, (ii) it calls
  `repair_metro_start` with `NO_BUILD` forced to 1 (no `expo run:ios`), (iii)
  `NIGHT_SHIFT_METRO_RESET_CACHE=1` reaches the `--reset-cache` branch.
- **clean SKIP:** Metro absent → `__visual_force_fresh_bundle` non-zero, `repair_recapture_screen`
  still completes via `visual_recapture_screen` (capture path identical to current).
- Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
  exit 0); full fixture suite green.

## 7. Validation (real simulator, recorded in the doc)

Reuse the proven closeable-gap setup (reference = a capture of the correct screen; candidate
= a perturbed `WaterRing`/`WaterWave`). Run `--repair=5` with the opus repair model and
confirm the per-attempt `attempts[].diff_pct` **strictly decreases** across ≥2 attempts and
the loop ends on the improved code (not the baseline). The background "reliable refine" run
(per-attempt Metro restart — the reset-every-attempt extreme of this mechanism) is the
baseline evidence: its per-iteration progression confirms (i) the stale bundle is the sole
convergence blocker and (ii) the strict-decrease bar is reachable.

## 8. Related

- PR #36 (`feat/repair-metro-reuse`) — fixed the Metro *collision*; this fixes the deeper
  *staleness* it exposed. The reset path here deliberately reuses #36's `_REPAIR_METRO_STARTED`
  ownership model and stays port-scoped rather than reviving the blanket `pkill`.
- `docs/2026-06-24-visual-review-live-path.md` — first end-to-end live capture.
- `docs/2026-06-25-visual-repair-in-loop-validation.md` — in-loop wiring proven on a
  single-attempt fresh Metro (the case where the bug doesn't yet bite).
- Local contract: `specs/visual-repair-bundle-freshness.md` (gitignored, local-only).
