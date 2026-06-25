# Visual Auto-Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, bounded visual auto-repair loop that edits screens toward their Figma design + annotations, serving both the standalone `visual-review.sh --repair` and an opt-in in-loop `visual_review` repair via one shared `scripts/lib/visual-repair.sh` primitive.

**Architecture:** A new sourced lib `scripts/lib/visual-repair.sh` holds the surface-agnostic bounded loop (snapshot → agent edit → scope check → validate → re-capture → diff → record attempt, ≤ N). The agent, capture, and validate steps are **injected as function names** so each surface (standalone spawned `claude -p`; in-loop implement session) and the fixtures supply their own. Repair runs against a Metro dev build (`EXPO_PUBLIC_PREVIEW=1`) so JS edits hot-reload and the existing file-drive cold-launch re-captures in seconds.

**Tech Stack:** Bash (sourced libs, `set -uo pipefail`, shellcheck-clean), `jq`, `xcrun simctl`, `odiff`, Expo/Metro, `claude -p`, the Figma MCP (agent-only) + Figma REST. Tests are deterministic fixtures in `scripts/test/fixtures.sh` run via the engine's fixture suite.

**Spec:** `docs/superpowers/specs/2026-06-24-visual-auto-repair-design.md`.

## Global Constraints

- Both surfaces default **OFF**; with flags unset, behavior is byte-for-byte unchanged.
- Run the fixture suite with: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` (passes when it prints `all deterministic fixtures passed` and `grep -c "not ok"` is 0).
- New fixtures follow the existing pattern: a `fixture_*` function returning 0/1, registered in `run_dry_fixtures` via `fixture_assert "<desc>" fixture_<name> "$root"`.
- All new shell must be shellcheck-clean: `shellcheck -S error scripts/lib/visual-repair.sh scripts/visual-review.sh scripts/lib/visual-capture.sh`.
- Numeric `awk`/`printf` that emits JSON values uses `LC_ALL=C` (comma-decimal-locale safety, per GH #16).
- The repair agent never runs git, commits, pushes, or builds native; repair edits are left **uncommitted**.
- Default edit scope = paths under `src/features/`; `src/ui/` only when shared edits are opted in; everything else is denied.
- Per-screen attempts default 3 (`NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS`); global cap default 30 (`NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP`).

## File Structure

- **Create** `scripts/lib/visual-repair.sh` — the shared repair primitive: scope check, snapshot/restore, validate, per-screen bounded loop (`visual_repair_screen`), and the screen-set driver (`visual_repair_run`). Surface-agnostic via injected function names.
- **Modify** `scripts/lib/visual-capture.sh` — extend `visual_assemble_screen` with an `unmet_brief` field; add a single-screen re-capture helper `visual_recapture_screen`.
- **Modify** `schemas/visual-diff.json` — add the always-present `unmet_brief` array to the screen object.
- **Modify** `scripts/visual-review.sh` — `--repair[=N]` / `--repair-shared` flags, the Metro fast-reload harness (start/stop, dev build), the standalone repair agent (`claude -p`), and the first-capture → repair → final-pass flow.
- **Modify** `scripts/night-shift.sh` — `NIGHT_SHIFT_VISUAL_REPAIR` opt-in and the in-loop `visual_review` repair routing.
- **Modify** `scripts/test/fixtures.sh` — fixtures for the new behavior.

---

### Task 1: Add `unmet_brief` to the report schema and assembler

**Files:**
- Modify: `schemas/visual-diff.json` (screen object `required` + `properties`)
- Modify: `scripts/lib/visual-capture.sh` (`visual_assemble_screen`)
- Test: `scripts/test/fixtures.sh` (extend `fixture_visual_assemble_screen`)

**Interfaces:**
- Produces: `visual_assemble_screen <screen> <state> <device> <reference> <screenshot> <diff_pct> <tolerance> <diff_image> [analysis] [attempts_json] [unmet_brief_json]` — now emits a 12th key `unmet_brief` (JSON array of strings, default `[]`), always present.

- [ ] **Step 1: Write the failing test** — extend the assembler fixture to assert the new field. In `scripts/test/fixtures.sh`, inside `fixture_visual_assemble_screen`, add after the existing assertions:

```bash
  # unmet_brief defaults to [] and is always present
  obj="$(visual_assemble_screen Home default iphone-15 d.png s.png 0.05 0.1 di.png "" "[]")"
  printf '%s' "$obj" | jq -e '.unmet_brief == []' >/dev/null || return 1
  # and round-trips a provided list
  obj="$(visual_assemble_screen Home default iphone-15 d.png s.png 0.05 0.1 di.png "" "[]" '["button 44pt"]')"
  printf '%s' "$obj" | jq -e '.unmet_brief == ["button 44pt"]' >/dev/null || return 1
  printf '%s\n' "$obj" >"$root/asm_brief.json"
  printf '{"task":"t","screens":[%s]}' "$obj" >"$root/asm_brief_full.json"
  json_schema_basic visual-diff "$root/asm_brief_full.json" || return 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -i "assembly derives"`
Expected: `not ok - visual screen assembly derives pass and null diff_image` (jq `.unmet_brief` is null → fails).

- [ ] **Step 3: Add the field to the schema.** In `schemas/visual-diff.json`, change the screen object `required` line to include `unmet_brief`:

```json
          "diff_pct", "tolerance", "pass", "analysis", "attempts", "diff_image", "unmet_brief"
