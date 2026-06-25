# Maestro capture drive mode — design

Date: 2026-06-25. Status: approved design (pre-plan). Repo: `night-shift-engine`.
Builds on the merged visual-fidelity capture (`scripts/lib/visual-capture.sh`
`__visual_capture_screenshot`, drive modes file/launcharg/openurl).

## 1. Summary

Add an **opt-in capture drive mode** that uses **Maestro** (mobile UI automation,
YAML flows) to drive the **real** React Native app into a scenario matching the
Figma frame, then screenshot it for the existing `odiff` comparison — a peer to the
current file/launcharg/openurl modes. Unlike those (which cold-launch a seeded
preview route), Maestro navigates the real app through real interactions, so it
needs **no preview harness/route** and works against a **normal build**.

Locked decisions (from brainstorming):
- **Alternative drive mode** (a peer; the existing modes are untouched), selected by
  `--drive maestro` / `NIGHT_SHIFT_MAESTRO_DIR`.
- **Maestro drives only; the existing pipeline screenshots.** The flow navigates;
  then the shared status-bar override + `simctl io screenshot "$out"` take the shot.
- **One YAML flow per `screen`-`state`, by convention**:
  `$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml`.

## 2. Goals / Non-goals

**Goals**
- A `maestro` drive mode in `__visual_capture_screenshot`, opt-in, that drives the
  real app to the target scenario then reuses the shared screenshot/diff pipeline.
- Convention-based flow resolution; a missing flow or missing `maestro` **cleanly
  SKIPs** that screen (returns 2), never blocks — consistent with the existing
  degrade-cleanly contract.
- `visual-review.sh --drive maestro` wiring; works against a normal build (no
  `EXPO_PUBLIC_PREVIEW`/preview route).
- Deterministic fixtures + a sample flow + an authoring note.

**Non-goals**
- Replacing the preview-harness modes (they stay; this is a peer).
- Authoring real flows for any specific app (the project author writes flows; we
  ship one sample).
- Android (iOS simulator only, consistent with the rest of the pipeline).
- Maestro Cloud / sharded/parallel Maestro runs.

## 3. Background (current state, on `main`)

- `__visual_capture_screenshot screen state device out [udid]` (`scripts/lib/visual-capture.sh`):
  resolves the udid, boots the sim, overrides the status bar (09:41, full battery),
  then drives the app into preview mode via one of three env-selected modes
  (file = `NIGHT_SHIFT_PREVIEW_BUNDLE_ID`+`NIGHT_SHIFT_PREVIEW_FILE`; launcharg =
  `_BUNDLE_ID`; openurl = neither), then `sleep $NIGHT_SHIFT_VISUAL_SETTLE_SECONDS`
  and `xcrun simctl io "$udid" screenshot "$out"`. Returns 2 on any failure (clean SKIP).
- `visual_capture_available()` gates on `NIGHT_SHIFT_VISUAL_CAPTURE=1` + `xcrun` +
  the diff tool (`odiff`).
- `visual_capture_screens <spec>` yields `screen|state|device` triples from the
  Design Contract.
- `visual-review.sh` has `--drive openurl|file`; `DRIVE=file` exports the preview
  env. Maestro is installed at `~/.maestro/bin/maestro`.

## 4. Architecture

### 4.1 Capture branch (`scripts/lib/visual-capture.sh`)

In `__visual_capture_screenshot`, add a **fourth** branch, checked **first** (before
the `bid`/`pfile` dispatch), gated on `NIGHT_SHIFT_MAESTRO_DIR` being set:

```bash
local mdir="${NIGHT_SHIFT_MAESTRO_DIR:-}"
if [ -n "$mdir" ]; then
  command -v maestro >/dev/null 2>&1 || return 2
  local flow="$mdir/${screen}-${state}.yaml"
  [ -f "$flow" ] || return 2                       # missing flow -> clean SKIP
  maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2
elif [ -n "$bid" ] && [ -n "$pfile" ]; then
  … (1) file …
elif [ -n "$bid" ]; then
  … (2) launcharg …
else
  … (3) openurl …
fi
# unchanged: sleep settle; xcrun simctl io screenshot "$out"; [ -s "$out" ]
```

Maestro runs synchronously (the flow completes with the app at the target state),
so the existing `sleep $NIGHT_SHIFT_VISUAL_SETTLE_SECONDS` + `simctl io screenshot`
capture the result. The status-bar override (already applied above the dispatch)
still pins 09:41 for determinism. No change to the screenshot/diff path.

### 4.2 Flow resolution + contract

