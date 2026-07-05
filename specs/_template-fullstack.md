# Spec: [Feature Name] (Fullstack)

> Copy this file to `specs/feature-name.md` before starting implementation.
> This is the **fullstack** template: one change spanning an API/backend surface
> AND a web UI surface (e.g. a route handler + the page that consumes it, or a
> monorepo change touching `apps/api` and `apps/web` together). For web-only
> work use `_template-web.md`; for backend-only work use the `node` track. Fill
> in every section. Ambiguous specs produce wrong implementations.

---

## Status

- [ ] Draft
- [ ] Ready for implementation
- [ ] In progress
- [ ] Done — branch: `feat/[name]`

---

## Repository

- Project path: `~/work/[project-name]`
- Base branch: `main`
- Feature branch: `feat/[name]`
- Existing worktree path (if any): none
<!-- Monorepo apps only: uncomment to run EVERY validation phase (baseline,
     test-first red/green, final) inside a project subdirectory, so commands
     stay app-local while --project remains the repo root. Rejected unless the
     directory exists under the project, is tracked at HEAD, and resolves
     inside it (backticks around the value are REQUIRED — a bare value fails
     loudly at spec selection). Example (indented so this example is not
     itself parsed as the field):
       - Workdir: `apps/my-app`
-->

The project path must resolve to the repository that will be changed (for a
monorepo: the repo root, with validation commands written to run from the
root, e.g. `pnpm --filter <app> test` — or set `- Workdir:` above and write
them app-local). Night-shift runs do not infer a repository from the
workspace root.

---

## Review

- Track: fullstack
- Review Profile: full | logic

`Track: fullstack` runs the full web bench with a stronger floor: **Backend &
Data Expert joins Web Architect in the always-run floor**, so neither side of
the stack can be dropped by a lighter profile. Pick one:

| Profile | Personas                          | Use for |
|---------|-----------------------------------|---------|
| `full`  | all six (default)                 | anything with UI impact; when unsure |
| `logic` | floor + Performance Expert        | seam/contract/business-rule work with no visual change |

Floor (always runs, every profile): Web Architect, Backend & Data Expert,
TypeScript & Code Quality Expert, Human Advocate — plus the independent
observer. There is deliberately no `frontend`/`data` profile here: a change
narrow enough to drop one side of the stack belongs on the `web` or `node`
track instead. A missing or unknown profile blocks the run.

- Optional reviewers: none
<!-- Optional, cross-track reviewers. Off by default. Allowed values (comma- or
     pipe-separated): Product Reviewer, Design Fidelity Reviewer, Security
     Reviewer, API Contract Reviewer. Each listed reviewer is added to the active
     set. A reviewer also auto-activates when its contract section is present
     (## Product Contract → Product Reviewer; ## Design Contract → Design Fidelity
     Reviewer; ## Security Contract → Security Reviewer; ## API Contract → API
     Contract Reviewer). Use `none` for no extras. An active optional reviewer
     must own a Documentation line below. For fullstack work the **API Contract
     Reviewer** is usually worth opting into — the API/UI seam is where these
     specs fail. -->

<!-- OPTIONAL per-spec override. Uncomment to name the EXACT reviewers to run,
     overriding the Review Profile above. The active set becomes the fullstack
     floor (Web Architect + Backend & Data Expert + TypeScript & Code Quality
     Expert + Human Advocate) plus exactly these names. Each name must be a
     fullstack-track persona or an optional reviewer; an off-track name is
     rejected. When set, Review Profile is ignored.
     Example (indented so this example is not itself parsed as the field):
       - Personas: Web UX & Accessibility Designer, API Contract Reviewer
-->

---

## Summary

One paragraph. What is this feature, why does it exist, and who uses it?

---

## User Story

> As a [type of user], I want to [do something] so that [outcome].

---

## Acceptance Criteria

Each criterion is binary — pass or fail. The agent must satisfy all of them.
For fullstack work, include at least one criterion that exercises the seam
end-to-end (UI action → API → persisted/returned state → UI).

- [ ] AC1: ...
- [ ] AC2: ...
- [ ] AC3: ...

---

## Surface Notes

| Area | Behavior |
|---|---|
| API (routes / handlers / services) | ... |
| Contract (shapes shared across the seam) | ... |
| Client (page, interactivity, state) | ... |
| Data (schema / DB / migration) | ... |
| i18n (locales, default) | ... |

Name where the seam lives (shared types package? OpenAPI? hand-rolled fetch?),
which side owns the contract, and how a breaking change on one side is caught
on the other.

---

