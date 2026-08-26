# Cursor CLI Setup (opt-in implementer backend)

> Summary: How to install/authenticate the Cursor CLI (`cursor-agent`) and
> what `NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` does — the four knobs, the
> `--trust`/`-f` semantics, envelope/pricing differences from Claude, and the
> boundary (cursor never plans/reviews/observes/designs).

This document covers the engine's **opt-in second implementer vendor**: with
`NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` set, the primary's post-plan work
(implement, observe-request, completion turns — plus the sweep fix cycle and
run-feedback sessions) runs on the [Cursor CLI](https://cursor.com/cli)
driving Grok 4.6 instead of Claude. See `specs/cursor-implementer-backend.md`
for the full design; this doc is the setup/reference guide.

With the knob unset (the default), nothing here applies — engine behavior is
byte-for-byte unchanged.

## Install

```sh
curl https://cursor.com/install -fsS | bash
```

This installs the `cursor-agent` binary (the CLI also ships a newer `agent`
alias). Confirm it landed on `PATH`:

```sh
command -v cursor-agent
cursor-agent --version
```

## Authentication

Two ways to authenticate, either sufficient for headless use:

```sh
cursor-agent login          # interactive browser login
```

or, for headless machines / CI, set an API key instead:

```sh
export CURSOR_API_KEY=...
```

Check the current auth state:

```sh
cursor-agent status
```

Whenever the backend knob is `cursor`, the engine's own `cursor_available`
check (which shells out to `command -v cursor-agent`) runs at startup — a
missing binary dies loudly before any work starts, it does not silently fall
back. This guard runs on both entry points: the normal run path and the
standalone `--sweep-only` surface each carry their own copy of the same
check with the same die message.

## Model discovery

```sh
cursor-agent --list-models
```

is the source of truth for available slugs. The engine talks to the Grok
family: model names are shaped `cursor-grok-4.6-{low,medium,high,xhigh}`
(plus `-fast` variants) — the reasoning effort is encoded in the slug suffix,
not a separate flag. A bare `grok-4.6` is rejected; you must use the full
slug. The engine's default is:

```
cursor-grok-4.6-high
```

## The four knobs

| Knob | Default | Meaning |
|---|---|---|
| `NIGHT_SHIFT_IMPLEMENT_BACKEND` | `claude` | `claude` or `cursor`. Anything else dies at startup. |
| `NIGHT_SHIFT_CURSOR_IMPLEMENT_MODEL` | `cursor-grok-4.6-high` | Passed verbatim to `cursor-agent --model` on fresh sessions only — a `--resume` turn must not re-pass `--model`, same rule the Claude side follows. |
| `NIGHT_SHIFT_CURSOR_MAX_RETRIES` | `3` | Cursor invocation retries (incremental backoff) before the run sticks a per-run fallback to the Claude implement model. |
| `NIGHT_SHIFT_CURSOR_RETRY_BACKOFF` | `30` | Seconds; actual sleep is this value times the attempt number. |

There is no `inherit` sentinel for the cursor model — `inherit` means "use the
Claude CLI's startup model," a concept specific to the Claude branch. The
cursor model never passes through the Claude model-fallback ladder
(`model_flag` / `resolve_effective_model` / `successor_model`); that ladder
stays Claude-only.

`NIGHT_SHIFT_SESSION_SCOPE=stage` (the engine's default) is what makes the
cursor backend viable at all: each stage scope hands off through files on
disk and starts a fresh session, so `cursor-agent --resume <session_id>`
only ever needs to carry one stage's context forward, matching the same
session invariants the Claude branch relies on (non-empty, stable
`session_id` across a scope). This is not just a recommendation — it is
enforced at startup: `NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` with
`NIGHT_SHIFT_SESSION_SCOPE` set to anything other than `stage` (e.g. the
legacy `run` scope) dies immediately with `"NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor
requires NIGHT_SHIFT_SESSION_SCOPE=stage (the backend switches vendors at
stage-scope session boundaries)"` before any work starts.

## `--trust` / `-f` semantics

Headless invocation looks like:

```sh
cursor-agent -p --model cursor-grok-4.6-high --output-format json --trust -f "<prompt>"
```

- `--trust` — required. An untrusted working directory hard-fails headless
  without it.
- `-f` / `--force` — allow commands unless explicitly denied; the headless
  edit-permission flag, the cursor analogue of Claude's
  `--permission-mode bypassPermissions`.

Per-project/user config (allow/deny lists) lives in
`~/.cursor/cli-config.json` and `<project>/.cursor/cli.json`. `cursor-agent`
also auto-applies the target repo's own `AGENTS.md`/`CLAUDE.md` as rules, so
target-repo instructions still reach the grok implementer the same way they
reach Claude.

Not every cursor invocation passes both flags: the run-feedback session
(`write_run_feedback`) deliberately runs `--trust` **without** `-f` — it only
reads the journal and writes 5-15 bullets of advisory feedback, never edits
the target repo, so it needs no edit-permission flag. The sweep fix cycle
and the primary implement turns pass both, since those sessions do edit
files.

## Envelope differences from Claude

A successful cursor turn's stdout is a single JSON object:

```json
{"type":"result","subtype":"success","is_error":false,"duration_ms":...,
 "result":"...","session_id":"<uuid>","request_id":"...",
 "usage":{"inputTokens":...,"outputTokens":...,"cacheReadTokens":...,"cacheWriteTokens":...}}
```

Two differences the rest of the engine has to account for:

- **No `total_cost_usd`.** The cost ledger's `record_cost` already treats a
  missing USD figure as non-fatal; a cursor turn additionally records the
  `usage` token fields so the ledger row isn't left empty, but there is no
  USD parity with Claude turns in v1.
- **Errors are stderr-only, no JSON.** A failing invocation exits non-zero
  and prints a plain-text message to stderr — there is no error envelope on
  stdout to parse. `invoke_cursor_primary` therefore redirects cursor's
  stderr to `${raw}.err` explicitly (the Claude primary's no-stderr-redirect
  quirk is deliberately not copied here). Capacity/rate-limit errors surface
  as `RetriableError: [resource_exhausted]` on stderr after Cursor's own
  internal retries — there is no Claude-style 429 prose or reset timestamp
  to parse, so the engine treats any non-zero exit / `is_error:true` the
  same way: retry, then fall back.

## Retry → sticky Claude fallback

On a cursor turn failure (non-zero exit or `is_error:true`), the engine
journals `backend_retry {attempt, rc}` and sleeps
`NIGHT_SHIFT_CURSOR_RETRY_BACKOFF * attempt` seconds, up to
`NIGHT_SHIFT_CURSOR_MAX_RETRIES` retries after the initial turn (the
default of `3` means at most 4 invocations total before falling back). On
exhaustion it sets a sticky
per-run state flag (`.implement_backend_fallback="claude"`, survives
`--resume`), nulls the session, journals `backend_fallback
{from:"cursor", to:"claude", reason, rc}`, and continues the same stage
fresh on the Claude implement model — an overnight run survives a Cursor
outage instead of blocking on it.

This retry/fallback machinery belongs **only to the primary turn loop**
(`invoke_primary`). The sweep fix cycle and the run-feedback session also
dispatch on the active backend, but they degrade through their own,
pre-existing paths instead of this one: the sweep fix cycle's failure mode
is a dirty-tree/failed-revalidation `git reset --hard` back to the pre-fix
tip, and a failed run-feedback session is just a WARN (it's advisory
output, not something the run blocks on). Neither retries cursor N times or
sets the sticky fallback flag itself.

The Claude branch's own failure handling (session-limit 429 waits, per-model
usage-cap fallback, the rate-limit contract canary) is untouched and stays
Claude-only regardless of the backend knob.

### Resuming a run under a different backend

`--resume` refuses to switch backends mid-run: the engine compares the
`NIGHT_SHIFT_IMPLEMENT_BACKEND` recorded in the run's state at start time
against the value passed to the resume invocation, and dies if they differ
(`existing run was started with NIGHT_SHIFT_IMPLEMENT_BACKEND=<recorded>;
relaunch with NIGHT_SHIFT_IMPLEMENT_BACKEND=<recorded> to resume it`). This
also covers the sticky per-run fallback above — once a run has fallen back
to Claude, its recorded backend is still `cursor` (the fallback is a runtime
flag, not a rewrite of the original knob), so a resume must still pass
`NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` even though the run is currently
executing on Claude.

## Design Contract specs force Claude

Any spec with a `## Design Contract` section ignores the cursor backend for
the **whole run**, even if the knob is set to `cursor` — `implement_backend_active()`
checks the backend knob first, then `spec_has_design_contract`. Design-fidelity
implement work is judgment-heavy (bumped to
`NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL`, strongest-available Claude, on the
Claude branch) and this avoids a per-scope vendor sandwich mid-run.

## The boundary

Cursor is an implement-tier alternative only:

- It never plans (`NIGHT_SHIFT_PLAN_MODEL` scope is always Claude).
- It never reviews as a persona (`NIGHT_SHIFT_PERSONA_MODEL` stays Claude).
- It never observes (the final gate is always an independent Claude
  session — `observer-review.json`'s `observer` field stays a hard
  `"claude"` const; only `primary` varies with the active backend).
- It never does design-fidelity implement work (see above).

## Pricing

Grok 4.6 usage through `cursor-agent` is billed from the Cursor plan's usage
pool first; beyond that pool, per-token pricing is:

| | Price |
|---|---|
| Input | $2 / M tokens |
| Cached input | $0.50 / M tokens |
| Output | $6 / M tokens |

(The `-fast` model variants cost more than their base counterparts.) There
is no USD figure in the cursor turn envelope itself (see above) — the
engine's cost ledger records token usage for cursor rows, not a computed
USD total, so reconciling this pricing table against actual Cursor billing
is a manual step in v1.
