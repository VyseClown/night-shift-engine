# Cursor CLI Setup (opt-in implementer backend)

> Summary: How to install/authenticate the Cursor CLI (`cursor-agent`) and
> what `NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` does — the knobs, the startup
> probes and version canary, the `--trust`/`-f`/`--add-dir` semantics, where
> the four invocations live, the bounded retry → sticky Claude fallback and how
> a fallen-back run resumes, envelope/pricing differences from Claude, and
> the boundary (cursor never plans/reviews/observes/designs).

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
back. This guard runs on both entry points: the normal run path (inside
`cursor_startup_guards`) and the standalone `--sweep-only` surface each carry
their own copy of the same check with the same die message.

On the run path the guard is deliberately **deferred** past spec selection and
state recovery, because two situations make `cursor-agent` irrelevant for the
whole run and dying on it would refuse a run that needs the binary for nothing:

- the run's state already records the sticky fallback
  (`.implement_backend_fallback == "claude"`) or the design latch
  (`.implement_backend_design_latch == true`) — every remaining turn is Claude;
- the selected spec declares a `## Design Contract` — the backend is inert all
  run (see *Design Contract specs force Claude* below).

Either case logs the skip and proceeds. A fresh cursor run with neither still
dies at startup, before `initialize_run`'s minutes-long baseline, so a genuinely
misconfigured backend fails as fast as it ever did.

### Startup probes (auth + model slug)

`command -v` cannot see the two misconfigurations that actually cost a night:
a **logged-out** CLI, and a **typo'd model slug**. Either one passes the
availability check, then burns the whole retry budget plus backoff on the
first post-plan turn and silently strands the run on the Claude fallback —
the operator's vendor choice discarded, with only a journal entry to show
for it. So when (and only when) the backend knob is `cursor` — and, on the run
path, only when the deferred guards above did not skip — startup also runs two
free, bounded probes: `cursor-agent status` and `cursor-agent --list-models`,
never a paid model call. `--sweep-only` runs the same probe from its own copy
(no canary there: journaling needs a `RUN_ROOT` that surface never has). Each
probe has three outcomes:

| Outcome | What it means | What the engine does |
|---|---|---|
| ok | `status` reports logged in; the configured slug appears in the model list | proceed silently |
| definitive failure | the probe completed and positively reported "not logged in" — **only the auth check can reach this outcome** | **die** with an actionable message naming `cursor-agent login` / `CURSOR_API_KEY` |
| inconclusive | timeout, non-zero rc, output the engine does not recognize — **and a slug absent from an otherwise well-formed model list** | **WARN and proceed** — a transient blip or a formatting change must never block a run the in-run retry/fallback could have handled |

The slug check is a WARN, not a die, and the asymmetry is deliberate: "not
logged in" is a *positive report from the CLI*, while a slug miss is *inferred
from the list's row format* (`<slug> - <display name>`, exact first-field
match). A build that indents, prefixes, or colorizes its rows keeps the
`available models` header while failing that match — killing a run whose slug is
perfectly valid, and doing it before the version canary that would have flagged
the drift. A genuinely typo'd slug is not silently tolerated either: it is
warned at startup with the correct slug spelled out, and then fails fast through
the in-run retry/fallback, landing the run on Claude within ~180s at the default
knobs (30s + 60s + 90s of backoff).

Two deliberate exemptions: a **parameterized** model
(`--model 'name[key=value,…]'`) is legitimate but never listed verbatim, so
slug validation is skipped rather than failed; and
`NIGHT_SHIFT_CURSOR_SKIP_PROBE=1` disables both probes entirely. That knob is
an operator escape hatch for a machine where the probes themselves misbehave —
it gives up all auth and slug validation for the run, so the skip itself is
logged rather than silent. It is **not** how the test suites run: the
subprocess-driven integration harness leaves it unset — its scripted
`cursor-agent` answers only real turns, so both probes come back *inconclusive*
and take the WARN-and-proceed arm. The knob's only user in-tree is one sub-check
inside `fixture_cursor_startup_probe`. Probe commands are wrapped in a portable
watchdog — macOS has no coreutils `timeout` — bounded by
`NIGHT_SHIFT_CURSOR_PROBE_TIMEOUT` (default `30` seconds).

