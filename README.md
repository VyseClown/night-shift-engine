# night-shift-engine

An **overnight autonomous coding engine**. You write a spec; the engine plans,
implements, validates, runs a multi-persona review and an independent observer
gate, and leaves a reviewed candidate commit on a feature branch by morning — it
never pushes or merges on its own.

`scripts/night-shift.sh` is the orchestrator. It drives the whole flow through
real `claude` CLI sessions, tiers models by role to spend the strong model only
where judgment matters, and treats the spec as the single executable contract.

> **Two repos.** This is the **engine** (`VyseClown/night-shift-engine`). The
> sibling [`night-shift-viewer/`](./night-shift-viewer) (`VyseClown/night-shift-viewer`)
> is a separate repo: a read-only dashboard with a gated launcher and spec editor
> that *spawns this same script* — it does not reimplement the workflow.

## Read these first

| Doc | Audience | What it covers |
|---|---|---|
| [`NIGHT_SHIFT_HOWTO.md`](./NIGHT_SHIFT_HOWTO.md) | **humans** | Quickstart: what to write first, what happens on a run |
| [`AGENTS.md`](./AGENTS.md) | agents | Workspace router: layout, tools, rules, validation checklists |
| [`AGENT_LOOP.md`](./AGENT_LOOP.md) | agents | Step-by-step process for autonomous overnight runs |
| [`specs/_template.md`](./specs/_template.md) / [`_template-web.md`](./specs/_template-web.md) | both | How to write a feature spec (rn / web) |
| [`docs/review-personas.md`](./docs/review-personas.md) / [`-web.md`](./docs/review-personas-web.md) | both | The review persona sets and their checklists |

## How a run works

```
write a spec  →  list it in TODO.md  →  launch the script  →  review in the morning
```

1. **Spec gate.** `validate_spec` enforces structural completeness — repo path,
   base/feature branch, a valid Review Profile for the track, dependency/native
   permissions, a documentation owner per active persona, and all three Test Plan
   fields. An incomplete spec **blocks the run** instead of guessing.
2. **Plan → implement → observe**, as stage-scoped primary sessions (a fresh
   `claude` session per stage scope, handing off through files on disk to keep
   cost down).
3. **Test Plan is the engine.** Baseline commands run before any edit, the first
   failing test must fail then pass, and final commands run in an isolated
   validation worktree and must not regress vs baseline. An optional `- Smoke:`
   field adds a gated boot-proof phase (exit mode or, with `- Smoke URL:`,
   server mode) right alongside baseline/final — proof the app actually
   *starts*, not just that its checks pass.
4. **Review.** The spec's Track + Review Profile select the persona set that
   reviews the plan and the implementation. Every finding is a blocker; progress
   needs an approval from each active persona. A doc-freshness gate (default
   on) hands the observer a list of docs the diff may have made stale, for it
   to judge case-by-case — advisory, never blocking.
5. **Observer gate.** A fresh, independent observer session reviews the candidate
   commit. A BLOCK returns the task to a fresh implement session.
6. **Wrap-up.** On completion a short session distills the run's journal into
   feedback for whoever writes specs, appended to `<project>/.night-shift/feedback.md`
   (default on). Optionally, `NIGHT_SHIFT_BRANCH_SWEEP=1` (or `=advisory`) adds
   one whole-branch strong-model review at the very end — the full merge-base
   diff, for cross-task interactions a per-task review can't see — and `=1`
   additionally runs one capped fix cycle on findings. Run it standalone anytime
   with `scripts/night-shift.sh --sweep-only --project <path>`. Optionally,
   `NIGHT_SHIFT_TEST_AUDIT=1` runs a false-confidence pass over only the test
   files the candidate touched, hunting vacuous assertions and self-testing mocks.

## Tracks

A spec declares `- Track: rn | web | node` (default `rn`), which selects the
review persona set, the spec template, and the validation checklist:

