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
   validation worktree and must not regress vs baseline.
4. **Review.** The spec's Track + Review Profile select the persona set that
   reviews the plan and the implementation. Every finding is a blocker; progress
   needs an approval from each active persona.
5. **Observer gate.** A fresh, independent observer session reviews the candidate
   commit. A BLOCK returns the task to a fresh implement session.

## Tracks

A spec declares `- Track: rn | web | node` (default `rn`), which selects the
review persona set, the spec template, and the validation checklist:

- **`rn`** — React Native (`rn-sandbox`). Personas in `docs/review-personas.md`.
- **`web`** — Next.js / React (`web-app`). Personas in `docs/review-personas-web.md`.
- **`node`** — plain Node / CLI / backend, no UI surface. Reuses the backend
  personas; `full` and `logic` profiles only (no UX persona).

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
| `--resume --project PATH [--spec PATH]` | Resume a **preserved logic-blocked run** (re-enters a blocked run rather than starting fresh). |
| `--list-optional-personas` | JSON manifest of the optional cross-track reviewers (no run). |

> **Trust boundary — specs are executable.** The primary runs with
> `--permission-mode bypassPermissions`, and the spec's validation commands are
> executed verbatim via `bash -lc`. Only run specs you authored or fully reviewed.

`NIGHT_SHIFT_ACCEPT_COSTS=YES` is a safety gate so live model calls are never made
by accident (not a billing switch). On a Claude Pro/Max login runs consume plan
**usage limits**; with `ANTHROPIC_API_KEY` set they are **billed per token**.

A run is bounded so it can't burn cost unattended: per-stage and per-task turn/time
budgets (`NIGHT_SHIFT_MAX_STAGE_TURNS` / `…_TASK_TURNS` / `…_STAGE_SECONDS` /
`…_TASK_SECONDS`), and a cap on consecutive malformed/absent primary signals
(`NIGHT_SHIFT_MAX_MALFORMED_SIGNALS`, default 5) that fails fast instead of
grinding the whole turn budget on junk. Hitting any limit blocks the run for
manual review rather than continuing.

## Model tiering (cost)

The engine spends the strong model only where judgment matters. All knobs accept
`inherit` to fall back to the CLI's startup model (e.g. a Pro plan without Opus).

| Knob | Default | Role |
|---|---|---|
| `NIGHT_SHIFT_PLAN_MODEL` | `opus` | Planning (high-leverage) |
| `NIGHT_SHIFT_IMPLEMENT_MODEL` | `sonnet` | Implement grind, observe-request, completion |
| `NIGHT_SHIFT_PERSONA_MODEL` | `sonnet` | Review persona sub-agents |
| `NIGHT_SHIFT_OBSERVER_MODEL` | `opus` | Independent final gate (the backstop that makes a cheaper primary safe) |
| `NIGHT_SHIFT_SESSION_SCOPE` | `stage` | Fresh session per stage scope; `run` for one pinned session |

The model changes only at stage-scope boundaries (which already start a fresh
session), so it is constant within a scope and resumes never re-pass it.

## Layout

```
scripts/night-shift.sh           orchestrator
scripts/lib/personas.sh          persona / track / profile / optional resolution
scripts/lib/visual-capture.sh    opt-in design-fidelity scaffold (inert without a simulator)
scripts/lib/device-registry.sh   opt-in device registry for parallel rn visual_review
scripts/test/fixtures.sh         the deterministic + live fixture suite (sourced under --fixture-test)
scripts/parallel-worktrees.sh    wrapper for fan-out night-shift runs across worktrees
.github/workflows/ci.yml         CI: shellcheck (pinned) + the fixture suite
.shellcheckrc                    repo-wide shellcheck config (categorical false positives only)
schemas/                         machine-readable coordination / review contracts
specs/                           one markdown file per feature (the contract)
docs/                            review personas + environment setup
TODO.md  CHANGELOG.md  NIGHT_SHIFT_REVIEW.md   work queue / log / observer ledger
night-shift-viewer/              dashboard + gated launcher (own repo, git-ignored here)
```

## Tests & CI

The engine self-tests with a large **deterministic fixture suite** (no model
calls, no network) plus a smaller **live** suite that does make paid calls:

```sh
scripts/night-shift.sh --fixture-test --dry-run                    # deterministic only — free
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test # also runs the live (paid) fixtures
```

Fixtures live in [`scripts/test/fixtures.sh`](./scripts/test/fixtures.sh),
sourced by the orchestrator only under `--fixture-test`.

CI ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) runs on every push
to `main` and every PR: a **Shellcheck** job (pinned shellcheck `0.11.0`, linting
all `scripts/**/*.sh` at default severity, honoring [`.shellcheckrc`](./.shellcheckrc))
and a **Fixture tests** job (the deterministic suite). The version is pinned so a
green local lint matches CI; `.shellcheckrc` disables only categorical false
positives, and intentional cases carry visible inline pragmas.

## Visual fidelity (opt-in)

Set `NIGHT_SHIFT_VISUAL_CAPTURE=1` and give an `rn` spec a `## Design Contract` to
enable the `visual_review` stage (Figma-MCP reference + iOS-simulator capture +
`odiff` pixel-diff + agent auto-repair). It requires `xcrun`, `odiff`, a Figma MCP
server, and the app's preview harness; absent any of these it cleanly SKIPs.
