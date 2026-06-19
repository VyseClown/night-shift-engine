# Design: Pixel-perfect visual fidelity (Figma → React Native) for the night-shift

- Date: 2026-06-18
- Status: design approved; pending implementation plan
- Repos affected: engine (`~/work`), viewer (`night-shift-viewer/`), target app (`rn-sandbox/`)

## Purpose

Let an autonomous night-shift run validate — and auto-repair — that a React
Native screen is a **pixel-perfect** translation of its Figma design, and surface
the screenshots, pixel-diffs, and the agent's analysis in the night-shift viewer so
the result is verifiable in the morning.

The deterministic **pixel-diff is the authoritative pass/fail**. The agent's vision
analysis (reading reference + screenshot + diff image + Figma tokens) is the
diagnostic layer that explains *what* is off and drives the fix; it never decides
"pass."

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Figma reference acquisition | **Figma MCP server** — agent fetches frame export + tokens + measurements at run time |
| Capture navigation | **Preview harness route** — dev-only deep link renders one screen/state/device in isolation with mock data |
| Failure behavior | **Closed-loop auto-repair**, attempt-bounded, with attempt history surfaced for morning review |
| Target | **iOS simulator, multiple device sizes** (responsive): grid = screens × states × devices |
| Engine integration | **New dedicated `visual_review` stage** (Approach A) |

## Architecture

Agent-driven loop with deterministic bash helpers. The closed loop needs judgment
(read diff → edit RN code → re-render), so the **agent owns the loop**; bash
provides only deterministic, model-agnostic primitives (sim capture, pixel-diff,
report assembly + schema gate).

Five units, each with one job:

1. **`visual_review` stage** (`scripts/night-shift.sh`) — new stage in the machine:
   `implementation_ready → visual_review → observer_review → completion`. Its own
   **stage scope = `visual`** (fresh session), runs on **Sonnet** (implement-tier).
   Adds `transition_allowed` rows, a `stage_session_scope` mapping, an
   `expected_action` (`RUN_VISUAL` → emit a valid report), and the stage gate.

2. **`scripts/lib/visual-capture.sh`** (extend the existing scaffold) — replace the
   two stubs with real deterministic CLIs the agent invokes:
   - `capture <screen> <state> <device>` → boot/use iOS sim, fix the status bar
     (`simctl status_bar override`), disable animations, deep-link to the preview
     route, `simctl io screenshot`.
   - `diff <ref> <shot> <out>` → perceptual pixel-diff (`odiff`) → prints
     `diff_pct`, writes a diff image.
   - `run_visual_capture` keeps assembling `visual-diff-*.json` from per-screen
     results. The pure parts (grid expansion screens×states×devices, tolerance,
     assemble) stay and grow.

3. **App preview harness** (`rn-sandbox`) — a dev-only
   `nightshift://preview?screen=&state=&device=` route rendering one screen/state in
   isolation with mock data at the device frame. Per-app; the deterministic capture
   target.

4. **Schema + validator** (`schemas/visual-diff.json` and the viewer's
   `server/src/visualDiff.js`) — extended for agent analysis + attempt history, kept
   in lock-step (both use `additionalProperties:false`).

5. **Viewer panel** (`web/src/VisualValidation.jsx`) — extended to show analysis
   text + a collapsible attempt history alongside the existing reference/impl/diff
   images, diff% vs tolerance, and pass/fail badge.

### The loop (inside the `visual_review` Sonnet session, bounded by `N` attempts)

```
for each screen × state × device in the Design Contract:
  Figma MCP → export reference PNG + read tokens/measurements
  attempt = 1
  loop:
    capture (deep-link sim) → screenshot
    diff → diff_pct + diff image
    if diff_pct ≤ tolerance: record pass, break
    if attempt == N: record give-up + analysis, break
    agent: read diff + tokens → write analysis → edit RN code → attempt++
assemble report (per-screen: pass, diff%, images, analysis, attempts) → validated/
if any RN code changed during repair:
  re-run the spec's validation commands (must stay green)
  update the candidate commit (amend / new commit on the feature branch)
signal RUN_VISUAL  →  observer reviews the POST-REPAIR candidate + the report
```

**Candidate handling:** the candidate is first created at `implementation_ready`.
Because `visual_review` may edit RN code to reach pixel-perfect, the stage must,
after the loop, re-run validation and refresh the candidate commit so the observer
always reviews the repaired code (not the pre-repair candidate). If no code changed
(all screens passed first try), the candidate is untouched.

### Model tiering

Pixel-diff is deterministic (no model). The Sonnet `visual_review` session runs the
repair loop (cheap, and image tokens do not cache, so they are kept off Opus). The
**Opus observer** receives the final visual report as evidence for its verdict.

## Schema & data

