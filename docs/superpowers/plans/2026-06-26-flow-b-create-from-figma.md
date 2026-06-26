# Flow B — create-from-Figma Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** When a spec has a `## Design Contract`, the night-shift implement stage follows a build-from-Figma procedure (MCP pull incl. annotations/comments → decompose → reuse-existing → build-missing → assemble) on opus; the existing `visual_review` (Flow A) validates + auto-fixes.

**Architecture:** Two small changes to `scripts/night-shift.sh`: (1) a `spec_has_design_contract` gate + a `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` (default opus) knob wired into `stage_model`'s `implement` scope; (2) a gated `design_build_note` interpolated into `primary_prompt`. Pure prompt + model wiring — no new stage, command, or change to Flow A. Both gated on the `## Design Contract` marker, so non-design specs are byte-identical.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck default severity), the night-shift stage machine + `primary_prompt`. Tests = deterministic fixtures in `scripts/test/fixtures.sh`.

**Spec:** `docs/superpowers/specs/2026-06-26-flow-b-create-from-figma-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/flowb-wt` (branch `feat/flow-b`, off `main`).
- Both the procedure note and the opus bump are gated on `spec_has_design_contract` (a `## Design Contract` line). A spec WITHOUT it: byte-identical prompt, `IMPLEMENT_MODEL` unchanged.
- **Figma MCP only** — the procedure text names `mcp__figma__get_figma_data` / `mcp__figma__download_figma_images`, never `FIGMA_TOKEN`/`api.figma.com`.
- New knob `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` default **opus**; `inherit`/`sonnet` overrides it.
- Only the `implement` scope bumps to opus; `visual`/`observe`/`complete` stay `IMPLEMENT_MODEL`.
- Fixture suite green: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` → `grep -c "not ok"` is `0`.
- Shellcheck default severity: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/night-shift.sh` — the knob (near line 65), `spec_has_design_contract`, `stage_model` (Task 1); `design_build_note` in `primary_prompt` (Task 2).
- **Modify** `scripts/test/fixtures.sh` — extend `fixture_stage_model` (Task 1); add a `primary_prompt` procedure fixture (Task 2).

---

### Task 1: Design-Contract gate + opus implement model

**Files:**
- Modify: `scripts/night-shift.sh` (knob after line 65; new `spec_has_design_contract`; `stage_model` ~line 667)
- Test: `scripts/test/fixtures.sh` (`fixture_stage_model` ~line 1095)

**Interfaces:**
- Produces: `spec_has_design_contract spec` → 0 if the file exists and contains a `^## Design Contract` line, else non-zero (and non-zero for empty/missing path). `DESIGN_IMPLEMENT_MODEL` global (`${NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL:-opus}`). `stage_model implement` → `DESIGN_IMPLEMENT_MODEL` when `spec_has_design_contract "$SPEC"`, else `IMPLEMENT_MODEL`.

- [ ] **Step 1: Write the failing test.** Replace the body of `fixture_stage_model` (it currently does not set `SPEC` or `DESIGN_IMPLEMENT_MODEL`) with this superset — it keeps every existing assertion and adds the Design-Contract ones:

```bash
fixture_stage_model() {
  local root="$1" d="$root/sm"
  mkdir -p "$d"
  # The primary plans on PLAN_MODEL and does post-plan work on IMPLEMENT_MODEL;
  # a ## Design Contract bumps the IMPLEMENT scope to DESIGN_IMPLEMENT_MODEL.
  local PLAN_MODEL=opus IMPLEMENT_MODEL=sonnet DESIGN_IMPLEMENT_MODEL=opus SPEC=""
  printf 'Spec\n\n## Test Plan\n- x\n' >"$d/plain.md"
  printf 'Spec\n\n## Design Contract\n- Figma file: X, fileKey `ABC`\n' >"$d/design.md"
  # No Design Contract -> implement stays IMPLEMENT_MODEL.
  SPEC="$d/plain.md"
  [ "$(stage_model plan)" = "opus" ] || return 1
  [ "$(stage_model implement)" = "sonnet" ] || return 1
  [ "$(stage_model observe)" = "sonnet" ] || return 1
  [ "$(stage_model complete)" = "sonnet" ] || return 1
  [ "$(stage_model bogus)" = "inherit" ] || return 1
  # Empty SPEC also -> IMPLEMENT_MODEL (no contract).
  SPEC=""
  [ "$(stage_model implement)" = "sonnet" ] || return 1
  # Design Contract -> implement bumps to DESIGN_IMPLEMENT_MODEL (opus); other
  # scopes stay IMPLEMENT_MODEL.
  SPEC="$d/design.md"
  [ "$(stage_model implement)" = "opus" ] || return 1
  [ "$(stage_model visual)" = "sonnet" ] || return 1
  [ "$(stage_model observe)" = "sonnet" ] || return 1
  [ "$(stage_model complete)" = "sonnet" ] || return 1
  # inherit values flow straight through.
  PLAN_MODEL=inherit IMPLEMENT_MODEL=inherit DESIGN_IMPLEMENT_MODEL=inherit SPEC="$d/plain.md"
  [ "$(stage_model plan)" = "inherit" ] || return 1
  [ "$(stage_model implement)" = "inherit" ] || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/flowb-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "stage_model tiers"`
