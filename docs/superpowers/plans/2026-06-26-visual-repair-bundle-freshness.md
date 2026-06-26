# Visual-repair Bundle Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

> **Revision (post-review, PR #37):** reworked after code review. All Metro/freshness logic now lives in `scripts/lib/visual-repair.sh` (not `visual-capture.sh`); the loop injects a new `repair_recapture_screen` `capture_fn`; the reset fallback is a dedicated, parallel-safe, no-rebuild `repair_metro_reset` that actually resets a reused Metro.

**Goal:** Each re-capture inside `visual-review.sh --repair` (and the in-loop repair) reads a JS bundle that reflects the agent's just-made edits, so the keep-best loop observes real diff improvement and converges — instead of re-capturing an identical stale-bundle screenshot, stalling, and reverting to baseline.

**Architecture:** A new injected `capture_fn`, `repair_recapture_screen` (in `scripts/lib/visual-repair.sh`), runs a freshness step then the existing, untouched `visual_recapture_screen`. The freshness step `__visual_force_fresh_bundle` (also in `visual-repair.sh`, beside `repair_metro_*`) touches the in-scope edited sources + triggers a Metro reload, then **polls** Metro's served `/index.bundle` hash until it changes (fast path); on a wall-clock timeout it calls **`repair_metro_reset`** — a port-scoped, `NO_BUILD`-forced, `--reset-cache` restart that resets even a *reused* Metro without touching sibling worktrees. `scripts/lib/visual-capture.sh` is **not** modified (it stays the surface-agnostic, directly-invokable capture scaffold). Both surfaces benefit because both inject `repair_recapture_screen`.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck default severity). Tests = deterministic fixtures in `scripts/test/fixtures.sh` (stub `curl`/`lsof` on PATH; override `repair_metro_reset` to record calls). Diagnosis + convergence validated manually against a real simulator and recorded in `docs/2026-06-26-visual-repair-bundle-freshness-validation.md`.

**Design:** `docs/superpowers/specs/2026-06-26-visual-repair-bundle-freshness-design.md`.

## Global Constraints

- Work in a worktree off `main` (branch `feat/visual-repair-bundle-freshness`).
- The freshness step runs ONLY via `repair_recapture_screen` (the repair `capture_fn`); the first-pass `run_visual_capture` and the bare `visual_recapture_screen` are unchanged.
- `scripts/lib/visual-capture.sh` is NOT modified — no Metro/freshness logic enters the surface-agnostic scaffold (preserves its standalone `BASH_SOURCE==$0` dispatch + "return 2 / degrade cleanly" contract).
- Fast path must NOT restart Metro when the served bundle changes within the timeout; `repair_metro_reset` fires only on timeout.
- `repair_metro_reset` must (a) be port-scoped (`lsof -ti tcp:$PORT`), never a blanket `pkill` (PR #36 removed that); (b) force `NO_BUILD=1` so it never runs `expo run:ios`; (c) actually clear the port before restarting so the `metro_is_up` reuse-guard passes through to a fresh `--reset-cache` start.
- Absent Metro/simulator → `repair_recapture_screen` still completes via `visual_recapture_screen` (clean degrade, no block).
- New knobs defaulted: `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT` (25), `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL` (2). Reuse `${NIGHT_SHIFT_METRO_PORT:-8081}` (already used by `metro_is_up`).
- Fixture suite green: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` → `grep -c "not ok"` is `0`.
- Shellcheck default severity: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/lib/visual-repair.sh` — add `__visual_bundle_hash`, `__visual_force_fresh_bundle`, `repair_metro_reset`, `repair_recapture_screen`; add the `--reset-cache` conditional to `repair_metro_start`; inject `repair_recapture_screen` (replacing `visual_recapture_screen`) and set `REPAIR_TOUCH_GLOB`/`REPAIR_RESET_DEVICE`/`NIGHT_SHIFT_VISUAL_PREVHASH_FILE` in `_repair_one` (Tasks 1-2).
- **Modify** `scripts/test/fixtures.sh` — `fixture_bundle_freshness` (fast path / fallback / reset-safety / clean-degrade) (Tasks 1-2).
- **Add** `docs/2026-06-26-visual-repair-bundle-freshness-validation.md` — diagnosis + convergence smoke record (Task 3).
- **Not modified:** `scripts/lib/visual-capture.sh`.

---

### Task 0 (diagnosis — do before locking the reload trigger)

**Not a code change.** Run the bounded diagnostic from §3 of the design against a real persistent Metro: edit a screen source, then read `GET :$PORT/index.bundle?platform=ios&dev=true` (i) with no trigger, (ii) after a packager reload, (iii) after `touch`. Record which combination flips the served bytes in `docs/2026-06-26-visual-repair-bundle-freshness-validation.md`. The adaptive mechanism is correct regardless, but the finding tunes the cheap-path trigger (reload vs touch vs both) and confirms the fallback is warranted.

- [ ] Diagnosis recorded with evidence; cheap-path trigger chosen accordingly.

---

### Task 1: freshness helpers + parallel-safe reset (all in `visual-repair.sh`)

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (new helpers beside `repair_metro_*`; `--reset-cache` conditional in `repair_metro_start`)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `__visual_bundle_hash` → prints a stable hash of Metro's served `/index.bundle` (empty + non-zero when Metro is unreachable). `__visual_force_fresh_bundle` → reads `$NIGHT_SHIFT_VISUAL_PREVHASH_FILE`, triggers reload + touch, polls until the hash differs or the wall-clock deadline; on timeout invokes `repair_metro_reset`; writes the resulting hash back; returns non-zero when Metro is absent. `repair_metro_reset <device>` → port-scoped kill + `NO_BUILD`-forced `--reset-cache` restart.

- [ ] **Step 1: Write the failing test.** Register after the `fixture_repair_metro` line in `run_dry_fixtures`:

```bash
  fixture_assert "bundle freshness: polls, resets only on timeout, reset is port-scoped + no-rebuild, clean-degrades without Metro" fixture_bundle_freshness "$root"
```

Add the fixture (a `( … )` subshell inherits the outer shell's functions, so overriding `repair_metro_reset`/`repair_metro_start` as functions is sufficient — no `export -f` needed):

```bash
fixture_bundle_freshness() {
  local root="$1" d="$root/bfresh"
  mkdir -p "$d/bin"
  # curl serves the contents of $d/served (the "served bundle"); reload/status URLs are no-ops.
  cat >"$d/bin/curl" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *index.bundle*) cat "$d/served" 2>/dev/null; exit 0;; esac; done
exit 0
STUB
  chmod +x "$d/bin/curl"
  export NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT=2 NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL=1
  export NIGHT_SHIFT_VISUAL_PREVHASH_FILE="$d/prevhash"

  # (a) fast path: a background mutation flips the served bytes within the deadline -> NO reset.
  printf 'v1' >"$d/served"; printf '%s' "$(printf 'v1' | shasum | awk '{print $1}')" >"$d/prevhash"; : >"$d/reset.log"
  ( sleep 1; printf 'v2' >"$d/served" ) &
  (
    export PATH="$d/bin:$PATH"
    repair_metro_reset() { echo reset >>"$d/reset.log"; }
    __visual_force_fresh_bundle || exit 1
    [ -s "$d/reset.log" ] && exit 1   # reset must NOT have fired
    exit 0
  ) || { wait; return 1; }
  wait

  # (b) fallback: bytes never change within the deadline -> reset fires exactly once.
  printf 'same' >"$d/served"; printf '%s' "$(printf 'same' | shasum | awk '{print $1}')" >"$d/prevhash"; : >"$d/reset.log"
  (
    export PATH="$d/bin:$PATH"
    repair_metro_reset() { echo reset >>"$d/reset.log"; }
    __visual_force_fresh_bundle >/dev/null 2>&1 || true
    [ "$(grep -c reset "$d/reset.log" 2>/dev/null || echo 0)" = "1" ] || exit 1
    exit 0
  ) || return 1

  # (c) reset is port-scoped + forces NO_BUILD=1 (no expo run:ios) + sets --reset-cache.
  : >"$d/lsof.log"; : >"$d/start.log"
  cat >"$d/bin/lsof" <<STUB
#!/usr/bin/env bash
echo lsof "\$@" >>"$d/lsof.log"; echo 4242   # a fake pid holding the port
STUB
  chmod +x "$d/bin/lsof"
  cat >"$d/bin/kill" <<STUB
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$d/bin/kill"
  (
    export PATH="$d/bin:$PATH" NO_BUILD=0
    metro_is_up() { return 1; }   # port clears immediately so the wait loop ends
    repair_metro_start() { echo "start nb=$NO_BUILD rc=${NIGHT_SHIFT_METRO_RESET_CACHE:-0} dev=$1" >>"$d/start.log"; }
    repair_metro_stop() { :; }
    repair_metro_reset "iPhone 16" || exit 1
    grep -q 'tcp:' "$d/lsof.log" || exit 1                         # port-scoped kill
    grep -q 'start nb=1 rc=1 dev=iPhone 16' "$d/start.log" || exit 1 # NO_BUILD forced 1 + --reset-cache flag
    exit 0
  ) || return 1

  # (d) clean degrade: no Metro (curl serves nothing) -> empty hash, non-zero, no crash.
  rm -f "$d/served" "$d/prevhash"; 
  (
    export PATH="$d/bin:$PATH"
    repair_metro_reset() { :; }
    if __visual_force_fresh_bundle >/dev/null 2>&1; then exit 1; fi   # returns non-zero
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "bundle freshness"`
Expected: `not ok …` (the helpers are undefined).

- [ ] **Step 3a: Add the `--reset-cache` conditional to `repair_metro_start`.** In its `expo start` line:

```bash
  local _extra=""; [ "${NIGHT_SHIFT_METRO_RESET_CACHE:-0}" = "1" ] && _extra="--reset-cache"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start $_extra >/tmp/visual-repair-metro.log 2>&1 ) &
```

- [ ] **Step 3b: Add the helpers** in `scripts/lib/visual-repair.sh`, beside `repair_metro_start`/`repair_metro_stop`:

```bash
# Hash Metro's currently-served iOS bundle (empty + non-zero when Metro is unreachable).
__visual_bundle_hash() {
  local port="${NIGHT_SHIFT_METRO_PORT:-8081}" body
  body="$(curl -s "http://localhost:${port}/index.bundle?platform=ios&dev=true" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  printf '%s' "$body" | shasum 2>/dev/null | awk '{print $1}'
}

# Force a fresh, cache-cleared Metro on THIS run's port. Port-scoped (safe under
# NIGHT_SHIFT_DEVICE_REGISTRY: distinct ports) — never the blanket pkill PR #36 removed.
# Forces NO_BUILD=1 so it never runs `expo run:ios`; clears the port first so the
# repair_metro_start reuse-guard falls through to a fresh `--reset-cache` start.
repair_metro_reset() {
  local device="$1" port="${NIGHT_SHIFT_METRO_PORT:-8081}" pids i=0 _nb
  repair_metro_stop
  pids="$(lsof -ti "tcp:${port}" 2>/dev/null)"
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  while metro_is_up && [ "$i" -lt 15 ]; do i=$((i+1)); sleep 1; done
  _nb="${NO_BUILD:-0}"; NO_BUILD=1
  NIGHT_SHIFT_METRO_RESET_CACHE=1 repair_metro_start "$device"
  NO_BUILD="$_nb"
}

# Make Metro serve a bundle reflecting on-disk sources, then record its hash. Fast path:
# touch + reload, poll the served-bundle hash until it differs from the previous attempt
# (wall-clock deadline NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT). Fallback: repair_metro_reset.
# Returns non-zero when Metro is unreachable (caller degrades to a plain re-capture).
__visual_force_fresh_bundle() {
  local hf="${NIGHT_SHIFT_VISUAL_PREVHASH_FILE:-}" prev="" \
        timeout="${NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT:-25}" \
        interval="${NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL:-2}" \
        port="${NIGHT_SHIFT_METRO_PORT:-8081}" deadline h
  [ -n "$hf" ] && [ -f "$hf" ] && prev="$(cat "$hf")"
  curl -s -o /dev/null "http://localhost:${port}/reload" 2>/dev/null || true
  [ -n "${REPAIR_TOUCH_GLOB:-}" ] && find "${REPAIR_TOUCH_GLOB}" -type f -exec touch {} + 2>/dev/null || true
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    h="$(__visual_bundle_hash)" || return 1
    if [ -n "$h" ] && [ "$h" != "$prev" ]; then [ -n "$hf" ] && printf '%s' "$h" >"$hf"; return 0; fi
    sleep "$interval"
  done
  log "visual-repair: bundle unchanged after ${timeout}s; resetting Metro"
  repair_metro_reset "${REPAIR_RESET_DEVICE:-}"
  h="$(__visual_bundle_hash)" || return 1
  [ -n "$h" ] || return 1
  [ -n "$hf" ] && printf '%s' "$h" >"$hf"
  return 0
}
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): __visual_force_fresh_bundle + parallel-safe repair_metro_reset"
```

---

### Task 2: inject `repair_recapture_screen` as the repair `capture_fn`

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`repair_recapture_screen`; `_repair_one` sets `REPAIR_TOUCH_GLOB`/`REPAIR_RESET_DEVICE`/`NIGHT_SHIFT_VISUAL_PREVHASH_FILE` and injects `repair_recapture_screen`)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `repair_recapture_screen screen state device out` → calls `__visual_force_fresh_bundle` then `visual_recapture_screen`. It is the `capture_fn` injected by both the standalone (`_repair_one`) and in-loop callers, replacing the bare `visual_recapture_screen`.

- [ ] **Step 1: Write the failing test.** Add `fixture_recapture_wrapper`: stub `__visual_force_fresh_bundle` + `visual_recapture_screen` as recorders, call `repair_recapture_screen`, assert freshness runs first then capture; and assert `visual_recapture_screen` alone (the first-pass path) never invokes freshness. Register it after the Task-1 fixture line.

- [ ] **Step 2: Run test to verify it fails.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "recapture"`
Expected: `not ok …`.

- [ ] **Step 3a: Add `repair_recapture_screen`** in `scripts/lib/visual-repair.sh`:

```bash
# Repair re-capture: force a fresh bundle (so the agent's edit reaches the screenshot),
# then the existing, surface-agnostic capture. Injected as capture_fn by both repair surfaces.
repair_recapture_screen() {
  __visual_force_fresh_bundle || true   # advisory: a missing fresh bundle never blocks capture
  visual_recapture_screen "$@"
}
```

- [ ] **Step 3b: Wire `_repair_one`** (in `visual_repair_for_spec`) to export the per-screen context and inject the wrapper. Replace the `visual_recapture_screen` argument to `visual_repair_screen` with `repair_recapture_screen`, and before it add:

```bash
    export NIGHT_SHIFT_VISUAL_PREVHASH_FILE="$out_dir/_rsnap/$sc-prevhash"
    export REPAIR_TOUCH_GLOB="$project/${allow_csv%%,*}"   # the primary in-scope tree
    export REPAIR_RESET_DEVICE="$(device_label_to_name "$dv")"
```

(The in-loop caller in `scripts/night-shift.sh` that injects `visual_recapture_screen` is switched to `repair_recapture_screen` the same way; confirm by reading `run_visual_inloop_repair`.)

- [ ] **Step 4: Run tests + shellcheck.** Same two commands as Task 1 Step 4 → `0` / `0`. Confirm the first-pass capture is unaffected (the `fixture_recapture_wrapper` "first-pass" assertion is green).

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): repair re-capture forces a fresh bundle per attempt (both surfaces)"
```

---

### Task 3: Diagnosis + convergence validation doc

**Files:**
- Add: `docs/2026-06-26-visual-repair-bundle-freshness-validation.md`

- [ ] **Step 1:** Record the Task-0 diagnosis (which trigger flips the served bundle: cache vs watcher vs timing) with the raw evidence.
- [ ] **Step 2:** Run the real-simulator convergence smoke (closeable gap, `--repair=5`, opus model) and paste the per-attempt `attempts[].diff_pct` progression, confirming a strict decrease and that the loop ends on improved code. Cross-reference the background "reliable refine" (reset-every-attempt) run as corroborating evidence.
- [ ] **Step 3: Commit.**

```bash
git add docs/2026-06-26-visual-repair-bundle-freshness-validation.md
git commit -m "docs(visual-repair): bundle-freshness diagnosis + convergence validation"
```

---

## Self-Review

**Design coverage:** §3 diagnosis → Task 0 + Task 3; §4 mechanism (`repair_recapture_screen` wrapper, `__visual_force_fresh_bundle` poll-then-reset, hash threading) → Tasks 1-2; §4.1 reset fallback (`repair_metro_reset`: port-scoped, `NO_BUILD`-forced, `--reset-cache`) → Task 1; §4 knobs → Task 1; §6 fixtures (fast/fallback/reset-safety/clean-degrade + wrapper) → Tasks 1-2; §7 convergence → Task 3.

**Code-review fixes folded in:** (1) reset no-op — `repair_metro_reset` clears the port before `repair_metro_start`, so a *reused* Metro is actually reset; (2) native-rebuild risk — `repair_metro_reset` forces `NO_BUILD=1`, so `expo run:ios` is never reached and an empty device is harmless; (3) module boundary — all new code lives in `visual-repair.sh` beside `repair_metro_*`; `visual-capture.sh` is untouched and the loop injects a new `repair_recapture_screen` rather than editing `visual_recapture_screen`. Also: `find "${REPAIR_TOUCH_GLOB}"` is quoted; the poll uses a wall-clock `date +%s` deadline (no interval/timeout arithmetic edge).

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `__visual_bundle_hash`, `__visual_force_fresh_bundle`, `repair_metro_reset`, `repair_recapture_screen`, `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT`/`_INTERVAL`, `NIGHT_SHIFT_VISUAL_PREVHASH_FILE`, `NIGHT_SHIFT_METRO_RESET_CACHE`, `REPAIR_TOUCH_GLOB`, `REPAIR_RESET_DEVICE` are used identically across the helpers, `repair_recapture_screen`, and `_repair_one`.

**Surface-agnostic invariant:** the loop (`visual_repair_screen`) and `visual-capture.sh` are untouched; freshness rides entirely on the injected `repair_recapture_screen` in `visual-repair.sh`, so the fixtures' injected `capture_fn` keeps working and both standalone + in-loop repair inherit the behavior by injecting the same wrapper.

**Degrade invariant:** `__visual_force_fresh_bundle` returns non-zero without Metro and `repair_recapture_screen` swallows that (`|| true`) then runs the unchanged `visual_recapture_screen` — a missing fresh bundle never blocks the existing terminate→launch→screenshot path (preserves today's clean SKIP).