`schemas/visual-diff.json` + `server/src/visualDiff.js` gain three per-screen keys
(added to both the schema and the validator's `SCREEN_KEYS` allow-list together):

```jsonc
{
  "task": "specs/login-screen.md",
  "screens": [
    {
      "screen": "Login", "state": "error",
      "device": "iphone-15",            // NEW — responsive grid axis
      "reference": "design/Login-error-iphone-15.png",
      "screenshot": "screenshots/<candidate>/Login-error-iphone-15.png",
      "diff_image": "diffs/<candidate>/Login-error-iphone-15.png",
      "diff_pct": 0.04, "tolerance": 0.10, "pass": true,
      "analysis": "Final: title baseline 2px low (spacing/lg=24, was 22). Fixed.", // NEW
      "attempts": [                      // NEW — morning audit trail
        { "attempt": 1, "diff_pct": 0.31, "pass": false,
          "analysis": "Title 2px low; primary button #2E6 vs Figma #22DD66.",
          "screenshot": "screenshots/<candidate>/Login-error-iphone-15.a1.png",
          "diff_image": "diffs/<candidate>/Login-error-iphone-15.a1.png" },
        { "attempt": 2, "diff_pct": 0.04, "pass": true, "analysis": "Within tolerance.",
          "screenshot": "screenshots/<candidate>/Login-error-iphone-15.a2.png",
          "diff_image": null }
      ]
    }
  ]
}
```

`pass` stays deterministic (`diff_pct ≤ tolerance`); the existing pass-consistency
check in the validator is preserved. `analysis`/`attempts` are explanatory only and
never flip a pass. A screen that exhausted attempts has `pass:false` plus a final
`analysis` saying so.

### Data flow (end to end)

```
Design Contract (Figma file/node IDs, Frames, Required states, Devices, Tolerance)
  → visual_review stage (fresh Sonnet session)
  → per screen×state×device: Figma MCP export ref + tokens
  → capture (sim deep-link) → diff → [repair loop ≤ N]
  → assemble validated/visual-diff-<spec>.json + images under
    validated/{design,screenshots,diffs}/
  → observer_review: Opus observer reads the report as evidence
  → archive: report + images travel into the run archive
  → viewer: server resolves image paths → URLs; panel renders in the morning
```

### Viewer panel (morning view)

```
┌ Login · error · iphone-15                      [ pass ]
│  [reference]   [implementation]   [diff]
│  diff 0.04%  vs tolerance 0.10%
│  Analysis: title baseline was 2px low (spacing/lg=24, was 22). Fixed.
│  ▸ Attempts (2)                ← click to expand
│     1  0.31%  fail  "title 2px low; btn #2E6 vs #22DD66"
│     2  0.04%  pass  "within tolerance"
└
```

A failed screen renders the same way with a `fail` badge, so the morning view shows
which screens missed pixel-perfect, the agent's reasoning, and each attempt's
before/after.

## Error handling & degradation

The feature is opt-in and inert by default. `visual_review` is a clean **SKIP
no-op** (transitions straight to `observer_review`) unless: the spec has a
`## Design Contract`, **and** `NIGHT_SHIFT_VISUAL_CAPTURE=1`, **and** `xcrun`/`odiff`
are on PATH. Existing runs (web track, `spell-favorites`, etc.) are unaffected.

| Failure | Behavior |
|---|---|
| Figma MCP unavailable / ref export fails | Log loudly; mark those screens `unresolved` in the report; do **not** hard-block the night — hand to observer (may BLOCK). |
| Simulator won't boot / deep-link fails | Record the capture failure in the report; degrade, don't crash. |
| Attempt budget `N` exhausted on a screen | Stop that screen, record `pass:false` + final analysis, continue other screens, then signal. No infinite loops. |
| Flaky pixel diff (antialiasing) | Perceptual diff (`odiff` antialiasing mode) + small default tolerance (0.10%) + determinism measures. |

**Determinism measures:** fixed device + scale, `simctl status_bar override` (fixed
time/battery/wifi), animations disabled, mock data via the preview harness, fonts
pinned.

## Cost guards

Image tokens are the new cost driver and do not cache well.

- Bounded attempts `N` (default 3) **and** a grid cap (max screens × states ×
  devices), so a large Design Contract cannot explode cost.
- Repair loop on Sonnet; only the final report goes to the Opus observer (no
  per-attempt Opus image reads).
- Knobs: `NIGHT_SHIFT_VISUAL_CAPTURE=1`, `NIGHT_SHIFT_VISUAL_TOLERANCE` (exists),
  `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS`, `NIGHT_SHIFT_VISUAL_MAX_SCREENS`,
  `NIGHT_SHIFT_VISUAL_DEVICES`.

## Testing

- **Engine fixtures (deterministic, no simulator)** — extend the free fixture
  suite: grid expansion (screens×states×devices), tolerance parse, report assembly
  with `analysis`/`attempts`, schema shape, pass-consistency, the new
  `visual_review` transitions + `stage_session_scope=visual` + `expected_action`,
  and the SKIP path when disabled. Sim/diff CLIs are mocked (real `xcrun`/`odiff`
  never run in CI).
- **Viewer** — extend `server/test/visualDiff.test.js` for the new fields; schema +
  validator stay in lock-step.
- **Real validation (opt-in, manual)** — one run on `rn-sandbox` with a Design
  Contract, a booted iOS sim, Figma MCP configured; confirm report + images +
  analysis render in the viewer.

## Prerequisites

- A configured Figma MCP server (+ `FIGMA_TOKEN`).
- Xcode / `xcrun simctl`.
- An image-diff tool (`odiff`).
- The per-app preview harness added to `rn-sandbox`.

## Out of scope (YAGNI)

- Android emulator capture (iOS first; the device axis leaves room to add it later).
- Off-simulator component rendering.
- Scripted UI-automation navigation (the preview harness replaces it).
- Pulling Figma references via committed PNGs or the REST API (MCP chosen instead).
- Auto-generating the preview harness for arbitrary apps (added per app by hand for
  now).

## Open prerequisites to confirm before implementation

- Figma MCP is actually installed/available to the `claude -p` subprocess.
- A reference device list + matching Figma frame exports per device size exist.
