# RN `visual_review` parallelism: dedicated simulators via an opt-in device registry

**Date:** 2026-06-23
**Status:** approved (design), pending implementation
**Repo:** engine (`~/work`, `VyseClown/night-shift-engine`)
**Implementation:** by hand (the night-shift cannot safely self-target the engine repo); verified by deterministic fixtures with a stubbed `simctl`.
**Related:** `2026-06-18-visual-fidelity-design.md` (the `visual_review` stage this builds on); PR #4 (`scripts/parallel-worktrees.sh`, the fan-out wrapper); PR #5 (engine accepts a spec run from inside a worktree of the declared project — the prerequisite that makes worktree runs possible at all).

## Problem

`scripts/parallel-worktrees.sh` runs multiple night-shift runs concurrently, one git
worktree per spec. Worktrees isolate the **filesystem** (working dir, branch,
`.night-shift/`), which is enough for the default rn validation
(`npm run typecheck && npm run lint && npm test` — none of which boot a device) and for
the `web`/`node` tracks.

It is **not** enough for the one engine stage that drives a real device: the opt-in
`visual_review` stage (`NIGHT_SHIFT_VISUAL_CAPTURE=1`, `scripts/lib/visual-capture.sh`).
That stage resolves a simulator by device label with a fallback to "any booted device"
(`__visual_pick_udid`: booted-matching-label → matching-label → **any booted** → any).
Two concurrent runs therefore resolve to the **same** simulator and stomp on each
other's app install, launch, and screenshots — corrupting the pixel diffs of both.

## Scope (deliberately narrow)

Solve the collision where it actually exists: the `visual_review` stage. Out of scope:

- Default validation (tsc/lint/jest) — already parallel-safe, untouched.
- `web` / `node` tracks — no device.
- **Metro / ports** — the design mandates a **pre-bundled** preview build (JS embedded),
  so no Metro runs during capture. The simulator is the only contended resource. This
  also makes screenshots more deterministic. (A debug-build/Metro-per-port variant is
  explicitly deferred; it would require an iOS `Podfile` `RCT_METRO_PORT` bake-in in the
  app repo and Metro lifecycle management — not worth it for the current goal.)
- Interactive "second Claude Code instance runs the app" — humans coordinate that
  themselves; the engine only manages its own `visual_review` device claims.

## Key principle: parallel mode is opt-in; the normal run is unchanged

A plain `scripts/night-shift.sh` run executes **today's exact code path** — resolve the
simulator with `__visual_resolve_udid`, no registry, no lock, no clone, no prune. Zero
new overhead and zero new failure modes in the common (single-run) case.

The registry engages **only** when `NIGHT_SHIFT_DEVICE_REGISTRY=1`.
`scripts/parallel-worktrees.sh` sets that env automatically when it fans out with
`--jobs > 1`; a human may also set it. This is a single branch at the top of the stage:

```sh
# visual_review stage
if [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ]; then
  udid="$(device_claim "$label" "$RUN_ID")" || udid=""   # poll-then-skip on scarcity
  [ -n "$udid" ] && trap 'device_release "$udid"' EXIT
else
  udid="$(__visual_resolve_udid "$label")"                # today's path, untouched
fi
# pass $udid explicitly into capture
```

## Architecture

### New component: `scripts/lib/device-registry.sh`

A self-contained bash library mirroring the existing `run.lock` idiom
(`lock_is_stale` / `acquire_lock` / `release_lock`). It depends only on `simctl` and
the lock helpers; it knows nothing about specs, stages, or capture.

- **Registry root:** `~/.night-shift/devices/` — **machine-global, not per-worktree.**
  The contention is machine-global (one set of simulators), so the registry that
  arbitrates it must be visible to every worktree. Overridable via
  `NIGHT_SHIFT_DEVICE_REGISTRY_DIR` for tests.
- **`device_claim <label> <run_id>` → prints a UDID (empty on timeout):**
  1. List `simctl` devices whose label matches `<label>` (label = device name
     lowercased, spaces → hyphens, matching `__visual_pick_udid`).
  2. For each, attempt an atomic `mkdir "$REG/<udid>.lock"`; on success write the owner
     PID + `run_id` + `clone=false` inside and return that UDID. A lock whose PID is
     dead is reclaimed (`lock_is_stale`), exactly like `run.lock`.
  3. If no matching device is free, `simctl clone` a temp device named `ns-<run_id>`,
     claim its lock with `clone=true`, boot it, and return it.
  4. If cloning is unavailable/fails, poll from step 1 until
     `NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT` elapses, then print empty (caller SKIPs).
