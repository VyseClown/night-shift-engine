# Claude Workspace Instructions

Read and follow `AGENTS.md` first. For autonomous or overnight work, also read
and follow `AGENT_LOOP.md`.

> **Which command for my task?** See `docs/COMMAND-PLAYBOOK.md` — a task → command
> index (Figma export via MCP, RN visual-fidelity review/auto-fix, in-loop repair,
> Maestro-driven capture + flow generation, running a night-shift, Figma→web
> component conversion) with the exact command and prerequisites for each.

Do not switch roles with reviewers or the observer, and do not use implicit
session selectors. The engine deliberately tiers models by role to spend the
strongest model only where judgment matters: the primary **plans** on
`NIGHT_SHIFT_PLAN_MODEL` (default `opus`) and does all post-plan work — implement,
observe-request, completion — on the cheaper `NIGHT_SHIFT_IMPLEMENT_MODEL`
(default `sonnet`); persona review sub-agents default to `sonnet`
(`NIGHT_SHIFT_PERSONA_MODEL`); and the independent final observer runs on
`NIGHT_SHIFT_OBSERVER_MODEL` (default `opus`) as the strong backstop that makes a
cheaper primary safe (an observer BLOCK returns the task to a fresh implement
session). The model switches only at stage-scope boundaries, which already start
a fresh session, so it is constant within a scope and resumes never re-pass it.
Set any knob to `inherit` to use the CLI's startup model (e.g. a Pro plan without
Opus access).

## Model ruling

Which model each knob should carry, by the kind of work the spec demands. Knobs
pass their value verbatim to `claude --model`, so full IDs (`claude-fable-5`)
work anywhere an alias is uncertain. "Strongest available" means the best
judgment-tier model the current subscription carries — `claude-fable-5` while
it lasts, `opus` after it leaves the subscription (the built-in defaults
already say `opus`, so the fable choice is an explicit opt-in, never a default
that silently breaks).

| Role (knob) | Ruling |
|---|---|
| `NIGHT_SHIFT_PLAN_MODEL` | Strongest available. Planning quality bounds the whole run. |
| `NIGHT_SHIFT_IMPLEMENT_MODEL` | `sonnet`. The grind; the observer backstops it. |
| `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` | Strongest available — design-contract builds are judgment-heavy. |
| `NIGHT_SHIFT_PERSONA_MODEL` | `sonnet`. Breadth over depth; the observer is the deep gate. |
| `NIGHT_SHIFT_OBSERVER_MODEL` | Strongest available. Never weaker than the implement model. |
| `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` | Strongest available for design-contract work; `sonnet` for cosmetic-only specs. |
| `NIGHT_SHIFT_SWEEP_MODEL` | Strongest available — whole-branch judgment; defaults to the observer model. |
| `NIGHT_SHIFT_IMPLEMENT_BACKEND` | `claude` (default). Opt-in `cursor` runs post-plan implement work on `NIGHT_SHIFT_CURSOR_IMPLEMENT_MODEL` (default `cursor-grok-4.6-high`); plan/observer/design stay strongest-available Claude regardless. Never for money-math or engine-safety specs without an explicit call. |

Spec-type adjustments: scratch/demo targets (`nightshift-demo`, throwaway
specs) run everything on `sonnet` — never spend judgment-tier budget there.
Specs touching money math, wire contracts, or engine safety invariants keep
plan AND observer on the strongest available even when implement stays
`sonnet`. Fixture/dry runs (`--fixture-test`, `--dry-run`) never need a model
choice at all. The global per-project defaults live in `~/.claude/CLAUDE.md`.

## Workspace Map

The **night-shift engine repo** (`night-shift-engine/` — the orchestrator
`scripts/`, the `schemas/` contracts, `docs/`, `specs/`, and these workflow docs)
lives in its own directory inside a workspace container. The independent app
project repos (`rn-sandbox/`, `web-app/`, `water-tracker-app/`, `night-shift-viewer/`,
…) are **siblings alongside it**, each its own repo; the container itself is not a
git repo. Run a project's own git and validation commands inside that project
directory; run engine/workflow git inside the engine directory.

