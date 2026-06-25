# Maestro Capture Drive Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `maestro` capture drive mode that runs a per-screen-state Maestro flow to navigate the real app into a Figma-matching scenario, then reuses the existing status-bar-override + `simctl io screenshot` pipeline for the odiff comparison.

**Architecture:** A 4th branch in `__visual_capture_screenshot` (`scripts/lib/visual-capture.sh`), checked first and gated on `NIGHT_SHIFT_MAESTRO_DIR`, runs `maestro --device <udid> test <dir>/<Screen>-<state>.yaml` then falls through to the unchanged screenshot path. `visual-review.sh` gains `--drive maestro` / `--maestro-dir` (normal build, no preview harness). Missing `maestro` or a missing flow returns 2 → clean SKIP.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck-clean at default severity), `maestro` CLI, `xcrun simctl`, `odiff`. Tests = deterministic fixtures in `scripts/test/fixtures.sh`.

**Spec:** `docs/superpowers/specs/2026-06-25-maestro-capture-drive-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/maestro-wt` (branch `feat/maestro-drive`, off `main`).
- **Opt-in:** the maestro branch runs only when `NIGHT_SHIFT_MAESTRO_DIR` is set; with it unset, `__visual_capture_screenshot` behaves exactly as today (file/launcharg/openurl).
- Fixture suite: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` — pass = `grep -c "not ok"` is `0` + `all deterministic fixtures passed`.
- Shellcheck gate is **default severity** (the CI gate): `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` must exit `0`.
- New fixtures follow the existing `fixture_*` pattern, registered in `run_dry_fixtures`, mirroring `fixture_visual_capture_file_drive` (stub binaries on `PATH`).
- Maestro flows are self-contained (`launchApp` + navigation, **no screenshot**); the pipeline screenshots.
- Maestro mode takes **precedence** over the preview env (`NIGHT_SHIFT_MAESTRO_DIR` checked before `_BUNDLE_ID`/`_FILE`).

## File Structure

- **Modify** `scripts/lib/visual-capture.sh` — the maestro branch in `__visual_capture_screenshot` + the comment block.
- **Modify** `scripts/test/fixtures.sh` — `fixture_visual_capture_maestro`.
- **Modify** `scripts/visual-review.sh` — `--drive maestro` + `--maestro-dir` + the two `--drive` validations + the `case "$DRIVE"` export block.
- **Create** `docs/examples/maestro/Home-default.yaml` — sample flow.
- **Modify** `CLAUDE.md` — Maestro-drive authoring note.

---

### Task 1: Maestro capture branch + fixture

**Files:**
- Modify: `scripts/lib/visual-capture.sh` (`__visual_capture_screenshot`, ~146-178)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `__visual_capture_screenshot` gains a maestro branch — when `NIGHT_SHIFT_MAESTRO_DIR` is set, it requires `maestro` on PATH (else `return 2`), resolves the flow `$NIGHT_SHIFT_MAESTRO_DIR/<screen>-<state>.yaml` (else `return 2`), runs `maestro --device "$udid" test "$flow"` (non-zero → `return 2`), then falls through to the existing `sleep` + `simctl io screenshot` path. Unchanged otherwise.

- [ ] **Step 1: Write the failing test.** Add to `scripts/test/fixtures.sh` and register it in `run_dry_fixtures` right after the file-drive registration line (`fixture_assert "visual capture file-drive writes target + cold-launches prompt-free" fixture_visual_capture_file_drive "$root"`):

```bash
  fixture_assert "visual capture maestro-drive runs the screen-state flow + screenshots" fixture_visual_capture_maestro "$root"
```

Then add the fixture (mirrors `fixture_visual_capture_file_drive`; `xcrun` + `maestro` stubs in `$d/bin`, a clean PATH so the absent-maestro sub-case is reliable):

```bash
fixture_visual_capture_maestro() {
  local root="$1" d="$root/vmae"
  mkdir -p "$d/bin" "$d/flows"
  cat >"$d/bin/xcrun" <<STUB
#!/usr/bin/env bash
log="$d/calls.log"
shift  # drop "simctl"
case "\$1" in
  io)      printf x >"\${!#}" ;;
  *)       printf 'xcrun %s\n' "\$*" >>"\$log" ;;
esac
exit 0
STUB
  cat >"$d/bin/maestro" <<STUB
