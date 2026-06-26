# Headless-MCP permission fix + Figma-data caching — design

Date: 2026-06-26. Repo: `night-shift-engine`. Fixes a bug found by the live
design-fidelity test ([[headless-mcp-bypass-permissions]]) and cuts the Figma call
volume that exhausted the API quota (the 429).

## 1. Problem (proven by the live test)

- In headless `claude -p`, MCP server tools are **deferred** — a plain `claude -p`
  reports `mcp__figma__*` as **NONE**. They execute only when the invocation passes
  **`--permission-mode bypassPermissions`** AND names them in `--allowed-tools`.
  **Proven:** `download_figma_images` failed with `--allowed-tools` alone, then executed
  (reaching a Figma 429) once the flag was added. CORE tools (Read/Edit/Write/Bash) DO
  run headless without the flag — only **MCP** tools need it.
- Two engine sites lack the flag: `visual_stage_ref` (`visual-capture.sh`,
  `download_figma_images`) and the repair agent (`visual-repair.sh`, `get_figma_data`).
  The fixtures **stub `claude`**, so the broken invocation was never exercised.
- The repair agent calls `get_figma_data` on **every attempt** — the most expensive
  repeat Figma call, a primary contributor to the 429 (Figma rate-limits per token; the
  MCP server holds a Starter-tier token, ~2.2-day reset).
- The PRIMARY night-shift already uses `--permission-mode bypassPermissions`
  (`night-shift.sh:887,890`) — the fix matches an existing, proven pattern.

## 2. Goal / non-goals

**Goal:** the engine's MCP `claude -p` calls actually execute their MCP tools in
headless mode; the repair agent runs on opus by default and fetches the Figma design
data **once per run** (cached), not per attempt; with tests that assert the flag, the
model, and the caching wiring.

**Non-goals:** the Figma 429 itself (external account/plan limit); diff noise-masking
(separate follow-up); the primary night-shift `claude -p` (already correct).

## 3. Changes (Approach A — engine pre-fetches the Figma data once)

### 3.1 `visual_stage_ref` (`scripts/lib/visual-capture.sh`)

Add `--permission-mode bypassPermissions` to its `claude -p` (model knob unchanged — a
one-shot download stays on the cheap `NIGHT_SHIFT_VISUAL_REF_MODEL`, default haiku):

```bash
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "mcp__figma__download_figma_images" >/dev/null 2>&1 ) || true
```

### 3.2 New `visual_stage_figma_data` (`scripts/lib/visual-repair.sh`)

Fetch the node's design data via the MCP **once**, cached to a file:

```bash
# Fetch node $node's Figma design data (Dev Mode specs + annotations) via the MCP and
# write concise design notes to $cache, ONCE — the repair agent then Reads $cache each
# attempt instead of calling get_figma_data live (cuts Figma API volume; avoids 429).
# Caches (skips if $cache exists). Degrades cleanly (returns non-zero) if claude/MCP
# unavailable — the agent then works from the images alone.
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

### 3.3 Repair agent (`scripts/lib/visual-repair.sh` `repair_agent`)

The agent reads the cache instead of calling the MCP, runs on opus, and no longer needs
`bypassPermissions`:
- Add `local cache="$out_dir/design/$screen-figma.md"`.
- Prompt line change: replace *"Pull the Figma design for node $node in file $key via
  mcp__figma__get_figma_data — its Dev Mode specs … AND any annotations/comments …"*
  with: *"Read the cached Figma design notes at $cache (the node's Dev Mode specs —
  sizes, spacing, colors, typography, tokens — and annotations/comments) and treat them
  as requirements. (If that file is absent, work from the images.) Figma is accessed
  ONLY through the MCP; never a token or REST."*
- `--allowed-tools` **drops** `mcp__figma__get_figma_data` →
  `"Read,Edit,Write,Bash(npx tsc*),Bash(npx eslint*)"`.
- Add the model knob: `--model "${NIGHT_SHIFT_VISUAL_REPAIR_MODEL:-claude-opus-4-8}"`
  (design-fidelity repair is judgment-heavy — [[opus-for-design-fidelity]]; `=sonnet`/
  `=inherit` overrides; a cost knob). No `bypassPermissions` (no MCP tool; core tools
  run headless without it).

### 3.4 Pre-fetch in the orchestration (`visual_repair_for_spec` `_repair_one`)

`_repair_one` runs once per failing screen, before its attempt loop. Add, after the
node is resolved there:

```bash
    visual_stage_figma_data "$REPAIR_FILEKEY" "$(node_id_for "$spec" "$sc")" \
      "$out_dir/design/$sc-figma.md" || true
```

So the Figma data is fetched once per screen per run; every attempt's `repair_agent`
then Reads the cached `$out_dir/design/$sc-figma.md`.

### 3.5 Safety

Consistent with the primary's existing `bypassPermissions` usage. Tight `--allowed-tools`
allowlists bound each agent: `visual_stage_ref` → only the image download;
`visual_stage_figma_data` → only `Write` + `get_figma_data`; the repair agent → core
Read/Edit/Write + `npx tsc`/`eslint` (no MCP), edits constrained to `src/features`
(`src/ui` under `--repair-shared`).

## 4. Testing

Deterministic fixtures (stub `claude` on PATH — now argv-aware):

- **`fixture_visual_stage_ref` (update):** the `claude` stub records its argv to a file;
  assert the recorded argv contains `--permission-mode bypassPermissions` (plus the
  existing: stages the PNG, caches, degrades, empty key/node → non-zero). The regression
  test that would have caught the bug.
- **`fixture_visual_stage_figma_data` (new):** an argv-recording `claude` stub that
  writes the cache file; assert `visual_stage_figma_data key node cache` returns 0,
  writes `$cache`, the argv carries `--permission-mode bypassPermissions` and
  `mcp__figma__get_figma_data`; caches (pre-existing `$cache` → no claude call); empty
  key/node and absent `claude` → non-zero.
- **Repair-agent shape (structural):** assert `repair_agent`'s `claude -p` invocation
  (a) carries `--model` referencing `NIGHT_SHIFT_VISUAL_REPAIR_MODEL`, (b) its
  `--allowed-tools` does **not** contain `mcp__figma__get_figma_data`, and (c) the prompt
  reads the `-figma.md` cache. (The agent needs `$PROJECT`/prompt vars, so a structural
  assertion is the reliable guard, like the existing `fixture_visual_review_no_token`.)
- **MCP-only preserved:** no `FIGMA_TOKEN`/`api.figma.com` introduced anywhere.

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 5. Documentation

`CLAUDE.md` visual-fidelity section: add `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default opus,
the repair-agent model); note that the engine's headless MCP `claude -p` calls run with
`--permission-mode bypassPermissions` (required — MCP tools are otherwise deferred); and
that the repair flow fetches `get_figma_data` once per run (cached under
`design/<screen>-figma.md`) to bound Figma API volume.

## 6. Validation caveat

The full live loop can't be re-validated until the Figma key's 429 clears (~2.2 days) or
a higher-tier key is used. The flag's effect is already proven at the tool-execution
level; the fixtures guard the invocation shape + the caching wiring so the fix can't
silently regress.