| Project | Stack | Validation / commands |
|---|---|---|
| `web-app/` | Next.js 16 + React 19 + Prisma + Postgres (web) | see `web-app/CLAUDE.md` |
| `rn-sandbox/` | React Native 0.85 (bare, New Arch) | see `rn-sandbox/CLAUDE.md` |
| `water-tracker-app/` | React Native (Expo 56 + expo-router + Skia) | see `water-tracker-app/CLAUDE.md` |
| `nightshift-demo/` | plain Node (vitest) — scratch/demo target | `node --test` |
| `night-shift-viewer/` | Hono + Vite/React dashboard, launcher, spec editor | its own repo + `WORKFLOW.md` |

## Engine + viewer (two repos)

- **Engine** = this repo (`night-shift-engine/`, GitHub `VyseClown/night-shift-engine`):
  `scripts/night-shift.sh` + sourced libs `scripts/lib/personas.sh` (persona/profile
  resolution) and `scripts/lib/visual-capture.sh` (Phase-2 design-fidelity scaffold,
  inert without a simulator), plus `schemas/`, `specs/`, `docs/`.
- **Viewer** = `night-shift-viewer/` (GitHub `VyseClown/night-shift-viewer`): a
  read-only dashboard + **gated** launcher + **gated** spec editor. It does not
  reimplement the workflow — its Launch tab spawns this same `scripts/night-shift.sh`.
  Authoritative model: `night-shift-viewer/WORKFLOW.md`.

## Running a night-shift

- **CLI** (run from the `night-shift-engine/` directory): `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <project-path> --spec specs/<name>.md`.
  Free pre-flight: append `--fixture-test --dry-run` (deterministic fixtures).
- **Viewer** (run from the workspace container, where the engine and viewer are siblings): server `cd night-shift-viewer/server && NSV_ALLOW_EDIT=1 NSV_ALLOW_LAUNCH=1 NSV_ALLOW_REAL=1 npm run dev:real`;
  web `cd ../web && npm run dev`; open http://127.0.0.1:5173. `NSV_ALLOW_REAL` = real
  paid runs, `NSV_ALLOW_EDIT` = spec editor. The viewer **auto-discovers**
  target repos in the workspace container: any sibling that is its own git repo and has opted
  in by gitignoring `.night-shift/` (or already has a `.night-shift/` run dir).
  Override with `NSV_PROJECT_DIRS=/abs/a:/abs/b`. A repo that does not gitignore
  `.night-shift/` is intentionally skipped (a run there would commit artifacts).
- A target project must gitignore `.night-shift/` and be on the spec's feature
  branch before a run. **Monorepos:** point `--project` at the repo root; a
  spec may declare ``- Workdir: `apps/<app>` `` (backticks required) to run every
  validation phase in that subdir (validated at spec selection: must exist,
  be tracked at HEAD, and resolve inside the project — no symlink escapes;
  malformed fields fail loudly). pnpm
  workspaces need no `NIGHT_SHIFT_DEPENDENCY_LINKS` override — each workspace
  package's `node_modules` (from `pnpm-workspace.yaml`) plus `.nx/cache` are
  auto-linked into the validation worktree. `NEXT_TASK` only continues to same-project TODO specs,
  and only on runs started *without* `--spec` (the engine picks the task from
  TODO). An explicit `--spec` run is a single task: on `NEXT_TASK` it completes
  and exits 0 so an external wrapper can own cross-spec sequencing/branching.
