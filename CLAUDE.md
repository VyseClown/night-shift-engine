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

> **Note:** the night-shift workflow is two-track. A spec declares `- Track: rn`
> or `- Track: web` (default `rn`), which selects the review persona set
> (`docs/review-personas.md` vs `docs/review-personas-web.md`), the spec template
> (`specs/_template.md` vs `specs/_template-web.md`), and the matching Validation
> Checklist in `AGENTS.md`. `rn-sandbox` is the `rn` track; `web-app` is the
> `web` track. Always use each project's own `CLAUDE.md` for its real commands.
> The night-shift process rules in `AGENTS.md` apply to both tracks.
