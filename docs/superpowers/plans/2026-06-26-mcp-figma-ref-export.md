# MCP Figma Reference Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the engine export Figma reference images autonomously via the Figma MCP (no `FIGMA_TOKEN`/REST, no hand-staging), on both the standalone `visual-review.sh` and the in-loop night-shift `visual_review`.

**Architecture:** A single-node primitive `visual_stage_ref` (spawns `claude -p` with `mcp__figma__download_figma_images`) in `scripts/lib/visual-capture.sh`, plus a shared matrix loop `visual_stage_refs_for_spec` in `scripts/lib/visual-repair.sh` (it uses `figma_key_for`/`node_id_for` which live there). Both surfaces call the shared loop; the token/REST `stage_ref` is deleted.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck-clean at default severity), `claude -p`, the Figma MCP. Tests = deterministic fixtures in `scripts/test/fixtures.sh` (stub binaries on PATH, mirroring `fixture_visual_capture_file_drive`).

**Spec:** `docs/superpowers/specs/2026-06-26-mcp-figma-ref-export-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/mcpref-wt` (branch `feat/mcp-figma-ref-export`, off `main`).
- **Figma MCP only — never a token/REST.** The end state has no `FIGMA_TOKEN` or `api.figma.com` anywhere in `scripts/`.
- `claude -p` invocation form (proven): prompt via **STDIN**; `--allowed-tools` a single tool name (no comma needed for one tool); model knob `NIGHT_SHIFT_VISUAL_REF_MODEL` (default `claude-haiku-4-5`).
- **Degrade cleanly:** a failed export returns non-zero; callers `|| true` per ref and SKIP ref-less screens (existing behavior). No regression when Figma/claude is absent.
- Fixture suite: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` — pass = `grep -c "not ok"` is `0`.
- Shellcheck **default severity**: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/lib/visual-capture.sh` — add `visual_stage_ref` (Task 1).
- **Modify** `scripts/lib/visual-repair.sh` — add `visual_stage_refs_for_spec` (Task 2).
- **Modify** `scripts/visual-review.sh` — call the shared loop; delete `stage_ref` + `stage_refs_for_spec`; update `--help` (Task 3).
- **Modify** `scripts/night-shift.sh` — `run_visual` stages refs before `run_visual_capture` (Task 4).
- **Modify** `scripts/test/fixtures.sh` — fixtures for Tasks 1-3.

---

### Task 1: `visual_stage_ref` — single-node MCP export

**Files:**
- Modify: `scripts/lib/visual-capture.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `visual_stage_ref key node out` → exports the Figma node PNG to `out` via the MCP; returns 0 when `out` exists (caches if already present), non-zero when `key`/`node` empty or `claude`/MCP/download unavailable.

- [ ] **Step 1: Write the failing test.** Register after the file-drive fixture line (`fixture_assert "visual capture file-drive writes target + cold-launches prompt-free" fixture_visual_capture_file_drive "$root"`):

```bash
  fixture_assert "visual_stage_ref exports a Figma node via the MCP (claude -p), caches, degrades" fixture_visual_stage_ref "$root"