**Maintenance:** `fixture_cursor_startup_probe` holds all three outcomes
(including that the slug miss WARNs and the auth failure still dies), both
exemptions, and the presence of the call on both surfaces;
`fixture_cursor_startup_guards` holds the two run-path skips (each with a
control that genuinely dies) and that `main_run` reaches the guards from both
arms of its recover/init fork; `fixture_sweep_only_backend_guards` drives the
`--sweep-only` availability guard through a real subprocess.

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

## The knobs

The five that shape a run:

| Knob | Default | Meaning |
|---|---|---|
| `NIGHT_SHIFT_IMPLEMENT_BACKEND` | `claude` | `claude` or `cursor`. Anything else dies at startup. |
| `NIGHT_SHIFT_CURSOR_IMPLEMENT_MODEL` | `cursor-grok-4.6-high` | Passed verbatim to `cursor-agent --model` on fresh sessions only — a `--resume` turn must not re-pass `--model`, same rule the Claude side follows. |
| `NIGHT_SHIFT_CURSOR_MAX_RETRIES` | `3` | Cursor invocation retries (incremental backoff) before the run sticks a per-run fallback to the Claude implement model. |
| `NIGHT_SHIFT_CURSOR_RETRY_BACKOFF` | `30` | Seconds; actual sleep is this value times the attempt number. |
| `NIGHT_SHIFT_CURSOR_MAX_WAIT` | `600` | Ceiling (seconds) on the TOTAL backoff one primary turn may spend retrying cursor. Retries × backoff is otherwise an unbounded product; once the next sleep would cross this, the turn takes the sticky Claude fallback immediately instead of sleeping out the remaining budget. The cursor twin of `NIGHT_SHIFT_SWEEP_MAX_WAIT`. |

Plus two that only tune the startup probes (see below):

| Knob | Default | Meaning |
|---|---|---|
| `NIGHT_SHIFT_CURSOR_PROBE_TIMEOUT` | `30` | Seconds each free probe command (`status`, `--list-models`, `--version`) may take before its watchdog kills it. |
| `NIGHT_SHIFT_CURSOR_SKIP_PROBE` | `0` | `1` skips the auth/model startup probes entirely — an operator escape hatch that trades away auth + slug validation for the run (the skip is logged). Not used by the integration harness. |

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
cursor-agent -p --model cursor-grok-4.6-high --output-format json \
  --trust -f --add-dir "<workspace-root>" "<prompt>"
