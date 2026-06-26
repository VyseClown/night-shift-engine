# Headless-MCP permission fix — design

Date: 2026-06-26. Repo: `night-shift-engine`. Fixes a bug found by the live
design-fidelity test ([[headless-mcp-bypass-permissions]]): the engine's design-fidelity
`claude -p` agents that call MCP tools never pass a permission mode, so in **headless
`claude -p`** the MCP tools (`mcp__figma__*`) are **deferred and unavailable**, and the
calls silently no-op.

## 1. Problem (proven by the live test)

- In headless `claude -p`, MCP server tools are deferred — a plain `claude -p` reports
  `mcp__figma__*` as **NONE**. They become executable only when the invocation passes
  **`--permission-mode bypassPermissions`** (or `--dangerously-skip-permissions`) AND
  names them in `--allowed-tools`.
- **Proven:** the exact `download_figma_images` prompt failed with `--allowed-tools`
  alone (model: "I cannot invoke that tool"), then executed (reaching a Figma 429) once
  `--permission-mode bypassPermissions` was added.
- **Nuance:** CORE tools (Read/Edit/Write/Bash) DO execute headless without the flag
  (verified — an Edit changed `1`→`2` with no flag). So only **MCP** tools need it.
- Two engine sites are affected; both lack the flag:
  - `scripts/lib/visual-capture.sh` `visual_stage_ref` (uses `download_figma_images`).
  - `scripts/lib/visual-repair.sh` repair agent (uses `get_figma_data`).
- **The fixtures stub `claude` on PATH**, so they "pass" regardless of the invocation —
  the broken call was never exercised.
- The PRIMARY night-shift already uses `--permission-mode bypassPermissions`
  (`night-shift.sh:887,890`), so the fix matches an existing, proven pattern.

## 2. Goal / non-goals

**Goal:** the engine's two design-fidelity MCP `claude -p` calls actually execute their
MCP tools in headless mode, and the repair agent runs on opus by default; with a
regression test that asserts the flag is passed.

**Non-goals:** the Figma 429 rate limit (external; not an engine concern); the
noise-inflated diff masking (separate follow-up); any change to the primary night-shift
`claude -p` (already correct).

## 3. Changes

### 3.1 `visual_stage_ref` (`scripts/lib/visual-capture.sh`)

Add `--permission-mode bypassPermissions` to its `claude -p`:

```bash
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "mcp__figma__download_figma_images" >/dev/null 2>&1 ) || true
```

(Model unchanged — a one-shot download stays on the cheap `NIGHT_SHIFT_VISUAL_REF_MODEL`,
default haiku.)

### 3.2 Repair agent (`scripts/lib/visual-repair.sh`)

Add `--permission-mode bypassPermissions` AND an opus model knob to its `claude -p`:

```bash
  result="$(cd "$PROJECT" && printf '%s' "$prompt" | claude -p --output-format json \
    --model "${NIGHT_SHIFT_VISUAL_REPAIR_MODEL:-claude-opus-4-8}" \
    --permission-mode bypassPermissions \
    --allowed-tools "Read,Edit,Write,Bash(npx tsc*),Bash(npx eslint*),mcp__figma__get_figma_data" 2>/dev/null)"
```

`NIGHT_SHIFT_VISUAL_REPAIR_MODEL` defaults to **`claude-opus-4-8`** — design-fidelity
repair is judgment-heavy ([[opus-for-design-fidelity]]); `=sonnet`/`=inherit` overrides
it (a cost knob).

### 3.3 Safety

Consistent with the primary night-shift's existing `bypassPermissions` usage. The tight
`--allowed-tools` allowlists bound exactly what each agent can run: `visual_stage_ref` →
only the Figma image download; the repair agent → Read/Edit/Write, `npx tsc`/`eslint`,
and `get_figma_data`, with edits already constrained to `src/features` (and `src/ui`
under `--repair-shared`) by the prompt + the repair orchestration.

## 4. Testing

Deterministic fixtures (stub `claude` on PATH — now argv-aware):

- **`fixture_visual_stage_ref` (update):** the `claude` stub records its argv to a file;
  the fixture asserts the recorded argv contains `--permission-mode bypassPermissions`
  (and still: stages the PNG, caches, degrades, empty key/node → non-zero). This is the
  regression test that would have caught the bug.
- **Repair-agent flag + model (structural):** a fixture asserts `scripts/lib/visual-repair.sh`'s
  `claude -p` invocation carries both `--permission-mode bypassPermissions` and
  `--model` referencing `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (the agent needs `$PROJECT` +
  prompt vars, so an isolated call is impractical; the structural assertion is the
  reliable guard, like the existing `fixture_visual_review_no_token`).

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 5. Documentation

- `CLAUDE.md` visual-fidelity section: add `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default
  opus, the repair-agent model) and a one-line note that the engine's headless MCP
  `claude -p` calls run with `--permission-mode bypassPermissions` (required — MCP tools
  are otherwise deferred in headless and unavailable).

## 6. Validation caveat

The full live loop can't be re-validated until the Figma MCP key's 429 clears (~2.2
days) or a higher-tier key is used. The flag's effect is already proven at the
tool-execution level (the MCP tool went from "cannot invoke" to executing). The fixtures
guard the invocation shape so the fix can't silently regress.