## Technical Approach

Describe the implementation strategy at a high level. Include:
- Which files will be created or modified, on each side of the seam
- Which libraries will be used (must already be declared)
- The data flow (API handler → transport → client state → render)
- The order of work (contract first, then API, then UI — or as fits)

---

## Permissions

- New dependencies permitted: no
- Database migration permitted: no
- Network access required during implementation: no

List every approved dependency, migration, or change here. A `yes` without
details is not approval.

---

## Documentation

- Required workspace docs:
- Required project docs:
- Documentation owned by each review persona:
  - Web UX & Accessibility Designer:
  - Web Architect:
  - Backend & Data Expert:
  - TypeScript & Code Quality Expert:
  - Performance Expert:
  - Human Advocate:
  <!-- Add an ownership line for any active OPTIONAL persona too, e.g.:
  - API Contract Reviewer: API Contract -->

Every active persona needs an ownership line — whether it is active via the
Review Profile, an explicit `- Personas:` list, or an optional reviewer. For
personas that are not active, use `none — not in profile`; use `none — [reason]`
when an active persona has no domain-relevant documentation.

---

<!-- OPTIONAL contract sections follow. Each is a top-level `## … Contract`
     heading (level 2 — auto-activation matches `^## `, so do NOT nest them).
     Delete the ones you don't need; fill in the ones you keep. -->

## API Contract

> OPTIONAL but recommended on this track. Auto-activates the **API Contract
> Reviewer** (and makes it own this contract). Delete the section if not needed.

- Surface: ... (HTTP routes, RPC, shared schema, public module boundary)
- Endpoints / operations: ...
- Request / response shapes: ...
- Error model: ... (status codes / error types)
- Versioning & backward compatibility: ...
- Schema / contract file: ...

---

## Security Contract

> OPTIONAL. Auto-activates the **Security Reviewer** (and makes it own this
> contract). Delete the section if not needed.

- Trust boundary: ... (what untrusted input crosses into this change)
- Sensitive data touched: ... (PII, credentials, tokens, financial, none)
- Authn / authz changes: ...
- Secrets handling: ... (never in source/logs/bundles)
- Threats considered: ...
- Accepted risks: ...

---

## Edge Cases

List the non-happy-path scenarios the implementation must handle:

- API down / slow / returning errors while the UI is live
- Contract drift (client built against an older response shape)
- Empty state (no data) on both sides
- Interrupted flow (double-submit, refresh, navigate away mid-action)
- Unauthenticated vs authenticated user
- Large or malformed payloads crossing the seam
- [Add more specific to this feature]

---

## Test Plan

- First failing test or executable check: `[test command for the seam-level failing test]`
<!-- Must be RED before the change. Net-new: name the not-yet-existing test (absent →
     red). MODIFYING an already-tested module (named test exists and passes at
     baseline): the engine auto-detects "modify-mode" — it does not block on the green
     baseline and instead proves red by overlaying the candidate's updated test files
     onto BASE production after implementation. Naming an existing test is fine. -->
- Unit tests for: [API handlers/services AND client logic]
- Integration tests for: [the seam — request/response shapes both sides agree on]
- E2E test (if applicable): [the end-to-end flow through the real UI]
- Baseline validation commands (run before edits):
  1. `[typecheck command]`
  2. `[lint command]`
  3. `[test command]`
- Final validation commands (run in this order):
  1. `[typecheck command]`
  2. `[lint command]`
  3. `[test command]`
  4. `[build command]` (both sides must build)
<!-- Monorepo note: write every command to run from the repo root, filtered to
     the touched projects (e.g. `pnpm nx run-many -t typecheck test --projects
     app-api,app-web`). Rebuild consumed packages before typechecking consumers
     when imports resolve through built dist/. -->
- Expected evidence paths:
- Manual test checklist:
  - [ ] Exercise the flow end-to-end in a browser against the real API
  - [ ] Kill the API mid-flow; the UI degrades per the Edge Cases
  - [ ] Test with keyboard-only navigation
  - [ ] Test both locales (if localized)

---

## Out of Scope

List things that might seem related but are NOT part of this spec:

- ...

---

## Open Questions

Questions that must be resolved before implementation starts. Leave blank if none.

- Q: ...  A: ...

---

## Related

- Spec: (link to any related specs)
- TODO entry: `TODO.md#[entry]`
- Changelog entry: `CHANGELOG.md#[entry]`
- Review artifact: `NIGHT_SHIFT_REVIEW.md#[run-id]`
- PR: (filled in after merge)
- Issue / ticket: (if tracked externally)