```

and add to the screen `properties` (after the `attempts` block):

```json
          ,
          "unmet_brief": {
            "type": "array",
            "items": { "type": "string" }
          }
```

- [ ] **Step 4: Emit the field from the assembler.** In `scripts/lib/visual-capture.sh`, change `visual_assemble_screen`:

```bash
visual_assemble_screen() {
  local screen="$1" state="$2" device="$3" reference="$4" screenshot="$5" \
    diff_pct="$6" tolerance="$7" diff_image="$8" analysis="${9:-}" attempts="${10:-[]}" \
    unmet_brief="${11:-[]}"
  jq -nc \
    --arg screen "$screen" --arg state "$state" --arg device "$device" \
    --arg reference "$reference" --arg screenshot "$screenshot" \
    --argjson diff_pct "$diff_pct" --argjson tolerance "$tolerance" \
    --arg diff_image "$diff_image" --arg analysis "$analysis" \
    --argjson attempts "$attempts" --argjson unmet_brief "$unmet_brief" '
    {
      screen: $screen, state: $state, device: $device, reference: $reference,
      screenshot: $screenshot, diff_pct: $diff_pct, tolerance: $tolerance,
      pass: ($diff_pct <= $tolerance), analysis: $analysis,
      diff_image: (if $diff_image == "" then null else $diff_image end),
      attempts: $attempts, unmet_brief: $unmet_brief
    }'
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"`
Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add schemas/visual-diff.json scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "feat(visual): add unmet_brief field to visual-diff screen object"
```

---

### Task 2: Scope-check helper

**Files:**
- Create: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `visual_repair_scope_check <project> <allow_prefix>...` — returns 0 if every path in `git -C <project> status --porcelain` starts with one of the allow-prefixes; otherwise prints the offending paths to stderr and returns 1.

- [ ] **Step 1: Write the failing test.** Add to `scripts/test/fixtures.sh` and register it in `run_dry_fixtures` (near the other visual fixtures) with `fixture_assert "visual-repair scope-check allows in-scope, rejects out-of-scope" fixture_visual_repair_scope "$root"`:

```bash
fixture_visual_repair_scope() {
  local root="$1" proj="$root/scopep"
  mkdir -p "$proj/src/features/home" "$proj/src/data"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; : >"$proj/src/data/db.ts"
  git -C "$proj" add -A && git -C "$proj" commit -qm base
  # in-scope edit only -> pass
  printf 'x' >>"$proj/src/features/home/HomeScreen.tsx"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; visual_repair_scope_check "$proj" "src/features/" ) || return 1
  # out-of-scope edit -> fail
  printf 'x' >>"$proj/src/data/db.ts"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; visual_repair_scope_check "$proj" "src/features/" ) && return 1
  # shared opt-in: src/ui allowed when listed
  mkdir -p "$proj/src/ui"; : >"$proj/src/ui/tokens.ts"; git -C "$proj" add -A; git -C "$proj" commit -qm two
  printf 'x' >>"$proj/src/ui/tokens.ts"; git -C "$proj" checkout -q -- src/data/db.ts
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; visual_repair_scope_check "$proj" "src/features/" "src/ui/" ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "scope-check"`
Expected: `not ok - visual-repair scope-check ...` (file/function does not exist yet).

- [ ] **Step 3: Create the lib with the function.** Create `scripts/lib/visual-repair.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# visual-repair.sh — surface-agnostic bounded auto-repair loop for the
# design-fidelity pipeline. Sourced by scripts/visual-review.sh (standalone) and
# scripts/night-shift.sh (in-loop). The agent, capture, and validate steps are
# INJECTED as function names so each caller (and the fixtures) supplies its own.
# Expects a `log` function in scope (callers define it).

# Return 0 iff every changed path in <project>'s working tree begins with one of
# the allow-prefixes; else print offenders and return 1.
visual_repair_scope_check() {
  local project="$1"; shift
  local offenders="" line path p ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"            # strip the 2-char status + space
    ok=0
    for p in "$@"; do case "$path" in "$p"*) ok=1; break ;; esac; done
    [ "$ok" = "1" ] || offenders="$offenders$path"$'\n'
  done < <(git -C "$project" status --porcelain 2>/dev/null)
  if [ -n "$offenders" ]; then
    printf 'visual-repair: out-of-scope edits:\n%s' "$offenders" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"`
Expected: `0`

- [ ] **Step 5: Shellcheck + commit**

```bash
shellcheck -S error scripts/lib/visual-repair.sh
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): scope-check helper for in-scope edits"
```

---

### Task 3: Snapshot / restore of in-scope trees

**Files:**
- Modify: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `visual_repair_snapshot <project> <tmpdir> <prefix>...` — copies each existing `<project>/<prefix>` tree into `<tmpdir>`. `visual_repair_restore <project> <tmpdir> <prefix>...` — restores them (used to revert a failed attempt). Both return 0 on success.

- [ ] **Step 1: Write the failing test.** Add and register `fixture_visual_repair_snapshot`:

```bash
fixture_visual_repair_snapshot() {
  local root="$1" proj="$root/snapp" tmp="$root/snaptmp"
  mkdir -p "$proj/src/features/home"
  printf 'orig' >"$proj/src/features/home/HomeScreen.tsx"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; visual_repair_snapshot "$proj" "$tmp" "src/features/" ) || return 1
  printf 'edited' >"$proj/src/features/home/HomeScreen.tsx"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; visual_repair_restore "$proj" "$tmp" "src/features/" ) || return 1
  [ "$(cat "$proj/src/features/home/HomeScreen.tsx")" = "orig" ] || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "snapshot"`
Expected: `not ok - ...snapshot...`

- [ ] **Step 3: Implement.** Append to `scripts/lib/visual-repair.sh`:

```bash
# Copy in-scope trees aside so a failed repair attempt can be reverted.
visual_repair_snapshot() {
  local project="$1" tmpdir="$2"; shift 2
  local p
  rm -rf "$tmpdir"; mkdir -p "$tmpdir"
  for p in "$@"; do
    [ -e "$project/$p" ] || continue
    mkdir -p "$tmpdir/$(dirname "$p")"
    cp -R "$project/$p" "$tmpdir/$p"
  done
}

# Restore the snapshotted trees over the working copy.
visual_repair_restore() {
  local project="$1" tmpdir="$2"; shift 2
  local p
  for p in "$@"; do
    [ -e "$tmpdir/$p" ] || continue
    rm -rf "$project/$p"
    mkdir -p "$project/$(dirname "$p")"
    cp -R "$tmpdir/$p" "$project/$p"
  done
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"`
Expected: `0`

- [ ] **Step 5: Shellcheck + commit**

```bash
shellcheck -S error scripts/lib/visual-repair.sh
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): snapshot/restore of in-scope trees"
```

---

### Task 4: Bounded per-screen repair loop

**Files:**
- Modify: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_repair_scope_check`, `visual_repair_snapshot`, `visual_repair_restore` (Tasks 2-3); `visual_assemble_screen` (Task 1).
- Produces: `visual_repair_screen <project> <tmpdir> <out_dir> <screen> <state> <device> <ref> <shot> <diff_img> <tolerance> <max_attempts> <agent_fn> <capture_fn> <validate_fn> <allow_prefixes_csv>` — runs the bounded loop and prints the final per-screen JSON object (via `visual_assemble_screen`, with `attempts[]` populated). Returns 0 if the screen ends within tolerance, 1 otherwise.
  - `agent_fn <screen> <state> <ref> <shot> <diff_img> <diff_pct> <tolerance> <out_dir>` — edits the screen; prints a JSON `{"unmet_brief":[...]}` to stdout; returns 0.
  - `capture_fn <screen> <state> <device> <out_png>` — re-captures one screen to `<out_png>`; returns 0.
  - `validate_fn <project>` — runs the project's checks (tsc/eslint); returns 0 if clean.

- [ ] **Step 1: Write the failing test.** Register `fixture_visual_repair_loop` and add it. It injects stub functions to drive each branch:

```bash
fixture_visual_repair_loop() {
  local root="$1" proj="$root/loopp" out="$root/loopout"
  mkdir -p "$proj/src/features/home" "$out/design" "$out/diffs"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"; : >"$out/shot.png"; : >"$out/diff.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"
    . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"
    log() { :; }
    # agent makes an in-scope edit and reports one unmet item
    _agent() { printf 'x' >>"$proj/src/features/home/HomeScreen.tsx"; printf '{"unmet_brief":["spacing"]}'; }
    _validate_ok() { return 0; }
    # capture: stub diff sequence via a global counter -> first 0.3 (fail), then 0.05 (pass)
    _N=0
    _capture() { :; }
    _diffseq() { _N=$((_N+1)); [ "$_N" -ge 2 ] && printf '0.05' || printf '0.30'; }
    # Override the diff used by the loop by exporting a pluggable hook:
    NIGHT_SHIFT_VISUAL_DIFF_FN=_diffseq
    obj="$(visual_repair_screen "$proj" "$root/lt" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" \
        0.10 3 _agent _capture _validate_ok "src/features/")"
    # ends passing (0.05 <= 0.10), with a 2-entry attempts[] and the unmet item
    printf '%s' "$obj" | jq -e '.pass == true and (.attempts|length)==2 and (.unmet_brief==["spacing"])' >/dev/null || exit 1
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair loop\|visual_repair_screen"`
Expected: `not ok` (function not defined).

- [ ] **Step 3: Implement the loop.** Append to `scripts/lib/visual-repair.sh`. Note the pluggable diff hook `NIGHT_SHIFT_VISUAL_DIFF_FN` (defaults to the real `__visual_pixel_diff`) so the fixture can drive the diff sequence deterministically:

