# MCP-based Figma reference export — design

Date: 2026-06-26. Repo: `night-shift-engine`. Increment **1** (shared foundation) of
the two-flow design-fidelity vision — see [[design-fidelity-two-flows]]. Makes the
engine pull the Figma reference "printscreen" **autonomously via the Figma MCP**, on
both design-review surfaces, with no `FIGMA_TOKEN`/REST and no hand-staging.

## 1. Problem (both surfaces lack autonomous MCP ref export)

- **Standalone** `scripts/visual-review.sh` `stage_ref()` exports the Figma node via
  `FIGMA_TOKEN` + the Figma REST API (`curl -H X-Figma-Token api.figma.com/v1/images`);
  with no token it logs *"pre-stage refs yourself"* and returns 1 → manual staging.
  This violates the standing **Figma-MCP-only, never-a-token** rule.
- **In-loop** night-shift `run_visual` → `run_visual_capture` only **reads**
  `design/<screen>-<state>-<device>.png` — **nothing in the engine stages it** — so the
  visual_review silently SKIPs (no ref → diff fails → "absent" → on to the observer)
  unless a ref is hand-placed.

## 2. Goal / non-goals

**Goal:** one shared, MCP-based ref-export used by both surfaces, so
`visual-review.sh --repair` and the night-shift `visual_review` autonomously run the
whole loop — **Figma pull (MCP) → app screenshot → odiff % → auto-fix → report** — token-free.

**Non-goals (separate work):** Flow B (create-from-Figma: decompose → verify-existing →
build-missing → assemble → validate) — its own increment. Pulling the Figma **structure**
(`get_figma_data`) for the component breakdown — that belongs to Flow B; this increment
only exports the **image** reference for the pixel diff.

## 3. The shared function — `visual_stage_ref`

Add to `scripts/lib/visual-capture.sh`:

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

Notes: `claude -p` gets the prompt via STDIN and a comma-free single tool in
`--allowed-tools` (the proven invocation form). The model is a knob
(`NIGHT_SHIFT_VISUAL_REF_MODEL`, default a cheap tier — it is one tool call).

## 4. Wire into the standalone (`visual-review.sh`)

`stage_refs_for_spec` currently calls `stage_ref "$key" … "$ref"`. Replace the
token-based `stage_ref` with the shared MCP export:

- **Delete** `stage_ref()` (the `FIGMA_TOKEN` + `curl api.figma.com` retry loop).
- In `stage_refs_for_spec`, call `visual_stage_ref "$key" "$(node_id_for "$spec" "$screen")" "$ref"`.
- Update the `--help` prerequisites: the `FIGMA_TOKEN` line becomes "references are
  exported via the Figma MCP (`claude` + `mcp__figma__download_figma_images`); without
  it, pre-stage references under `<out>/design/`." (`--no-refs` still skips export.)

## 5. Wire into the in-loop (`run_visual`, `night-shift.sh`)

Before `run_visual_capture` in `run_visual`, stage each Design-Contract screen's ref
into `$RUN_ROOT/validated/design/` via the shared function (the in-loop sources both
libs, so `figma_key_for`/`node_id_for` from visual-repair.sh + `visual_stage_ref` +
`visual_capture_screens` from visual-capture.sh are in scope):

```bash
  local _k _sc _st _dv _rest
  _k="$(figma_key_for "$SPEC")"
  visual_capture_screens "$SPEC" | while IFS='|' read -r _sc _st _dv; do
    visual_stage_ref "$_k" "$(node_id_for "$SPEC" "$_sc")" \
      "$RUN_ROOT/validated/design/${_sc}-${_st}-${_dv}.png" || true
  done
```

`run_visual_capture` then finds the refs and diffs as today; a screen whose export
failed simply lacks a ref → SKIPped (existing clean-skip). No other in-loop change.

## 6. Degradation

A failed export (no `claude`, MCP down, node missing) → `visual_stage_ref` returns
non-zero. Standalone: `stage_refs_for_spec` already `|| true`s per ref and continues;
the capture step SKIPs a ref-less screen. In-loop: the screen lacks a ref →
`run_visual_capture` SKIPs it (today's behavior). **No regression when Figma/claude is
absent**; the only change is that, when present, the engine stages refs itself.

## 7. Testing

Deterministic fixtures (stub `claude` on PATH):
- **stages via MCP:** a `claude` stub that writes a 1-byte PNG to the `$out` path parsed
  from its stdin prompt → `visual_stage_ref key node out` returns 0 and `$out` exists.
- **caches:** with `$out` pre-existing, `visual_stage_ref` returns 0 **without** invoking
  the stub (assert the stub's call-log is empty).
- **degrades:** with no `claude` on PATH → returns non-zero, no file.
- **no token/REST:** assert `scripts/visual-review.sh` no longer contains `FIGMA_TOKEN`
  or `api.figma.com` (grep), and `stage_refs_for_spec` references `visual_stage_ref`.

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 8. Risks

- **MCP image-dir constraint:** `download_figma_images` writes under the MCP server's
  configured image directory; `$out` (under the project's `.night-shift/…`) must be
  within it (it is, under `~/work`). If a deployment configures it elsewhere, the
  export fails → clean SKIP (documented).
- **Cost:** one cheap `claude -p` per ref (a single tool call), cached thereafter.