- **`rn`** — React Native (`rn-sandbox`). Personas in `docs/review-personas.md`.
- **`web`** — Next.js / React with its data/API layer (`web-app`, e.g. Prisma +
  Postgres). Personas in `docs/review-personas-web.md`, including a dedicated
  **Backend & Data Expert**; the `data` profile targets that backend/data work.
- **`node`** — plain Node / CLI / backend, no UI surface. Reuses the backend
  personas (the **Backend & Data Expert** stands in for the architecture role);
  `full` and `logic` profiles only (no UX persona).

## Running it

Launch unattended from a terminal (not a Claude session):

```sh
# Free pre-flight (deterministic fixtures, no model calls):
scripts/night-shift.sh --fixture-test --dry-run

# A real run on a spec:
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <workspace>/<proj> --spec specs/<name>.md
```

| Command | What it does |
|---|---|
| `--project PATH [--spec PATH]` | Run a task. Without `--spec`, the engine picks the next task from `TODO.md` (and may continue via `NEXT_TASK`); with `--spec` it is a single task. |
| `--fixture-test [--dry-run]` | Deterministic self-test on fixtures; `--dry-run` makes it free. |
| `--preflight --project PATH --spec PATH` | **Read-only launch-readiness report** (JSON, no run): spec validity, on-feature-branch, clean tree, `.night-shift` gitignored, worktree conflicts. The viewer renders this as a checklist. |
| `--resume --project PATH [--spec PATH]` | Resume a **preserved logic-blocked run** (re-enters a blocked run rather than starting fresh); under the default `NIGHT_SHIFT_SESSION_SCOPE=stage` this includes a run blocked with no pinned session. |
| `--list-optional-personas` | JSON manifest of the optional cross-track reviewers (no run). |

> **Trust boundary — specs are executable.** The primary runs with
> `--permission-mode bypassPermissions`, and the spec's validation commands are
> executed verbatim via `bash -lc`. Only run specs you authored or fully reviewed.

A bare relaunch (no `--resume`) over a prior run that stopped `blocked` for a
reason other than a rate limit, with uncommitted work still in the project
tree, refuses to start fresh — a new run could never legitimately claim that
work as its own commit. It dies naming `--resume` and the alternative
(commit/stash first) instead of silently stranding the work as baseline noise.
A rate-limit block still auto-recovers regardless of tree state, and a clean
tree proceeds to normal task selection exactly as before.

`--resume` re-enters such a run even when it blocked with **no pinned session**
— normal under the default `NIGHT_SHIFT_SESSION_SCOPE=stage`, where a stage
session is restartable from the files on disk (the legacy `=run` scope still
refuses, and the refusal names the precondition that failed). A run that took
the cursor backend's sticky fallback resumes with either
`NIGHT_SHIFT_IMPLEMENT_BACKEND` value, and with `cursor-agent` absent or logged
out — nothing left in it uses cursor. Never hand-edit `.night-shift/state.json`
to unstick a run: it is integrity-anchored, so an out-of-band edit is
quarantined and blocks the run.

`NIGHT_SHIFT_ACCEPT_COSTS=YES` is a safety gate so live model calls are never made
by accident (not a billing switch). On a Claude Pro/Max login runs consume plan
**usage limits**; with `ANTHROPIC_API_KEY` set they are **billed per token**.

A run is bounded so it can't burn cost unattended: per-stage and per-task turn/time
budgets (`NIGHT_SHIFT_MAX_STAGE_TURNS` / `…_TASK_TURNS` / `…_STAGE_SECONDS` /
`…_TASK_SECONDS`), and a cap on consecutive malformed/absent primary signals
(`NIGHT_SHIFT_MAX_MALFORMED_SIGNALS`, default 5) that fails fast instead of
grinding the whole turn budget on junk. Hitting any limit blocks the run for
manual review rather than continuing.

A Claude session-limit 429 waits until the reported reset plus a safety
buffer, then resumes the same pinned session (up to 5 consecutive resets
before blocking for manual review). A per-model usage cap is a distinct 429
shape (no reset time) and blocks by default with a knob-and-model suggestion;
`NIGHT_SHIFT_MODEL_FALLBACK=1` instead auto-steps the capped role down the
scarcity ladder (`fable → opus → sonnet`) and continues on the successor.
Persona and observer sub-agent calls hit the same two shapes independently of
the primary: a session-limit 429 mid-batch waits once and re-spawns only the
still-incomplete workers, and a per-model cap follows the identical
block/fallback rule.