- **Smoke-run validation (opt-in per spec):** an optional `- Smoke: `<command>`` field
  (+ `- Smoke URL: `<http://127.0.0.1:PORT/…>`` for a server) adds a gated phase
  right after baseline and final validation, on both the initial and any chained
  task — proof the app actually BOOTS, not just that tsc/eslint/jest pass (the
  evidence class: a Release-bundle break that passed every one of those). No URL
  ⇒ exit mode (the command itself must exit 0 within `NIGHT_SHIFT_SMOKE_TIMEOUT`,
  default 120s); URL present ⇒ server mode (poll for HTTP 200 every 2s until the
  timeout, then TERM-then-KILL the whole process group — never leaves a zombie
  dev server, including on an interrupted run). Baseline never blocks on its own
  smoke result (recorded and only judged for regression, exactly like any other
  baseline command); final regresses the candidate exactly like the ordinary
  final-validation gate. The URL must be loopback-only (`http://127.0.0.1` or
  `http://localhost`) and both fields require backticks — malformed or missing
  fields fail loudly at spec selection, same dialect as `- Workdir:`.
- **Cost knobs:** the primary runs as **stage-scoped sessions** by default
  (`NIGHT_SHIFT_SESSION_SCOPE=stage`) — a fresh Claude session per stage scope
  (plan → implement → observe) handing off through files, which avoids replaying
  one ever-growing session every turn; set `=run` for the legacy single pinned
  session. Persona sub-agents default to `sonnet` (`NIGHT_SHIFT_PERSONA_MODEL`).
  Per-role model tiering: `NIGHT_SHIFT_PLAN_MODEL` (default `opus`) for planning,
  `NIGHT_SHIFT_IMPLEMENT_MODEL` (default `sonnet`) for the implement grind,
  `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` (default `opus`) for the implement grind of a
  spec with a `## Design Contract` (judgment-heavy design-fidelity build — Flow B), and
  `NIGHT_SHIFT_OBSERVER_MODEL` (default `opus`) for the independent final gate —
  any set to `inherit` to fall back to the CLI's startup model.
- **Test audit (opt-in, default OFF):** `NIGHT_SHIFT_TEST_AUDIT=1` runs
  `scripts/test-audit.sh` once per candidate over ONLY the test files the
  candidate diff touched (skips cleanly when none), on
  `NIGHT_SHIFT_TEST_AUDIT_MODEL` (default `sonnet` — the Model ruling's
  breadth tier, same as `NIGHT_SHIFT_PERSONA_MODEL`/port-audit; escalate to a
  judgment-tier model only for specs where false-confidence findings would be
  expensive to miss, it is not the default). A deterministic static scan for
  vacuous-assertion smells plus one bounded agent judgment pass (confirm/
  refute each static finding, hunt additional judgment-tier smells like a mock
  tested against itself) — every count in the report is recomputed by the
  script, never taken from the agent. NON-gating: the report is attached to
  the implementation-review bundle and the observer's evidence, and a
  `test_audit` event (`{files, final_total}`) is journaled; a failed or
  missing report only WARNs. See `docs/COMMAND-PLAYBOOK.md` §11 for the
  standalone CLI contract.
- **Journal events added by this tranche** (for anyone grepping
  `events.jsonl`): `sweep` (branch-sweep verdict), `sweep_fix` /
  `sweep_fix_reverted` (fix-cycle round + deterministic revert, the latter
  carrying a `reason` of `dirty_tree` or a failed re-validation), `run_feedback`
  (feedback entry appended), `smoke` (smoke-phase result), and — from the
  cursor implementer backend — `backend_retry` (a failed cursor turn retrying)
  and `backend_fallback` (sticky per-run fallback to Claude after retries are
  exhausted). All are advisory; none gates a run.
- **Codex second opinion (opt-in, default OFF):** `NIGHT_SHIFT_CODEX_REVIEW=1`
  adds one bounded `codex exec -s read-only` advisory review per candidate
  (gpt-5.5 via the Codex CLI), handed to the observer as supplementary,
  NON-gating evidence (`NIGHT_SHIFT_CODEX_TIMEOUT`, default 300s). Missing
  CLI / failure / timeout skip cleanly and are journaled (`codex_review`
  events). The verdict pipeline stays Claude-only either way — leave this off
  unless you deliberately want a second vendor's perspective.
- **Run feedback (default ON):** at every run's completion (before the branch
  sweep block below, and regardless of `NIGHT_SHIFT_BRANCH_SWEEP`), a short
  fresh session distills the run's journal into 5-15 bullets for the human who
  authors specs — spec ambiguities, stages that looped, validation friction —
  appended to `<project>/.night-shift/feedback.md` (a persistent, cross-run
  file; never touched by `compact_success`). Gated on `NIGHT_SHIFT_RUN_FEEDBACK`
  (default `1`; set `=0` to skip the session's cost entirely). Advisory only —
  a session failure or unparseable reply WARNs and never blocks or delays
  completion.
- **Branch sweep, in-run (opt-in, default OFF):** `NIGHT_SHIFT_BRANCH_SWEEP=1`
  or `=advisory` adds one whole-branch strong-model review at run completion —
  the full merge-base diff, read by `NIGHT_SHIFT_SWEEP_MODEL` (default = the
  observer model) — for what per-task reviews can't see: cross-task
  interactions, accumulated minor findings, hygiene. Never gates completion.
  `=1` additionally runs a capped fix cycle (`NIGHT_SHIFT_SWEEP_MAX_FIX`,
  default `1`) on a `SWEEP_FINDINGS` verdict — an implement-model session
  fixes only the findings, final validation re-runs, and a failed
  re-validation deterministically `git reset --hard`s back to the pre-fix tip
  rather than trusting the agent to self-revert. `=advisory` writes findings
  only, no fix cycle. `NIGHT_SHIFT_SWEEP_MAX_WAIT` (default `900`s) bounds the
  sweep session's own rate-limit retry. Standalone surface: `scripts/night-shift.sh
  --sweep-only --project <path>` runs the same review outside any run/queue —
  verdict-only by default regardless of `NIGHT_SHIFT_BRANCH_SWEEP` (that knob
  must be exactly `1` on this surface to also run the fix cycle), exit `0`
  `SWEEP_PASS` / `2` `SWEEP_FINDINGS`/`SWEEP_ERROR`. See
  `docs/COMMAND-PLAYBOOK.md` for the full contract.
- **Visual fidelity (opt-in):** set `NIGHT_SHIFT_VISUAL_CAPTURE=1` and give an rn
  spec a `## Design Contract` to enable the `visual_review` stage (Figma-MCP
  reference + iOS-simulator capture + `odiff` pixel-diff + agent auto-repair).
  Requires `xcrun`, `odiff`, a Figma MCP server, and the app's preview harness;
  absent any of these it cleanly SKIPs. The viewer renders the per-screen
  reference/implementation/diff images, diff%, analysis, and attempt history.
  The repair agent runs on `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default `opus` — design
  fidelity is judgment-heavy; `=sonnet`/`=inherit` overrides). The engine's headless MCP
  `claude -p` calls (Figma reference export + the per-run `get_figma_data` fetch) run
  with `--permission-mode bypassPermissions` — MCP tools are otherwise deferred in
  headless — and the repair flow fetches `get_figma_data` once per run (cached under
  `design/<screen>-figma.json`, reused across runs) rather than a prose summary, and the
  repair agent honors the spec's `## Design Contract` + `## Design source` sections — so
  design details a flat image misses (e.g. a ring built from two layered wave nodes) are
  stated in the spec you edit and backed by the complete node tree.
