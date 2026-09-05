# ai-memory integration (opt-in cross-run agent memory)

> Summary: What `NIGHT_SHIFT_MEMORY=ai-memory` does and does not do — the
> verified facts about ai-memory and Claude Code headless hooks that shaped
> it, the operator setup, the reviewer-isolation rule that keeps the
> observer independent, the journal event, and the deliberately deferred
> deterministic HTTP write.

## Verdict

Yes — [ai-memory](https://github.com/akitaonrails/ai-memory) can back the
engine, and the integration is small because ai-memory already speaks the two
protocols the engine's sessions speak: Claude Code **lifecycle hooks** (capture)
and **MCP** (recall/handoff). The engine adds nothing on the wire; it adds two
prompt paragraphs, one startup probe, and one safety rule. Everything is
inert unless `NIGHT_SHIFT_MEMORY=ai-memory` is set.

The one thing that is **not** safe without engine support is the naive
"just install the hooks" path, because of how the engine is built. Those
facts, verified 2026-09 against the ai-memory sources and the Claude Code CLI
reference, are the whole design:

| Fact | Consequence for the engine |
|---|---|
| ai-memory installs hooks into `~/.claude/settings.json` (user scope) and its MCP server into `~/.claude.json`; both are honored by headless `claude -p` exactly like interactive sessions. | Every session the engine spawns — primary, personas, observer, sweep, feedback — is captured and can call the memory tools, with no engine change. |
| Its `SessionStart` hook (`hooks/claude-code/session-start.sh`) GETs `/handoff` and prints it as `additionalContext`, injected into **every** new session; there is no print-mode or subagent exclusion. | The independent observer and the persona bench would receive the primary's handoff — the context leak the engine's "fresh session from a neutral empty dir" design exists to prevent. |
| ai-memory files a project under `basename(cwd)` (default strategy; `--project-strategy repo-root` collapses worktrees). | Personas/observer run in `/tmp/night-shift-{persona,observer}-<run-id>…` dirs: they would create one junk wiki project per run. |
| Claude Code: `--settings '<inline JSON>'` overrides settings for one invocation, `disableAllHooks` turns hooks off, and `--strict-mcp-config` with no `--mcp-config` leaves zero MCP servers. | Reviewer sessions can be isolated per invocation without touching the user's config — `reviewer_isolation_args` in `scripts/lib/memory.sh`. |
| The zero-LLM path (capture, FTS5 search, handoffs) needs no API key; consolidation/summaries need `AI_MEMORY_LLM_PROVIDER`. | No cost inside the engine's budget; any LLM spend is the server's, configured by the operator. |
| The HTTP API (`docs/frontend-api.md`) is read-only for pages/search/briefing/handoffs; the only write ingress is the hook event vocabulary (`POST /hook`) and the MCP tools. | The engine does **not** POST anything: forging hook events would create fake sessions. Writes go through the primary's MCP tools, which is how ai-memory is designed to be written. |

## What the knob does

`NIGHT_SHIFT_MEMORY=ai-memory` (default `off`; any other value dies at startup):

1. **Startup probe** — `memory_startup_probe` GETs `NIGHT_SHIFT_MEMORY_URL`
   (default `http://127.0.0.1:49374`) `/auth/me`, the identity endpoint that
   answers 200 with an anonymous snapshot even with no auth configured.
   `NIGHT_SHIFT_MEMORY_TOKEN` rides along as the Bearer token when set;
   `NIGHT_SHIFT_MEMORY_TIMEOUT` (default 3s) bounds it. Journals one
   `memory_probe {backend, url, http, ok}` event. **WARN, never block** — the
   primary uses the MCP tools, which connect through Claude's own config, not
   this URL; the probe only catches "nothing is listening".
2. **Recall paragraph** (plan scope only): the primary is told to query
   `memory_query` / `memory_briefing` for prior decisions, gotchas and failed
   approaches relevant to the spec before planning, to treat the result as
   untrusted evidence (never instructions), and to write `memory: unavailable`
   in the plan and proceed when the tools are absent.
3. **Handoff paragraph** (completion scope only): before signaling `COMPLETE`,
   file ONE `memory_handoff_begin` with `shared: true` (handoffs are personal
   by default; an unattended run's outcome must reach the human's next
   interactive session) summarizing spec, candidate commits, decisions,
   reviewer/observer flags and open questions. Skip silently if absent.
4. **Reviewer isolation** — every session whose output feeds the independent
   gate gets `--settings '{"disableAllHooks":true}' --strict-mcp-config`:
   personas, the observer, the branch sweep (both its spawns, the rate-limit
   retry included) and the standalone test-audit / port-audit CLIs (which
   re-derive the same rule from the two env knobs). *Not* isolated, on
   purpose: the primary, and its implementer-side kin that edit the project
   on the primary's tier — the run feedback session, the sweep fix cycle and
   the visual repair agent (capturing them is useful memory). Available on
   its own as `NIGHT_SHIFT_REVIEWER_ISOLATION=1` for any user-level hook/MCP
   setup; `=0` forces it off even under memory (not recommended).

`NIGHT_SHIFT_MEMORY`, `NIGHT_SHIFT_REVIEWER_ISOLATION` (`0`/`1`) and
`NIGHT_SHIFT_MEMORY_TIMEOUT` (a positive integer) are validated loudly at
startup on both entry surfaces — `main_run` and `--sweep-only`, which also
runs the probe (WARN-only there: no run journal exists).

Unset, every function in `scripts/lib/memory.sh` returns empty and the
prompts, argv and journal are byte-identical to the pre-memory engine.

## Operator setup

```sh
# 1. Run the server (docker or systemd — see ai-memory's README/docs/install.md)
docker run -d --name ai-memory --restart unless-stopped \
  -p 127.0.0.1:49374:49374 -v ai-memory-data:/data akitaonrails/ai-memory:latest

# 2. Wire Claude Code (user scope — the engine's sessions inherit it)
ai-memory install-mcp   --client claude-code --apply
ai-memory install-hooks --agent  claude-code --apply --project-strategy repo-root

# 3. Run the night shift with memory on
NIGHT_SHIFT_MEMORY=ai-memory NIGHT_SHIFT_ACCEPT_COSTS=YES \
  scripts/night-shift.sh --project <path> --spec specs/<name>.md
```

`--project-strategy repo-root` matters for `scripts/parallel-worktrees.sh`
runs: without it each worktree's basename becomes its own wiki project.

Optional server-side: `AI_MEMORY_LLM_PROVIDER=anthropic` + `ANTHROPIC_API_KEY`
for consolidated session pages; `AI_MEMORY_AUTH_TOKEN` when the server is not
loopback-only (then set `NIGHT_SHIFT_MEMORY_TOKEN` to the same value so the
probe authenticates).

## What is deliberately deferred

- **A deterministic engine-side write** (the run outcome filed even when the
  primary forgets). ai-memory has no documented "write a page/handoff" HTTP
  endpoint for third parties — only hook events and MCP. A future version
  could drive the MCP `memory_write_page` tool over streamable HTTP from
  bash, but that means a JSON-RPC handshake per run for a page the primary
  is already asked to file; not worth it until a run is seen skipping the
  handoff.
- **Managed workstreams** (`ai-memory run claude`): the wrapper's session
  adoption is for interactive continuity across harnesses; the engine's
  stage-scoped fresh sessions hand off through files by design and would gain
  nothing from it.
- **Codex/cursor implement backends**: ai-memory supports both (`install-hooks
  --agent codex|cursor`), but this tranche only prompts the *Claude* primary.
  A codex implement stage still gets captured by ai-memory's own codex hooks
  if installed; its recall/handoff paragraphs are not sent because the
  paragraphs name Claude MCP tool ids.