- **`device_release <udid>`:** only if we own the lock PID — if the lock marks the
  device `clone=true`, `simctl delete` it; then `rm -rf` the lock dir.
- **`device_registry_prune`:** reclaim dead-PID locks and `simctl delete` orphaned
  `ns-*` clones that have no live lock. Same self-heal as the worktree-prune shipped in
  PR #4.

### Change to `scripts/lib/visual-capture.sh`

Thread an explicit UDID **in** rather than resolving internally:
`__visual_capture_screenshot` (and `run_visual_capture`) take a `udid` argument. The
default path passes `__visual_resolve_udid`'s result (behavior-preserving — the same
UDID it would have used); the registry path passes the claimed UDID. This is the only
change to existing capture code and the default path exercises it too.

### Change to `scripts/night-shift.sh`

- Source `device-registry.sh` alongside `visual-capture.sh`.
- At the `visual_review` stage, the opt-in branch above: claim + `EXIT`/signal trap to
  release (or delete a clone) even on crash mid-capture — same trap discipline as
  `release_lock`.
- In registry mode only, call `device_registry_prune` once at startup. Single runs never
  invoke it.

### Change to `scripts/parallel-worktrees.sh`

When fanning out with `--jobs > 1`, export `NIGHT_SHIFT_DEVICE_REGISTRY=1` to each child
run so concurrent `visual_review` stages claim distinct devices automatically.

## Data flow

```
parallel-worktrees.sh (--jobs 2)
  └─ exports NIGHT_SHIFT_DEVICE_REGISTRY=1
     ├─ run A (worktree A) ── visual_review ── device_claim(label, A) ─┐
     └─ run B (worktree B) ── visual_review ── device_claim(label, B) ─┤
                                                                       ▼
                                        ~/.night-shift/devices/ (atomic mkdir locks)
                                          <udidX>.lock  owner=A
                                          <udidY>.lock  owner=B   (or ns-B clone)
     each run captures on its own UDID → release/delete on EXIT
```

## Error handling

- **Device scarcity:** poll up to `NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT` (default `300`),
  then **SKIP** `visual_review` and continue the run — matching the existing
  "no tooling → clean SKIP" degrade. A resource shortage never blocks or fails
  otherwise-good work.
- **Crash mid-capture:** the `EXIT`/signal trap releases the lock and deletes a clone.
  Anything missed is swept by the next registry-mode run's `device_registry_prune`.
- **`simctl` absent:** `visual_capture_available` already SKIPs the whole stage before
  any claim is attempted; the registry is never reached.
- **Stale lock (dead PID):** reclaimed on the next claim, identical to `run.lock`.

## Configuration knobs

| Env | Default | Meaning |
|---|---|---|
| `NIGHT_SHIFT_DEVICE_REGISTRY` | `0` | Master opt-in. `1` enables claim/lock/clone/prune. The wrapper sets it for `--jobs > 1`. |
| `NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT` | `300` | Seconds to poll for a free device before the clean SKIP. |
| `NIGHT_SHIFT_DEVICE_POLL_SECONDS` | `5` | Seconds between device-acquisition poll attempts inside `device_claim`. |
| `NIGHT_SHIFT_DEVICE_REGISTRY_DIR` | `~/.night-shift/devices` | Registry root (tests point this at a temp dir). |

## Testing

All deterministic, no real simulator — mirroring how `fixture_run_lock` tests the lock
decision without a real run. A PATH shim stubs `simctl` to return canned device JSON and
record `clone`/`delete` calls.

1. `fixture_device_claim_distinct` — two claims for the same label return **different**
   UDIDs (second claims a different device, or a clone when only one matches).
2. `fixture_device_claim_clone_on_exhaustion` — when all matching devices are locked,
   claim issues a `simctl clone ns-<id>` and locks it.
3. `fixture_device_lock_stale` — a lock with a dead PID is reclaimable; a live PID is
   not (reuses the `lock_is_stale` predicate).
4. `fixture_device_release` — release of a `clone=true` device calls `simctl delete`;
   release of a claimed real device does **not**.
5. `fixture_device_prune` — prune reclaims dead-PID locks and deletes orphan `ns-*`
   clones with no live lock.
6. `fixture_visual_registry_off` — with `NIGHT_SHIFT_DEVICE_REGISTRY` unset, the capture
   path resolves via `__visual_resolve_udid` and **never** touches the registry
   (guards the "normal run unchanged" guarantee).

## Out-of-scope / future

- Debug-build + Metro-per-port parallelism (needs app-repo `Podfile` `RCT_METRO_PORT`).
- Android emulators (`adb` pool) — the same registry shape would extend, but iOS is the
  current target.
- Engine-managed Metro lifecycle.
