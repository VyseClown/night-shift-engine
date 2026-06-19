# Build report: pixel-perfect visual fidelity (Figma → React Native)

- Date: 2026-06-18 → 2026-06-19
- Spec: `docs/superpowers/specs/2026-06-18-visual-fidelity-design.md`
- Plan: `docs/superpowers/plans/2026-06-18-visual-fidelity.md`
- Repos: engine (`night-shift-engine`), viewer (`night-shift-viewer`), test app (`rn-sandbox`)

## What we built

An **opt-in `visual_review` stage** for the night-shift that proves a React Native
screen is a pixel-accurate translation of its Figma frame, auto-repairing until it
is within tolerance, and surfaces the screenshots + diff + agent analysis in the
viewer for morning review. Inert by default: a no-op unless
`NIGHT_SHIFT_VISUAL_CAPTURE=1` **and** the spec has a `## Design Contract` **and**
the simulator/diff tooling is present.

Pipeline: `implementation_ready → visual_review → observer_review`. The deterministic
pixel-diff is the authoritative pass/fail; the agent's vision analysis explains and
drives fixes but never decides "pass".

### Components
- **Engine stage machine** (`scripts/night-shift.sh`): the `visual_review` stage
  (scope `visual` → `IMPLEMENT_MODEL`), `transition_allowed`/`expected_action`,
  routing in `verify_candidate`, the `RUN_VISUAL` dispatch + `run_visual` gate, and
  the agent procedure block in `primary_prompt`.
- **Capture/diff** (`scripts/lib/visual-capture.sh`): the device-axis capture grid,
  report assembly (`assemble-screen`/`report` CLIs), real iOS capture + `odiff`
  pixel-diff, device-by-label simulator selection, dimension-safe diff, and the
  launch-arg preview trigger.
- **Schema** (`schemas/visual-diff.json`, `schemas/next-action.json`): per-screen
  `device`/`analysis`/`attempts`; `RUN_VISUAL` action.
- **Viewer** (`night-shift-viewer`): the validator + run wiring + the Visual
  Validation panel (reference / implementation / diff images, diff% vs tolerance,
  pass badge, analysis, attempt history); surfaces live/blocked runs too.
- **App preview harness** (`rn-sandbox`): a dev-only preview mode that renders one
  screen/state in isolation, reachable via a launch argument (and a deep link).

## How it was built

Brainstorm → design spec → implementation plan → **subagent-driven execution**
(fresh implementer per task + two-stage review: spec compliance, then code quality).
Tasks 1–11 built the scaffolding (schema, stage machine, capture/diff, viewer,
harness, docs); Tasks 13–15 made it actually runnable and robust. Every task passed
both reviews; a final holistic review verdict was READY TO MERGE.

## Problems found & fixes (the valuable part)

Several real gaps were caught — some by the two-stage review, the most important
ones only by a live paid run. This is why the live smoke mattered.

1. **Agent had no procedure (Task 13).** Tasks 1–11 wired the stage/gate/CLIs but
   never told the agent *how* to run the capture→diff→repair loop, and the report
   assembler wasn't agent-callable. Caught before spending money. Fix: a `RUN_VISUAL`
   procedure block in `primary_prompt` + `assemble-screen`/`report` CLIs.

2. **Producer/consumer field mismatch (code-quality review, Task 7).** The grid
   emitted `screen|state|device` but the consumer loop read only two fields, folding
   `device` into `state`. Fix: read all three.

3. **Fail-open diff parser + missing shebang (code-quality review, Task 9).** An
   unparseable `odiff` result defaulted to 0% (a false PASS); the CLI dispatch
   needed a shebang. Fix: fail-closed + `#!/usr/bin/env bash` + robust %-token parse.

4. **Capture ignored the device label (live smoke, → Task 14).** `__visual_capture_
   screenshot` grabbed the first available sim, so the screenshot wouldn't match the
   Figma frame; and `odiff` requires identical dimensions. Fix: select the sim by
   device label; resize a copy of the reference to the screenshot's exact pixel size
   before diffing.

5. **iOS deep-link prompt blocks unattended capture (live smoke, → Task 15).** A
   custom-scheme `simctl openurl` always shows an "Open in app?" confirmation that
   can't be tapped unattended (no idb; Maestro lacked a JDK; AppleScript can't reach
   inside the sim). Fix: replaced the trigger with a **prompt-free launch argument**
   — `simctl launch … --nightshift-preview <screen>:<state>` → AppDelegate forwards
   it as an initial prop → the harness cold-launches straight into preview mode.

6. **`RUN_VISUAL` missing from the `next-action` schema enum (live smoke).** The
   agent finished visual_review with a PASS but couldn't emit a valid `RUN_VISUAL`
   signal, so it **correctly BLOCKED** rather than fake one. Fix: add `RUN_VISUAL`
   to `schemas/next-action.json` and the inline `json_schema_basic` check.

> Discipline that paid off: a free on-simulator capture sanity-check was run BEFORE
> the paid night-shift, which caught the deep-link prompt (#5) without spending.

## Cost

- A/B on a prior feature (spell-favorites): optimized **$11.71** vs baseline
  **$14.55** total; ~50% cheaper per unit of work (see
  `night-shift-ab-cost-result` memory).
- The FinWise visual-fidelity smoke run: **$4.90** through visual_review
  (plan $1.53 / impl+personas $1.88 / candidate $0.75 / **visual_review $0.74**);
  no observer (blocked before it) — a full complete run ≈ **$5.50**. The new
  visual_review stage added only ~$0.74 including the Figma-MCP fetch and image
  reads, because the screen passed on the first diff attempt (no repair loop).

## Validation outcome

A real paid run built the **FinWise launch screen** in `rn-sandbox` from Figma frame
`7020:3572` (file `DQQ72qDGGuQL8OLjA55sKg`): 6/6 personas APPROVE on both plan and
implementation rounds, candidate committed, then `visual_review` exported the Figma
reference via MCP, captured the screen via the launch-arg trigger, and `odiff`
returned **4.63% ≤ 5% tolerance = PASS on the first attempt** (residual is the
View-primitive logo approximation; background + wordmark exact). The viewer renders
the run's reference/implementation/diff images, the metric, the analysis, and the
attempt history; image assets serve over the API and path traversal is blocked.

The run ended BLOCKED only on problem #6 (the `RUN_VISUAL` schema enum), which is now
fixed — a fresh run would complete through the observer to `COMPLETE`.

## Prerequisites (for a real run)
- A Figma MCP server configured at user scope (+ token).
- Xcode / `xcrun simctl`, `odiff`, the app's preview harness, and a built app with
  the native preview trigger.
- Set `NIGHT_SHIFT_VISUAL_CAPTURE=1` and `NIGHT_SHIFT_PREVIEW_BUNDLE_ID=<app bundle id>`.

## Not done / follow-ups
- Android capture (iOS-first; the device axis leaves room).
- Per-screen "every target appears" assertion in the report (minor).
- Temp resized-reference cleanup in the diff artifact dir (minor).