- **Path:** `$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml`. `<Screen>`/`<state>`
  are the Design Contract frame name + state verbatim (e.g. `Home-default.yaml`).
- **A flow is self-contained:** `appId:` header + `launchApp` + the taps/input/scroll
  to reach the exact scenario matching the Figma frame. It must **not** take a
  screenshot (the pipeline does). The author owns determinism — the flow sets up the
  precise data/navigation (this is the point of Maestro: a real scenario "exactly
  like the Figma image").
- **Missing flow → `return 2`.** Per the existing `run_visual_capture` contract, a
  per-screen capture `return 2` ends **that spec's** capture (a clean SKIP — logged,
  no block — it does not continue to later screens). So in practice **author a flow
  for every `screen`-`state` in the matrix**, or expect capture to stop at the first
  missing flow. (This matches how the preview-harness modes behave when a screen
  can't be driven; it is not maestro-specific.)

### 4.3 `visual-review.sh` wiring

- Accept `--drive maestro` (extend the `case "$DRIVE"`), plus an optional
  `--maestro-dir DIR` (default `<project>/.maestro`).
- `--drive maestro` exports `NIGHT_SHIFT_MAESTRO_DIR="$maestro_dir"` and does NOT set
  the preview bundle/file. The build/install stage builds a **normal** app (no
  `EXPO_PUBLIC_PREVIEW`).
- Refs, diff, report, and the repair surface are unchanged (maestro is purely a
  capture-drive concern). `--repair` may combine with `--drive maestro` later, but
  is out of scope here (the repair agent edits code, then re-capture re-runs the
  flow — which works for free since capture is drive-mode-agnostic).

### 4.4 Gating + clean skip

- `visual_capture_available` is unchanged (it gates capture generally). The maestro
  branch self-gates: `command -v maestro` and `[ -f "$flow" ]`, each returning 2 on
  absence. `run_visual_capture` treats a per-screen `return 2` as "SKIP" and ends the
  spec's capture cleanly (no block) — so absent maestro / a missing flow degrades
  cleanly (the spec is simply not captured) rather than erroring.
- `visual-review.sh` logs once when `--drive maestro` is selected (flow dir, and a
  warning if `maestro` is not on PATH).

## 5. Reporting

No schema change. The report is produced exactly as today from the captured
screenshots; SKIPped screens (missing flow) are simply absent, as with any
unavailable screen.

## 6. Testing

Deterministic fixtures (mock `maestro` + `xcrun` on PATH, mirroring
`fixture_visual_capture_udid_arg`):
- **dispatch:** with `NIGHT_SHIFT_MAESTRO_DIR` set and a flow file present, the
  maestro branch runs (`maestro … test <dir>/Home-default.yaml`), NOT openurl/file —
  assert the stub logs the flow path and the screenshot byte is written via the
  shared `io` path.
- **flow resolution:** the path is `<dir>/<Screen>-<state>.yaml` verbatim.
- **missing flow → return 2** (clean SKIP); **missing `maestro` on PATH → return 2**.
- **precedence:** `NIGHT_SHIFT_MAESTRO_DIR` takes priority over `_BUNDLE_ID`/`_FILE`.
- `visual-review.sh`: `--drive maestro` accepted + documented; a bogus `--drive`
  still rejected.

Plus a **sample flow** (`docs/examples/maestro/Home-default.yaml`) and a short
authoring note in `CLAUDE.md` (how to write a flow per screen-state; that it must
not screenshot; that missing flows SKIP).

Real smoke (manual, documented follow-up): author a real flow for one screen of a
project, run `visual-review.sh --drive maestro`, confirm the screenshot matches the
flow's scenario and the diff report is produced.

## 7. Risks / open questions

- **Maestro device targeting:** `maestro --device <udid> test <flow>` targets the
  specific booted simulator; confirmed by the fixture's stub and the manual smoke.
- **Flow flakiness / timing:** real flows can be flaky (animations, async). The
  flow author uses Maestro's `assertVisible`/`waitForAnimationToEnd`; the pipeline's
  settle still applies. A `maestro test` non-zero → return 2 (SKIP) rather than a
  false screenshot.
- **Status-bar override vs a real app:** the override is applied before the flow; a
  flow that backgrounds/relaunches the app could drop it. Documented; the sample
  flow does a single `launchApp`.
- **Determinism is the flow author's responsibility** (real data/state) — unlike the
  seeded preview harness. This is the explicit trade-off of the black-box approach.

## 8. Out of scope / future

- `--drive maestro` + in-loop repair interplay (works for free, but unsmoked).
- Android via Maestro.
- Auto-generating flows from the Figma frame.
