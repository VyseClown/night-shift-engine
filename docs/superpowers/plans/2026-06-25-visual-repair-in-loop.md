# In-loop Visual-Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make night-shift's `visual_review` stage auto-repair over-tolerance screens (opt-in `NIGHT_SHIFT_VISUAL_REPAIR`), reusing the proven standalone repair loop moved into the shared `scripts/lib/visual-repair.sh`, committing a `fix(visual): auto-repair …` commit so the observer reviews the repaired tip.

**Architecture:** Extract the repair orchestration (`repair_agent`, `repair_validate`, `repair_metro_*`, Figma/device helpers) out of `scripts/visual-review.sh` into the shared `scripts/lib/visual-repair.sh`, plus a new `visual_repair_for_spec` parameterized by `out_dir`+`candidate_label`. `visual-review.sh` becomes a thin caller (behavior unchanged). `night-shift.sh` sources the lib and `run_visual` calls the shared orchestration when enabled, then commits + refreshes the report.

**Tech Stack:** Bash (sourced libs, `set -uo pipefail`, shellcheck-clean at default severity), `jq`, `git`, `claude -p`, Expo/Metro. Tests = deterministic fixtures in `scripts/test/fixtures.sh` via the engine fixture suite.

**Spec:** `docs/superpowers/specs/2026-06-25-visual-repair-in-loop-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/inloop-wt` (branch `feat/visual-repair-in-loop`, off `main`).
- Both surfaces default **OFF**; with `NIGHT_SHIFT_VISUAL_REPAIR` unset, `run_visual` is byte-for-byte unchanged, and the standalone `visual-review.sh --repair` external behavior is unchanged.
- Fixture suite: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` — pass = `grep -c "not ok"` is `0` and it prints `all deterministic fixtures passed`.
- Shellcheck (the CI gate runs default severity): `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` must exit `0`. (`-S error` alone is NOT sufficient — a prior PR's CI failed this way.)
- New fixtures follow the existing `fixture_*` pattern, registered in `run_dry_fixtures`.
- Functions invoked indirectly (as injected names) get an inline `# shellcheck disable=SC2329` pragma.
- The in-loop repair commit must NEVER run on `main`/`master` (guard on the project's current branch).
- Per-screen attempts default 3 (`NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS`); global cap default 30 (`NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP`).

## File Structure

- **Modify** `scripts/lib/visual-repair.sh` — gains the relocated repair orchestration (`repair_agent`, `repair_validate`, `repair_metro_start/stop`, `_REPAIR_METRO_PID`, `figma_key_for`, `node_id_for`, `device_label_to_name`, new `visual_repair_devices`) + the new `visual_repair_for_spec` orchestrator. (The loop primitives already live here.)
- **Modify** `scripts/visual-review.sh` — delete the relocated definitions; call the shared ones; replace the inline repair block with one `visual_repair_for_spec` call. External behavior unchanged.
- **Modify** `scripts/night-shift.sh` — source `visual-repair.sh`; add `VISUAL_REPAIR` constant; rewire `run_visual` to run engine-invoked repair + commit + refresh.
- **Modify** `scripts/test/fixtures.sh` — new fixtures.

---

### Task 1: Relocate the pure helpers to the shared lib

Move the small pure/string helpers first (lowest risk), so later tasks can rely on them in the lib.

**Files:**
- Modify: `scripts/lib/visual-repair.sh`, `scripts/visual-review.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces (now in `visual-repair.sh`): `device_label_to_name <label>` (e.g. `iphone-16` → `iPhone 16`); `node_id_for <spec> <screen>`; `figma_key_for <spec>`; new `visual_repair_devices <spec>` = `visual_capture_screens "$spec" | awk -F'|' '{print $3}' | sort -u`.

- [ ] **Step 1: Write the failing test.** Add to `scripts/test/fixtures.sh` and register in `run_dry_fixtures` (near the visual fixtures): `fixture_assert "visual-repair helpers (devices/node/key/label) in shared lib" fixture_visual_repair_helpers "$root"`:

```bash
fixture_visual_repair_helpers() {
  local root="$1" spec="$root/s.md"
  cat >"$spec" <<'SPEC'
## Design Contract
- Figma file: X, fileKey `ABC123`
- Frames: Home, SetGoal
- Figma node IDs: Home = `1:10`, SetGoal = `1:20`
- Devices: iphone-16, iphone-13-mini
- Required states: default
SPEC
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"
    [ "$(device_label_to_name iphone-16)" = "iPhone 16" ] || exit 1
    [ "$(figma_key_for "$spec")" = "ABC123" ] || exit 1
    [ "$(node_id_for "$spec" SetGoal)" = "1:20" ] || exit 1
    [ "$(visual_repair_devices "$spec" | sort | paste -sd, -)" = "iphone-13-mini,iphone-16" ] || exit 1
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alessandrogentil/inloop-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair helpers"`
Expected: `not ok` (functions not yet in the lib).

- [ ] **Step 3: Move the helpers into the lib.** In `scripts/lib/visual-repair.sh`, append (after the existing functions):

```bash
# Spec/Figma helpers (shared by both repair surfaces).
device_label_to_name() { printf '%s' "$1" | sed -E 's/-/ /g' | sed -E 's/\b(.)/\u\1/g'; }

# Per-spec capture device labels (e.g. iphone-16) from the Design Contract.
visual_repair_devices() { visual_capture_screens "$1" | awk -F'|' '{print $3}' | sort -u; }

# Resolve a screen's Figma node id from the spec's `- Figma node IDs:` line, else
# the spec's single declared node.
node_id_for() {
  local spec="$1" screen="$2" line id
  line="$(grep -E '^- Figma node IDs:' "$spec" | head -n1)"
  id="$(printf '%s' "$line" | grep -oE "${screen}[[:space:]]*=[[:space:]]*\`[0-9I][0-9:I;-]*\`" | grep -oE '`[^`]+`' | tr -d '`' | head -n1)"
  [ -n "$id" ] || id="$(printf '%s' "$line" | grep -oE '`[0-9I][0-9:I;-]*`' | head -n1 | tr -d '`')"
  printf '%s' "$id"
}

figma_key_for() { sed -nE 's/.*fileKey `([A-Za-z0-9]+)`.*/\1/p' "$1" | head -n1; }
```

- [ ] **Step 4: Delete the originals from `visual-review.sh` and rewire `matrix_devices`.** In `scripts/visual-review.sh`: delete the `device_label_to_name` definition (line ~152), the `node_id_for` definition (~228-234), and the `figma_key_for` definition (~235-237). Replace the `matrix_devices` body so it reuses the shared per-spec helper:

```bash
matrix_devices() { local f; for f in "${SPECS[@]}"; do visual_repair_devices "$f"; done | sort -u; }
```

(`visual-review.sh` already sources `scripts/lib/visual-repair.sh`, so the moved functions are in scope.)

- [ ] **Step 5: Run tests + shellcheck**

Run: `cd /Users/alessandrogentil/inloop-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/visual-repair.sh scripts/visual-review.sh scripts/test/fixtures.sh
git commit -m "refactor(visual-repair): move spec/Figma/device helpers to shared lib"
```

---

### Task 2: Relocate the Metro harness + agent + validate to the shared lib

**Files:**
- Modify: `scripts/lib/visual-repair.sh`, `scripts/visual-review.sh`

**Interfaces:**
- Produces (now in `visual-repair.sh`): `repair_metro_start <device>` (returns non-zero on dev-build failure — no longer `die`), `repair_metro_stop`, `_REPAIR_METRO_PID`, `repair_validate <project>`, `repair_agent <screen> <state> <ref> <shot> <diff_img> <pct> <tol> <out_dir>`.
- Globals these read (documented; both callers set them): `PROJECT`, `NO_BUILD`, `REPAIR_FILEKEY`, `REPAIR_FALLBACK_NODE`, `REPAIR_NODE_*`, `REPAIR_SHARED`.

> Integration glue (Metro/`claude -p`) — no automated fixture; verified by the standalone parity check (Task 4) + the existing standalone fixtures + the real smoke (Task 6).

- [ ] **Step 1: Move the functions verbatim into the lib, with one change to `repair_metro_start`.** Cut these blocks from `scripts/visual-review.sh` and paste into `scripts/lib/visual-repair.sh` (after the Task 1 helpers):
  - `_REPAIR_METRO_PID=""` + `repair_metro_start()` + `repair_metro_stop()` (currently `visual-review.sh` ~175-198)
  - `repair_validate()` (~198-200, keep its `# shellcheck disable=SC2329` pragma)
  - `repair_agent()` (~202-218, keep its pragma + the stdin/`--allowed-tools` invocation verbatim — that is the #27 fix, do not alter it)

  In the moved `repair_metro_start`, change the dev-build failure line from `die "repair: dev build failed; build manually then re-run with --no-build"` to:

```bash
      || { log "repair: dev build failed (build manually + re-run with --no-build)"; return 1; }
```

  (So in-loop can clean-skip instead of aborting the whole run.)

- [ ] **Step 2: Re-add the `|| die` at the standalone call site.** In `scripts/visual-review.sh`, the standalone repair block calls `repair_metro_start "$first_dev"`; change that call to `repair_metro_start "$first_dev" || die "repair: could not start Metro"` so the standalone tool still aborts on harness failure (its existing contract).

- [ ] **Step 3: Verify parse + shellcheck + fixtures**

Run: `cd /Users/alessandrogentil/inloop-wt && bash -n scripts/visual-review.sh && bash -n scripts/lib/visual-repair.sh && echo PARSE_OK`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `scripts/visual-review.sh --help >/dev/null 2>&1; echo $?` → Expected `0`

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/visual-repair.sh scripts/visual-review.sh
git commit -m "refactor(visual-repair): move Metro harness + repair agent/validate to shared lib"
```

---

### Task 3: New `visual_repair_for_spec` orchestrator

**Files:**
- Modify: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `figma_key_for`, `node_id_for` (Task 1); `repair_agent`, `repair_validate` (Task 2); `visual_repair_run`, `visual_repair_screen` (existing); `visual_recapture_screen`, `visual_capture_tolerance` (in `visual-capture.sh`).
- Produces: `visual_repair_for_spec <spec> <project> <out_dir> <candidate_label> <report_path> <max_attempts> <allow_csv> <iteration_device>` — builds the failing-screens TSV from `<report_path>`, sets `REPAIR_FILEKEY`/`REPAIR_FALLBACK_NODE`/`REPAIR_SHARED`, and runs `visual_repair_run`. Screenshot/diff paths use `<out_dir>/screenshots/<candidate_label>/…` and `<out_dir>/diffs/<candidate_label>/…`; refs use `<out_dir>/design/…`.

- [ ] **Step 1: Write the failing test.** Register `fixture_assert "visual_repair_for_spec builds TSV + parameterizes paths by candidate_label" fixture_visual_repair_for_spec "$root"` and add:

```bash
fixture_visual_repair_for_spec() {
  local root="$1" spec="$root/s.md" out="$root/out"
  mkdir -p "$out"
  cat >"$spec" <<'SPEC'
## Design Contract
- Figma file: X, fileKey `K1`
- Frames: Home
- Figma node IDs: Home = `1:9`
- Devices: iphone-16
- Required states: default
- Tolerance: 0.12
SPEC
  # a report with one failing screen
  cat >"$out/visual-diff-s.json" <<'JSON'
{"task":"s","screens":[{"screen":"Home","state":"default","device":"iphone-16","reference":"r","screenshot":"s","diff_pct":0.4,"tolerance":0.12,"pass":false,"analysis":"","diff_image":null,"attempts":[],"unmet_brief":[]}]}
JSON
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    # stub the screen loop to record the paths it is handed
    visual_repair_screen() { printf '%s|%s\n' "$8" "$9" >>"$out/paths.log"; }   # $8=shot $9=diff_img
    visual_repair_run() { local tsv="$1" cap="$2" fn="$3" l; while IFS=$'\t' read -r _ s st d; do "$fn" "$s" "$st" "$d" >/dev/null; done <"$tsv"; }
    visual_capture_tolerance() { printf '0.12'; }
    visual_repair_for_spec "$spec" "$root/proj" "$out" "CAND7" "$out/visual-diff-s.json" 3 "src/features/" iphone-16
  )
  # the failing-TSV was built and the screen path used candidate_label=CAND7
  grep -q "screenshots/CAND7/Home-default-iphone-16.png|.*diffs/CAND7/Home-default-iphone-16.png" "$out/paths.log" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alessandrogentil/inloop-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "for_spec"`
Expected: `not ok`.

- [ ] **Step 3: Implement.** Append to `scripts/lib/visual-repair.sh`:

```bash
# Per-spec repair orchestration shared by both surfaces. candidate_label is the only
# path difference between them (standalone: "review"; in-loop: the candidate SHA).
# Assumes Metro/the dev build is already up (the caller manages repair_metro_*).
visual_repair_for_spec() {
  local spec="$1" project="$2" out_dir="$3" candidate_label="$4" report="$5" \
        max="$6" allow_csv="$7" iter_dev="$8"
  REPAIR_FILEKEY="$(figma_key_for "$spec")"
  REPAIR_FALLBACK_NODE="$(node_id_for "$spec" "")"
  case "$allow_csv" in *src/ui*) REPAIR_SHARED=1 ;; *) REPAIR_SHARED=0 ;; esac
  local fail="$out_dir/_fail.tsv"
  jq -r '.screens[]|select(.pass|not)|[.diff_pct,.screen,.state,.device]|@tsv' "$report" >"$fail"
  # shellcheck disable=SC2329  # invoked indirectly via visual_repair_run
  _repair_one() {
    local sc="$1" st="$2" dv="$3"
    eval "REPAIR_NODE_$sc=\"$(node_id_for "$spec" "$sc")\""
    visual_repair_screen "$project" "$out_dir/_rsnap" "$out_dir" "$sc" "$st" "$dv" \
      "$out_dir/design/$sc-$st-$dv.png" "$out_dir/screenshots/$candidate_label/$sc-$st-$dv.png" \
      "$out_dir/diffs/$candidate_label/$sc-$st-$dv.png" "$(visual_capture_tolerance "$spec")" \
      "$max" repair_agent visual_recapture_screen repair_validate "$allow_csv" >/dev/null
    printf '%s\n' "$max"
  }
  visual_repair_run "$fail" "${NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP:-30}" _repair_one
  unset -f _repair_one
}
```

`iter_dev` is accepted for signature symmetry (the caller already used it to start Metro); it is intentionally unused inside the function — add `# shellcheck disable=SC2034` is NOT needed since it is a positional param, but reference it once to avoid confusion: leave as-is (positionals don't trigger SC2034).

- [ ] **Step 4: Run tests + shellcheck**

Run: `cd /Users/alessandrogentil/inloop-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): visual_repair_for_spec orchestrator (out_dir/candidate_label parameterized)"
```

---

### Task 4: Thin `visual-review.sh` to call `visual_repair_for_spec`

**Files:**
- Modify: `scripts/visual-review.sh`

**Interfaces:**
- Consumes: `visual_repair_for_spec`, `visual_repair_devices`, `device_label_to_name`, `repair_metro_start/stop` (Tasks 1-3).

- [ ] **Step 1: Replace the inline repair block.** In `scripts/visual-review.sh`, replace the whole `if [ "$REPAIR" -eq 1 ]; then … fi` block (the inline `repair_one` + TSV + `visual_repair_run`) with:

```bash
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
  log "repair: done. Edited files (uncommitted):"; git -C "$PROJECT" status --porcelain | sed 's/^/  /' >&2
fi
```

- [ ] **Step 2: Parity — verify standalone behavior unchanged.**

Run: `cd /Users/alessandrogentil/inloop-wt && bash -n scripts/visual-review.sh && echo PARSE_OK`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0` (the standalone `fixture_visual_review_repair_args` still passes — `--repair`/`--repair-shared` documented, bogus `--drive` rejected).
Run: `scripts/visual-review.sh --help 2>&1 | grep -c -- '--repair'` → Expected `≥1`

- [ ] **Step 3: Commit**

```bash
git add scripts/visual-review.sh
git commit -m "refactor(visual-review): call shared visual_repair_for_spec (behavior unchanged)"
```

---

### Task 5: `night-shift.sh` — source the lib + `run_visual` engine-invoked repair

**Files:**
- Modify: `scripts/night-shift.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_repair_for_spec`, `visual_repair_devices`, `device_label_to_name`, `repair_metro_start/stop` (shared lib); `visual_capture_available`, `run_visual_capture` (existing); `state_set`, `now_iso`, `write_json_atomic` (night-shift.sh).
- Produces: `VISUAL_REPAIR` constant; `run_visual` repairs+commits when enabled.

- [ ] **Step 1: Write the failing test.** Register `fixture_assert "run_visual: VISUAL_REPAIR constant + lib sourced + repair branch gated" fixture_run_visual_repair_gate "$root"` and add (a static-source-shape check, like the existing repair-optin fixture style):

```bash
fixture_run_visual_repair_gate() {
  # lib is sourced
  grep -q '\. "\$NIGHT_SHIFT_LIB/visual-repair.sh"' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  # the constant exists and defaults off
  grep -q 'VISUAL_REPAIR="\${NIGHT_SHIFT_VISUAL_REPAIR:-0}"' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  # repair is gated on the flag AND capture availability, and commit is guarded off main
  grep -q '\[ "\$VISUAL_REPAIR" = "1" \] && visual_capture_available' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  grep -q 'fix(visual): auto-repair' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  grep -q 'branch --show-current' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/alessandrogentil/inloop-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair branch gated"`
Expected: `not ok`.

- [ ] **Step 3: Source the lib + add the constant.** In `scripts/night-shift.sh`: after the `. "$NIGHT_SHIFT_LIB/visual-capture.sh"` line (~88) add:

```bash
# shellcheck source=scripts/lib/visual-repair.sh
. "$NIGHT_SHIFT_LIB/visual-repair.sh"
```

After `VISUAL_CAPTURE="${NIGHT_SHIFT_VISUAL_CAPTURE:-0}"` (~70) add:

```bash
# Opt-in in-loop visual auto-repair. OFF by default: when 1, the visual_review stage
# repairs over-tolerance screens (engine-invoked) and commits a fix(visual) commit
# before handing the repaired tip to the observer. Requires the project's dev
# build/Metro; cleanly skips (proceeds unrepaired) if unavailable.
VISUAL_REPAIR="${NIGHT_SHIFT_VISUAL_REPAIR:-0}"
```

- [ ] **Step 4: Rewire `run_visual`.** In `scripts/night-shift.sh`, replace the `valid)` arm body and the trailing `set_stage observer_review` of `run_visual` so the repair runs between them. The current tail is:

```bash
  case "$(visual_report_status "$report")" in
    valid)
      log "visual_review: report accepted ($(jq -r '[.screens[]|select(.pass)]|length' "$report")/$(jq -r '.screens|length' "$report") screens pass); handing to observer" ;;
    absent)
      log "visual_review: no visual-diff report produced (capture skipped or tooling unavailable); proceeding to observer" ;;
    malformed)
      block_run "visual_review produced a malformed visual-diff report" ;;
  esac
  set_stage observer_review
}
```

Replace it with:

```bash
  case "$(visual_report_status "$report")" in
    valid)
      log "visual_review: report accepted ($(jq -r '[.screens[]|select(.pass)]|length' "$report")/$(jq -r '.screens|length' "$report") screens pass)"
      run_visual_inloop_repair "$report" "$candidate" ;;
    absent)
      log "visual_review: no visual-diff report produced (capture skipped or tooling unavailable); proceeding to observer" ;;
    malformed)
      block_run "visual_review produced a malformed visual-diff report" ;;
  esac
  set_stage observer_review
}

# Engine-invoked in-loop repair. No-op unless NIGHT_SHIFT_VISUAL_REPAIR=1, capture
# tooling is available, and the report has over-tolerance screens. On any harness
# failure it logs and returns (the run proceeds to the observer unrepaired).
run_visual_inloop_repair() {
  local report="$1" candidate="$2"
  [ "$VISUAL_REPAIR" = "1" ] && visual_capture_available || return 0
  local over; over="$(jq -r '[.screens[]|select(.pass|not)]|length' "$report")"
  [ "$over" -gt 0 ] || { log "visual_review: all screens within tolerance; no repair needed"; return 0; }
  local branch; branch="$(git -C "$PROJECT" branch --show-current)"
  case "$branch" in main|master|'') log "visual_review: refusing to auto-repair on '$branch'; skipping repair"; return 0 ;; esac
  local iter_dev; iter_dev="$(visual_repair_devices "$SPEC" | head -n1)"
  NO_BUILD="${NIGHT_SHIFT_VISUAL_REPAIR_NO_BUILD:-0}"
  repair_metro_start "$(device_label_to_name "$iter_dev")" || { log "visual_review: repair harness unavailable; proceeding unrepaired"; return 0; }
  visual_repair_for_spec "$SPEC" "$PROJECT" "$RUN_ROOT/validated" "$candidate" "$report" \
    "${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" \
    "$([ "${NIGHT_SHIFT_VISUAL_REPAIR_SHARED:-0}" = "1" ] && echo 'src/features/,src/ui/' || echo 'src/features/')" \
    "$iter_dev"
  repair_metro_stop
  if git -C "$PROJECT" diff --quiet && git -C "$PROJECT" diff --cached --quiet; then
    log "visual_review: repair made no edits; proceeding unrepaired"; return 0
  fi
  local screens; screens="$(jq -r '[.screens[]|select(.pass|not)|.screen]|unique|join(", ")' "$report")"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -q -m "fix(visual): auto-repair $screens" || { log "visual_review: repair commit failed; proceeding"; return 0; }
  local newsha; newsha="$(git -C "$PROJECT" rev-parse HEAD)"
  state_set '
    .candidate_commits = ((.candidate_commits + [$c])
      | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) |
    .candidate=$c | .updated_at=$now
  ' --arg c "$newsha" --arg now "$(now_iso)"
  run_visual_capture "$SPEC" "$newsha" "$RUN_ROOT/validated"
  log "visual_review: auto-repaired ($screens); committed $newsha; refreshed report for observer"
}
```

- [ ] **Step 5: Run tests + shellcheck**

Run: `cd /Users/alessandrogentil/inloop-wt && bash -n scripts/night-shift.sh && echo PARSE_OK`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`

- [ ] **Step 6: Add the default-off behavioral fixture.** Append to `fixture_run_visual_repair_gate` (before `return 0`) a check that `run_visual_inloop_repair` is a clean no-op when the flag is off — source night-shift's function in isolation is hard, so assert the guard order instead (flag check precedes any git/Metro call):

```bash
  # the repair helper returns BEFORE any git/Metro side effect when the flag is off:
  awk '/^run_visual_inloop_repair\(\)/{f=1} f&&/return 0/{print NR; exit}' "$WORKSPACE_ROOT/scripts/night-shift.sh" | head -1 | grep -q '[0-9]' || return 1
  # and the very first guard line references VISUAL_REPAIR
  awk '/^run_visual_inloop_repair\(\)/{f=1} f&&/VISUAL_REPAIR/{print "ok"; exit}' "$WORKSPACE_ROOT/scripts/night-shift.sh" | grep -q ok || return 1
```

Run the suite again: `… | grep -c "not ok"` → Expected `0`.

- [ ] **Step 7: Commit**

```bash
git add scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(night-shift): engine-invoked in-loop visual repair (commit + refresh, default off)"
```

---

### Task 6: Docs + real-smoke record

**Files:**
- Modify: `CLAUDE.md` (document `NIGHT_SHIFT_VISUAL_REPAIR`)
- Create: `docs/2026-06-25-visual-repair-in-loop-validation.md`

> No fixture can exercise a real night-shift + sim + `claude -p`. This records the manual in-loop smoke.

- [ ] **Step 1: Document the knob.** In `CLAUDE.md`'s visual-fidelity section, add a line: in-loop auto-repair is opt-in via `NIGHT_SHIFT_VISUAL_REPAIR=1` (requires the project's dev build/Metro; commits a `fix(visual): auto-repair …` commit; cleanly skips if the harness is unavailable; never runs on `main`).

- [ ] **Step 2: Run the manual in-loop smoke.** On a project with a closeable-gap screen, run a night-shift with `NIGHT_SHIFT_VISUAL_CAPTURE=1 NIGHT_SHIFT_VISUAL_REPAIR=1` and a `## Design Contract` spec; confirm: the `visual_review` stage captures over-tolerance → repairs → a `fix(visual): auto-repair …` commit lands on the feature branch → `.candidate` points at it → the observer receives the refreshed report. Record the observed commit + before/after diffs in `docs/2026-06-25-visual-repair-in-loop-validation.md`. (Convergence itself is already proven by the standalone smoke — same loop.)

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/2026-06-25-visual-repair-in-loop-validation.md
git commit -m "docs(visual-repair): in-loop knob + real-smoke validation record"
```

---

## Self-Review

**Spec coverage:** §4.1 extraction → Tasks 1-2; new `visual_repair_for_spec` (§4.1) → Task 3; `visual-review.sh` thinning (§4.1) → Task 4; `run_visual` rewire + engine-invoked repair + commit + refresh (§4.2) → Task 5; clean-skip on harness/tooling absence (§4.3) → Task 5 (`repair_metro_start || …return 0`, `visual_capture_available` gate); commit semantics / new candidate commit (§4.4) → Task 5 (`state_set` append, never on main); reporting refresh (§5) → Task 5 (`run_visual_capture` at the repaired tip); testing (§6) → fixtures in Tasks 1,3,5 + the real smoke in Task 6.

**Placeholder scan:** the only runtime-substituted value is `$screens` in the commit message (computed from the report); all other steps show complete code + exact commands.

**Type/name consistency:** `visual_repair_devices`, `device_label_to_name`, `node_id_for`, `figma_key_for`, `repair_metro_start/stop`, `repair_validate`, `repair_agent`, `visual_repair_for_spec`, `run_visual_inloop_repair` are used consistently across tasks; `visual_repair_for_spec`'s 8-arg signature matches both call sites (Task 4 standalone, Task 5 in-loop); the `candidate_label` path layout (`screenshots/<label>/…`, `diffs/<label>/…`) matches `run_visual_capture`'s own layout (`<out>/screenshots/<candidate>/…`).

**Shellcheck:** every code task runs the default-severity `find … shellcheck -s bash` gate (per the global constraint), not just `-S error`.
