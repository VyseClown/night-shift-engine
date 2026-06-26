# Visual-repair Bundle Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Each re-capture inside `visual-review.sh --repair` (and the in-loop repair) reads a JS bundle that reflects the agent's just-made edits, so the keep-best loop observes real diff improvement and converges — instead of re-capturing an identical stale-bundle screenshot, stalling, and reverting to baseline.

**Architecture:** A freshness step (`__visual_force_fresh_bundle`) runs between the agent's gate-passing edit and the cold-launch re-capture, inside the RN/Metro-specific capture lib so the loop stays surface-agnostic. It touches the edited sources + triggers a Metro reload, then **polls** Metro's served `/index.bundle` hash until it changes (fast path); on timeout it **resets** Metro (the PR #36 `repair_metro_*` harness, cache cleared) and re-reads once. `visual_recapture_screen` threads the previous bundle hash across attempts and invokes the step before its existing terminate→launch→settle→screenshot. Both surfaces benefit because both inject `visual_recapture_screen` as `capture_fn`.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck default severity). Tests = deterministic fixtures in `scripts/test/fixtures.sh` (stub `curl`/Metro controls on PATH). Diagnosis + convergence validated manually against a real simulator and recorded in `docs/2026-06-26-visual-repair-bundle-freshness-validation.md`.

**Design:** `docs/superpowers/specs/2026-06-26-visual-repair-bundle-freshness-design.md`.

## Global Constraints

- Work in a worktree off `main` (branch `feat/visual-repair-bundle-freshness`).
- The freshness step runs ONLY on a repair re-capture (a prior edit exists); the first-pass `run_visual_capture` path is unchanged (no prior edit to reflect).
- Fast path must NOT restart Metro when the served bundle changes within the timeout; the reset fallback fires only on timeout.
- Absent Metro/simulator → clean SKIP/degrade identical to today (no block).
- Reuse `repair_metro_start`/`repair_metro_stop` (PR #36) for the reset fallback; reuse `${NIGHT_SHIFT_METRO_PORT:-8081}`.
- New knobs defaulted: `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT` (25), `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL` (2).
- Fixture suite green: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` → `grep -c "not ok"` is `0`.
- Shellcheck default severity: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/lib/visual-capture.sh` — add `__visual_bundle_hash`, `__visual_force_fresh_bundle`; call the freshness step from `visual_recapture_screen` (Tasks 1-2).
- **Modify** `scripts/test/fixtures.sh` — `fixture_bundle_freshness` (fast path + fallback + clean SKIP) (Tasks 1-2).
- **Add** `docs/2026-06-26-visual-repair-bundle-freshness-validation.md` — the diagnosis (cache vs watcher vs timing) + the convergence smoke record (Task 3).

---

### Task 0 (diagnosis — do before locking the reload trigger)

**Not a code change.** Run the bounded diagnostic from §3 of the design against a real persistent Metro: edit a screen source, then read `GET :$PORT/index.bundle?platform=ios&dev=true` (i) with no trigger, (ii) after a packager reload, (iii) after `touch`. Record which combination flips the served bytes in `docs/2026-06-26-visual-repair-bundle-freshness-validation.md`. The adaptive mechanism is correct regardless, but the finding tunes the cheap-path trigger (reload vs touch vs both) and confirms the fallback is warranted.

- [ ] Diagnosis recorded with evidence; cheap-path trigger chosen accordingly.

---

### Task 1: `__visual_bundle_hash` + `__visual_force_fresh_bundle`

**Files:**
- Modify: `scripts/lib/visual-capture.sh` (new helpers near `visual_recapture_screen`)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `__visual_bundle_hash` → prints a stable hash of Metro's served `/index.bundle` (empty when Metro is unreachable). `__visual_force_fresh_bundle <prev_hash>` → triggers reload + touch, polls until the hash differs from `<prev_hash>` or `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT`; on timeout invokes the Metro reset; prints the resulting hash. Degrades (prints empty, returns non-zero) when Metro is absent.

- [ ] **Step 1: Write the failing test.** Register after the `fixture_repair_metro` line in `run_dry_fixtures`:

```bash
  fixture_assert "force_fresh_bundle: polls then resets Metro only on timeout; clean-degrades without Metro" fixture_bundle_freshness "$root"
```

Add the fixture (stubs `curl` to model the served-bundle bytes; stubs the reset by overriding `repair_metro_stop`/`repair_metro_start` to record a call):

```bash
fixture_bundle_freshness() {
  local root="$1" d="$root/bfresh"
  mkdir -p "$d/bin"
  # curl prints the contents of $d/served (the "served bundle"); we mutate it to simulate a rebuild.
  cat >"$d/bin/curl" <<STUB
#!/usr/bin/env bash
# ignore flags; the LAST arg is the URL. Serve the file if it's a bundle/status URL.
cat "$d/served" 2>/dev/null
exit 0
STUB
  chmod +x "$d/bin/curl"
  # Reset stubs record invocation; touch/reload are no-ops here.
  repair_metro_stop() { echo stop >>"$d/reset.log"; }
  repair_metro_start() { echo start >>"$d/reset.log"; }
  export NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT=2 NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL=1

  # (a) fast path: a background mutation flips the served bytes within the timeout -> NO reset.
  printf 'v1' >"$d/served"; : >"$d/reset.log"
  ( sleep 1; printf 'v2' >"$d/served" ) &
  (
    export PATH="$d/bin:$PATH"
    h="$(__visual_force_fresh_bundle "$(printf 'v1' | shasum | awk '{print $1}')")" || exit 1
    [ -n "$h" ] || exit 1
    [ -s "$d/reset.log" ] && exit 1   # reset must NOT have fired
    exit 0
  ) || { wait; return 1; }
  wait

  # (b) fallback: bytes never change within the timeout -> reset fires exactly once.
  printf 'same' >"$d/served"; : >"$d/reset.log"
  (
    export PATH="$d/bin:$PATH"
    __visual_force_fresh_bundle "$(printf 'same' | shasum | awk '{print $1}')" >/dev/null || true
    [ "$(grep -c start "$d/reset.log" 2>/dev/null || echo 0)" = "1" ] || exit 1
    exit 0
  ) || return 1

  # (c) clean degrade: no Metro (curl prints nothing) -> empty hash, non-zero, no crash.
  rm -f "$d/served"; : >"$d/reset.log"
  (
    export PATH="$d/bin:$PATH"
    if __visual_force_fresh_bundle "x" >/dev/null 2>&1; then exit 1; fi  # returns non-zero
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "force_fresh_bundle"`
Expected: `not ok …` (`__visual_force_fresh_bundle`/`__visual_bundle_hash` undefined).

- [ ] **Step 3: Implement the helpers** in `scripts/lib/visual-capture.sh`, just above `visual_recapture_screen`:

```bash
# Hash Metro's currently-served iOS bundle (empty when Metro is unreachable). Used to
# detect when an edit has actually reached the served bundle.
__visual_bundle_hash() {
  local port="${NIGHT_SHIFT_METRO_PORT:-8081}" body
  body="$(curl -s "http://localhost:${port}/index.bundle?platform=ios&dev=true" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  printf '%s' "$body" | shasum 2>/dev/null | awk '{print $1}'
}

# Force Metro to serve a bundle reflecting the on-disk sources, then print its hash.
# Fast path: touch + reload, poll the served-bundle hash until it differs from <prev_hash>
# (bounded by NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT). Fallback: on timeout, reset Metro
# (repair_metro_stop + repair_metro_start, cache cleared) and read once. Returns non-zero
# (empty) when Metro is unreachable, so the caller degrades cleanly.
__visual_force_fresh_bundle() {
  local prev="$1" timeout="${NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT:-25}" \
        interval="${NIGHT_SHIFT_VISUAL_BUNDLE_POLL_INTERVAL:-2}" \
        port="${NIGHT_SHIFT_METRO_PORT:-8081}" waited=0 h
  # Cheap triggers: a packager reload + (the diagnosis-selected trigger) touch the
  # in-scope sources so the watcher re-stats them.
  curl -s -o /dev/null "http://localhost:${port}/reload" 2>/dev/null || true
  [ -n "${REPAIR_TOUCH_GLOB:-}" ] && find ${REPAIR_TOUCH_GLOB} -type f -exec touch {} + 2>/dev/null || true
  while [ "$waited" -lt "$timeout" ]; do
    h="$(__visual_bundle_hash)" || return 1
    [ -n "$h" ] && [ "$h" != "$prev" ] && { printf '%s' "$h"; return 0; }
    sleep "$interval"; waited=$((waited + interval))
  done
  # Fallback: hard reset so Metro re-reads from disk.
  log "visual-repair: bundle unchanged after ${timeout}s; resetting Metro"
  repair_metro_stop
  NIGHT_SHIFT_METRO_RESET_CACHE=1 repair_metro_start "${REPAIR_RESET_DEVICE:-}"
  h="$(__visual_bundle_hash)" || return 1
  [ -n "$h" ] || return 1
  printf '%s' "$h"
}
```

(`repair_metro_start` honors a `NIGHT_SHIFT_METRO_RESET_CACHE` to add `--reset-cache`/`--clear` to its `expo start` — a one-line conditional in that function; `REPAIR_TOUCH_GLOB`/`REPAIR_RESET_DEVICE` are set by the loop wiring in Task 2.)

- [ ] **Step 4: Run tests + shellcheck.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): __visual_force_fresh_bundle — poll-then-reset for fresh re-captures"
```

---

### Task 2: Thread freshness into `visual_recapture_screen`

**Files:**
- Modify: `scripts/lib/visual-capture.sh` (`visual_recapture_screen`)
- Modify: `scripts/lib/visual-repair.sh` (`_repair_one` sets `REPAIR_TOUCH_GLOB`/`REPAIR_RESET_DEVICE`; `repair_metro_start` honors `NIGHT_SHIFT_METRO_RESET_CACHE`)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `__visual_force_fresh_bundle` (Task 1). Threads `prev_hash` across attempts via a per-screen file under the loop tmp dir (mirrors the `_pct_file` pattern). The freshness step runs ONLY when invoked as a repair re-capture (guarded by a `NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE=1` env the loop sets), never on the first-pass capture.

- [ ] **Step 1: Write the failing test.** Extend `fixture_bundle_freshness` (or add `fixture_recapture_calls_freshness`) to assert: with `NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE=1` set, `visual_recapture_screen` calls `__visual_force_fresh_bundle` before `__visual_capture_screenshot`; with it unset, it does not. Stub both as recorders and assert call order / presence.

- [ ] **Step 2: Run test to verify it fails.**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "recapture"`
Expected: `not ok …`.

- [ ] **Step 3: Wire it.** In `visual_recapture_screen` (`scripts/lib/visual-capture.sh`), before the `__visual_capture_screenshot` call, when `NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE=1`:

```bash
  if [ "${NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE:-0}" = "1" ]; then
    local _hf="${NIGHT_SHIFT_VISUAL_PREVHASH_FILE:-}"
    local _prev=""; [ -n "$_hf" ] && [ -f "$_hf" ] && _prev="$(cat "$_hf")"
    local _new; _new="$(__visual_force_fresh_bundle "$_prev")" || _new=""
    [ -n "$_hf" ] && [ -n "$_new" ] && printf '%s' "$_new" >"$_hf"
  fi
```

In `scripts/lib/visual-repair.sh::_repair_one`, export the per-screen hash file + the touch glob + reset device, and set the recapture flag for the duration of the screen's repair:

```bash
    export NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE=1
    export NIGHT_SHIFT_VISUAL_PREVHASH_FILE="$out_dir/_rsnap/$sc-prevhash"
    export REPAIR_TOUCH_GLOB="$project/${allow_csv%%,*}"   # the primary in-scope tree
    export REPAIR_RESET_DEVICE="$(device_label_to_name "$dv")"
```

And in `repair_metro_start`, honor the reset-cache flag:

```bash
  local _extra=""; [ "${NIGHT_SHIFT_METRO_RESET_CACHE:-0}" = "1" ] && _extra="--reset-cache"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start $_extra >/tmp/visual-repair-metro.log 2>&1 ) &
```

- [ ] **Step 4: Run tests + shellcheck.** Same two commands as Task 1, Step 4 → `0` / `0`. Also confirm the first-pass capture is unaffected: a fixture with the flag unset records no `__visual_force_fresh_bundle` call.

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-capture.sh scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): re-capture forces a fresh bundle per attempt (both surfaces)"
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