```bash
# Re-diff a screenshot against a reference; honors an injectable hook for tests.
visual_repair_diff() {
  local ref="$1" shot="$2" diff_out="$3"
  if [ -n "${NIGHT_SHIFT_VISUAL_DIFF_FN:-}" ]; then
    "$NIGHT_SHIFT_VISUAL_DIFF_FN" "$ref" "$shot" "$diff_out"
  else
    __visual_pixel_diff "$ref" "$shot" "$diff_out"
  fi
}

# Bounded per-screen repair. Prints the final screen object; returns 0 if it ends
# within tolerance, else 1.
visual_repair_screen() {
  local project="$1" tmpbase="$2" out_dir="$3" screen="$4" state="$5" device="$6" \
    ref="$7" shot="$8" diff_img="$9" tol="${10}" max="${11}" agent_fn="${12}" \
    capture_fn="${13}" validate_fn="${14}" allow_csv="${15}"
  local IFS_OLD="$IFS"; IFS=','; read -r -a allow <<<"$allow_csv"; IFS="$IFS_OLD"
  local attempts="[]" unmet="[]" cur="" n=0 snap="$tmpbase/snap" passed=0 agent_out
  # cur is the latest diff_pct; seed from the caller's pre-repair diff image dir.
  cur="$(visual_repair_diff "$ref" "$shot" "$diff_img" 2>/dev/null || printf '1')"
  while [ "$n" -lt "$max" ]; do
    n=$((n+1))
    visual_repair_snapshot "$project" "$snap" "${allow[@]}"
    agent_out="$("$agent_fn" "$screen" "$state" "$ref" "$shot" "$diff_img" "$cur" "$tol" "$out_dir" 2>/dev/null || printf '{}')"
    unmet="$(printf '%s' "$agent_out" | jq -c '.unmet_brief // []' 2>/dev/null || printf '[]')"
    # scope + validation gate; revert this attempt on failure and stop.
    if ! visual_repair_scope_check "$project" "${allow[@]}" || ! "$validate_fn" "$project"; then
      log "visual-repair: $screen attempt $n failed scope/validation; reverting"
      visual_repair_restore "$project" "$snap" "${allow[@]}"
      attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --arg s "$shot" --arg d "$diff_img" \
        '. + [{attempt:$a, diff_pct:0, pass:false, analysis:"reverted: scope/validation failed", screenshot:$s, diff_image:$d}]')"
      break
    fi
    "$capture_fn" "$screen" "$state" "$device" "$shot"
    cur="$(visual_repair_diff "$ref" "$shot" "$diff_img" 2>/dev/null || printf '1')"
    local pass; pass="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --argjson p "$cur" --argjson ps "$pass" \
      --arg s "$shot" --arg d "$diff_img" \
      '. + [{attempt:$a, diff_pct:$p, pass:$ps, analysis:"", screenshot:$s, diff_image:$d}]')"
    if [ "$pass" = "true" ]; then passed=1; break; fi
  done
  visual_assemble_screen "$screen" "$state" "$device" "$ref" "$shot" "$cur" "$tol" "$diff_img" "" "$attempts" "$unmet"
  [ "$passed" = "1" ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"`
Expected: `0`

- [ ] **Step 5: Add the give-up + revert fixtures.** Append two more assertions inside `fixture_visual_repair_loop` (before `return 0`) to cover give-up-after-N and validation-revert:

```bash
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _agent(){ printf 'x' >>"$proj/src/features/home/HomeScreen.tsx"; printf '{}'; }
    _cap(){ :; }; _ok(){ return 0; }; _bad(){ return 1; }
    _hi(){ printf '0.30'; }; NIGHT_SHIFT_VISUAL_DIFF_FN=_hi
    # never converges -> 3 attempts, returns 1
    obj="$(visual_repair_screen "$proj" "$root/lt2" "$out" Home default iphone-15 "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.10 3 _agent _cap _ok "src/features/")" && exit 1
    printf '%s' "$obj" | jq -e '(.attempts|length)==3 and .pass==false' >/dev/null || exit 1
    # validation fails -> edit reverted, file back to committed state
    git -C "$proj" checkout -q -- src/features/home/HomeScreen.tsx
    visual_repair_screen "$proj" "$root/lt3" "$out" Home default iphone-15 "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.10 3 _agent _cap _bad "src/features/" >/dev/null
    [ -z "$(git -C "$proj" status --porcelain)" ] || exit 1
    exit 0
  ) || return 1
```

- [ ] **Step 6: Run + shellcheck + commit**

```bash
cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"   # expect 0
shellcheck -S error scripts/lib/visual-repair.sh
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): bounded per-screen repair loop with scope+validation gate"
```

---

### Task 5: Screen-set driver (worst-first + global cap)

**Files:**
- Modify: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_repair_screen` (Task 4).
- Produces: `visual_repair_run <failing_screens_tsv> <global_cap> <repair_one_fn>` — iterates failing screens ordered by descending `diff_pct`, calling `<repair_one_fn> <screen> <state> <device>` for each until the cap of cumulative attempts is reached. `<failing_screens_tsv>` lines are `diff_pct\tscreen\tstate\tdevice`. Prints the order it processed (one `screen` per line) and stops early when the cap is hit.

- [ ] **Step 1: Write the failing test.** Register and add `fixture_visual_repair_run`:

```bash
fixture_visual_repair_run() {
  local root="$1" tsv="$root/fail.tsv" log="$root/order.log"
  printf '0.10\tHome\tdefault\tiphone-15\n0.40\tHistory\tdefault\tiphone-15\n0.25\tGoal\tdefault\tiphone-15\n' >"$tsv"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _one(){ printf '%s\n' "$1" >>"$log"; }   # records processing order
    visual_repair_run "$tsv" 99 _one >/dev/null )
  # worst-first: History (0.40), Goal (0.25), Home (0.10)
  [ "$(paste -sd, "$log")" = "History,Goal,Home" ] || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair_run\|repair run"`