- **Ad-hoc visual comparison (no capture):** `scripts/visual-compare.sh --manifest
  <pairs.json> --run-dir <runDir> [--name <report>]` pixel-diffs EXISTING image pairs
  (e.g. responsive-web screenshots vs native sim captures for a design review) and
  writes a standard `visual-diff-<name>.json` + assets into the run's `validated/`,
  so the viewer's Visual-validation panel renders reference|candidate|diff + diff%
  with zero viewer changes. Reuses `__visual_pixel_diff` (odiff parsing + resize
  edge cases); `diff_pct` is the contract's 0–1 fraction; per-pair
  `tolerance`/`device`/`analysis` overrides in the manifest (see the script header
  for the manifest shape). Requires `odiff` + `jq`; no simulator, no Figma.

> For **parallel** visual_review across worktrees, set `NIGHT_SHIFT_DEVICE_REGISTRY=1`
> (the `scripts/parallel-worktrees.sh` wrapper sets it automatically for `--jobs>1`). Each
> concurrent run then claims a dedicated iOS simulator from a machine-global registry at
> `~/.night-shift/devices/`, cloning `ns-<run-id>` devices when the matching pool is
> exhausted and pruning them on the next registry-mode run. A single run is unaffected.
> Requires pre-bundled preview builds (no Metro).