```

- `--trust` — required. An untrusted working directory hard-fails headless
  without it.
- `-f` / `--force` — allow commands unless explicitly denied; the headless
  edit-permission flag, the cursor analogue of Claude's
  `--permission-mode bypassPermissions`.
- `--add-dir <dir>` — grant access outside the trusted root. The primary
  turns pass the workspace root, because the prompt orders reads of
  `AGENTS.md`, `AGENT_LOOP.md`, the spec and `schemas/`, plus the `TODO.md`
  edit — all outside the trusted `$PROJECT`.

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
  stdout to parse. Every cursor call site therefore redirects stderr to
  `${raw}.err` explicitly (the Claude primary's no-stderr-redirect quirk is
  deliberately not copied here). Capacity/rate-limit errors surface as
  `RetriableError: [resource_exhausted]` on stderr after Cursor's own
  internal retries — there is no Claude-style 429 prose or reset timestamp
  to parse, so the engine treats any non-zero exit / `is_error:true` the
  same way: retry, then fall back.

### Where the invocations live

There is no single `invoke_cursor_primary` wrapper — the `cursor-agent`
command line is written out inline at **four** call sites, so read all four
when changing the contract:

| Call site | File | Flags |
|---|---|---|
| primary turn, fresh session | `scripts/night-shift.sh` (`invoke_primary`) | `-p --model … --output-format json --trust -f --add-dir "$WORKSPACE_ROOT"` |
| primary turn, `--resume` | `scripts/night-shift.sh` (`invoke_primary`) | `-p --resume "$session" --output-format json --trust -f --add-dir "$WORKSPACE_ROOT"` |
| run-feedback session | `scripts/lib/sweep.sh` (`write_run_feedback`) | `-p --output-format json --model … --trust` |
| sweep fix cycle | `scripts/lib/sweep.sh` (`sweep_fix_cycle`) | `-p --output-format json --model … --trust -f --add-dir "$out"` |

Shared invariants across all four:

- **`--trust` always.** No cursor invocation in this codebase omits it; a
  call missing it is a wiring bug (headless hard-fails on an untrusted dir).
- **stderr always goes to a `.err` file** next to the raw envelope, because
  cursor prints its errors there and nowhere else.
- **`--model` only on a fresh session.** A `--resume` turn carries its
  creation model, so re-passing `--model` is forbidden — the same rule the
  Claude branch follows. The two non-primary sessions are always fresh, so
  they always pass `--model`.
- **`-f` only where the session edits files.** The primary turns and the
  sweep fix cycle pass it; the read-only run-feedback session does not (see
  the `--trust` / `-f` section above).
- **`--add-dir` only where the session must reach outside its trusted root.**
  The primary reads workspace files (`AGENTS.md`, `AGENT_LOOP.md`, the spec,
  `schemas/`) and edits `TODO.md`, all outside `$PROJECT`; the sweep fix
  cycle reaches its own out-of-project output dir. The advisory run-feedback
  session gets neither `-f` nor `--add-dir`.

**Maintenance:** most — not all — of those invariants have a named pin, so
check which one covers the flag you are about to touch:

| Invariant | Pinned by |
|---|---|
| primary dispatches on the backend; stderr → `.err` | `fixture_cursor_primary_dispatch` (`scripts/test/fixtures.sh`) |
| `--add-dir "$WORKSPACE_ROOT"` on **both** primary branches (fresh + `--resume`) | `fixture_cursor_primary_dispatch` (counts two occurrences) and `integration-cursor.sh` Scenario A (every recorded primary argv) |
| `--model` on a fresh start, never on a `--resume` | `fixture_cursor_retry_resumes_and_rechecks_limits` |
| `--trust` on every invocation | the integration harness's `cursor-agent` stub rejects any argv without it |
| `--trust`/`-f`/`--add-dir` on the two `sweep.sh` sites, including the deliberate asymmetry between them | `fixture_sweep_backend_dispatch` |

The one gap worth knowing: **the primary's `-f` has no pin** — dropping it would
not turn the suite red (the stub only checks `--trust`, and a real cursor
session without `-f` would fail at edit time, not at argv time). Add the flag
back by hand if you refactor those two lines. End-to-end behavior lives in
`scripts/test/integration-cursor.sh`.

## Retry → sticky Claude fallback

A cursor turn counts as failed on a non-zero exit, on `is_error:true` in an
otherwise clean envelope, on a missing `session_id`, or when a `--resume` echoes
back a *different* session id (that last one is logged as CLI-contract drift and
routed here rather than hard-blocking — the Claude path keeps its hard block,
because its `--resume` contract is verified). On any of them the engine journals
`backend_retry {attempt, rc}` and sleeps
`NIGHT_SHIFT_CURSOR_RETRY_BACKOFF * attempt` seconds, up to
`NIGHT_SHIFT_CURSOR_MAX_RETRIES` retries after the initial turn (the
default of `3` means at most 4 invocations total before falling back).

Three things happen around each retry:

- **The retry resumes the failed attempt's own session** when that attempt
  emitted one. A failed cursor turn is not side-effect-free — the CLI can have
  edited files or even committed before reporting the error — so a retry in a
  brand-new session would re-run the identical prompt blind to that work.
- **The turn budget is re-checked** (`enforce_limits`) after every backoff
  sleep. Turn counters deliberately do not advance on a retry, so without this a
  retry storm could outrun the stage/task *time* caps entirely. A budget hit at
  the re-check blocks the run there — before any fallback.
- **The cumulative backoff is capped** by `NIGHT_SHIFT_CURSOR_MAX_WAIT`
  (default `600`s). Once the *next* sleep would push this turn's total backoff
  past the ceiling, the engine stops retrying and takes the fallback
  immediately, logging (and journaling, in the `backend_fallback` reason) that
  the ceiling — not the retry count — is what fired.

On either stop condition it sets a sticky
per-run state flag (`.implement_backend_fallback="claude"`, survives
`--resume`) and nulls the session **in one atomic state write** — split
across two writes, a crash in between would leave the run pinned to Claude
with a *cursor* session id, and every relaunch would then run
`claude -p --resume <cursor-uuid>` into a failure no retry can clear. It
then journals `backend_fallback
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

### CLI version canary

The headless envelope, `--resume`, the stderr-only error shape and the
`--trust`/`-f`/`--add-dir` flags were live-verified against exactly ONE
`cursor-agent` build, pinned in `scripts/night-shift.sh` as
`CURSOR_CONTRACT_CLI_VERSION` (the cursor twin of
`RATE_LIMIT_CONTRACT_CLI_VERSION`). Envelope drift cannot be re-proven
without a paid call, so the engine ships a version tripwire instead: on every
cursor-backend startup it reads `cursor-agent --version` and journals a
`contract_canary` event `{contract:"cursor-cli", expected, found}` — on a
match too, so each run's journal pins the exact build behind it. When the
installed build differs it logs a `WARNING` naming both versions and telling
you to re-verify per `specs/cursor-implementer-backend.md` and bump the
constant.

