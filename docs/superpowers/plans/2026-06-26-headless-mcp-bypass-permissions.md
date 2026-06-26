# Headless-MCP Permission Fix + Figma-Data Caching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the engine's design-fidelity `claude -p` agents actually execute their MCP tools in headless mode (`--permission-mode bypassPermissions`), run the repair agent on opus, and fetch the Figma design data once per run (cached) instead of per attempt.

**Architecture:** `visual_stage_ref` gains the permission flag. A new `visual_stage_figma_data` fetches `get_figma_data` once per run into a cache file (with the flag). The repair agent reads that cache, drops the MCP tool from its allowlist (so it no longer needs the flag), and gains an opus `--model` knob. The orchestration pre-fetches the cache per screen. Argv-aware stub fixtures assert the flag/model/caching wiring.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck default severity), `claude -p`, the Figma MCP. Tests = deterministic fixtures in `scripts/test/fixtures.sh` (argv-recording stub on PATH).

**Spec:** `docs/superpowers/specs/2026-06-26-headless-mcp-bypass-permissions-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/bypass-wt` (branch `feat/headless-mcp-bypass`, off `main`).
- **MCP `claude -p` calls require `--permission-mode bypassPermissions`** — headless defers MCP tools otherwise (proven). Matches the primary (`night-shift.sh:887,890`).
- **Figma MCP only** — no `FIGMA_TOKEN`/`api.figma.com` anywhere.
- `claude -p` form: prompt via **STDIN**; `--allowed-tools` comma-separated.
- New knob `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` default **`claude-opus-4-8`**; `=sonnet`/`=inherit` overrides.
- Degrade cleanly: a failed fetch returns non-zero; the agent then works from the images.
- Fixture suite green: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` → `grep -c "not ok"` is `0`.
- Shellcheck default severity: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` exit `0`.

## File Structure

- **Modify** `scripts/lib/visual-capture.sh` — `visual_stage_ref` flag (Task 1).
- **Modify** `scripts/lib/visual-repair.sh` — `visual_stage_figma_data` (Task 2); `repair_agent` rewire + `_repair_one` pre-fetch (Task 3).
- **Modify** `scripts/test/fixtures.sh` — argv-aware `fixture_visual_stage_ref` (Task 1); `fixture_visual_stage_figma_data` (Task 2); repair-agent structural fixture (Task 3).
- **Modify** `CLAUDE.md` — visual-fidelity doc (Task 4).

---

### Task 1: `visual_stage_ref` permission flag + argv-aware fixture

**Files:**
- Modify: `scripts/lib/visual-capture.sh` (`visual_stage_ref` `claude -p`, ~line 48)
- Test: `scripts/test/fixtures.sh` (`fixture_visual_stage_ref`)

**Interfaces:**
- Produces: `visual_stage_ref`'s `claude -p` now passes `--permission-mode bypassPermissions`.

- [ ] **Step 1: Make the fixture argv-aware + assert the flag.** Replace `fixture_visual_stage_ref`'s `claude` stub and case (a)/(b) so it records argv and asserts the flag. The stub becomes:

```bash
  cat >"$d/bin/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$d/argv.log"
p="\$(cat)"   # prompt via stdin
out="\$(printf '%s' "\$p" | grep -oE '/[^ ]+\.png' | head -1)"
[ -n "\$out" ] && printf x >"\$out"
exit 0
STUB
```

Case (a) (after the `[ -s … ]` line) replace `grep -q called "$d/claude.log" || exit 1` with:

```bash
    grep -q -- '--permission-mode bypassPermissions' "$d/argv.log" || exit 1
```

Case (b) replace `: >"$d/claude.log"` with `: >"$d/argv.log"` and `[ -s "$d/claude.log" ] && exit 1` with `[ -s "$d/argv.log" ] && exit 1`. (Cases (c)/(d) unchanged.)

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "visual_stage_ref exports"`
Expected: `not ok …` (the flag is not yet in the invocation, so the argv assertion fails).

- [ ] **Step 3: Add the flag.** In `scripts/lib/visual-capture.sh`, in `visual_stage_ref`, change its `claude -p` to:

```bash
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "mcp__figma__download_figma_images" >/dev/null 2>&1 ) || true
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-capture.sh scripts/test/fixtures.sh
git commit -m "fix(visual-capture): visual_stage_ref MCP export needs --permission-mode bypassPermissions"
```

---

### Task 2: `visual_stage_figma_data` (fetch the node data once, cached)

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (new function)
- Test: `scripts/test/fixtures.sh` (`fixture_visual_stage_figma_data`)

**Interfaces:**
- Produces: `visual_stage_figma_data key node cache` → fetches `get_figma_data` for the node via `claude -p` (`--permission-mode bypassPermissions`, `--allowed-tools "Write,mcp__figma__get_figma_data"`) and writes design notes to `cache`; returns 0 when `cache` exists (caches if already present); non-zero when key/node empty or claude unavailable.

- [ ] **Step 1: Write the failing test.** Register after the Task-1 fixture line in `run_dry_fixtures` (`fixture_assert "visual_stage_ref exports a Figma node via the MCP (claude -p), caches, degrades" fixture_visual_stage_ref "$root"`):

```bash
  fixture_assert "visual_stage_figma_data caches the node's Figma design data via the MCP" fixture_visual_stage_figma_data "$root"
