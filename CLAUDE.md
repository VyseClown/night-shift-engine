# Claude Workspace Instructions

Read and follow `AGENTS.md` first. For autonomous or overnight work, also read
and follow `AGENT_LOOP.md`.

The startup-selected model remains the primary for the entire run. Do not switch
roles with reviewers or the observer, and do not use implicit session selectors.

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
  paid runs, `NSV_ALLOW_EDIT` = spec editor. The viewer scans `rn-sandbox`,
  `web-app`, `nightshift-demo` only.
- A target project must gitignore `.night-shift/` and be on the spec's feature
  branch before a run. `NEXT_TASK` only continues to same-project TODO specs.

> **Note:** the night-shift workflow is two-track. A spec declares `- Track: rn`
> or `- Track: web` (default `rn`), which selects the review persona set
> (`docs/review-personas.md` vs `docs/review-personas-web.md`), the spec template
> (`specs/_template.md` vs `specs/_template-web.md`), and the matching Validation
> Checklist in `AGENTS.md`. `rn-sandbox` is the `rn` track; `web-app` is the
> `web` track. Always use each project's own `CLAUDE.md` for its real commands.
> The night-shift process rules in `AGENTS.md` apply to both tracks.