## Model tiering (cost)

The engine spends the strong model only where judgment matters. All knobs accept
`inherit` to fall back to the CLI's startup model (e.g. a Pro plan without Opus).

| Knob | Default | Role |
|---|---|---|
| `NIGHT_SHIFT_PLAN_MODEL` | `opus` | Planning (high-leverage) |
| `NIGHT_SHIFT_IMPLEMENT_MODEL` | `sonnet` | Implement grind, observe-request, completion |
| `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` | `opus` | Implement grind for a spec with a `## Design Contract` (judgment-heavy design fidelity) |
| `NIGHT_SHIFT_PERSONA_MODEL` | `sonnet` | Review persona sub-agents |
| `NIGHT_SHIFT_OBSERVER_MODEL` | `opus` | Independent final gate (the backstop that makes a cheaper primary safe) |
| `NIGHT_SHIFT_SESSION_SCOPE` | `stage` | Fresh session per stage scope; `run` for one pinned session. The cursor implement backend requires `stage` — `=run` is rejected at startup. |
| `NIGHT_SHIFT_IMPLEMENT_BACKEND` | `claude` | Opt-in `cursor` runs post-plan primary work (implement/observe/completion) on the Cursor CLI instead; plan/observer/design stay Claude |
| `NIGHT_SHIFT_CURSOR_IMPLEMENT_MODEL` | `cursor-grok-4.6-high` | Model slug for the cursor backend, fresh sessions only |
| `NIGHT_SHIFT_CURSOR_MAX_RETRIES` | `3` | Cursor turn retries before a sticky per-run fallback to Claude |
| `NIGHT_SHIFT_CURSOR_RETRY_BACKOFF` | `30` | Seconds; backoff is this value times the attempt number |
| `NIGHT_SHIFT_CURSOR_MAX_WAIT` | `600` | Ceiling on one turn's TOTAL cursor retry backoff; crossing it falls back to Claude immediately |

The model changes only at stage-scope boundaries (which already start a fresh
session), so it is constant within a scope and resumes never re-pass it.

## Codex as an implement-stage vendor (opt-in)

A spec can declare `- Engines: implement=codex review=codex` to run its
implement-stage grind on the Codex CLI instead of Claude, and/or opt the
advisory per-candidate codex review in/out per spec (overrides
`NIGHT_SHIFT_CODEX_REVIEW` in both directions — the spec wins). Default (no
field): claude-only, codex dormant, byte-for-byte today's behavior. Only the
`implement` role may be `codex`; `plan`/`observer` are Claude-only judgment
gates and are rejected outright — the independent Claude observer always gates
the candidate, whichever vendor implemented it.

| Knob | Default | Role |
|---|---|---|
| `NIGHT_SHIFT_CODEX_SANDBOX` | `danger-full-access` | Sandbox for the codex primary (`-s` fresh / `-c sandbox_mode=...` resume); `workspace-write` also accepted but cannot complete the implement pipeline today (see below) |
| `NIGHT_SHIFT_CODEX_IMPLEMENT_MODEL` | *(empty)* | Codex model override; empty = codex's own configured default; passed on both the fresh AND the resume invocation |
| `NIGHT_SHIFT_CODEX_MAX_RETRY` | `2` | Extra attempts (60s apart) on a nonzero codex exit before `block_run` — no Claude-shaped 429 handling for codex in v1 |