#!/usr/bin/env bash
printf 'maestro %s\n' "\$*" >>"$d/calls.log"
exit 0
STUB
  chmod +x "$d/bin/xcrun" "$d/bin/maestro"
  : >"$d/flows/Home-default.yaml"
  # (a) maestro mode: flow present -> maestro test runs that flow, screenshot written,
  #     NO openurl/launch from the preview modes.
  (
    export PATH="$d/bin:/usr/bin:/bin" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
           NIGHT_SHIFT_MAESTRO_DIR="$d/flows"
    __visual_capture_screenshot Home default iphone-15 "$d/shot.png" UDID-X || exit 1
    grep -q "maestro --device UDID-X test $d/flows/Home-default.yaml" "$d/calls.log" || exit 1
    grep -q '^xcrun openurl' "$d/calls.log" && exit 1
    grep -q '^xcrun launch' "$d/calls.log" && exit 1
    [ -s "$d/shot.png" ] || exit 1
  ) || return 1
  # (b) missing flow -> return 2 (clean SKIP).
  (
    export PATH="$d/bin:/usr/bin:/bin" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
           NIGHT_SHIFT_MAESTRO_DIR="$d/flows"
    __visual_capture_screenshot Missing default iphone-15 "$d/m.png" UDID-X; [ "$?" -eq 2 ]
  ) || return 1
  # (c) maestro absent on PATH -> return 2 (PATH excludes the stub + real ~/.maestro).
  (
    export PATH="/usr/bin:/bin" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
           NIGHT_SHIFT_MAESTRO_DIR="$d/flows"
    # xcrun must still be present for the earlier guards; use the stub dir for it only.
    PATH="$d/binx:$PATH"; mkdir -p "$d/binx"; cp "$d/bin/xcrun" "$d/binx/xcrun"
    __visual_capture_screenshot Home default iphone-15 "$d/n.png" UDID-X; [ "$?" -eq 2 ]
  ) || return 1
  # (d) precedence: NIGHT_SHIFT_MAESTRO_DIR wins over preview env -> maestro, not file.
  : >"$d/calls.log"
  (
    export PATH="$d/bin:/usr/bin:/bin" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
           NIGHT_SHIFT_MAESTRO_DIR="$d/flows" \
           NIGHT_SHIFT_PREVIEW_BUNDLE_ID=com.example.app NIGHT_SHIFT_PREVIEW_FILE=p.txt
    __visual_capture_screenshot Home default iphone-15 "$d/p.png" UDID-X || exit 1
    grep -q "^maestro " "$d/calls.log" || exit 1
    grep -q 'get_app_container' "$d/calls.log" && exit 1
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alessandrogentil/maestro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "maestro-drive"`
Expected: `not ok - visual capture maestro-drive …` (no maestro branch yet → it takes the openurl path, no `maestro …` in the log).

- [ ] **Step 3: Add the maestro branch.** In `scripts/lib/visual-capture.sh`, in `__visual_capture_screenshot`, replace the dispatch head:

```bash
  local bid="${NIGHT_SHIFT_PREVIEW_BUNDLE_ID:-}"
  local pfile="${NIGHT_SHIFT_PREVIEW_FILE:-}"
  if [ -n "$bid" ] && [ -n "$pfile" ]; then
    # (1) file-driven cold launch.
```

with (adds the maestro branch first):

```bash
  local mdir="${NIGHT_SHIFT_MAESTRO_DIR:-}"
  local bid="${NIGHT_SHIFT_PREVIEW_BUNDLE_ID:-}"
  local pfile="${NIGHT_SHIFT_PREVIEW_FILE:-}"
  if [ -n "$mdir" ]; then
    # (0) maestro — drive the REAL app to the scenario via a per-screen-state flow,
    # then the shared status-bar override + screenshot below capture it. The flow is
    # self-contained (launchApp + navigation, no screenshot). Missing maestro or a
    # missing flow returns 2 (clean SKIP). Takes precedence over the preview modes.
    command -v maestro >/dev/null 2>&1 || return 2
    local flow="$mdir/${screen}-${state}.yaml"
    [ -f "$flow" ] || return 2
    maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2
  elif [ -n "$bid" ] && [ -n "$pfile" ]; then
    # (1) file-driven cold launch.
```

(The trailing `else`/`fi` and the `sleep`/`simctl io screenshot` lines are unchanged — the maestro branch is just one more `if` arm; the others become `elif`/`else` as shown.) Also update the comment block directly above `local bid=` to list the maestro mode — change the `# Drive the app into preview mode. Three modes…` line to `# Drive the app into the target scenario. Four modes (maestro, then preview file/launcharg/openurl):` and add a bullet:

```bash
  #   (0) maestro — NIGHT_SHIFT_MAESTRO_DIR: run a per-screen-state Maestro flow
  #       (<dir>/<Screen>-<state>.yaml) to navigate the REAL app; no preview harness.
```

- [ ] **Step 4: Run tests + shellcheck**

Run: `cd /Users/alessandrogentil/maestro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "feat(visual-capture): maestro drive mode (NIGHT_SHIFT_MAESTRO_DIR + per-screen-state flow)"
```

---

### Task 2: `visual-review.sh --drive maestro` wiring

**Files:**
- Modify: `scripts/visual-review.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: the maestro branch (Task 1) via `NIGHT_SHIFT_MAESTRO_DIR`.
- Produces: `visual-review.sh` accepts `--drive maestro` (sets `DRIVE=maestro`) and `--maestro-dir DIR` (default `<project>/.maestro`); `--drive maestro` exports `NIGHT_SHIFT_MAESTRO_DIR` and does NOT set the preview env; the build/install path builds a normal app (unchanged — `build_and_install` never sets `EXPO_PUBLIC_PREVIEW`).

- [ ] **Step 1: Write the failing test.** Register and add (mirrors `fixture_visual_review_repair_args`, pipefail-safe):

```bash
fixture_visual_review_maestro_args() {
  "$WORKSPACE_ROOT/scripts/visual-review.sh" --help 2>&1 | grep -q -- '--drive maestro\|--maestro-dir' || return 1
  out="$("$WORKSPACE_ROOT/scripts/visual-review.sh" --project "$1" --drive bogus 2>&1 || true)"
  printf '%s' "$out" | grep -qi "unknown --drive" || return 1
  return 0
}
```
Register it after the existing `fixture_visual_review_repair_args` registration:
```bash
  fixture_assert "visual-review --drive maestro + --maestro-dir documented; bogus --drive rejected" fixture_visual_review_maestro_args "$root"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alessandrogentil/maestro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "maestro_args\|maestro-dir"`
Expected: `not ok` (`--help` has no `--drive maestro`/`--maestro-dir` yet).

- [ ] **Step 3: Implement.** In `scripts/visual-review.sh`:

(a) defaults line (currently `PROJECT="" SCHEME="" OUT="" NO_BUILD=0 NO_REFS=0 DRIVE="openurl" PREVIEW_FILE=""`) — add `MAESTRO_DIR=""`:
```bash
PROJECT="" SCHEME="" OUT="" NO_BUILD=0 NO_REFS=0 DRIVE="openurl" PREVIEW_FILE="" MAESTRO_DIR=""
```

(b) arg parser — add a `--maestro-dir` case next to `--drive`:
```bash
    --maestro-dir) MAESTRO_DIR="${2:-}"; shift 2 ;;