Expected: `not ok`.

- [ ] **Step 3: Implement.** Append to `scripts/lib/visual-repair.sh`:

```bash
# Process failing screens worst-diff first, stopping at the global attempt cap.
# repair_one_fn returns the number of attempts it consumed on its stdout's last
# line (an integer); if it prints nothing numeric, 1 is assumed.
visual_repair_run() {
  local tsv="$1" cap="$2" repair_one_fn="$3" used=0 line pct screen state device out
  while IFS=$'\t' read -r pct screen state device; do
    [ -n "$screen" ] || continue
    [ "$used" -lt "$cap" ] || { log "visual-repair: global cap $cap reached; stopping"; break; }
    out="$("$repair_one_fn" "$screen" "$state" "$device" 2>/dev/null | tail -n1)"
    case "$out" in (''|*[!0-9]*) out=1 ;; esac
    used=$((used + out))
  done < <(sort -t"$(printf '\t')" -k1,1 -rn "$tsv")
}
```

- [ ] **Step 4: Run + shellcheck + commit**

```bash
cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"   # expect 0
shellcheck -S error scripts/lib/visual-repair.sh
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): worst-first screen-set driver with global cap"
```

---

### Task 6: Single-screen re-capture helper

**Files:**
- Modify: `scripts/lib/visual-capture.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `__visual_capture_screenshot`, `__visual_resolve_udid` (existing).
- Produces: `visual_recapture_screen <screen> <state> <device> <out_png>` — resolves the device UDID and drives the existing file-drive capture for one screen to `<out_png>`; returns 0 on success, non-zero on capture failure. This is the `capture_fn` the standalone surface injects.

- [ ] **Step 1: Write the failing test.** Register and add `fixture_visual_recapture`, reusing the existing fake-`xcrun`-on-PATH pattern (file-drive vars set so it takes the prompt-free path):

```bash
fixture_visual_recapture() {
  local root="$1" d="$root/rc"; mkdir -p "$d/bin" "$d/data"
  cat >"$d/bin/xcrun" <<STUB
#!/usr/bin/env bash
shift
case "\$1" in
  get_app_container) printf '%s\n' "$d/data" ;;
  io) printf x >"\${!#}" ;;
