# Capture-path robustness — design

Date: 2026-06-25. Repo: `night-shift-engine`. Two surgical hardening fixes to the
visual-capture / repair path, both surfaced by a live Maestro-driven auto-fix demo.

## Background (what broke)

A live demo ran the auto-fix loop with Maestro-driven capture. The auto-fix *logic*
was correct (the agent matched the reference on its first attempt), but the **capture
harness** failed in two ways:

1. **Maestro capture hung the whole loop.** `maestro --device <udid> test <flow>` (an
   `xcodebuild` UI-test run) stalled and never returned; the call had no timeout, so
   the repair loop froze for ~an hour.
2. **A capture taken right after a hot edit was bad.** Metro was still rebuilding, so
   the screenshot was unusable; `visual_repair_diff` then *failed* and the loop
   recorded the failure sentinel `1.0` as the attempt's diff. That bogus value misled
   the agent into oscillating instead of trusting its correct fix.

Neither is a flaw in the repair logic — both are capture-harness robustness gaps.

## Fix A — timeout the Maestro capture

In `scripts/lib/visual-capture.sh`, `__visual_capture_screenshot`'s maestro branch
(currently `maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2`):

- Run `maestro test` under a timeout of `NIGHT_SHIFT_MAESTRO_TIMEOUT` seconds (default
  **180**). On timeout (or any non-zero exit) → `return 2` (the existing clean-SKIP
  contract). A SKIP is strictly better than an unbounded hang.
- This machine has **no `timeout`/`gtimeout`**, so add a small portable helper
  `__visual_run_timeout SECS CMD...` (bash watchdog): run the command in the
  background, start a watchdog that `kill -TERM`s (then `-KILL`s) it after `SECS`,
  `wait` for the command, cancel the watchdog, and return the command's exit status
  (the watchdog kill surfaces as non-zero). Killing the `maestro` CLI unblocks the
  loop; lingering `xcodebuild` children are left to the OS (best-effort — no broad
  `pkill`, which could match unrelated processes).

Knob: `NIGHT_SHIFT_MAESTRO_TIMEOUT` (default 180). Default behavior unchanged except a
hung maestro now SKIPs after the timeout instead of hanging forever.

## Fix B — retry a repair re-capture whose diff failed

In `scripts/lib/visual-repair.sh`, `visual_repair_screen`'s per-attempt capture+diff
(currently a single `"$capture_fn" …; visual_repair_diff … || printf '1'`):

- Treat a **failed diff** (`visual_repair_diff` exits non-zero — the bad/blank/corrupt
  screenshot case) as "re-capture, don't trust": retry the `capture_fn` + diff **once**
  after a settle of `NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE` seconds (default **5**, to let
  Metro finish rebuilding). Only if the retry's diff also fails do we fall back to the
  `1.0` sentinel.
- A diff that **succeeds** with a high value is a real signal and is **not** retried —
  this only guards against a failed diff computation, not a legitimately large diff.

Knob: `NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE` (default 5). The success path is unchanged
(one capture, one diff); the retry only triggers when the diff computation fails.

### Residual (documented, out of scope)

A capture that yields a *valid* PNG of the *wrong* content (e.g. a Metro splash with
correct dimensions) makes `odiff` **succeed** with a high diff, so Fix B won't retry
it. Detecting that needs content/variance analysis and is deferred; Fix B covers the
observed failure (the diff-computation failure → `1.0` sentinel).

## Non-goals

- Wiring `--drive maestro` together with `--repair` (still separate; repair forces
  file-drive). These fixes harden each path independently.
- Killing lingering `xcodebuild`/simulator child processes on maestro timeout.
- Content-based blank-screenshot detection (the residual above).

## Testing

Deterministic fixtures (stub binaries / injected fns on PATH):
- **Fix A:** an `xcrun` stub + a `maestro` stub that **hangs** (`sleep 30`); with
  `NIGHT_SHIFT_MAESTRO_TIMEOUT=2`, `__visual_capture_screenshot` returns **2** quickly
  (well under the hang), proving the timeout fires (assert wall-clock < ~10s). A second
  case: a `maestro` stub that exits 0 fast → capture proceeds to the screenshot as today.
- **Fix B:** drive `visual_repair_screen` with an injected `capture_fn` and a
  `NIGHT_SHIFT_VISUAL_DIFF_FN` that **fails on the first call, succeeds on the second**;
  assert the attempt records the *succeeded* diff (not the `1.0` sentinel) — i.e. the
  retry happened. A control case: a diff that succeeds first try is not retried.

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green. Both knobs default to today's behavior except the
specific failure modes above.