```

(c) BOTH `--drive` validations (the early `case "$DRIVE" in openurl|file)` and the `*) die` in the export `case`) must accept `maestro`. Change the early validation line to:
```bash
case "$DRIVE" in openurl|file|maestro) : ;; *) die "unknown --drive '$DRIVE' (expected: openurl | file | maestro)" ;; esac
```

(d) the export `case "$DRIVE"` block — add a `maestro)` arm and update the `*) die`:
```bash
case "$DRIVE" in
  openurl) : ;;
  file)
    export NIGHT_SHIFT_PREVIEW_BUNDLE_ID="$BUNDLE_ID"
    export NIGHT_SHIFT_PREVIEW_FILE="${PREVIEW_FILE:-nightshift-preview.txt}"
    log "drive=file (prompt-free): writes $NIGHT_SHIFT_PREVIEW_FILE into $BUNDLE_ID's docs, then simctl launch"
    ;;
  maestro)
    export NIGHT_SHIFT_MAESTRO_DIR="${MAESTRO_DIR:-$PROJECT/.maestro}"
    command -v maestro >/dev/null 2>&1 || log "WARN: maestro not on PATH — every screen will SKIP"
    log "drive=maestro: runs \$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml against the real app (no preview harness)"
    ;;
  *) die "unknown --drive '$DRIVE' (expected: openurl | file | maestro)" ;;
esac
```

(e) the `--help` header block (the `sed -n '4,40p'`-printed options near the `--drive MODE` line) — document the new option/flag. After the `--drive MODE` description block add:
```bash
#                       maestro — run a Maestro flow per screen-state
#                         ($NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml) to drive
#                         the REAL app to the scenario; no preview harness needed.
#   --maestro-dir DIR maestro flows dir for --drive maestro (default <project>/.maestro)
```

- [ ] **Step 4: Run tests + shellcheck**

Run: `cd /Users/alessandrogentil/maestro-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run: `scripts/visual-review.sh --help 2>&1 | grep -c -- '--maestro-dir'` → Expected `≥1`

- [ ] **Step 5: Commit**

```bash
git add scripts/visual-review.sh scripts/test/fixtures.sh
git commit -m "feat(visual-review): --drive maestro + --maestro-dir wiring"
```

---