esac
exit 0
STUB
  chmod +x "$d/bin/xcrun"
  ( . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"
    export PATH="$d/bin:$PATH" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0 \
      NIGHT_SHIFT_PREVIEW_BUNDLE_ID=com.example.app NIGHT_SHIFT_PREVIEW_FILE=p.txt
    __visual_resolve_udid() { printf 'UDID-X\n'; }
    visual_recapture_screen Home default iphone-15 "$d/out.png" || exit 1
    [ -s "$d/out.png" ] || exit 1 ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "recapture"`
Expected: `not ok`.

- [ ] **Step 3: Implement.** Add to `scripts/lib/visual-capture.sh` (after `__visual_capture_screenshot`):

```bash
# Re-capture a single screen via the existing file-drive path. Used by the repair
# loop after an edit hot-reloads. Returns non-zero if capture fails.
visual_recapture_screen() {
  local screen="$1" state="$2" device="$3" out="$4" udid
  udid="$(__visual_resolve_udid "$device")" || return 2
  [ -n "$udid" ] || return 2
  __visual_capture_screenshot "$screen" "$state" "$device" "$out" "$udid"
}
```

- [ ] **Step 4: Run + shellcheck + commit**

```bash
cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"   # expect 0
shellcheck -S error scripts/lib/visual-capture.sh
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "feat(visual): single-screen re-capture helper for repair"
```

---

### Task 7: Standalone `--repair` flags + cost warning

**Files:**
- Modify: `scripts/visual-review.sh`
- Test: `scripts/test/fixtures.sh` (usage/parse smoke)

**Interfaces:**
- Produces: `visual-review.sh` accepts `--repair[=N]` (sets `REPAIR=1`, `MAX_ATTEMPTS=N` default 3) and `--repair-shared` (adds `src/ui/` to the allow-list). `--repair` implies `DRIVE=file`. Sourcing `scripts/lib/visual-repair.sh` happens near the existing `scripts/lib/visual-capture.sh` source.

- [ ] **Step 1: Write the failing test.** Register and add `fixture_visual_review_repair_args`, which runs the script with a bad `--repair` arg and asserts the help/usage lists `--repair`:

```bash
fixture_visual_review_repair_args() {
  local root="$1"
  # --help text documents --repair
  "$WORKSPACE_ROOT/scripts/visual-review.sh" --help 2>&1 | grep -q -- '--repair' || return 1
  # unknown drive still rejected (regression guard)
  "$WORKSPACE_ROOT/scripts/visual-review.sh" --project "$root" --drive bogus 2>&1 | grep -qi "unknown --drive" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair_args\|repair args"`
Expected: `not ok` (help has no `--repair` yet).

- [ ] **Step 3: Implement parsing + sourcing.** In `scripts/visual-review.sh`: (a) source the repair lib next to the capture lib:

```bash
# shellcheck source=scripts/lib/visual-repair.sh
. "$SCRIPT_DIR/lib/visual-repair.sh"
```

(b) add to the args defaults line: `REPAIR=0 MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" REPAIR_SHARED=0`; (c) add cases in the arg `while`:

```bash
    --repair)        REPAIR=1; case "${2:-}" in ''|--*) : ;; *) MAX_ATTEMPTS="$2"; shift ;; esac; shift ;;
    --repair-shared) REPAIR_SHARED=1; shift ;;
```

(d) add the doc lines to the `--help` header block (lines 4-40) under the options:

```bash
#   --repair[=N]      after the report, auto-repair over-tolerance screens (N
#                     attempts/screen, default 3). Implies --drive file; edits are
#                     left UNCOMMITTED for review. Off by default.
#   --repair-shared   allow repair edits to src/ui (shared) as well as src/features
```

(e) after the `case "$DRIVE"` block, force file-drive + warn when repair is on:

```bash
if [ "$REPAIR" -eq 1 ]; then
  [ "$DRIVE" = "file" ] || { DRIVE=file; export NIGHT_SHIFT_PREVIEW_BUNDLE_ID="$BUNDLE_ID" NIGHT_SHIFT_PREVIEW_FILE="${PREVIEW_FILE:-nightshift-preview.txt}"; }
  log "REPAIR ON (≤${MAX_ATTEMPTS}/screen): spawns PAID claude sessions and EDITS screen code (left uncommitted)."
fi
```

- [ ] **Step 4: Run + shellcheck + commit**

```bash
cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"   # expect 0
shellcheck -S error scripts/visual-review.sh
git add scripts/visual-review.sh scripts/test/fixtures.sh
git commit -m "feat(visual-review): --repair/--repair-shared flags + cost warning"
```

---

### Task 8: Metro fast-reload harness (standalone)

**Files:**
- Modify: `scripts/visual-review.sh`

**Interfaces:**
- Produces (internal to `visual-review.sh`): `repair_metro_start` / `repair_metro_stop` — build+install the dev client on the first matrix device and start/stop Metro with `EXPO_PUBLIC_PREVIEW=1`. Registered on `trap ... EXIT` so Metro is always torn down.

> This task is integration glue against Expo/Metro, which the fixture harness cannot run. It is verified by the real smoke in Task 11. Keep the functions tiny and side-effect-isolated.

- [ ] **Step 1: Implement the harness.** Add to `scripts/visual-review.sh`:

```bash
_REPAIR_METRO_PID=""
repair_metro_start() {
  local device="$1"
  if [ "$NO_BUILD" -ne 1 ]; then
    log "repair: building dev client on '$device' (slow, once)…"
    ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --device "$device" >/dev/null 2>&1 ) \
      || die "repair: dev build failed; build manually then re-run with --no-build"
  fi
  log "repair: starting Metro (EXPO_PUBLIC_PREVIEW=1)…"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start >/tmp/visual-repair-metro.log 2>&1 ) &
  _REPAIR_METRO_PID=$!
  # wait for the bundler port
  local i=0; until curl -s http://localhost:8081/status >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -ge 30 ] && break; sleep 2; done
}
repair_metro_stop() {
  [ -n "$_REPAIR_METRO_PID" ] || return 0
  kill "$_REPAIR_METRO_PID" 2>/dev/null || true
  pkill -f "expo start" 2>/dev/null || true
  _REPAIR_METRO_PID=""
}
```

- [ ] **Step 2: Shellcheck + commit**

```bash
shellcheck -S error scripts/visual-review.sh
git add scripts/visual-review.sh
git commit -m "feat(visual-review): Metro fast-reload harness for repair"
```

---

### Task 9: Standalone repair agent + wire the flow

**Files:**
- Modify: `scripts/visual-review.sh`

**Interfaces:**
- Consumes: `visual_repair_run`, `visual_repair_screen` (Tasks 4-5); `visual_recapture_screen` (Task 6); `repair_metro_start/stop` (Task 8); `node_id_for`, `figma_key_for` (existing).
- Produces (internal): `repair_agent <screen> <state> <ref> <shot> <diff_img> <diff_pct> <tol> <out_dir>` — spawns a scoped `claude -p` to edit the screen; prints `{"unmet_brief":[...]}`. `repair_validate <project>` — runs the project's `tsc`+`eslint`. The repair stage runs after `review_spec`'s first capture, then a final full re-capture.

> Integration glue (spawns `claude -p`); verified by Task 11's real smoke.

- [ ] **Step 1: Implement the agent + validate.** Add to `scripts/visual-review.sh`. The prompt hands the agent the images, numbers, Figma `fileKey`+`nodeId`, the token-availability flag, and the scope rules; it must use the Figma MCP for Dev Mode specs and (if `FIGMA_TOKEN`) the REST comments endpoint:

```bash
repair_validate() {
  ( cd "$1" && npx tsc --noEmit >/dev/null 2>&1 && npx eslint . --max-warnings 0 >/dev/null 2>&1 )
}

repair_agent() {
  local screen="$1" state="$2" ref="$3" shot="$4" diff_img="$5" pct="$6" tol="$7" out_dir="$8"
  local key node allow scope_note tok_note result
  key="$REPAIR_FILEKEY"; node="$REPAIR_NODE_${screen}"; node="${!node:-$REPAIR_FALLBACK_NODE}"
  allow="src/features/"; [ "$REPAIR_SHARED" -eq 1 ] && allow="src/features/ and src/ui/"
  [ -n "${FIGMA_TOKEN:-}" ] && tok_note="FIGMA_TOKEN is set: also fetch pinned comments via GET https://api.figma.com/v1/files/$key/comments and treat them as requirements." \
    || tok_note="FIGMA_TOKEN is NOT set: skip pinned comments; note them as unavailable in unmet_brief context."
  result="$(cd "$PROJECT" && claude -p --output-format json \
    --allowedTools "Read Edit Write Bash(npx tsc*) Bash(npx eslint*) mcp__figma__get_figma_data" \
    "You are repairing the '$screen' screen ($state) of this Expo RN app to match its Figma frame.
Reference image: $ref  Current screenshot: $shot  Diff overlay: $diff_img  diff=$pct tolerance=$tol.
Pull the Figma Dev Mode specs for node $node in file $key via mcp__figma__get_figma_data (sizes, spacing, colors, typography, tokens). $tok_note
Edit ONLY files under $allow to bring the screen to the design. Do NOT touch tests, src/data, src/domain, app/, or native config. Keep 'npx tsc --noEmit' and 'npx eslint . --max-warnings 0' clean. Do NOT run git, commit, push, or build native.
When done, print ONLY a JSON object: {\"unmet_brief\":[\"<specs/comments you could not satisfy>\"]}." 2>/dev/null)"
  printf '%s' "$result" | jq -r '.result // "{}"' 2>/dev/null | grep -o '{.*}' | tail -n1
  [ -n "$result" ]
}
```

- [ ] **Step 2: Wire the repair stage into the run.** In `scripts/visual-review.sh`, after the existing per-spec `review_spec` first pass, when `REPAIR=1`: parse `fileKey`/node IDs (reuse `figma_key_for`/`node_id_for`), start Metro on the first matrix device, build the failing-screens TSV from the report, run `visual_repair_run` with a `repair_one` that calls `visual_repair_screen` (injecting `repair_agent`, `visual_recapture_screen`, `repair_validate`), then do one final full `run_visual_capture` pass, then `repair_metro_stop`. Add near the run section:

```bash
if [ "$REPAIR" -eq 1 ]; then
  REPAIR_FILEKEY="$(figma_key_for "${SPECS[0]}")"; REPAIR_FALLBACK_NODE="$(node_id_for "${SPECS[0]}" "")"
  trap 'repair_metro_stop' EXIT
  first_dev="$(device_label_to_name "$(matrix_devices | head -n1)")"
  repair_metro_start "$first_dev"
  report="$OUT/$(basename "${SPECS[0]}" .md)/visual-diff-$(basename "${SPECS[0]}" .md).json"
  jq -r '.screens[]|select(.pass|not)|[.diff_pct,.screen,.state,.device]|@tsv' "$report" >"$OUT/_fail.tsv"
  repair_one() {
    local sc="$1" st="$2" dv="$3" rd="$OUT/$(basename "${SPECS[0]}" .md)"
    eval "REPAIR_NODE_$sc=\"$(node_id_for "${SPECS[0]}" "$sc")\""
    visual_repair_screen "$PROJECT" "$OUT/_rsnap" "$rd" "$sc" "$st" "$dv" \
      "$rd/design/$sc-$st-$dv.png" "$rd/screenshots/review/$sc-$st-$dv.png" \
      "$rd/diffs/review/$sc-$st-$dv.png" "$(visual_capture_tolerance "${SPECS[0]}")" \
      "$MAX_ATTEMPTS" repair_agent visual_recapture_screen repair_validate \
      "$([ "$REPAIR_SHARED" -eq 1 ] && echo "src/features/,src/ui/" || echo "src/features/")" >/dev/null
    printf '%s\n' "$MAX_ATTEMPTS"
  }
  visual_repair_run "$OUT/_fail.tsv" "${NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP:-30}" repair_one
  log "repair: final authoritative pass…"
  review_spec "${SPECS[0]}"
  repair_metro_stop; trap - EXIT
  log "repair: done. Edited files (uncommitted):"; git -C "$PROJECT" status --porcelain | sed 's/^/  /' >&2
fi
```

- [ ] **Step 3: Shellcheck + commit**

```bash
shellcheck -S error scripts/visual-review.sh
git add scripts/visual-review.sh
git commit -m "feat(visual-review): standalone repair agent + flow (first pass -> repair -> final pass)"
```

---

### Task 10: In-loop `visual_review` repair (opt-in)

**Files:**
- Modify: `scripts/night-shift.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `NIGHT_SHIFT_VISUAL_REPAIR` (default `0`) read into a `VISUAL_REPAIR` constant near `VISUAL_CAPTURE`. When `1`, the `visual_review` stage, after capture+diff, hands over-tolerance screens + brief inputs to the in-session implement agent (the `RUN_VISUAL` primary prompt gains a bounded-repair clause) before signaling stage completion. When `0`, behavior is unchanged.

- [ ] **Step 1: Write the failing test.** Register and add `fixture_visual_repair_optin` asserting the knob is read and the RUN_VISUAL prompt mentions repair only when enabled:

```bash
fixture_visual_repair_optin() {
  # the constant exists and defaults off
  grep -q 'VISUAL_REPAIR="\${NIGHT_SHIFT_VISUAL_REPAIR:-0}"' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  # the RUN_VISUAL guidance gains a repair clause gated on the flag
  grep -q 'NIGHT_SHIFT_VISUAL_REPAIR' "$WORKSPACE_ROOT/scripts/night-shift.sh" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "repair_optin\|repair optin"`
Expected: `not ok`.

- [ ] **Step 3: Implement.** In `scripts/night-shift.sh`: (a) near `VISUAL_CAPTURE="${NIGHT_SHIFT_VISUAL_CAPTURE:-0}"` add:

```bash
# Opt-in visual auto-repair (in-loop). OFF by default: when 1, the visual_review
# stage runs a bounded per-screen repair (implement session edits -> re-capture)
# before completing, instead of leaving all repair to the observer cycle.
VISUAL_REPAIR="${NIGHT_SHIFT_VISUAL_REPAIR:-0}"
```

(b) In the `RUN_VISUAL` guidance block of `primary_prompt`, append a flag-gated clause:

```bash
$( [ "$VISUAL_REPAIR" = "1" ] && cat <<'RC'
- VISUAL REPAIR IS ON: if the engine's visual-diff report marks screens over
  tolerance and attempts remain (NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS, default 3), edit
  ONLY the over-tolerance screens' feature modules (src/features/**; src/ui/** only
  if NIGHT_SHIFT_VISUAL_REPAIR_SHARED=1) toward the Figma frame + its Dev Mode specs
  (mcp__figma__get_figma_data) and pinned comments (Figma REST, if FIGMA_TOKEN),
  keep tsc/eslint clean, then signal RUN_VISUAL again to re-capture. Do not exceed
  the attempt budget; leave residual gaps to the observer.
RC
)
```

- [ ] **Step 4: Run + shellcheck + commit**

```bash
cd ~/work && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"   # expect 0
shellcheck -S error scripts/night-shift.sh
git add scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(night-shift): opt-in in-loop visual_review repair clause"
```

---

### Task 11: Real smoke validation (manual) + docs

**Files:**
- Modify: `CLAUDE.md` (document `--repair`)
- Create: `docs/2026-06-24-visual-auto-repair-validation.md` (record the smoke)

**Interfaces:** none (validation + docs).

> No fixture can exercise a real simulator + `claude -p` + Metro. This task records a manual smoke on a **closeable-gap** screen.

- [ ] **Step 1: Prepare a closeable-gap case.** In a throwaway branch of `water-tracker-app`, perturb one screen by a known, recoverable amount (e.g. change a padding token on `src/features/home/HomeScreen.tsx` so Home drifts ~3–8% from its Figma frame but stays the same layout). Build the preview-enabled dev client.

- [ ] **Step 2: Run repair.**

Run:
```bash
cd ~/work
FIGMA_TOKEN=$(cat ~/.config/figma-token 2>/dev/null) \
scripts/visual-review.sh --project ~/work/water-tracker-app --repair=3 \
  --spec specs/visual-review-validation.md
```
Expected: Metro starts; Home is captured over tolerance; the agent edits `src/features/home/**` only; `tsc`/`eslint` stay green; re-capture shows the diff dropping across attempts; the final pass reports Home within (or closer to) tolerance; edited files are listed uncommitted; Metro stops.

- [ ] **Step 3: Confirm guardrails.** Verify `git -C ~/work/water-tracker-app status --porcelain` shows only `src/features/**` changes, nothing committed, and the report's `attempts[]` records the per-attempt diffs.

- [ ] **Step 4: Document.** Write `docs/2026-06-24-visual-auto-repair-validation.md` with the observed attempt-by-attempt diffs and any `unmet_brief` items. Add a `--repair` blurb to `CLAUDE.md`'s visual-fidelity section.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/2026-06-24-visual-auto-repair-validation.md
git commit -m "docs(visual-repair): --repair docs + real-smoke validation record"
```

---

## Self-Review

**Spec coverage:** §4.1 agent contract → Task 9 (standalone) + Task 10 (in-loop); §4.2 bounded loop → Tasks 4-5; §4.3 Metro harness → Tasks 6, 8; §4.4 standalone → Tasks 7-9; §4.5 in-loop → Task 10; §5 reporting/`unmet_brief` → Task 1; §6 config flags → Tasks 7, 10; §7 guardrails (scope, validate, no-commit, caps) → Tasks 2-5, 9; §8 testing → fixtures in Tasks 1-7,10 + manual smoke Task 11. Brief assembly is the agent's responsibility (Tasks 9-10), consistent with the MCP-is-agent-only constraint.

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands have expected output.

**Type/name consistency:** `visual_repair_scope_check`, `visual_repair_snapshot`/`_restore`, `visual_repair_diff`, `visual_repair_screen`, `visual_repair_run`, `visual_recapture_screen`, `repair_agent`, `repair_validate`, `repair_metro_start`/`_stop` are used consistently across tasks; `visual_assemble_screen`'s new 11th arg `unmet_brief` matches its consumer in Task 4; the `NIGHT_SHIFT_VISUAL_DIFF_FN` test hook is defined (Task 4) before use.

**Staging:** Tasks 1-6 = shared primitive + reporting + recapture (all fixture-tested); 7-9 = standalone surface; 10 = in-loop; 11 = real smoke — matching spec §9.