```

Add the fixture (a `claude` stub that reads the prompt from stdin, extracts the `.png` target path, writes a byte):

```bash
fixture_visual_stage_ref() {
  local root="$1" d="$root/vsr"
  mkdir -p "$d/bin"
  cat >"$d/bin/claude" <<STUB
#!/usr/bin/env bash
printf 'called\n' >>"$d/claude.log"
p="\$(cat)"   # prompt via stdin
out="\$(printf '%s' "\$p" | grep -oE '/[^ ]+\.png' | head -1)"
[ -n "\$out" ] && printf x >"\$out"
exit 0
STUB
  chmod +x "$d/bin/claude"
  # (a) stages via MCP: out doesn't exist -> claude stub writes it.
  (
    export PATH="$d/bin:$PATH"
    visual_stage_ref ABC123 1:1548 "$d/design/Home-default-iphone-15.png" || exit 1
    [ -s "$d/design/Home-default-iphone-15.png" ] || exit 1
    grep -q called "$d/claude.log" || exit 1
  ) || return 1
  # (b) caches: out already exists -> returns 0 WITHOUT calling claude.
  : >"$d/claude.log"
  (
    export PATH="$d/bin:$PATH"
    visual_stage_ref ABC123 1:1548 "$d/design/Home-default-iphone-15.png" || exit 1
    [ -s "$d/claude.log" ] && exit 1   # claude must NOT have been called
    exit 0
  ) || return 1
  # (c) degrades: no claude on PATH -> non-zero, no file.
  (
    export PATH="/usr/bin:/bin"
    visual_stage_ref ABC123 1:1548 "$d/n.png"; [ "$?" -ne 0 ] || exit 1
    [ -e "$d/n.png" ] && exit 1
    exit 0
  ) || return 1
  # (d) empty key/node -> non-zero.
  ( export PATH="$d/bin:$PATH"; visual_stage_ref "" 1:1548 "$d/e.png"; [ "$?" -ne 0 ] || exit 1 ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "visual_stage_ref exports"`
Expected: `not ok …` (`visual_stage_ref` is not defined).

- [ ] **Step 3: Add `visual_stage_ref`.** In `scripts/lib/visual-capture.sh`, add (e.g. just before `visual_capture_screens`):

```bash
# Export a Figma node's PNG to $out via the Figma MCP (no token, no REST). Spawns a
# cheap `claude -p` whose only tool is mcp__figma__download_figma_images. Caches when
# $out already exists. Returns non-zero (degrade cleanly) when claude/MCP/download is
# unavailable, so callers SKIP rather than fail.
visual_stage_ref() {
  local key="$1" node="$2" out="$3" dir base prompt
  [ -s "$out" ] && return 0
  [ -n "$key" ] && [ -n "$node" ] || return 1
  command -v claude >/dev/null 2>&1 || { log "  no claude CLI — cannot MCP-export Figma $node"; return 1; }
  dir="$(dirname "$out")"; base="$(basename "$out")"; mkdir -p "$dir" || return 1
  prompt="Use the mcp__figma__download_figma_images tool to download fileKey ${key} node ${node} as a PNG (pngScale 2) to localPath \"${dir}\" with fileName \"${base}\" — i.e. exactly the file ${out}. Use ONLY that tool; never a Figma token or REST. Reply 'done' once the file exists."
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --output-format json --allowed-tools "mcp__figma__download_figma_images" >/dev/null 2>&1 ) || true
  [ -s "$out" ]
}
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "feat(visual-capture): visual_stage_ref — export a Figma node PNG via the MCP"
```

---

### Task 2: `visual_stage_refs_for_spec` — the shared matrix loop

**Files:**
- Modify: `scripts/lib/visual-repair.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_stage_ref` (Task 1); `figma_key_for`/`node_id_for` (already in visual-repair.sh); `visual_capture_screens` (visual-capture.sh).
- Produces: `visual_stage_refs_for_spec spec out_dir` → for each `screen|state|device` in the spec's Design Contract, exports `out_dir/design/<screen>-<state>-<device>.png` via `visual_stage_ref` (skips already-staged; `|| true` per ref). Returns 0; no fileKey → 0 (nothing to stage).

- [ ] **Step 1: Write the failing test.** Register after the Task-1 fixture line:

```bash
  fixture_assert "visual_stage_refs_for_spec stages the Design-Contract matrix via the MCP" fixture_visual_stage_refs_for_spec "$root"
```

Add the fixture (a minimal Design-Contract spec + the same `claude` stub idea):

```bash
fixture_visual_stage_refs_for_spec() {
  local root="$1" d="$root/vsrs"
  mkdir -p "$d/bin" "$d/out"
  cat >"$d/bin/claude" <<STUB
#!/usr/bin/env bash
out="\$(cat | grep -oE '/[^ ]+\.png' | head -1)"; [ -n "\$out" ] && printf x >"\$out"; exit 0
STUB
  chmod +x "$d/bin/claude"
  cat >"$d/spec.md" <<'SPEC'
## Design Contract
- Figma file: Demo, fileKey `ABC123`
- Frames: Home
- Figma node IDs: Home = `1:1548`
- Devices: iphone-15
- Required states: default
- Tolerance: 0.12
SPEC
  (
    export PATH="$d/bin:$PATH"
    visual_stage_refs_for_spec "$d/spec.md" "$d/out"
    [ -s "$d/out/design/Home-default-iphone-15.png" ] || exit 1
  ) || return 1
  # no fileKey -> returns 0, stages nothing.
  printf '## Design Contract\n- Frames: Home\n- Devices: iphone-15\n- Required states: default\n' >"$d/nokey.md"
  ( export PATH="$d/bin:$PATH"; visual_stage_refs_for_spec "$d/nokey.md" "$d/out2" || exit 1; [ -d "$d/out2/design" ] && [ -n "$(ls -A "$d/out2/design" 2>/dev/null)" ] && exit 1; exit 0 ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "stages the Design-Contract matrix"`
Expected: `not ok …` (function not defined).

- [ ] **Step 3: Add `visual_stage_refs_for_spec`.** In `scripts/lib/visual-repair.sh` (near `figma_key_for`/`node_id_for`), add:

```bash
# Stage every Design-Contract screen's Figma reference into $out_dir/design/ via the
# MCP (visual_stage_ref). Used by both visual-review.sh and the in-loop run_visual.
visual_stage_refs_for_spec() {
  local spec="$1" out_dir="$2" key screen state device ref
  key="$(figma_key_for "$spec")"
  [ -n "$key" ] || { log "  no fileKey in $spec Design Contract; skipping refs"; return 0; }
  while IFS='|' read -r screen state device; do
    [ -n "$screen" ] || continue
    ref="$out_dir/design/${screen}-${state}-${device}.png"
    [ -s "$ref" ] && continue
    visual_stage_ref "$key" "$(node_id_for "$spec" "$screen")" "$ref" || true
  done < <(visual_capture_screens "$spec")
}
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): visual_stage_refs_for_spec — MCP-stage the Design-Contract matrix"
```

---

### Task 3: Rewire `visual-review.sh` (delete the token/REST path)

**Files:**
- Modify: `scripts/visual-review.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_stage_refs_for_spec` (Task 2).

- [ ] **Step 1: Write the failing test.** Register after the Task-2 fixture line:

```bash
  fixture_assert "visual-review.sh exports refs via the MCP, no FIGMA_TOKEN/REST" fixture_visual_review_no_token "$root"
```

Add:

```bash
fixture_visual_review_no_token() {
  local f="$WORKSPACE_ROOT/scripts/visual-review.sh"
  grep -q "FIGMA_TOKEN" "$f" && return 1
  grep -q "api.figma.com" "$f" && return 1
  grep -q "visual_stage_refs_for_spec" "$f" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "no FIGMA_TOKEN/REST"`
Expected: `not ok …` (`FIGMA_TOKEN`/`api.figma.com` still present, `visual_stage_refs_for_spec` not called).

- [ ] **Step 3: Rewire.** In `scripts/visual-review.sh`:
(a) **Delete** the entire `stage_ref()` function (the `FIGMA_TOKEN` + `curl api.figma.com` retry loop).
(b) **Delete** the entire `stage_refs_for_spec()` function (its loop now lives in the shared `visual_stage_refs_for_spec`).
(c) At the staging call site, change `stage_refs_for_spec "$spec" "$out_dir"` to `visual_stage_refs_for_spec "$spec" "$out_dir"`.
(d) Update the `--help` prerequisites block — replace the two `FIGMA_TOKEN` lines:
```
#   - For reference export (unless --no-refs): FIGMA_TOKEN (a Figma personal access
#     token). Without it, pre-stage references yourself under <out>/design/.
```
with:
```
#   - For reference export (unless --no-refs): the Figma MCP (the `claude` CLI with
#     `mcp__figma__download_figma_images`). Without it, pre-stage references under
#     <out>/design/.
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run: `grep -rl "FIGMA_TOKEN\|api.figma.com" scripts/ --include='*.sh' | grep -v '/test/' ; echo "(empty above = clean)"` → Expected: empty (the only remaining match is the `fixtures.sh` assertion itself, excluded by `/test/`).

- [ ] **Step 5: Commit.**

```bash
git add scripts/visual-review.sh scripts/test/fixtures.sh
git commit -m "refactor(visual-review): stage refs via the MCP (delete the FIGMA_TOKEN/REST path)"
```

---

### Task 4: Wire the in-loop `run_visual` to stage refs

**Files:**
- Modify: `scripts/night-shift.sh`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: `visual_stage_refs_for_spec` (Task 2). `night-shift.sh` already sources both libs.

- [ ] **Step 1: Write the failing test.** Register after the Task-3 fixture line:

```bash
  fixture_assert "in-loop run_visual stages refs via the MCP before capture" fixture_run_visual_stages_refs "$root"
```

Add (structural — `run_visual` is too deep to invoke in isolation, but the wiring must be present and ordered):

```bash
fixture_run_visual_stages_refs() {
  local body
  body="$(sed -n '/^run_visual()/,/^}/p' "$WORKSPACE_ROOT/scripts/night-shift.sh")"
  printf '%s' "$body" | grep -q 'visual_stage_refs_for_spec "$SPEC" "$RUN_ROOT/validated"' || return 1
  # staging must come BEFORE the capture call.
  local sline cline
  sline="$(printf '%s\n' "$body" | grep -n 'visual_stage_refs_for_spec' | head -1 | cut -d: -f1)"
  cline="$(printf '%s\n' "$body" | grep -n 'run_visual_capture "$SPEC"' | head -1 | cut -d: -f1)"
  [ -n "$sline" ] && [ -n "$cline" ] && [ "$sline" -lt "$cline" ] || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "in-loop run_visual stages refs"`
Expected: `not ok …` (no staging call in `run_visual`).

- [ ] **Step 3: Wire it.** In `scripts/night-shift.sh`, in `run_visual`, insert the staging call immediately **before** the `run_visual_capture "$SPEC" "$candidate" "$RUN_ROOT/validated" || true` line:

```bash
  visual_stage_refs_for_spec "$SPEC" "$RUN_ROOT/validated"
```

(So the block reads: `… || block_run "…"` then `visual_stage_refs_for_spec "$SPEC" "$RUN_ROOT/validated"` then `run_visual_capture "$SPEC" "$candidate" "$RUN_ROOT/validated" || true`.)

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/mcpref-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(night-shift): in-loop run_visual MCP-stages Design-Contract refs before capture"
```

---

## Self-Review

**Spec coverage:** §3 `visual_stage_ref` → Task 1; §4 standalone wiring + delete token path + --help → Task 3 (using the shared loop from Task 2); §5 in-loop wiring → Task 4; the shared matrix loop (DRY improvement noted in the plan header) → Task 2; §6 degradation → Task 1 fixture (c)/(d) + the `|| true` in Task 2; §7 fixtures → Tasks 1-4.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `visual_stage_ref key node out` and `visual_stage_refs_for_spec spec out_dir` are used identically across Tasks 1-4; the `out_dir/design/<screen>-<state>-<device>.png` path form matches `run_visual_capture`'s `ref="design/${screen}-${state}-${device}.png"`; `NIGHT_SHIFT_VISUAL_REF_MODEL` is the one model knob. The deleted `stage_ref`/`stage_refs_for_spec` are replaced at the single call site by `visual_stage_refs_for_spec`.

**Shellcheck:** every code task runs the default-severity gate; the `claude -p` heredoc-free invocation + the `< <(…)` process substitution + the `while IFS='|' read` are all standard bash, shellcheck-clean.