### Task 3: Sample flow + authoring note

**Files:**
- Create: `docs/examples/maestro/Home-default.yaml`
- Modify: `CLAUDE.md`

> Docs + a sample artifact; no fixture. Verify the YAML is well-formed and the note renders.

- [ ] **Step 1: Create the sample flow.** Write `docs/examples/maestro/Home-default.yaml`:

```yaml
# Sample Maestro flow for the night-shift `--drive maestro` capture mode.
# Convention: <NIGHT_SHIFT_MAESTRO_DIR>/<Screen>-<state>.yaml (here: Home / default).
# The flow only NAVIGATES the real app to the exact scenario the Figma frame depicts.
# It MUST NOT take a screenshot — the visual-review pipeline pins the status bar
# (09:41) and runs `simctl io screenshot` after this flow completes.
appId: com.vyseclown.watertracker
---
- launchApp
# Confirm we landed on Home and it has settled (replace with this screen's anchor):
- assertVisible: "Good Morning"
# Add the steps that reproduce the Figma scenario, e.g.:
#   - tapOn: "+250 ml"
#   - inputText: "Custom"
#   - scroll
# Do NOT add `takeScreenshot` — the pipeline captures the result.
```

- [ ] **Step 2: Add the authoring note to `CLAUDE.md`.** In the visual-fidelity section (near the `--drive file` / in-loop notes), add a blockquote:

```
> **Maestro capture drive (`--drive maestro`).** An alternative to the seeded preview
> harness: instead of a preview route, write a Maestro flow per screen-state at
> `$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml` (default `<project>/.maestro`) that
> drives the **real** app to the scenario matching the Figma frame
> (`launchApp` + taps/input/scroll, **no `takeScreenshot`** — the pipeline screenshots).
> Run `scripts/visual-review.sh --project <app> --drive maestro` against a normal
> build (no `EXPO_PUBLIC_PREVIEW`/preview route). A missing flow or missing `maestro`
> on PATH cleanly SKIPs that spec's capture (never blocks), so author a flow for every
> screen-state in the matrix. Sample: `docs/examples/maestro/Home-default.yaml`.
```

- [ ] **Step 3: Verify + commit.**

Run: `cd /Users/alessandrogentil/maestro-wt && grep -c "appId:" docs/examples/maestro/Home-default.yaml` → Expected `1`
Run: `grep -c -- "--drive maestro" CLAUDE.md` → Expected `≥1`

```bash
git add docs/examples/maestro/Home-default.yaml CLAUDE.md
git commit -m "docs(visual-capture): maestro drive sample flow + authoring note"
```

---

### Task 4: Real smoke (manual) — optional follow-up

**Files:** none (validation record only, if run).

> No fixture can exercise a real `maestro test` + sim. This records the manual smoke and is optional/deferred (the dispatch + clean-skip are fixture-tested).

- [ ] **Step 1 (manual, optional):** Build+install a normal water-tracker build on a booted sim; write `~/work/water-tracker-app/.maestro/Home-default.yaml` (a `launchApp` + an `assertVisible` for the Home header); stage a Home reference; run `scripts/visual-review.sh --project ~/work/water-tracker-app --drive maestro --no-refs --spec specs/water-tracker-home-tracking.md`; confirm a `visual-diff-*.json` is produced with a Home screenshot that reflects the flow's scenario. Record the result in `docs/2026-06-25-maestro-drive-validation.md` if run.

---

## Self-Review

**Spec coverage:** §4.1 capture branch → Task 1; §4.2 flow resolution + clean-SKIP semantics → Task 1 (fixture cases b/c) ; §4.3 `visual-review.sh` wiring (normal build) → Task 2; §4.4 gating/clean-skip → Task 1 (maestro/flow `return 2`) + Task 2 (PATH warning); §6 testing (dispatch, flow resolution, missing-flow/missing-maestro skip, precedence, `--drive` args) → Tasks 1-2 fixtures; sample flow + authoring note → Task 3; real smoke → Task 4 (optional).

**Placeholder scan:** every code step shows full code; commands have expected output; the sample flow + note are complete. No TBD/TODO.

**Type/name consistency:** `NIGHT_SHIFT_MAESTRO_DIR`, `--drive maestro`, `--maestro-dir`/`MAESTRO_DIR`, the flow path `<dir>/<Screen>-<state>.yaml`, and the `maestro --device <udid> test <flow>` invocation are used identically across Tasks 1-3; both `--drive` validations in `visual-review.sh` (early `case` + export `case`) are updated to include `maestro` (Task 2c/2d). The fixture asserts the exact invocation string the branch emits.

**Shellcheck:** every code task runs the default-severity `find … shellcheck -s bash` gate.
