# Visual-repair Metro Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `visual-review.sh --repair` reuses one engine-owned Metro for the initial capture and the repair loop, so each opus edit is reflected in the re-capture and the screen converges toward the Figma image (instead of the loop silently no-op'ing on a Metro collision).

**Architecture:** `repair_metro_start` reuses an existing `:8081` Metro instead of starting a colliding second one; `repair_metro_stop` only kills a Metro the engine itself started; the start call moves before the initial capture loop so one Metro serves both phases.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck default severity). Tests = deterministic fixtures in `scripts/test/fixtures.sh` (stub `curl`/`npx` on PATH + a real background `sleep` for the kill check).

**Spec:** `docs/superpowers/specs/2026-06-26-visual-repair-metro-reuse-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/metro-wt` (branch `feat/repair-metro-reuse`, off `main`).
- `repair_metro_start` must NOT start a second `expo start` when `:8081` already answers (the collision); it reuses it.
- `repair_metro_stop` kills ONLY an engine-started Metro (`_REPAIR_METRO_STARTED=1`) — no blanket `pkill -f "expo start"`.
- Metro port via `${NIGHT_SHIFT_METRO_PORT:-8081}`.
- A non-`--repair` run is unchanged (no engine Metro management).
- Fixture suite green: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` → `grep -c "not ok"` is `0`.
- Shellcheck default severity: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/lib/visual-repair.sh` — `metro_is_up`, `repair_metro_start`, `repair_metro_stop`, the `_REPAIR_METRO_STARTED` var (Task 1).
- **Modify** `scripts/visual-review.sh` — move the `repair_metro_start` block before the capture loop (Task 2).
- **Modify** `scripts/test/fixtures.sh` — `fixture_repair_metro` (Task 1); `fixture_repair_metro_call_order` (Task 2).

---

### Task 1: Metro reuse in `repair_metro_start`/`repair_metro_stop`

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`_REPAIR_METRO_PID` decl ~line 208; `repair_metro_start` ~193; `repair_metro_stop` ~224)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `metro_is_up` → 0 iff `:${NIGHT_SHIFT_METRO_PORT:-8081}/status` answers. `repair_metro_start device` reuses an up Metro (sets `_REPAIR_METRO_STARTED=0`) or starts one (`_REPAIR_METRO_PID`, `_REPAIR_METRO_STARTED=1`). `repair_metro_stop` kills only when `_REPAIR_METRO_STARTED=1`.

- [ ] **Step 1: Write the failing test.** Register after the `fixture_visual_stage_figma_data` line in `run_dry_fixtures` (search for `fixture_visual_stage_figma_data` and add the line after it):

```bash
  fixture_assert "repair_metro_start reuses an existing :8081 Metro; stop kills only an engine-started one" fixture_repair_metro "$root"
```

Add the fixture:

```bash
fixture_repair_metro() {
  local root="$1" d="$root/rmetro"
  mkdir -p "$d/bin" "$d/proj"
  local PROJECT="$d/proj" NO_BUILD=1 _REPAIR_METRO_PID="" _REPAIR_METRO_STARTED=0
  cat >"$d/bin/npx" <<STUB
#!/usr/bin/env bash
echo called >>"$d/npx.log"
exit 0
STUB
  chmod +x "$d/bin/npx"
  # (a) reuse: curl always succeeds (Metro up) -> repair_metro_start must NOT run npx.
  cat >"$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$d/bin/curl"
  : >"$d/npx.log"
  (
    export PATH="$d/bin:$PATH"
    repair_metro_start somedev || exit 1
    [ "$_REPAIR_METRO_STARTED" = "0" ] || exit 1
    [ -s "$d/npx.log" ] && exit 1   # npx (expo start) must NOT have been called
    exit 0
  ) || return 1
  # (b) start: curl fails once (down) then succeeds -> repair_metro_start runs npx.
  cat >"$d/bin/curl" <<STUB
#!/usr/bin/env bash
n=\$(cat "$d/curln" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n >"$d/curln"
[ "\$n" -eq 1 ] && exit 1   # reuse check: down
exit 0                       # wait loop: up
STUB
  chmod +x "$d/bin/curl"
  : >"$d/npx.log"; rm -f "$d/curln"
  (
    export PATH="$d/bin:$PATH"
    repair_metro_start somedev || exit 1
    [ "$_REPAIR_METRO_STARTED" = "1" ] || exit 1
    i=0; until [ -s "$d/npx.log" ]; do i=$((i+1)); [ "$i" -ge 10 ] && exit 1; sleep 0.2; done
    exit 0
  ) || return 1
  # (c) stop kills ONLY an engine-started Metro.
  (
    sleep 30 & sp=$!
    _REPAIR_METRO_STARTED=0; _REPAIR_METRO_PID=$sp
    repair_metro_stop
    kill -0 "$sp" 2>/dev/null || exit 1    # NOT engine-started -> still alive
    _REPAIR_METRO_STARTED=1; _REPAIR_METRO_PID=$sp
    repair_metro_stop
    kill -0 "$sp" 2>/dev/null && { kill "$sp" 2>/dev/null; exit 1; }  # engine-started -> killed
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/metro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "reuses an existing :8081"`
Expected: `not ok …` (`metro_is_up`/`_REPAIR_METRO_STARTED` undefined; `repair_metro_start` always runs npx; the old `repair_metro_stop` kills regardless).

- [ ] **Step 3a: Add `metro_is_up` + the started-flag.** In `scripts/lib/visual-repair.sh`, just above `repair_metro_start`, add the helper; and beside `_REPAIR_METRO_PID=""` (line 208) add the flag:

```bash
# True when a Metro bundler already answers on the dev port.
metro_is_up() {
  curl -s -o /dev/null "http://localhost:${NIGHT_SHIFT_METRO_PORT:-8081}/status" 2>/dev/null
}
```

Next to `_REPAIR_METRO_PID=""`:

```bash
_REPAIR_METRO_STARTED=0
```

- [ ] **Step 3b: Rewrite `repair_metro_start`.** Replace the function body's start section (keep the build branch as-is):

```bash
repair_metro_start() {
  local device="$1"
  if [ "$NO_BUILD" -ne 1 ]; then
    log "repair: building dev client on '$device' (slow, once)…"
    ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --device "$device" >/dev/null 2>&1 ) \
      || { log "repair: dev build failed (build manually + re-run with --no-build)"; return 1; }
  fi
  _REPAIR_METRO_STARTED=0
  if metro_is_up; then
    log "repair: reusing the Metro already on :${NIGHT_SHIFT_METRO_PORT:-8081}"
    return 0
  fi
  log "repair: starting Metro (EXPO_PUBLIC_PREVIEW=1)…"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start >/tmp/visual-repair-metro.log 2>&1 ) &
  _REPAIR_METRO_PID=$!
  _REPAIR_METRO_STARTED=1
  local i=0; until metro_is_up; do
    i=$((i+1)); [ "$i" -ge 30 ] && { log "WARN: Metro did not come up after 60s"; break; }; sleep 2; done
}
```

- [ ] **Step 3c: Rewrite `repair_metro_stop`.** Replace it with:

```bash
repair_metro_stop() {
  [ "${_REPAIR_METRO_STARTED:-0}" = "1" ] || return 0
  [ -n "${_REPAIR_METRO_PID:-}" ] && kill "$_REPAIR_METRO_PID" 2>/dev/null || true
  _REPAIR_METRO_PID=""; _REPAIR_METRO_STARTED=0
}
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/metro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "fix(visual-repair): reuse an existing Metro; stop only an engine-started one"
```

---

### Task 2: Move `repair_metro_start` before the capture loop

**Files:**
- Modify: `scripts/visual-review.sh` (the `--repair` run block, lines ~209-223)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `repair_metro_start`/`repair_metro_stop` (Task 1).

- [ ] **Step 1: Write the failing test.** Register after the Task-1 fixture line:

```bash
  fixture_assert "visual-review --repair starts Metro before the initial capture loop" fixture_repair_metro_call_order "$root"
```

Add:

```bash
fixture_repair_metro_call_order() {
  local f="$WORKSPACE_ROOT/scripts/visual-review.sh" sline cline
  sline="$(grep -n 'repair_metro_start "' "$f" | head -1 | cut -d: -f1)"
  cline="$(grep -n 'for s in "${SPECS\[@\]}"; do review_spec' "$f" | head -1 | cut -d: -f1)"
  [ -n "$sline" ] && [ -n "$cline" ] && [ "$sline" -lt "$cline" ] || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/metro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "starts Metro before the initial capture"`
Expected: `not ok …` (`repair_metro_start` currently follows the first capture loop).

- [ ] **Step 3: Move the start block.** In `scripts/visual-review.sh`, the current block (lines ~209-223) is:

```bash
[ "$NO_BUILD" -eq 1 ] || build_and_install
rc=0
for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done

if [ "$REPAIR" -eq 1 ]; then
  trap 'repair_metro_stop' EXIT
  iter_dev="$(visual_repair_devices "${SPECS[0]}" | head -n1)"
  repair_metro_start "$(device_label_to_name "$iter_dev")" || die "repair: could not start Metro"
  base="$(basename "${SPECS[0]}" .md)"
  visual_repair_for_spec "${SPECS[0]}" "$PROJECT" "$OUT/$base" "review" \
    "$OUT/$base/visual-diff-$base.json" "$MAX_ATTEMPTS" \
    "$([ "$REPAIR_SHARED" -eq 1 ] && echo 'src/features/,src/ui/' || echo 'src/features/')" "$iter_dev"
  log "repair: final authoritative pass…"; rc=0; for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done
  repair_metro_stop; trap - EXIT
fi
```

Replace it with (the start block hoisted ahead of the capture loop):

```bash
[ "$NO_BUILD" -eq 1 ] || build_and_install
if [ "$REPAIR" -eq 1 ]; then
  trap 'repair_metro_stop' EXIT
  iter_dev="$(visual_repair_devices "${SPECS[0]}" | head -n1)"
  repair_metro_start "$(device_label_to_name "$iter_dev")" || die "repair: could not start Metro"
fi
rc=0
for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done

if [ "$REPAIR" -eq 1 ]; then
  base="$(basename "${SPECS[0]}" .md)"
  visual_repair_for_spec "${SPECS[0]}" "$PROJECT" "$OUT/$base" "review" \
    "$OUT/$base/visual-diff-$base.json" "$MAX_ATTEMPTS" \
    "$([ "$REPAIR_SHARED" -eq 1 ] && echo 'src/features/,src/ui/' || echo 'src/features/')" "$iter_dev"
  log "repair: final authoritative pass…"; rc=0; for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done
  repair_metro_stop; trap - EXIT
fi
```

(`iter_dev` is set in the first `REPAIR` block and consumed in the second; both run only when `REPAIR=1`, and `visual-review.sh` script-level vars persist between them.)

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/metro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/visual-review.sh scripts/test/fixtures.sh
git commit -m "fix(visual-review): start the repair Metro before the initial capture (one Metro per --repair run)"
```

---

## Self-Review

**Spec coverage:** §3.1 `metro_is_up` → Task 1 (3a); §3.2 `repair_metro_start` reuse → Task 1 (3b); §3.3 `repair_metro_stop` guard → Task 1 (3c); §3.4 call-site move → Task 2; §4 fixtures (reuse/start/stop + call-order) → Tasks 1-2.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `metro_is_up`, `_REPAIR_METRO_STARTED`, `_REPAIR_METRO_PID`, `${NIGHT_SHIFT_METRO_PORT:-8081}` are used identically across Task 1's helper, start, stop, and the fixture; Task 2's structural fixture greps `repair_metro_start "` and `for s in "${SPECS[@]}"; do review_spec`, both of which the Task-2 edit preserves verbatim.

**Shellcheck:** the `( … ) &` background, `until metro_is_up; do … sleep 2; done`, the counter stub, and the `kill -0` liveness check are standard bash; the fixture's `sp=$!` inside a `( … )` subshell is scoped to that subshell (no `local` needed, no leak).