It **never blocks**: a mismatch, a failed probe and a timed-out probe all
leave the run running. It is also skipped entirely on the claude backend (a
Claude-only run never shells out to `cursor-agent`) and on `--sweep-only`,
which has no `RUN_ROOT` to journal into. Grep `contract_canary` in
`events.jsonl` to find vendor drift for either CLI in one pass.

**Maintenance:** `fixture_cursor_contract_canary` pins all four of those
behaviors (drift WARNs, a match is still journaled, a failed probe is a
silent no-op, the claude backend never probes).

### Resuming a run under a different backend

A relaunch normally refuses to switch backends mid-run: the engine compares the
`NIGHT_SHIFT_IMPLEMENT_BACKEND` recorded in the run's state at start time
against the value passed to the relaunch, and dies if they differ
(`existing run was started with NIGHT_SHIFT_IMPLEMENT_BACKEND=<recorded>;
relaunch with NIGHT_SHIFT_IMPLEMENT_BACKEND=<recorded> to resume it`).

**A run that already took the sticky fallback is the exception**, and it needs
to be: expired or unreachable cursor auth is the usual *cause* of the fallback,
so demanding the original knob back would be circular — the operator could
resume with neither backend, behind a tree too dirty for a bare relaunch, with
the night's committed work stranded. So once state records
`.implement_backend_fallback == "claude"`:

- the backend comparison is relaxed (the flag can only be set on a run whose
  stored backend was cursor, so the relaxation is exactly cursor → claude) and
  the acceptance is logged. Resume with `NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor`,
  with `=claude`, or with the knob unset — all three work;
- `cursor_startup_guards` returns early, so `cursor-agent` may be **absent from
  `PATH` or logged out** and the run still resumes. Nothing left in the run uses
  it. (The version canary is likewise a silent no-op when the probe cannot run.)

There is no hand-edit alternative and never was: `state.json` is
integrity-anchored and guarded on every primary turn, so editing it out of band
quarantines the file, journals `integrity_violation`, restores the engine's copy
and blocks the run. Use the resume above instead.

**Null-session resumes.** The fallback nulls `.session_id` in the same write as
the flag, so a block during the fallback turn leaves `status: blocked` with no
pinned session. `--resume` re-enters that state under
`NIGHT_SHIFT_SESSION_SCOPE=stage` (the default, and the only scope this backend
allows): a stage session is restartable *from files* by construction, so the
next primary turn simply starts fresh and reorients from the working tree and
`control/plan.md`. Under the legacy `=run` scope a null session genuinely means
lost context, and the old refusal stands — the refusal message names which
precondition failed rather than guessing.

**Maintenance:** `integration-cursor.sh` Scenario E reproduces the whole
incident end to end — plan on Claude, cursor burns its budget, sticky fallback,
the fallback turn writes work and fails, the run blocks with `session_id: null`
over a dirty tree, a bare relaunch is refused, and `--resume` under
`NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor` with `cursor-agent` deleted from `PATH`
completes the run. `fixture_resume_blocked` and `fixture_resume_refusal_reason`
hold the scope rule and the refusal messages;
`fixture_recovery_guard_backend_mismatch_after_fallback` holds the relaxed die.

## Design Contract specs force Claude

Any spec with a `## Design Contract` section ignores the cursor backend for
the **whole run**, even if the knob is set to `cursor` —
`implement_backend_active()` checks the backend knob first, then
`spec_has_design_contract`. Design-fidelity implement work is judgment-heavy
(bumped to `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL`, strongest-available Claude,
on the Claude branch) and this avoids a per-scope vendor sandwich mid-run.

"Whole run" is enforced by a **latch**, not by re-reading the current spec:
the first activation check that sees a `## Design Contract` writes
`.implement_backend_design_latch=true` into run state, and every later check
honors the latch. Otherwise a chained `NEXT_TASK` task whose own spec has no
contract would flip the primary back to cursor mid-run — exactly the vendor
sandwich the rule exists to prevent. The latch is run-scoped and survives
`--resume`; a fresh run with a contract-free spec is cursor again.

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