```

Add the fixture (argv-aware stub that writes the `.md` cache parsed from the prompt):

```bash
fixture_visual_stage_figma_data() {
  local root="$1" d="$root/vsfd"
  mkdir -p "$d/bin"
  cat >"$d/bin/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$d/argv.log"
p="\$(cat)"
out="\$(printf '%s' "\$p" | grep -oE '/[^ ]+\.md' | head -1)"
[ -n "\$out" ] && printf 'specs\n' >"\$out"
exit 0
STUB
  chmod +x "$d/bin/claude"
  # (a) fetches + caches the node data, with the flag + get_figma_data tool.
  (
    export PATH="$d/bin:$PATH"
    visual_stage_figma_data ABC123 1:1548 "$d/design/Home-figma.md" || exit 1
    [ -s "$d/design/Home-figma.md" ] || exit 1
    grep -q -- '--permission-mode bypassPermissions' "$d/argv.log" || exit 1
    grep -q 'mcp__figma__get_figma_data' "$d/argv.log" || exit 1
  ) || return 1
  # (b) caches: file exists -> returns 0 WITHOUT calling claude.
  : >"$d/argv.log"
  ( export PATH="$d/bin:$PATH"; visual_stage_figma_data ABC123 1:1548 "$d/design/Home-figma.md" || exit 1; [ -s "$d/argv.log" ] && exit 1; exit 0 ) || return 1
  # (c) degrades: no claude -> non-zero, no file.
  ( export PATH="/usr/bin:/bin"; ! visual_stage_figma_data ABC123 1:1548 "$d/n.md" || exit 1; [ -e "$d/n.md" ] && exit 1; exit 0 ) || return 1
  # (d) empty key/node -> non-zero.
  ( export PATH="$d/bin:$PATH"; ! visual_stage_figma_data "" 1:1548 "$d/e.md" || exit 1 ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "caches the node's Figma design data"`
Expected: `not ok …` (function not defined).

- [ ] **Step 3: Add `visual_stage_figma_data`.** In `scripts/lib/visual-repair.sh`, near `figma_key_for`/`node_id_for`, add:

```bash
# Fetch node $node's Figma design data (Dev Mode specs + annotations) via the MCP and
# write concise design notes to $cache, ONCE — the repair agent then Reads $cache each
# attempt instead of calling get_figma_data live (cuts Figma API volume; avoids 429).
# Caches (skips if $cache exists). Degrades cleanly (non-zero) if claude/MCP unavailable.
visual_stage_figma_data() {
  local key="$1" node="$2" cache="$3" prompt
  [ -s "$cache" ] && return 0
  [ -n "$key" ] && [ -n "$node" ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$cache")" || return 1
  prompt="Call mcp__figma__get_figma_data for node ${node} in file ${key}. Then use the Write tool to write its Dev Mode specs (sizes, spacing, colors, typography, tokens) AND any annotations/comments to the file ${cache} as concise design notes. Figma is accessed ONLY through the MCP; never a token or REST. Reply 'done' once the file exists."
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "Write,mcp__figma__get_figma_data" >/dev/null 2>&1 ) || true
  [ -s "$cache" ]
}
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): visual_stage_figma_data — cache get_figma_data once per run"
```

---

### Task 3: Repair agent reads the cache (drops the MCP tool, opus model) + pre-fetch

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`repair_agent`, `_repair_one` inside `visual_repair_for_spec`)
- Test: `scripts/test/fixtures.sh` (`fixture_repair_agent_cached`)

**Interfaces:**
- Consumes: `visual_stage_figma_data` (Task 2).

- [ ] **Step 1: Write the failing test (structural — `repair_agent` needs `$PROJECT`/prompt vars).** Register after the Task-2 fixture line:

```bash
  fixture_assert "repair_agent runs on the opus knob + reads the cached Figma data (no live get_figma_data)" fixture_repair_agent_cached "$root"
```

Add:

```bash
fixture_repair_agent_cached() {
  local body
  body="$(sed -n '/^repair_agent()/,/^}/p' "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh")"
  # opus model knob present
  printf '%s' "$body" | grep -q 'NIGHT_SHIFT_VISUAL_REPAIR_MODEL' || return 1
  # MCP get_figma_data dropped from the agent's allowlist
  printf '%s' "$body" | grep -q 'mcp__figma__get_figma_data' && return 1
  # the agent reads the per-screen Figma cache
  printf '%s' "$body" | grep -q '\-figma\.md' || return 1
  # the pre-fetch CALL (not just the definition) is wired into the orchestration
  grep -qF 'visual_stage_figma_data "$REPAIR_FILEKEY"' "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh" || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "reads the cached Figma data"`
Expected: `not ok …` (the agent still names `get_figma_data` and has no model knob / cache read).

- [ ] **Step 3a: Rewire `repair_agent`.** In `scripts/lib/visual-repair.sh` `repair_agent`, after the `key=…; node=…` line add:

```bash
  local cache="$out_dir/design/$screen-figma.md"
```

Replace the prompt's get_figma_data line:

```
Pull the Figma design for node $node in file $key via mcp__figma__get_figma_data — its Dev Mode specs (sizes, spacing, colors, typography, tokens) AND any annotations/comments the MCP exposes — and treat them as requirements. Figma is accessed ONLY through the MCP; never use a Figma token or REST API.
```

with:

```
Read the cached Figma design notes at $cache (the node's Dev Mode specs — sizes, spacing, colors, typography, tokens — and annotations/comments) and treat them as requirements. If that file is absent, work from the images. Figma is accessed ONLY through the MCP; never use a Figma token or REST API.
```

Change the `claude -p` to add the model and drop the MCP tool:

```bash
  result="$(cd "$PROJECT" && printf '%s' "$prompt" | claude -p --output-format json \
    --model "${NIGHT_SHIFT_VISUAL_REPAIR_MODEL:-claude-opus-4-8}" \
    --allowed-tools "Read,Edit,Write,Bash(npx tsc*),Bash(npx eslint*)" 2>/dev/null)"
```

- [ ] **Step 3b: Pre-fetch the cache in `_repair_one`.** In `visual_repair_for_spec`, inside `_repair_one`, after the `eval "REPAIR_NODE_$sc=…"` line add:

```bash
    visual_stage_figma_data "$REPAIR_FILEKEY" "$(node_id_for "$spec" "$sc")" \
      "$out_dir/design/$sc-figma.md" || true
```

- [ ] **Step 4: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/bypass-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0`
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`
Run (MCP-only): `grep -rl "FIGMA_TOKEN\|api.figma.com" scripts/ --include='*.sh' | grep -v '/test/' ; echo "(empty = clean)"` → Expected empty.

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): repair agent reads cached Figma data on opus (no per-attempt get_figma_data)"
```

---

### Task 4: Document the knob + the bypassPermissions requirement

**Files:**
- Modify: `CLAUDE.md` (visual-fidelity section, ~line 79)

- [ ] **Step 1: Update the doc.** In `CLAUDE.md`, in the `- **Visual fidelity (opt-in):**` bullet, append these two sentences to the end of that bullet's prose (before the next `- **` bullet):

```markdown
  The repair agent runs on `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default `opus` — design
  fidelity is judgment-heavy; `=sonnet`/`=inherit` overrides). The engine's headless MCP
  `claude -p` calls (Figma reference export + the per-run `get_figma_data` fetch) run
  with `--permission-mode bypassPermissions` — MCP tools are otherwise deferred in
  headless — and the repair flow fetches `get_figma_data` once per run (cached under
  `design/<screen>-figma.md`) to bound Figma API volume.
```

- [ ] **Step 2: Verify + commit.**

Run: `cd /Users/alessandrogentil/bypass-wt && grep -c "NIGHT_SHIFT_VISUAL_REPAIR_MODEL" CLAUDE.md` → Expected `≥1`

```bash
git add CLAUDE.md
git commit -m "docs: NIGHT_SHIFT_VISUAL_REPAIR_MODEL + headless bypassPermissions + figma-data caching"
```

---

## Self-Review

**Spec coverage:** §3.1 `visual_stage_ref` flag → Task 1; §3.2 `visual_stage_figma_data` → Task 2; §3.3 repair-agent rewire (cache read, drop MCP tool, opus model) → Task 3; §3.4 `_repair_one` pre-fetch → Task 3; §3.5 safety (tight allowlists) → preserved by the allowlist edits in Tasks 1-3; §4 tests (argv stub asserts the flag; new fetch fixture; repair structural) → Tasks 1-3; §5 docs → Task 4.

**Placeholder scan:** every code step shows full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `visual_stage_figma_data key node cache` (Task 2) consumed by `_repair_one` (Task 3) with `cache=$out_dir/design/$sc-figma.md`, matching `repair_agent`'s `cache=$out_dir/design/$screen-figma.md` (`$sc`=`$screen`); `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` default `claude-opus-4-8` is identical across the agent, the spec, and the doc; `NIGHT_SHIFT_VISUAL_REF_MODEL` (haiku) is the fetch model for both `visual_stage_ref` and `visual_stage_figma_data`.

**Shellcheck:** the argv-recording stub (`printf '%s\n' "$*"`), the `grep -q --` flag-literal checks, and the `[ -s … ] && return 0` cache guards are standard bash, shellcheck-clean.