Expected: `not ok …` (`stage_model implement` returns `sonnet` for the design spec — opus bump not yet implemented; `spec_has_design_contract`/`DESIGN_IMPLEMENT_MODEL` undefined).

- [ ] **Step 3a: Add the knob.** In `scripts/night-shift.sh`, immediately after the `IMPLEMENT_MODEL=` line (line 65):

```bash
# Design-fidelity implements (a spec with a ## Design Contract) are judgment-heavy
# (decompose a Figma design, reuse/build components, reconcile with real state), so
# the IMPLEMENT scope bumps to this stronger model. inherit/sonnet to override.
DESIGN_IMPLEMENT_MODEL="${NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL:-opus}"
```

- [ ] **Step 3b: Add the gate helper.** In `scripts/night-shift.sh`, just above `stage_model()`:

```bash
# True when the spec declares a ## Design Contract (the marker that also activates the
# Design Fidelity Reviewer + visual_review). Drives the build-from-Figma procedure and
# the opus implement bump. Independent of VISUAL_CAPTURE (the build is design-directed
# even when capture tooling is absent). Empty/missing path -> false.
spec_has_design_contract() {
  [ -n "${1:-}" ] && grep -Eq '^## Design Contract([ \t]|$)' "$1" 2>/dev/null
}
```

- [ ] **Step 3c: Split the `implement` scope in `stage_model`.** Replace:

```bash
    implement|visual|observe|complete) printf '%s' "$IMPLEMENT_MODEL" ;;
```

with:

```bash
    implement)
      if spec_has_design_contract "${SPEC:-}"; then printf '%s' "$DESIGN_IMPLEMENT_MODEL"
      else printf '%s' "$IMPLEMENT_MODEL"; fi ;;
    visual|observe|complete) printf '%s' "$IMPLEMENT_MODEL" ;;
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/flowb-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(night-shift): opus implement for ## Design Contract specs (Flow B gate)"
```

---

### Task 2: The build-from-Figma procedure in `primary_prompt`

**Files:**
- Modify: `scripts/night-shift.sh` (`primary_prompt`, the `cat >"$prompt" <<EOF` heredoc ~line 727)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `spec_has_design_contract` (Task 1); the `$stage` local already computed in `primary_prompt`.
- Produces: `design_build_note` appears in the generated prompt iff the spec has a `## Design Contract` AND `$stage` is `implementation`/`implementation_review`.

- [ ] **Step 1: Write the failing test.** Register after the `fixture_stage_model` line in `run_dry_fixtures` (`fixture_assert "stage_model tiers plan vs the rest of the primary" fixture_stage_model "$root"`):

```bash
  fixture_assert "primary_prompt carries the build-from-Figma procedure iff a Design Contract" fixture_design_build_note "$root"
```

Add the fixture (drives `primary_prompt` with a stubbed STATE at the implementation stage, mirroring the existing prompt fixtures at ~line 1117):

```bash
fixture_design_build_note() {
  local root="$1" dir="$root/dbn"
  mkdir -p "$dir"
  local STATE="$dir/state.json" SPEC="$dir/spec.md" RUN_ID=testrun
  local PROJECT="$dir" BASE_COMMIT=deadbeef RUN_ROOT="$dir"
  printf '{"stage":"implementation","stage_turns":0,"primary_turns":4,"session_id":null}\n' >"$STATE"
  # Design Contract at the implementation stage -> the procedure is present.
  fixture_write_min_spec "$SPEC" "$(printf '## Design Contract\n- Figma file: X, fileKey `ABC`\n- Frames: Home')"
  primary_prompt "$dir/p-design.txt"
  grep -q "Pull the design via the Figma MCP" "$dir/p-design.txt" || return 1
  grep -q "mcp__figma__get_figma_data" "$dir/p-design.txt" || return 1
  grep -q "annotations" "$dir/p-design.txt" || return 1
  grep -q "Reuse what exists" "$dir/p-design.txt" || return 1
  grep -q "real app state" "$dir/p-design.txt" || return 1
  grep -q "FIGMA_TOKEN" "$dir/p-design.txt" && return 1
  # No Design Contract -> the procedure is absent.
  fixture_write_min_spec "$SPEC"
  primary_prompt "$dir/p-plain.txt"
  grep -q "Pull the design via the Figma MCP" "$dir/p-plain.txt" && return 1
  return 0
}
```

