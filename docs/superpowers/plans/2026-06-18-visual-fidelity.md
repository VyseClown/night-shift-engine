# Pixel-perfect Visual Fidelity (Figma → RN) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a closed-loop, opt-in `visual_review` stage to the night-shift that captures iOS screenshots of an RN app, pixel-diffs them against Figma references, auto-repairs to pixel-perfect, and surfaces screenshots + diffs + agent analysis in the viewer for morning review.

**Architecture:** Agent-driven repair loop with deterministic bash helpers. Pixel-diff is the authoritative pass/fail; the agent's analysis explains and drives fixes. A new `visual_review` stage sits between candidate creation and the observer. The whole feature is inert unless a spec has a `## Design Contract` AND `NIGHT_SHIFT_VISUAL_CAPTURE=1` AND tooling is present.

**Tech Stack:** bash 3.2 + jq (engine), Node built-in test (engine fixtures + viewer server), React/Vite (viewer web), React Native + iOS simulator (`xcrun simctl`) + `odiff` + Figma MCP (capture, opt-in only).

**Source of truth:** `docs/superpowers/specs/2026-06-18-visual-fidelity-design.md`

**Validation commands used throughout:**
- Engine syntax: `bash -n scripts/night-shift.sh`
- Engine fixtures (free, deterministic): `scripts/night-shift.sh --fixture-test --dry-run`
- Viewer server tests: `cd night-shift-viewer/server && node --test`
- Viewer web build: `cd night-shift-viewer/web && npm run build`

---

## Phase 1 — Schema + viewer surfacing (deterministic, no simulator)

This phase ships first because it is fully testable without a simulator and unblocks the morning-review UI independently of capture.

### Task 1: Extend the visual-diff schema with `device`, `analysis`, `attempts`

**Files:**
- Modify: `schemas/visual-diff.json`

- [ ] **Step 1: Add the three keys to the schema**

