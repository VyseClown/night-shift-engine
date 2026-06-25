# Visual auto-repair — design

Date: 2026-06-24. Status: approved design (pre-plan). Repo: `night-shift-engine`
(`~/work`).

## 1. Summary

Today the design-fidelity pipeline is **measure-and-report only**: it captures
each screen, pixel-diffs it against a Figma reference (`odiff`), and writes a
`visual-diff-*.json` (the viewer renders it). It does **not** fix screens that miss
tolerance. This feature adds an **opt-in auto-repair loop**: when a screen is over
tolerance, an agent edits the screen toward the Figma **design and its annotations**
(Dev Mode specs + pinned comments), the engine re-captures, and the loop repeats up
to a bounded number of attempts.

It serves **both** surfaces from one shared mechanism:

- **Standalone** — `scripts/visual-review.sh --repair` ("review the finished app,
  then fix").
- **In-loop** — an opt-in repair in the night-shift `visual_review` stage, so a
  Figma-driven build self-heals before the stage completes. (This re-introduces the
  per-screen agent repair that PR #15 deliberately removed — now opt-in, as #15's
  own note anticipated: "reintroduce pixel auto-repair later only as an opt-in
  bounded pass.")

Both default **off**; with the flags unset, current behavior is byte-for-byte
unchanged.

## 2. Goals / Non-goals

**Goals**
- Bounded, opt-in auto-repair that edits real screen code toward the Figma frame.
- Repair targets the **pixel diff AND a design brief** = Figma Dev Mode specs
  (sizes/spacing/tokens) + pinned comments (design-intent notes).
- Fast iteration: edits must be visible to re-capture in seconds, not minutes.
- Safe: scoped edits, validation gates, never auto-commit, bounded cost.
- One shared primitive, two surfaces (standalone + in-loop).
- Deterministic test coverage of the loop; a real smoke on a closeable-gap case.

**Non-goals**
- Pixel-matching a structurally-divergent design (e.g. water-tracker vs a generic
  community template) — repair closes *closeable* gaps; it is not a redesign engine.
- Editing non-UI layers (data/domain), tests, native config, or routes.
- Committing, pushing, or merging the repair edits (the human reviews them).
- Android (iOS simulator only, consistent with the existing capture).

## 3. Background (what exists)

- `scripts/visual-review.sh` — standalone capture→diff→report. Drive modes
  `openurl` / `launcharg` / `file` (`__visual_capture_screenshot` in
  `scripts/lib/visual-capture.sh`). Currently report-only.
- `scripts/lib/visual-capture.sh` — `visual_capture_screens` (parses the spec's
  `## Design Contract` into screen|state|device), `__visual_capture_screenshot`,
  `__visual_pixel_diff` (odiff, fraction 0–1), `visual_assemble_screen`
  (the report objects, including an already-present `attempts[]` array),
  `run_visual_capture`.
- `node_id_for` / `figma_key_for` in `visual-review.sh` already parse the frame
  `fileKey` and per-frame node IDs from the Design Contract.
- The file-drive boot (`EXPO_PUBLIC_PREVIEW=1`, target file in the app's doc dir)
  renders any seeded preview screen prompt-free.
- In-loop, `visual_review` is engine-invoked single-pass (`RUN_VISUAL`); repair is
  currently coarse (observer BLOCK → fresh implement cycle).
- The Figma MCP (`mcp__figma__get_figma_data`, `download_figma_images`) is
  **agent-only** — usable from a Claude session, not from bash.

## 4. Architecture

```
                ┌──────────────────────────────────────────────┐
 spec Design    │  shared repair primitive (scripts/lib/        │
 Contract  ───► │  visual-repair.sh): bounded per-screen loop,  │
 (fileKey,      │  capture↔diff↔agent-edit↔revalidate,          │
  nodeIds,      │  attempts[]/unmet-brief assembly, scope+       │
  tolerance)    │  validation guardrails                        │
                └───────────────┬───────────────┬──────────────┘
                                │               │
                   ┌────────────▼───┐   ┌────────▼──────────────┐
                   │ Surface 1      │   │ Surface 2             │
                   │ standalone     │   │ in-loop visual_review │
                   │ visual-review  │   │ (night-shift.sh)      │
                   │ --repair       │   │ NIGHT_SHIFT_VISUAL_   │
                   │ (spawns        │   │ REPAIR=1 (uses the    │
                   │  claude -p)    │   │  implement session)   │
                   └────────────────┘   └───────────────────────┘
                                │               │
                   ┌────────────▼───────────────▼──────────────┐
                   │ Metro fast-reload harness: dev build +     │
                   │ EXPO_PUBLIC_PREVIEW=1 + Metro; re-capture  │
                   │ via existing file-drive cold-launch        │
                   └────────────────────────────────────────────┘
```

The two surfaces differ only in **who the agent is** (a spawned `claude -p` vs the
existing in-loop implement session) and **when it runs** (after-the-fact vs during
the build). Everything else — the bounded loop, the design brief, capture/diff,
validation gates, reporting — is shared.

### 4.1 Repair-agent contract

The agent (Claude session with the Figma MCP available) is invoked per
over-tolerance screen with:

- **Images**: the Figma reference PNG, the current screenshot, the odiff overlay.
- **Numbers**: current `diff_pct`, `tolerance`.
- **Design brief inputs**: the frame `fileKey` + `nodeId` (parsed by bash from the
  Design Contract) and whether `FIGMA_TOKEN` is set. The agent assembles the brief
  itself: **Dev Mode specs** via `mcp__figma__get_figma_data` (sizes, spacing,
  colors, typography, tokens — no token needed); **pinned comments** via the Figma
  REST API `GET /v1/files/:key/comments` **only if `FIGMA_TOKEN` is set** (else it
  notes comments were unavailable). MCP rate-limit (429) is retried with backoff.
- **The screen's source** and the project's design tokens.
- **Rules**: edit only within the screen's feature module
  (`src/features/<screen>/**`); shared `src/ui/**` only when
  `--repair-shared` / `NIGHT_SHIFT_VISUAL_REPAIR_SHARED=1` is set. Never touch
  tests, `src/data`, `src/domain`, `app/`, or native config. Keep `tsc`/`eslint`
  green. Do not run git, commit, push, or build native.
- **Output (structured)**: the files it edited and a list of **unmet brief items**
  (specs/comments it could not satisfy and why).

Model: `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default = the implement model, `sonnet`).
For the in-loop surface the agent *is* the existing implement session, so no model
knob applies there.

### 4.2 Bounded loop (`scripts/lib/visual-repair.sh`)

Per over-tolerance screen, worst-`diff_pct` first:

1. Invoke the repair agent (§4.1).
2. Run the **validation gate**: `tsc --noEmit` + `eslint`. If red and the agent
   cannot fix it, `git checkout` the scoped files (revert this attempt) and stop
   repairing this screen (record the gate failure).
3. Let Fast Refresh settle (`NIGHT_SHIFT_VISUAL_REPAIR_SETTLE`, default 5s),
   **re-capture this one screen** via the existing file-drive cold-launch, re-diff.
4. Append `{attempt, diff_pct, pass, analysis, screenshot, diff_image}` to the
   screen's `attempts[]`. If `pass` → stop (success). If attempts remain → feed the
   new diff back and repeat. If exhausted → keep the best-scoring attempt's edits
   and record the screen as still-over-tolerance.

Bounds: `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` (default 3) per screen, plus a global
attempt cap (`NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP`, default 30) so a pathological
run can't spin unbounded. A one-line **paid-session cost warning** prints before the
first agent spawn.

### 4.3 Metro fast-reload harness

Repair requires edits to be live before re-capture. A Release build embeds the
bundle (a rebuild per edit is minutes); instead repair runs against a **dev build +
Metro**:

- Build/install a dev client (`expo run:ios`, debug) once on the iteration device;
  start Metro with `EXPO_PUBLIC_PREVIEW=1` so the file-drive boot is compiled in and
  `EXPO_PUBLIC_*` is inlined.
- Re-capture is the existing file-drive cold-launch: write `"<screen>:<state>"`,
  `simctl terminate` + `simctl launch`; the dev client reconnects to Metro, loads
  the latest (hot-reloaded) JS, and renders the preview. Screenshot.
- The harness owns Metro's lifecycle (start, and stop on exit, including on error).

Iteration happens on **one device** (first in the matrix) for speed.

### 4.4 Surface 1 — standalone `visual-review.sh --repair[=N]`

Flow: build/install dev + start Metro (unless `--no-build`) → first
capture+diff (existing) → for each over-tolerance screen run the bounded loop
(§4.2) with a **spawned scoped `claude -p`** as the agent → after all repairs, **one
final authoritative full-matrix capture+diff** (so cross-screen regressions from
shared edits are measured) → write the report → stop Metro. Edits are left
**uncommitted**; the tool prints the changed files.

### 4.5 Surface 2 — in-loop `visual_review` repair

Opt-in via `NIGHT_SHIFT_VISUAL_REPAIR=1`. The `visual_review` stage captures+diffs
as today; when repair is on and screens are over tolerance with attempts remaining,
the stage routes the diff + brief inputs back to the **existing implement session**
to edit the screens (the §4.1 contract), then re-captures (§4.3) — a bounded
sub-loop before the stage signals completion. With repair off, the stage behaves
exactly as today (single-pass, observer-driven repair). This reuses the same
`scripts/lib/visual-repair.sh` loop, brief contract, validation gate, and
`attempts[]` assembly, and the same Metro fast-reload harness (§4.3) to make edits
live before re-capture.

## 5. Reporting / schema

`schemas/visual-diff.json` per-screen object already carries `attempts[]`; the loop
populates it. Add one optional per-screen field:

- `unmet_brief`: array of strings — specs/comments the agent could not satisfy
  (empty/omitted when fully satisfied or no brief was available).

The viewer change to render `unmet_brief` and the attempt history is tracked but is
a small follow-up, not part of this engine spec.

## 6. Configuration

| Flag / env | Default | Meaning |
|---|---|---|
| `--repair[=N]` (standalone) | off | Enable repair; N = attempts/screen |
| `NIGHT_SHIFT_VISUAL_REPAIR=1` (in-loop) | off | Enable in-loop repair |
| `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` | 3 | Attempts per screen (both surfaces) |
| `NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP` | 30 | Global attempt ceiling |
| `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` | implement model (`sonnet`) | Standalone repair-agent model |
| `--repair-shared` / `NIGHT_SHIFT_VISUAL_REPAIR_SHARED=1` | off | Allow edits to `src/ui/**` |
| `NIGHT_SHIFT_VISUAL_REPAIR_SETTLE` | 5s | Fast-Refresh settle before re-capture |
| `FIGMA_TOKEN` | unset | Enables pinned-comments fetch (graceful skip if unset) |

## 7. Guardrails

- **Scope**: feature-module edits only by default; shared UI behind an explicit
  opt-in; tests/data/domain/routes/native config always denied (enforced by the
  agent's allowed-tools scope + a post-edit `git status` check that fails the
  attempt if out-of-scope files changed).
- **Validation gate**: `tsc` + `eslint` must pass each attempt or it is reverted.
- **No VCS actions** by the agent; edits left uncommitted for human review.
- **Bounded cost**: per-screen + global caps; explicit paid-run warning.
- **Determinism preserved**: repair uses the same seeded preview fixtures + pinned
  clock + Reduce-Motion as capture, so diffs remain stable across attempts.

## 8. Testing

**Deterministic fixtures** (no simulator, no real agent — the engine's existing
`--fixture-test` style, mocking `xcrun` and the agent invocation):
- loop control flow: attempts decrement, stop-on-pass, give-up-after-N, global cap;
- `attempts[]` and `unmet_brief` assembly into a schema-valid report;
- validation-gate failure reverts the scoped edits and stops that screen;
- out-of-scope edit detection fails the attempt;
- brief-input plumbing: fileKey/nodeId parsed and passed; `FIGMA_TOKEN`
  present/absent toggles the comments path (mock the agent's report of
  "comments unavailable").

**Real smoke** (manual, documented): a deliberately-perturbed but **closeable-gap**
screen (e.g. a known spacing/color offset from its Figma frame) repaired to within
tolerance in ≤ N attempts on a real simulator. *Not* water-tracker (structural
divergence won't close).

## 9. Risks / open questions

- **Agent edits real code.** Mitigated by scope + validation gate + revert +
  uncommitted-only + human review. Shared-UI edits can regress other screens; the
  final full-matrix pass measures it but does not auto-revert — over-tolerance
  regressions are reported for the human.
- **MCP availability to a spawned `claude -p`.** The Figma MCP must be registered so
  the repair subprocess inherits it (ideally user scope:
  `claude mcp add -s user figma …`). If absent, repair still runs on the pixel diff
  alone and notes the brief was unavailable (graceful).
- **Fast-Refresh edge cases** (a syntax error mid-edit, a stuck Metro). The
  validation gate catches broken edits before re-capture; the harness restarts/
  tears down Metro on failure.
- **Convergence not guaranteed.** A screen may not reach tolerance in N attempts;
  that is reported, not retried forever.
- **Combined-spec size.** Both surfaces in one spec is larger; the plan should stage
  it: shared primitive + Metro harness + standalone first, then in-loop wiring, then
  fixtures — each independently testable.

## 10. Out of scope / future

- Viewer rendering of `unmet_brief` (small follow-up).
- Android repair.
- A non-interactive "repair plan only" mode (analysis without edits).
- Auto-committing repairs behind a separate explicit flag.