Note: `fixture_write_min_spec` (already in `fixtures.sh`) writes a valid `full` rn spec that `primary_prompt`/`resolve_active_personas` accept; appending a `## Design Contract` heading via its `$2` adds the marker. Use it — a bare spec without a Review Profile would `block_run`. Set the locals exactly as the existing prompt fixtures (`fixture_visual_review_prompt` ~line 1140) do: `STATE`, `SPEC`, `RUN_ID`, `PROJECT`, `BASE_COMMIT`, `RUN_ROOT`.

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/flowb-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "build-from-Figma procedure"`
Expected: `not ok …` (the procedure text is not in the prompt yet). If the fixture errors because `primary_prompt` needs another local that the stub STATE doesn't provide, set that variable in the fixture (the existing prompt fixture near line 1117 shows the full set) — do not change `primary_prompt` to suit the test.

- [ ] **Step 3: Add `design_build_note` and interpolate it.** In `primary_prompt`, after the `fi` that closes the `handoff_note` block and BEFORE `cat >"$prompt" <<EOF` (~line 726), compute the note:

```bash
  design_build_note=""
  case "$stage" in
    implementation|implementation_review)
      if spec_has_design_contract "$SPEC"; then
        design_build_note="
Design-fidelity build (this spec has a \`## Design Contract\`). You are building this
screen to match its Figma design. Before/while implementing:
1. Pull the design via the Figma MCP (never a token): mcp__figma__get_figma_data for the
   node's structure (layout, text, sizes, colors, typography, tokens) AND its Dev Mode
   annotations / notes / comments, and mcp__figma__download_figma_images for the frame
   image — open and VIEW it. Treat the annotations and comments as requirements (states,
   spacing rationale, behavior), not just the pixels.
2. Decompose the design into a component breakdown.
3. Reuse what exists: Grep/Glob src/ui/components and src/features/* for components that
   already satisfy each piece and REUSE them; build only what is genuinely missing.
4. Build the missing components to the design (the project's tokens/sizes/spacing from
   src/ui), following the layer boundaries.
5. Assemble them on the screen, wired to real app state (per this spec) — do NOT hardcode
   the Figma's sample values.
6. Keep tsc/eslint/tests green. The engine's visual_review then pixel-diffs your screen
   against the Figma image and auto-repairs the residual — get the structure + tokens
   right here; it tightens the pixels.
"
      fi ;;
  esac
```

Declare the local: add `design_build_note` to one of `primary_prompt`'s existing `local` lines (e.g. the line declaring `handoff_note`).

Then reference it inside the `cat >"$prompt" <<EOF` heredoc by adding a line immediately after `Base commit: $BASE_COMMIT`:

```bash
Base commit: $BASE_COMMIT
$design_build_note
```

(For non-design specs `design_build_note` is empty → a blank line, leaving the prompt effectively unchanged.)

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/flowb-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run (MCP-only sanity): `grep -n "get_figma_data\|download_figma_images" scripts/night-shift.sh | head` → Expected: the procedure names both MCP tools.

- [ ] **Step 5: Commit.**

```bash
git add scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(night-shift): build-from-Figma procedure in the implement prompt (Flow B)"
```

---

## Self-Review

**Spec coverage:** §3.1 build-from-Figma procedure (incl. annotations/comments, reuse-existing, real state) → Task 2; §3.2 opus for Design-Contract implement + `spec_has_design_contract` + `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` → Task 1; §3.3 gate (same `## Design Contract` marker, non-design byte-identical) → both tasks' gating + the no-contract fixture branches; §5 fixtures (procedure iff Design Contract + key phrases + MCP-only; opus iff Design Contract) → Tasks 1-2.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `spec_has_design_contract` (Task 1) is consumed by both `stage_model` (Task 1) and `design_build_note` (Task 2); `DESIGN_IMPLEMENT_MODEL` is the one knob; the procedure's asserted phrases ("Pull the design via the Figma MCP", "Reuse what exists", "real app state", "annotations", `mcp__figma__get_figma_data`) match the note text in Task 2 verbatim; the `implement`/`visual`/`observe`/`complete` scope names match `stage_model`.

**Shellcheck:** the `case`/`if` blocks, `grep -Eq`, and the heredoc `$design_build_note` interpolation are standard bash; the note text escapes the backticks (`\`## Design Contract\``) so the heredoc does not run a command substitution.