In `schemas/visual-diff.json`, inside `properties.screens.items`, add `device`, `analysis`, `attempts` to `required` and `properties`. Replace the `items` object with:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "screen", "state", "device", "reference", "screenshot",
    "diff_pct", "tolerance", "pass", "analysis", "attempts", "diff_image"
  ],
  "properties": {
    "screen": { "type": "string", "minLength": 1 },
    "state": { "type": "string", "minLength": 1 },
    "device": { "type": "string", "minLength": 1 },
    "reference": { "type": "string", "minLength": 1 },
    "screenshot": { "type": "string", "minLength": 1 },
    "diff_pct": { "type": "number", "minimum": 0 },
    "tolerance": { "type": "number", "minimum": 0 },
    "pass": { "type": "boolean" },
    "analysis": { "type": "string" },
    "diff_image": { "type": ["string", "null"], "minLength": 1 },
    "attempts": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["attempt", "diff_pct", "pass", "analysis", "screenshot", "diff_image"],
        "properties": {
          "attempt": { "type": "integer", "minimum": 1 },
          "diff_pct": { "type": "number", "minimum": 0 },
          "pass": { "type": "boolean" },
          "analysis": { "type": "string" },
          "screenshot": { "type": "string", "minLength": 1 },
          "diff_image": { "type": ["string", "null"], "minLength": 1 }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Validate the JSON parses**

Run: `jq . schemas/visual-diff.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add schemas/visual-diff.json
git commit -m "schema(visual-diff): add device, analysis, attempts per screen"
```

---

### Task 2: Extend the viewer validator (`visualDiff.js`) + tests

**Files:**
- Modify: `night-shift-viewer/server/src/visualDiff.js`
- Test: `night-shift-viewer/server/test/visualDiff.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `night-shift-viewer/server/test/visualDiff.test.js`. Note the `screen()` helper there does NOT yet supply the new keys — update it first by adding these defaults inside its returned object: `device: 'iphone-15', analysis: '', attempts: []`. Then append:

```js
test('rejects a screen missing the new device key', () => {
  const r = report([{ ...screen(), device: undefined }]);
  delete r.screens[0].device;
  const { ok, errors } = validateVisualDiff(r);
  assert.equal(ok, false);
  assert.ok(errors.some((e) => e.includes('missing key: device')));
});

test('rejects non-string analysis', () => {
  const r = report([screen({ analysis: 42 })]);
  const { ok, errors } = validateVisualDiff(r);
  assert.equal(ok, false);
  assert.ok(errors.some((e) => e.includes('analysis must be a string')));
});

test('rejects attempts that is not an array', () => {
  const r = report([screen({ attempts: 'nope' })]);
  const { ok, errors } = validateVisualDiff(r);
  assert.equal(ok, false);
  assert.ok(errors.some((e) => e.includes('attempts must be an array')));
});

test('rejects an attempt with a bad diff_pct', () => {
  const r = report([screen({ attempts: [{ attempt: 1, diff_pct: -1, pass: false, analysis: 'x', screenshot: 's', diff_image: null }] })]);
  const { ok, errors } = validateVisualDiff(r);
  assert.equal(ok, false);
  assert.ok(errors.some((e) => e.includes('attempts[0].diff_pct must be a number >= 0')));
});

test('accepts a conforming screen with device, analysis, attempts', () => {
  const r = report([screen({
    device: 'iphone-15', analysis: 'fixed spacing',
    attempts: [{ attempt: 1, diff_pct: 0.04, pass: true, analysis: 'within tolerance', screenshot: 's1', diff_image: null }],
  })]);
  const { ok, errors } = validateVisualDiff(r);
  assert.equal(ok, true, errors.join('; '));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd night-shift-viewer/server && node --test test/visualDiff.test.js`
Expected: FAIL — the new keys are not yet validated (e.g. "unexpected key: device").

- [ ] **Step 3: Update the validator**

In `night-shift-viewer/server/src/visualDiff.js`, change `SCREEN_KEYS` to:

```js
const SCREEN_KEYS = [
  'screen', 'state', 'device', 'reference', 'screenshot',
  'diff_pct', 'tolerance', 'pass', 'analysis', 'attempts', 'diff_image',
];
```

Inside `report.screens.forEach`, after the existing `screenshot` string check, add device + analysis + attempts validation:

```js
    if (!isNonEmptyString(screen.device)) errors.push(`${at}.device must be a non-empty string`);
    if (typeof screen.analysis !== 'string') errors.push(`${at}.analysis must be a string`);

    if (!Array.isArray(screen.attempts)) {
      errors.push(`${at}.attempts must be an array`);
    } else {
      screen.attempts.forEach((a, j) => {
        const aat = `${at}.attempts[${j}]`;
        if (!isPlainObject(a)) { errors.push(`${aat} must be an object`); return; }
        if (!Number.isInteger(a.attempt) || a.attempt < 1) errors.push(`${aat}.attempt must be an integer >= 1`);
        if (!isFiniteNumber(a.diff_pct) || a.diff_pct < 0) errors.push(`${aat}.diff_pct must be a number >= 0`);
        if (typeof a.pass !== 'boolean') errors.push(`${aat}.pass must be a boolean`);
        if (typeof a.analysis !== 'string') errors.push(`${aat}.analysis must be a string`);
        if (!isNonEmptyString(a.screenshot)) errors.push(`${aat}.screenshot must be a non-empty string`);
        if (a.diff_image !== null && !isNonEmptyString(a.diff_image)) errors.push(`${aat}.diff_image must be a non-empty string or null`);
      });
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd night-shift-viewer/server && node --test test/visualDiff.test.js`
Expected: PASS (all cases, old + new).

- [ ] **Step 5: Commit**

```bash
cd night-shift-viewer
git add server/src/visualDiff.js server/test/visualDiff.test.js
git commit -m "viewer(visualDiff): validate device, analysis, attempts"
```

---

### Task 3: Pass new fields + resolve attempt image URLs in `runs.js`

**Files:**
- Modify: `night-shift-viewer/server/src/runs.js:215-223` (the per-screen mapping)

- [ ] **Step 1: Locate the screen mapping**

Around `runs.js:219` the code maps each screen to URLs (`referenceUrl`, `screenshotUrl`, `diffImageUrl`). Read the surrounding map function (the one returning those three URL fields) to find `urlFor`.

- [ ] **Step 2: Extend the mapping to include analysis + attempts**

Replace the object literal that currently spreads the screen and adds the three `*Url` fields so it also forwards `device`, `analysis`, and a resolved `attempts` array:

```js
      device: screen.device,
      analysis: screen.analysis ?? '',
      referenceUrl: urlFor(screen.reference),
      screenshotUrl: urlFor(screen.screenshot),
      diffImageUrl: urlFor(screen.diff_image),
      attempts: Array.isArray(screen.attempts)
        ? screen.attempts.map((a) => ({
            attempt: a.attempt,
            diff_pct: a.diff_pct,
            pass: a.pass,
            analysis: a.analysis ?? '',
            screenshotUrl: urlFor(a.screenshot),
            diffImageUrl: urlFor(a.diff_image),
          }))
        : [],
```

(Keep the existing `screen`, `state`, `diff_pct`, `tolerance`, `pass` fields the map already forwards.)

- [ ] **Step 3: Verify the server still starts and tests pass**

Run: `cd night-shift-viewer/server && node --test`
Expected: PASS (no regressions; this file has no dedicated unit test, so this guards the suite as a whole).

- [ ] **Step 4: Commit**

```bash
cd night-shift-viewer
git add server/src/runs.js
git commit -m "viewer(runs): forward device/analysis and resolve attempt image URLs"
```

---

### Task 4: Render analysis + attempt history in `VisualValidation.jsx`

**Files:**
- Modify: `night-shift-viewer/web/src/VisualValidation.jsx`

- [ ] **Step 1: Add the device to the screen title and render analysis + attempts**

In `VisualValidation.jsx`, replace the `VvScreen` function with:

```jsx
function VvAttempts({ attempts }) {
  if (!attempts?.length) return null;
  return (
    <details className="vv-attempts">
      <summary>Attempts ({attempts.length})</summary>
      <ol className="vv-attempt-list">
        {attempts.map((a) => (
          <li key={a.attempt} className="vv-attempt">
            <span className={a.pass ? 'exit-ok' : 'exit-bad'}>
              {a.attempt}. {a.diff_pct}% {a.pass ? 'pass' : 'fail'}
            </span>
            {a.analysis && <span className="vv-attempt-analysis"> — {a.analysis}</span>}
          </li>
        ))}
      </ol>
    </details>
  );
}

function VvScreen({ screen }) {
  const id = `${screen.screen ?? '—'} · ${screen.state ?? '—'} · ${screen.device ?? '—'}`;
  return (
    <section className="vv-screen">
      <div className="vv-screen-head">
        <h5 className="vv-screen-title">{id}</h5>
        <VvBadge pass={screen.pass === true} />
      </div>
      <div className="vv-images">
        <VvImage url={screen.referenceUrl} label="reference" alt={`${id} reference`} />
        <VvImage url={screen.screenshotUrl} label="implementation" alt={`${id} implementation`} />
        <VvImage url={screen.diffImageUrl} label="diff" alt={`${id} diff`} />
      </div>
      <p className="vv-metrics muted">
        diff <strong className={screen.pass === true ? 'exit-ok' : 'exit-bad'}>{screen.diff_pct}%</strong>{' '}
        vs tolerance {screen.tolerance}%
      </p>
      {screen.analysis && <p className="vv-analysis">Analysis: {screen.analysis}</p>}
      <VvAttempts attempts={screen.attempts} />
    </section>
  );
}
```

- [ ] **Step 2: Verify the web build succeeds**

Run: `cd night-shift-viewer/web && npm run build`
Expected: build completes with no errors.

- [ ] **Step 3: Commit**

```bash
cd night-shift-viewer
git add web/src/VisualValidation.jsx
git commit -m "viewer(ui): show device, analysis, and attempt history per screen"
```

---

## Phase 2 — Engine stage machine: the `visual_review` stage

Pure/deterministic; covered by the free fixture suite. No simulator involved.

### Task 5: Teach the stage machine about `visual_review`

**Files:**
- Modify: `scripts/night-shift.sh` — `stage_session_scope:2327`, `stage_model:2364`, `transition_allowed:2632`, `expected_action:2644`
- Test: new fixture in `scripts/night-shift.sh` registered in `run_dry_fixtures`

- [ ] **Step 1: Write the failing fixture**

Add this fixture function near `fixture_expected_action` (~line 1103):

```bash
fixture_visual_stage_machine() {
  # visual_review is its own scope, runs on the implement-tier model, and accepts
  # exactly RUN_VISUAL (plus BLOCKED). It sits between candidate and observer.
  [ "$(stage_session_scope visual_review)" = "visual" ] || return 1
  [ "$(stage_model visual)" = "$IMPLEMENT_MODEL" ] || return 1
  [ "$(expected_action visual_review)" = "RUN_VISUAL" ] || return 1
  transition_allowed visual_review RUN_VISUAL || return 1
  transition_allowed visual_review BLOCKED || return 1
  # Skipping ahead from visual_review to the observer is NOT allowed.
  ! transition_allowed visual_review REQUEST_OBSERVER || return 1
  # implementation_ready may still only CREATE_CANDIDATE.
  transition_allowed implementation_ready CREATE_CANDIDATE || return 1
}
```

Register it in `run_dry_fixtures` next to the other `fixture_assert` lines:

```bash
  fixture_assert "visual_review stage machine wiring" fixture_visual_stage_machine "$root"
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: FAIL on "visual_review stage machine wiring" (scope/model/transition not yet defined).

- [ ] **Step 3: Add `visual_review` to the four pure functions**

In `stage_session_scope` (2328-2334), add before the `*)` line:
```bash
    visual_review) printf 'visual' ;;
```

In `stage_model` (2365-2369), change the implement/observe/complete line to include `visual`:
```bash
    implement|visual|observe|complete) printf '%s' "$IMPLEMENT_MODEL" ;;
```

In `transition_allowed` (2634), add `visual_review:RUN_VISUAL` to the alternation (before `*:BLOCKED`):
```bash
    planning:RUN_PERSONAS|plan_review:RUN_PERSONAS|implementation:RUN_PERSONAS|implementation_review:RUN_PERSONAS|implementation_ready:CREATE_CANDIDATE|visual_review:RUN_VISUAL|observer_review:REQUEST_OBSERVER|completion:NEXT_TASK|completion:COMPLETE|*:BLOCKED) return 0 ;;
```

In `expected_action` (2645-2651), add before `*)`:
```bash
    visual_review) printf 'RUN_VISUAL' ;;
```

- [ ] **Step 4: Run to verify it passes (and syntax is clean)**

Run: `bash -n scripts/night-shift.sh && scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS, including "visual_review stage machine wiring". All existing fixtures still pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/night-shift.sh
git commit -m "engine: add visual_review to stage scope/model/transition/expected_action"
```

---

### Task 6: Insert `visual_review` into the live flow + `RUN_VISUAL` dispatch

**Files:**
- Modify: `scripts/night-shift.sh` — `verify_candidate` end (`set_stage observer_review:2947`), `handle_signal:3232`, plus a new `run_visual` function and a `VISUAL_CAPTURE` config knob.
- Test: new fixture for the enabled/disabled routing decision.

- [ ] **Step 1: Add the config knob near the other NIGHT_SHIFT_* config (~line 56)**

```bash
# Design-fidelity visual capture. OFF by default: the visual_review stage is a
# clean no-op SKIP unless this is 1 AND the spec has a `## Design Contract` AND
# the simulator/diff tooling is present (see scripts/lib/visual-capture.sh).
VISUAL_CAPTURE="${NIGHT_SHIFT_VISUAL_CAPTURE:-0}"
```

- [ ] **Step 2: Write the failing fixture for the routing decision**

Add a pure helper `visual_stage_enabled SPEC` decision and a fixture. First the fixture near `fixture_visual_stage_machine`:

```bash
fixture_visual_routing() {
  local root="$1" spec_yes="$root/dc.md" spec_no="$root/plain.md"
  printf '## Design Contract\n- Frames: Login\n- Required states: default\n' >"$spec_yes"
  printf '# plain spec\nno contract here\n' >"$spec_no"
  # Disabled globally -> never route to visual, regardless of contract.
  ( NIGHT_SHIFT_VISUAL_CAPTURE=0; VISUAL_CAPTURE=0; ! visual_stage_enabled "$spec_yes" ) || return 1
  # Enabled but no Design Contract -> skip.
  ( VISUAL_CAPTURE=1; ! visual_stage_enabled "$spec_no" ) || return 1
  # Enabled AND Design Contract present -> route to visual.
  ( VISUAL_CAPTURE=1; visual_stage_enabled "$spec_yes" ) || return 1
}
```

Register:
```bash
  fixture_assert "visual_review routing decision" fixture_visual_routing "$root"
```

- [ ] **Step 3: Run to verify it fails**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: FAIL — `visual_stage_enabled` is undefined.

- [ ] **Step 4: Implement `visual_stage_enabled` and `run_visual`**

Add near `run_observer` (~line 3004). `visual_stage_enabled` is pure (no tooling check — tooling is checked inside the capture helper so the decision stays unit-testable):

```bash
# Pure: should the visual_review stage do work for this spec? True iff capture is
# globally enabled AND the spec declares a `## Design Contract`. Tooling presence
# is checked later in the capture helper (which SKIPs cleanly if absent), so this
# decision is deterministic and fixture-testable without a simulator.
visual_stage_enabled() {
  [ "$VISUAL_CAPTURE" = "1" ] || return 1
  grep -Eq '^## Design Contract([ \t]|$)' "$1" 2>/dev/null
}

# The visual_review stage handler. The primary (Sonnet, fresh 'visual' scope
# session) runs the Figma-MCP → capture → diff → repair loop using the helpers in
# scripts/lib/visual-capture.sh, then emits RUN_VISUAL with a valid
# visual-diff-<spec>.json in validated/. This wrapper only gates that a valid
# report exists and then advances to the observer (which reviews the post-repair
# candidate + the report). Per-screen pass/fail is the observer's concern, not the
# gate's — a failing report still goes to the observer as evidence.
run_visual() {
  local report
  report="$RUN_ROOT/validated/visual-diff-$(basename "$SPEC" .md).json"
  [ -s "$report" ] ||
    block_run "RUN_VISUAL but $report is missing or empty"
  jq -e '.task and (.screens | type=="array" and length>0)' "$report" >/dev/null 2>&1 ||
    block_run "RUN_VISUAL but visual-diff report is malformed"
  log "visual_review: report accepted ($(jq -r '[.screens[]|select(.pass)]|length' "$report")/$(jq -r '.screens|length' "$report") screens pass); handing to observer"
  set_stage observer_review
}
```

- [ ] **Step 5: Route candidate → visual_review when enabled (degrade to observer otherwise)**

In `verify_candidate`, replace the final `set_stage observer_review` (line 2947) with:

```bash
  if visual_stage_enabled "$SPEC"; then
    set_stage visual_review
  else
    set_stage observer_review
  fi
```

- [ ] **Step 6: Add `RUN_VISUAL` to `handle_signal` dispatch**

In `handle_signal` (case block at 3232), add a line after the `REQUEST_OBSERVER` case:

```bash
    RUN_VISUAL) run_visual ;;
```

- [ ] **Step 7: Run fixtures + syntax**

Run: `bash -n scripts/night-shift.sh && scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS including "visual_review routing decision". Existing fixtures unaffected.

- [ ] **Step 8: Commit**

```bash
git add scripts/night-shift.sh
git commit -m "engine: route candidate->visual_review when enabled; RUN_VISUAL dispatch + gate"
```

---

## Phase 3 — `visual-capture.sh`: device axis, report assembly, real CLIs

### Task 7: Add the device axis to the capture grid

**Files:**
- Modify: `scripts/lib/visual-capture.sh` — `visual_capture_screens:40`
- Test: new fixture (the existing suite already sources this lib)

- [ ] **Step 1: Write the failing fixture**

Add near the other visual fixtures in `scripts/night-shift.sh`:

```bash
fixture_visual_grid() {
  local root="$1" spec="$root/dc.md"
  printf '## Design Contract\n- Frames: Login, Home\n- Required states: default, error\n- Devices: iphone-se, iphone-15\n' >"$spec"
  local out; out="$(visual_capture_screens "$spec" | sort)"
  # 2 frames x 2 states x 2 devices = 8 rows of screen|state|device
  [ "$(printf '%s\n' "$out" | grep -c '|')" -eq 8 ] || return 1
  printf '%s\n' "$out" | grep -q '^Login|error|iphone-15$' || return 1
  printf '%s\n' "$out" | grep -q '^Home|default|iphone-se$' || return 1
}
```

Register:
```bash
  fixture_assert "visual capture grid includes device axis" fixture_visual_grid "$root"
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: FAIL — `visual_capture_screens` currently emits `screen|state` (2 fields, 4 rows), not `screen|state|device`.

- [ ] **Step 3: Add the device axis to `visual_capture_screens`**

In `scripts/lib/visual-capture.sh`, in `visual_capture_screens`, after the `states=` line add a `devices=` parse, default to `iphone-15` when absent, and nest a device loop. Replace the body from the `states="..."` line through the final `IFS="$old_ifs"` with:

```bash
  states="$(printf '%s\n' "$section" | sed -nE 's/^- Required states: ?(.*)/\1/p' | head -n 1 | sed -E 's/[[:space:]]*<!--.*$//')"
  devices="$(printf '%s\n' "$section" | sed -nE 's/^- Devices: ?(.*)/\1/p' | head -n 1 | sed -E 's/[[:space:]]*<!--.*$//')"
  [ -n "$devices" ] || devices="iphone-15"
  [ -n "$frames" ] && [ -n "$states" ] || return 0
  old_ifs="$IFS"; IFS=','
  for f in $frames; do
    f="$(printf '%s' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$f" ] || continue
    for s in $states; do
      s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      [ -n "$s" ] || continue
      for d in $devices; do
        d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$d" ] || continue
        printf '%s|%s|%s\n' "$f" "$s" "$d"
      done
    done
  done
  IFS="$old_ifs"
```

Also add `d devices` to the function's `local` declaration line.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS including "visual capture grid includes device axis".

> NOTE: any pre-existing fixture that asserted the old 2-field `screen|state` output must be updated to the 3-field form in the same commit. Run the suite; if an older visual fixture fails, update its expected rows to include `|<device>`.

- [ ] **Step 5: Commit**

```bash
git add scripts/night-shift.sh scripts/lib/visual-capture.sh
git commit -m "visual-capture: add device axis to the capture grid"
```

---

### Task 8: Assemble per-screen `device`, `analysis`, `attempts` into the report

**Files:**
- Modify: `scripts/lib/visual-capture.sh` — `visual_assemble_screen:84`
- Test: new fixture

- [ ] **Step 1: Write the failing fixture**

```bash
fixture_visual_assemble() {
  local obj
  obj="$(visual_assemble_screen Login error iphone-15 design/r.png shot/s.png 0.04 0.10 diff/d.png \
        "title 2px low; fixed" '[{"attempt":1,"diff_pct":0.31,"pass":false,"analysis":"low","screenshot":"a1.png","diff_image":"d1.png"}]')"
  printf '%s' "$obj" | jq -e '.device=="iphone-15" and .analysis=="title 2px low; fixed" and .pass==true and (.attempts|length)==1 and .attempts[0].attempt==1' >/dev/null || return 1
}
```

Register:
```bash
  fixture_assert "visual report assembles device/analysis/attempts" fixture_visual_assemble "$root"
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: FAIL — `visual_assemble_screen` does not yet accept analysis/attempts/device.

- [ ] **Step 3: Update `visual_assemble_screen`**

Replace `visual_assemble_screen` in `scripts/lib/visual-capture.sh` with a version taking `device` (new 3rd positional) plus trailing `analysis` and `attempts` (a JSON array string):

```bash
# Pure: emit one screen object for the report. pass is derived, never trusted from
# input: pass == (diff_pct <= tolerance). `attempts` is a JSON array string.
visual_assemble_screen() {
  local screen="$1" state="$2" device="$3" reference="$4" screenshot="$5" \
    diff_pct="$6" tolerance="$7" diff_image="$8" analysis="${9:-}" attempts="${10:-[]}"
  jq -nc \
    --arg screen "$screen" --arg state "$state" --arg device "$device" \
    --arg reference "$reference" --arg screenshot "$screenshot" \
    --argjson diff_pct "$diff_pct" --argjson tolerance "$tolerance" \
    --arg diff_image "$diff_image" --arg analysis "$analysis" \
    --argjson attempts "$attempts" '
    {
      screen: $screen, state: $state, device: $device, reference: $reference,
      screenshot: $screenshot, diff_pct: $diff_pct, tolerance: $tolerance,
      pass: ($diff_pct <= $tolerance), analysis: $analysis,
      diff_image: (if $diff_image == "" then null else $diff_image end),
      attempts: $attempts
    }'
}
```

Update `run_visual_capture`'s call site so its `visual_assemble_screen` invocation passes the new `device`, `analysis`, and `attempts` arguments (the loop variable `device` from Task 7's grid; `analysis`/`attempts` come from the agent-written per-screen sidecar — for the scaffold path pass `"" "[]"`).

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS including "visual report assembles device/analysis/attempts".

- [ ] **Step 5: Commit**

```bash
git add scripts/night-shift.sh scripts/lib/visual-capture.sh
git commit -m "visual-capture: assemble device, analysis, attempts into screen report"
```

---

### Task 9: Real `capture`/`diff` CLI subcommands behind the tooling gate

**Files:**
- Modify: `scripts/lib/visual-capture.sh` — replace the `__visual_capture_screenshot:105` and `__visual_pixel_diff:112` stubs; add a CLI dispatch so the agent can call them as commands.

- [ ] **Step 1: Implement the iOS screenshot capture (replaces the stub)**

Replace `__visual_capture_screenshot` with a real implementation that boots the named device, fixes the status bar, deep-links to the preview route, and writes a PNG. It returns 2 only when tooling is absent, so CI still degrades:

```bash
# Capture <screen> <state> <device> -> PNG at $4. Requires xcrun. Returns 2 when
# unavailable so run_visual_capture degrades cleanly.
__visual_capture_screenshot() {
  local screen="$1" state="$2" device="$3" out="$4"
  command -v xcrun >/dev/null 2>&1 || return 2
  local udid; udid="$(xcrun simctl list devices available | grep -oE '\(([0-9A-F-]{36})\)' | head -n1 | tr -d '()')"
  [ -n "$udid" ] || return 2
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override \
    --time "2026-06-18T09:41:00" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  xcrun simctl openurl "$udid" \
    "${NIGHT_SHIFT_PREVIEW_SCHEME:-nightshift}://preview?screen=${screen}&state=${state}&device=${device}" >/dev/null 2>&1 || return 2
  # Allow the harness to render deterministically (animations disabled app-side).
  mkdir -p "$(dirname "$out")"
  xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1 || return 2
  [ -s "$out" ]
}
```

- [ ] **Step 2: Implement the pixel diff (replaces the stub)**

Replace `__visual_pixel_diff` with an `odiff`-backed implementation that prints the difference percentage and writes the diff image:

```bash
# Diff <reference> <screenshot> <diff_out>; prints diff_pct (0-100). Requires
# odiff. Returns 2 when unavailable.
__visual_pixel_diff() {
  local reference="$1" screenshot="$2" diff_out="$3"
  command -v "${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" >/dev/null 2>&1 || return 2
  mkdir -p "$(dirname "$diff_out")"
  # odiff prints "Different: N.NN% ..." on stdout and exits 22 when images differ,
  # 0 when identical; both are non-error here.
  local outp pct
  outp="$("${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" --parsable-stdout "$reference" "$screenshot" "$diff_out" 2>/dev/null)"
  pct="$(printf '%s' "$outp" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  [ -n "$pct" ] || pct="0"
  printf '%s' "$pct"
}
```

- [ ] **Step 3: Add a CLI dispatch at the bottom of the lib so the agent can invoke subcommands**

The library is normally sourced. Add a guarded dispatch so `bash scripts/lib/visual-capture.sh capture ...` works when executed directly. Append:

```bash
# When executed directly (not sourced), expose capture/diff as subcommands for the
# agent's repair loop. Sourcing (the orchestrator's use) skips this block.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    capture) __visual_capture_screenshot "$@"; exit $? ;;
    diff)    __visual_pixel_diff "$@"; exit $? ;;
    screens) visual_capture_screens "$@"; exit $? ;;
    *) printf 'usage: visual-capture.sh {capture screen state device out|diff ref shot diffout|screens spec}\n' >&2; exit 64 ;;
  esac
fi
```

- [ ] **Step 4: Verify syntax + the suite still passes (stubs replaced, fixtures mock results)**

Run: `bash -n scripts/lib/visual-capture.sh && scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS. (In CI without `xcrun`/`odiff`, `__visual_*` return 2 → `run_visual_capture` SKIPs, so no fixture exercises real capture; the assemble/grid fixtures cover the deterministic parts.)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/visual-capture.sh
git commit -m "visual-capture: real iOS capture + odiff pixel-diff CLIs (tooling-gated)"
```

---

## Phase 4 — App preview harness (`rn-sandbox`)

### Task 10: Add the deterministic preview harness route

**Files:**
- Create: `rn-sandbox/src/preview/PreviewHarness.tsx`
- Create: `rn-sandbox/src/preview/registry.ts`
- Modify: `rn-sandbox` deep-link / root navigation entry (follow `rn-sandbox/CLAUDE.md` for the real linking setup) to mount `PreviewHarness` for `nightshift://preview`.

> Follow `rn-sandbox/CLAUDE.md` for the project's actual navigation + deep-link conventions; the snippets below are the contract, adapt wiring to that project.

- [ ] **Step 1: Create the screen registry**

```ts
// rn-sandbox/src/preview/registry.ts
import type { ComponentType } from 'react';

// Map "<screen>:<state>" -> a component rendering that screen in that state with
// fixed mock data. Add entries as screens become design-fidelity targets.
export type PreviewEntry = { device?: string; Component: ComponentType };
export const previewRegistry: Record<string, PreviewEntry> = {
  // 'Login:default': { Component: () => <LoginScreen {...mockLoginDefault} /> },
  // 'Login:error':   { Component: () => <LoginScreen {...mockLoginError} /> },
};
```

- [ ] **Step 2: Create the harness component (deterministic render)**

```tsx
// rn-sandbox/src/preview/PreviewHarness.tsx
import React from 'react';
import { View, Text } from 'react-native';
import { previewRegistry } from './registry';

// Renders exactly one screen/state in isolation for screenshot capture. Reads
// screen/state from the deep-link params. No animations, no live data — the
// registry entry supplies fixed mock data so captures are deterministic.
export function PreviewHarness({ screen, state }: { screen: string; state: string }) {
  const entry = previewRegistry[`${screen}:${state}`];
  if (!entry) {
    return (
      <View testID="preview-missing" style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <Text>{`no preview for ${screen}:${state}`}</Text>
      </View>
    );
  }
  const { Component } = entry;
  return (
    <View testID="preview-root" style={{ flex: 1 }}>
      <Component />
    </View>
  );
}
```

- [ ] **Step 3: Wire the deep link**

In the app's deep-link handler (per `rn-sandbox/CLAUDE.md`), when the URL is `nightshift://preview`, parse `screen`/`state`/`device` query params and render `<PreviewHarness screen={screen} state={state} />` as the root, bypassing normal navigation. Disable animations for this mode (e.g. set the navigator's `animationEnabled: false` or render the harness directly).

- [ ] **Step 4: Verify the app still builds and the harness renders**

Run (per `rn-sandbox/CLAUDE.md`): the project's typecheck + test commands, e.g. `cd rn-sandbox && npm run typecheck && npm test`.
Expected: PASS (the registry starts empty; the harness shows the "no preview" fallback until screens are registered).

- [ ] **Step 5: Commit**

```bash
cd rn-sandbox
git add src/preview/
git commit -m "feat(preview): deterministic preview harness for visual capture"
```

---

## Phase 5 — Spec template + docs

### Task 11: Add `Devices` to the RN Design Contract template + document the feature

**Files:**
- Modify: `specs/_template.md` (the RN template's `## Design Contract` section)
- Modify: `CLAUDE.md` (document `NIGHT_SHIFT_VISUAL_CAPTURE` + the `visual_review` stage)

- [ ] **Step 1: Add the Devices line to the RN Design Contract template**

In `specs/_template.md`, in the `## Design Contract` section, add under `- Frames:`:
```markdown
- Devices: iphone-15                  <!-- comma-separated iOS device names; grid = Frames × Required states × Devices -->
```

- [ ] **Step 2: Document the knob + stage in CLAUDE.md**

Under the "Cost knobs" / running section in `CLAUDE.md`, add:
```markdown
- **Visual fidelity (opt-in):** set `NIGHT_SHIFT_VISUAL_CAPTURE=1` and give an rn
  spec a `## Design Contract` to enable the `visual_review` stage (Figma-MCP
  reference + iOS-simulator capture + `odiff` pixel-diff + agent auto-repair).
  Requires `xcrun`, `odiff`, a Figma MCP server, and the app's preview harness;
  absent any of these it cleanly SKIPs. The viewer renders the per-screen
  reference/implementation/diff images, diff%, analysis, and attempt history.
```

- [ ] **Step 3: Verify fixtures + syntax (template parse is exercised by spec validation)**

Run: `scripts/night-shift.sh --fixture-test --dry-run`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add specs/_template.md CLAUDE.md
git commit -m "docs: document visual_review stage + Devices in the RN Design Contract"
```

---

## Phase 6 — Real validation (manual, opt-in, paid)

### Task 12: End-to-end smoke on rn-sandbox

**Not automated.** Prerequisites: Xcode + a booted iOS simulator, `odiff` on PATH (`brew install odiff` or `npm i -g odiff-bin`), a configured Figma MCP server (+ `FIGMA_TOKEN`), and at least one screen registered in `rn-sandbox/src/preview/registry.ts` with a matching Figma frame.

- [ ] **Step 1:** Write an rn-sandbox spec with a `## Design Contract` (Figma file/node IDs, Frames, Required states, Devices, Tolerance) for the registered screen.
- [ ] **Step 2:** Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES NIGHT_SHIFT_VISUAL_CAPTURE=1 scripts/night-shift.sh --project ~/work/rn-sandbox --spec specs/<that-spec>.md`
- [ ] **Step 3:** Confirm `.night-shift/archive/<run>/validated/visual-diff-*.json` exists with `screens[].attempts` populated and the post-repair candidate committed.
- [ ] **Step 4:** Open the viewer; confirm the Visual Validation panel renders reference/implementation/diff images, diff%, analysis, and attempt history for the run.

---

## Self-Review notes

- **Spec coverage:** schema+viewer (Tasks 1-4), `visual_review` stage + routing + dispatch + gate (Tasks 5-6), device-axis grid + report assembly + real capture/diff CLIs (Tasks 7-9), preview harness (Task 10), Design Contract `Devices` + docs (Task 11), real validation (Task 12). Candidate-refresh-after-repair is the agent's responsibility inside the `visual_review` session (design doc "Candidate handling"); `run_visual` gates on a valid report and the observer reviews the post-repair candidate.
- **Degradation:** every enabling condition (knob, Design Contract, tooling) routes to a clean SKIP; existing runs unaffected (Tasks 6, 9).
- **Naming consistency:** `visual_stage_enabled`, `run_visual`, `visual_capture_screens`, `visual_assemble_screen`, `RUN_VISUAL`, scope `visual`, stage `visual_review` are used identically across all tasks.
- **Open dependency:** Figma MCP availability inside the `claude -p` subprocess and `odiff`'s exact `--parsable-stdout` format should be confirmed during Task 9/12 and adjusted if the tool's output differs.
