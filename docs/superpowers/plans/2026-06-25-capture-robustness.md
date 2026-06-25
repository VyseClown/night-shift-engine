# Capture-path Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Harden the visual-capture/repair path so a hung Maestro capture can't freeze a loop, and a failed re-capture diff is retried instead of poisoning the loop with a bogus `1.0`.

**Architecture:** Two surgical, independent fixes — (A) a bash-watchdog timeout around `maestro test` in `__visual_capture_screenshot`; (B) a one-shot capture+diff retry in `visual_repair_screen` when the diff computation fails.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck-clean at default severity). Tests = deterministic fixtures in `scripts/test/fixtures.sh`.

**Spec:** `docs/superpowers/specs/2026-06-25-capture-robustness-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/harden-wt` (branch `fix/capture-robustness`, off `main`).
- Fixture suite: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` — pass = `grep -c "not ok"` is `0`.
- Shellcheck gate is **default severity**: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` must exit `0`.
- **Default behavior unchanged** except the two specific failure modes: a maestro success path still proceeds to the screenshot; a diff that *succeeds* (even with a high value) is **not** retried.
- New fixtures follow the existing `fixture_*` pattern, registered in `run_dry_fixtures`.
- No `timeout`/`gtimeout` on the target machine — Fix A must use a pure-bash watchdog.

## File Structure

- **Modify** `scripts/lib/visual-capture.sh` — add `__visual_run_timeout`; wrap the maestro call (Task 1).
- **Modify** `scripts/lib/visual-repair.sh` — retry block in `visual_repair_screen` (Task 2).
- **Modify** `scripts/test/fixtures.sh` — one fixture per task.

---

### Task 1: Timeout the Maestro capture (Fix A)

**Files:**
- Modify: `scripts/lib/visual-capture.sh` (add helper; change the maestro branch line ~172)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `__visual_run_timeout SECS CMD...` — runs CMD in the background under an `SECS` watchdog; returns CMD's exit status, or non-zero if the watchdog killed it. The maestro branch calls `maestro test` through it with `NIGHT_SHIFT_MAESTRO_TIMEOUT` (default 180); timeout/failure → `return 2`.

- [ ] **Step 1: Write the failing test.** Register after the existing maestro fixture line (`fixture_assert "visual capture maestro-drive runs the screen-state flow + screenshots" fixture_visual_capture_maestro "$root"`):

```bash
  fixture_assert "visual capture maestro-drive times out a hung flow (no infinite hang)" fixture_visual_capture_maestro_timeout "$root"
```

Add the fixture (xcrun stub like `fixture_visual_capture_maestro`; a `maestro` stub that HANGS):

```bash
fixture_visual_capture_maestro_timeout() {
  local root="$1" d="$root/vmt"
  mkdir -p "$d/bin" "$d/flows"
  cat >"$d/bin/xcrun" <<STUB
#!/usr/bin/env bash
shift
case "\$1" in io) printf x >"\${!#}" ;; esac
exit 0
STUB
  cat >"$d/bin/maestro" <<'STUB'
#!/usr/bin/env bash
sleep 30   # simulate a hung xcodebuild UI-test run
exit 0
STUB
  chmod +x "$d/bin/xcrun" "$d/bin/maestro"
  : >"$d/flows/Home-default.yaml"
  (
    export PATH="$d/bin:/usr/bin:/bin" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
           NIGHT_SHIFT_MAESTRO_DIR="$d/flows" NIGHT_SHIFT_MAESTRO_TIMEOUT=2
    local start end rc
    start="$(date +%s)"
    __visual_capture_screenshot Home default iphone-15 "$d/shot.png" UDID-X; rc=$?
    end="$(date +%s)"
    # timed out -> clean SKIP (rc 2), and it did NOT hang for the full 30s.
    [ "$rc" -eq 2 ] || exit 1
    [ "$((end - start))" -lt 12 ] || exit 1
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/harden-wt && time (NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "maestro-drive times out")`
Expected: `not ok …` and it takes ~30s (the un-timed maestro stub hangs the full sleep) — proving the current code has no timeout.

- [ ] **Step 3: Add the watchdog helper.** In `scripts/lib/visual-capture.sh`, immediately **before** `__visual_capture_screenshot() {`, add:

```bash
# Run a command under a timeout without GNU `timeout` (absent on macOS): background
# the command, start a watchdog that TERM-then-KILLs it after $1 seconds, and return
# the command's exit status (a watchdog kill surfaces as non-zero).
__visual_run_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 3; kill -KILL "$cmd_pid" 2>/dev/null ) &
  local wd_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  kill "$wd_pid" 2>/dev/null
  wait "$wd_pid" 2>/dev/null
  return "$rc"
}
```

- [ ] **Step 4: Wrap the maestro call.** In the maestro branch of `__visual_capture_screenshot`, replace:

```bash
    maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2
```

with:

```bash
    # Bound the UI-test run: a hung xcodebuild driver must SKIP, not freeze the loop.
    __visual_run_timeout "${NIGHT_SHIFT_MAESTRO_TIMEOUT:-180}" \
      maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2
```

- [ ] **Step 5: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/harden-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 6: Commit.**

```bash
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "fix(visual-capture): timeout the maestro test (NIGHT_SHIFT_MAESTRO_TIMEOUT) so a hung flow SKIPs"
```

---

### Task 2: Retry a repair re-capture whose diff failed (Fix B)

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`visual_repair_screen`, the capture+diff lines)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_repair_diff` (returns non-zero when the diff computation fails); the `NIGHT_SHIFT_VISUAL_DIFF_FN` test hook.
- Produces: within a repair attempt, capture+diff is retried **once** (after `NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE`, default 5s) if the diff fails; only a second failure falls back to the `1.0` sentinel. A diff that succeeds is recorded as-is (no retry).

- [ ] **Step 1: Write the failing test.** Register after the existing repair-loop fixture (`fixture_assert "visual repair loop: converge on pass" fixture_visual_repair_loop "$root"`):

```bash
  fixture_assert "visual repair loop: retries a re-capture whose diff failed" fixture_visual_repair_recapture_retry "$root"
```

Add the fixture (models `fixture_visual_repair_loop`; the diff hook **fails first, succeeds second** within one attempt):

```bash
fixture_visual_repair_recapture_retry() {
  local root="$1" proj="$root/rrp" out="$root/rrout"
  mkdir -p "$proj/src/features/home" "$out/design"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"; : >"$out/shot.png"; : >"$out/diff.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"
    . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"
    log() { :; }
    _agent() { printf 'x' >>"$proj/src/features/home/HomeScreen.tsx"; printf '{}'; }
    _cap() { :; }
    _ok() { return 0; }
    # diff fails on the FIRST call (bad capture), succeeds (0.02) on the retry.
    _N=0
    _difffail1() { _N=$((_N+1)); if [ "$_N" -ge 2 ]; then printf '0.02'; return 0; else return 1; fi; }
    export NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE=0
    NIGHT_SHIFT_VISUAL_DIFF_FN=_difffail1
    obj="$(visual_repair_screen "$proj" "$root/rt" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" \
        0.10 3 _agent _cap _ok "src/features/")"
    # The retry happened: attempt 1 records the SUCCEEDED 0.02 (not the 1.0 sentinel)
    # and the loop passes in a single attempt.
    printf '%s' "$obj" | jq -e '.pass==true and (.attempts|length)==1 and (.attempts[0].diff_pct==0.02)' >/dev/null || exit 1
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/harden-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "retries a re-capture"`
Expected: `not ok …` — current code records `1` on the first failed diff (no retry), so `.attempts[0].diff_pct` is `1`, not `0.02`, and the loop does not pass in one attempt.

- [ ] **Step 3: Implement the retry.** In `scripts/lib/visual-repair.sh`, in `visual_repair_screen`, replace:

```bash
    "$capture_fn" "$screen" "$state" "$device" "$shot"
    visual_repair_diff "$ref" "$shot" "$diff_img" >"$_pct_file" 2>/dev/null || printf '1' >"$_pct_file"
    cur="$(cat "$_pct_file")"
```

with:

```bash
    # Capture + diff, with one retry if the diff COMPUTATION fails (a bad/blank
    # screenshot — e.g. captured while Metro was still rebuilding). A diff that
    # succeeds (even high) is a real signal and is not retried.
    local _try=0 _dok=0
    while [ "$_try" -lt 2 ]; do
      _try=$((_try+1))
      "$capture_fn" "$screen" "$state" "$device" "$shot"
      if visual_repair_diff "$ref" "$shot" "$diff_img" >"$_pct_file" 2>/dev/null; then _dok=1; break; fi
      [ "$_try" -lt 2 ] && { log "visual-repair: $screen re-capture diff failed; retrying after settle"; sleep "${NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE:-5}"; }
    done
    [ "$_dok" = "1" ] || printf '1' >"$_pct_file"
    cur="$(cat "$_pct_file")"
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/harden-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0` (the new fixture AND `fixture_visual_repair_loop` still pass — the success path is unchanged)
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "fix(visual-repair): retry a re-capture whose diff failed (NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE) instead of recording 1.0"
```

---

## Self-Review

**Spec coverage:** Fix A (maestro timeout + helper + knob) → Task 1; Fix B (retry-on-diff-failure + settle knob) → Task 2; both fixtures specified in §Testing → Tasks 1-2 Step 1.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `__visual_run_timeout`, `NIGHT_SHIFT_MAESTRO_TIMEOUT`, `NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE`, the `_try`/`_dok` locals, and `$_pct_file` are used consistently. The Fix B block preserves the existing `cur="$(cat "$_pct_file")"` contract and the `_pct_file` variable already declared in `visual_repair_screen`.

**Shellcheck:** both tasks run the default-severity gate.