`implement=codex` with no `codex` CLI on PATH fails at spec selection, not
mid-run. `danger-full-access` is the default because codex keeps `.git`
read-only under `workspace-write`, with no config escape hatch — a
workspace-write implement run could never `git commit` a candidate. It is
parity with the Claude primary's own `--permission-mode bypassPermissions`:
the engine's real safety layer (feature-branch confinement, wrapper-forbidden
git ops, `integrity_guard`, the independent observer gate) is vendor-agnostic.
`implement=codex` also requires `NIGHT_SHIFT_SESSION_SCOPE=stage` (the
default) — vendor-specific session ids never cross vendors. Both are validated
loudly at spec selection. A codex turn's usage is journaled on a
`codex_primary` event rather than the Claude-JSON-shaped cost ledger
(`record_cost`), so the viewer's cost panel reflects Claude spend only.

## Layout

```
scripts/night-shift.sh           orchestrator
scripts/lib/personas.sh          persona / track / profile / optional resolution
scripts/lib/visual-capture.sh    opt-in design-fidelity scaffold (inert without a simulator)
scripts/lib/device-registry.sh   opt-in device registry for parallel rn visual_review
scripts/test/fixtures.sh         the deterministic + live fixture suite (sourced under --fixture-test)
scripts/parallel-worktrees.sh    wrapper for fan-out night-shift runs across worktrees
.github/workflows/ci.yml         CI: shellcheck + doc summaries + JS syntax + fixtures + integration + mutation sample
.shellcheckrc                    repo-wide shellcheck config (categorical false positives only)
schemas/                         machine-readable coordination / review contracts
specs/                           one markdown file per feature (the contract)
docs/                            review personas + environment setup
TODO.md  CHANGELOG.md  NIGHT_SHIFT_REVIEW.md   work queue / log / observer ledger
night-shift-viewer/              dashboard + gated launcher (own repo, git-ignored here)
```

## Testing the engine itself

The engine tests itself with four free, deterministic layers — no model calls,
no network, run all of them before any engine commit:

1. **Fixture suite** — `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run`.
   Behavioral where possible, structural only where behavior is unfakeable.
2. **Integration + gherkin scenarios** — `bash scripts/test/integration-run.sh`,
   `bash scripts/test/integration-adverse.sh` (the real engine end-to-end
   against a scripted `claude` stub, happy-path and adverse-path), plus
   `bash scripts/test/scenario-run.sh --all` (executable QA procedures in
   `scripts/test/scenarios/*.feature`).
3. **Mutation harness** — `bash scripts/test/mutate.sh --run --sample <n>`:
   enumerates deterministic single-edit mutants of `scripts/lib/*.sh` and the
   static-scan `.js` libs, runs the fixture suite per mutant, and requires
   each to be killed (caught by the suite going red).
4. **Coverage + survivors ratchets** — shrink-only guardrails, both enforced
   automatically: `scripts/test/untested-allowlist.txt` fails the fixture
   suite if a new function has zero test references, and
   `scripts/test/surviving-mutants.txt` fails the mutation run if a mutant
   survives that isn't already on the (shrinking) allowlist.

CI ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) runs on every push
to `main` and every PR across four jobs: **Shellcheck** (pinned shellcheck
via [`.cursor/install.sh`](./.cursor/install.sh) over every `scripts/**/*.sh`
and `.cursor/*.sh`, honoring [`.shellcheckrc`](./.shellcheckrc))
plus doc-summary and JS-syntax (`node --check`) checks in the same job;
**Fixture tests** (the deterministic suite); **Integration smoke** (both
integration scripts + the gherkin scenarios); and a **Mutation sample** (a
bounded, seeded slice per push; a larger sample via `workflow_dispatch`, the
truly exhaustive `mutate.sh --full` local/overnight-only). Shellcheck is
version-pinned so a green local lint matches CI; `.shellcheckrc` disables only
categorical false positives, and intentional cases carry visible inline
pragmas.

## Visual fidelity (opt-in)

Set `NIGHT_SHIFT_VISUAL_CAPTURE=1` and give an `rn` spec a `## Design Contract` to
enable the `visual_review` stage (Figma-MCP reference + iOS-simulator capture +
`odiff` pixel-diff + agent auto-repair). It requires `xcrun`, `odiff`, a Figma MCP
server, and the app's preview harness; absent any of these it cleanly SKIPs.
