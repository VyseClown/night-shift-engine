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

## Workspace Map

`~/work` is the **night-shift engine repo** (the orchestrator `scripts/`, the
`schemas/` contracts, `docs/`, `specs/`, and these workflow docs). It also
*contains* independent app project repos (`rn-sandbox/`, `web-app/`,
`night-shift-viewer/`, …) which are **git-ignored here** — each has its own repo.
Run a project's own git and validation commands inside that project directory; run
engine/workflow git here at the root.

| Project | Stack | Validation / commands |
|---|---|---|
| `web-app/` | Next.js 16 + React 19 + Prisma + Postgres (web) | see `web-app/CLAUDE.md` |
| `rn-sandbox/` | React Native 0.85 (bare, New Arch) | see `rn-sandbox/CLAUDE.md` |
| `nightshift-demo/` | plain Node (vitest) — scratch/demo target | `node --test` |
| `night-shift-viewer/` | Hono + Vite/React dashboard, launcher, spec editor | its own repo + `WORKFLOW.md` |

## Engine + viewer (two repos)

- **Engine** = this repo (`~/work`, GitHub `VyseClown/night-shift-engine`):
  `scripts/night-shift.sh` + sourced libs `scripts/lib/personas.sh` (persona/profile
  resolution) and `scripts/lib/visual-capture.sh` (Phase-2 design-fidelity scaffold,
  inert without a simulator), plus `schemas/`, `specs/`, `docs/`.
- **Viewer** = `night-shift-viewer/` (GitHub `VyseClown/night-shift-viewer`): a
  read-only dashboard + **gated** launcher + **gated** spec editor. It does not
  reimplement the workflow — its Launch tab spawns this same `scripts/night-shift.sh`.
  Authoritative model: `night-shift-viewer/WORKFLOW.md`.

## Running a night-shift

- **CLI** (from `~/work`): `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project ~/work/<proj> --spec specs/<name>.md`.
  Free pre-flight: append `--fixture-test --dry-run` (deterministic fixtures).
- **Viewer**: server `cd night-shift-viewer/server && NSV_ALLOW_EDIT=1 NSV_ALLOW_LAUNCH=1 NSV_ALLOW_REAL=1 npm run dev:real`;
  web `cd ../web && npm run dev`; open http://127.0.0.1:5173. `NSV_ALLOW_REAL` = real
  paid runs, `NSV_ALLOW_EDIT` = spec editor. The viewer **auto-discovers**
  target repos under `~/work`: any sibling that is its own git repo and has opted
  in by gitignoring `.night-shift/` (or already has a `.night-shift/` run dir).
  Override with `NSV_PROJECT_DIRS=/abs/a:/abs/b`. A repo that does not gitignore
  `.night-shift/` is intentionally skipped (a run there would commit artifacts).
- A target project must gitignore `.night-shift/` and be on the spec's feature
  branch before a run. `NEXT_TASK` only continues to same-project TODO specs,
  and only on runs started *without* `--spec` (the engine picks the task from
  TODO). An explicit `--spec` run is a single task: on `NEXT_TASK` it completes
  and exits 0 so an external wrapper can own cross-spec sequencing/branching.
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
> `- Track: web`, or `- Track: node` (default `rn`), which selects the review
> persona set (`docs/review-personas.md` for `rn`, `docs/review-personas-web.md`
> for `web`; `node` reuses existing backend personas — Backend & Data Expert,
> TypeScript & Code Quality Expert, Performance Expert, Human Advocate — with no
> UX persona and only the `full`/`logic` profiles), the spec template
> (`specs/_template.md` vs `specs/_template-web.md`), and the matching Validation
> Checklist in `AGENTS.md`. `rn-sandbox` is the `rn` track; `web-app` is the
> `web` track; plain Node/CLI repos (e.g. `slack-status`) are the `node` track.
> Always use each project's own `CLAUDE.md` for its real commands. The night-shift
> process rules in `AGENTS.md` apply to all tracks.