> **Driving the preview on newer iOS (`scripts/visual-review.sh --drive file`).**
> Capture pushes each screen into the app one of three ways (`__visual_capture_screenshot`,
> most→least prompt-proof): **file** (`NIGHT_SHIFT_PREVIEW_FILE` + `NIGHT_SHIFT_PREVIEW_BUNDLE_ID`)
> writes `"<screen>:<state>"` into the app's document dir then cold-launches — prompt-free
> and needs no native code, so it works with a JS-only harness; **launcharg** (bundle id only)
> cold-launches with a `--nightshift-preview` arg the app must read natively; **openurl**
> (default) is a custom-scheme deep link, but **iOS 16+ pops an "Open in app?" confirmation
> that blocks unattended capture** — so on current simulators use `--drive file`. The app
> must implement the matching boot path (water-tracker: a `src/preview/bootTarget.ts` reader
> gated behind `EXPO_PUBLIC_PREVIEW=1`; build the capture app with that env). Also note the
> capture app must be a **Release/standalone build** (embedded bundle, no Metro) and **no
> test files may live in expo-router's `app/` dir** — its `require.context` sweeps every
> `*.ts(x)` into the production bundle, so a stray `*.test.tsx` importing `node:sqlite` etc.
> breaks the Release bundle while passing tsc/eslint/jest. See
> `docs/2026-06-24-visual-review-live-path.md`.

> **In-loop auto-repair (opt-in).** Set `NIGHT_SHIFT_VISUAL_REPAIR=1` to have the
> engine's `visual_review` stage auto-repair over-tolerance screens during a build:
> it captures, repairs the failing screens (the shared `claude -p` repair agent +
> Metro fast-reload), commits a `fix(visual): auto-repair …` commit on the project's
> feature branch, points the candidate at it, and hands the repaired tip to the
> observer. Requires the project's preview dev build/Metro; cleanly **skips** (proceeds
> to the observer unrepaired, never blocks) if the harness/tooling is unavailable, and
> never runs on `main`/`master`. Default OFF — when unset, `visual_review` is unchanged.
> Knobs: `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` (default 3), `NIGHT_SHIFT_VISUAL_REPAIR_SHARED=1`
> (also edit `src/ui`), `NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP` (default 30).

> **Maestro capture drive (`--drive maestro`).** An alternative to the seeded preview
> harness: instead of a preview route, write a Maestro flow per screen-state at
> `$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml` (default `<project>/.maestro`) that
> drives the **real** app to the scenario matching the Figma frame
> (`launchApp` + taps/input/scroll, **no `takeScreenshot`** — the pipeline screenshots).
> Run `scripts/visual-review.sh --project <app> --drive maestro` against a normal
> build (no `EXPO_PUBLIC_PREVIEW`/preview route). A missing flow or missing `maestro`
> on PATH cleanly SKIPs that spec's capture (never blocks), so author a flow for every
> screen-state in the matrix. Sample: `docs/examples/maestro/Home-default.yaml`.

> **Note:** the night-shift workflow is multi-track. A spec declares `- Track: rn`,
> `- Track: web`, `- Track: node`, or `- Track: fullstack` (default `rn`), which
> selects the review persona set (`docs/review-personas.md` for `rn`,
> `docs/review-personas-web.md` for `web`; `node` reuses existing backend
> personas — Backend & Data Expert, TypeScript & Code Quality Expert, Performance
> Expert, Human Advocate — with no UX persona and only the `full`/`logic`
> profiles; `fullstack` runs the web bench with Backend & Data Expert promoted
> into the always-run floor, `full`/`logic` profiles only — for changes spanning
> API + web UI, e.g. in a monorepo), the spec template (`specs/_template.md` vs
> `specs/_template-web.md` vs `specs/_template-fullstack.md`), and the matching
> Validation Checklist in `AGENTS.md`. `rn-sandbox` is the `rn` track; `web-app` is the
> `web` track; plain Node/CLI repos (e.g. `slack-status`) are the `node` track.
> Always use each project's own `CLAUDE.md` for its real commands. The night-shift
> process rules in `AGENTS.md` apply to all tracks.