**Design coverage:** §3 diagnosis → Task 0 + Task 3; §4 mechanism (`__visual_force_fresh_bundle`, poll-then-reset, hash threading, both surfaces via `visual_recapture_screen`) → Tasks 1-2; §4 knobs → Task 1 (`POLL_TIMEOUT`/`POLL_INTERVAL`) + Task 2 (`RESET_CACHE`); §6 fixtures (fast/fallback/clean-SKIP + recapture guard) → Tasks 1-2; §7 convergence → Task 3.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `__visual_bundle_hash`, `__visual_force_fresh_bundle`, `NIGHT_SHIFT_VISUAL_BUNDLE_POLL_TIMEOUT`/`_INTERVAL`, `NIGHT_SHIFT_VISUAL_REPAIR_RECAPTURE`, `NIGHT_SHIFT_VISUAL_PREVHASH_FILE`, `NIGHT_SHIFT_METRO_RESET_CACHE`, `REPAIR_TOUCH_GLOB`, `REPAIR_RESET_DEVICE` are used identically across the helper, the `visual_recapture_screen` wiring, and `_repair_one`.

**Surface-agnostic invariant:** the loop (`visual_repair_screen`) is untouched; freshness lives entirely in the RN capture lib + the RN-specific `_repair_one`, so the fixtures' injected `capture_fn` keeps working and both standalone + in-loop repair inherit the behavior.

**Degrade invariant:** `__visual_force_fresh_bundle` returns non-zero/empty without Metro, and the wiring only *advisably* updates the prev-hash file — a missing fresh bundle never blocks the existing terminate→launch→screenshot path (preserves today's clean SKIP).
