# Spec: [Feature Name] (Web)

> Copy this file to `specs/feature-name.md` before starting implementation.
> This is the **web** template (Next.js / React web apps). For React Native use
> `_template.md`. Fill in every section. Ambiguous specs produce wrong
> implementations.

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

The project path must resolve to the repository that will be changed. Night-shift
runs do not infer a repository from the workspace root.

---

## Review

- Track: web
- Review Profile: full | frontend | logic | data

`Track: web` selects the web persona set (`docs/review-personas-web.md`). The
profile selects which of those personas run, so review depth matches the work and
small tasks don't pay for irrelevant reviewers. Pick one:

| Profile    | Personas                                                     | Use for |
|------------|--------------------------------------------------------------|---------|
| `full`     | all six (default)                                            | broad or risky changes; when unsure |
| `frontend` | floor + Web UX & Accessibility Designer + Performance Expert | UI / page / component work |
| `logic`    | floor + Performance Expert                                   | business-rule / pure-logic work, no UI |
| `data`     | floor + Backend & Data Expert                                | schema / query / API / auth work |

Floor (always runs, every profile): Web Architect, TypeScript & Code Quality
Expert, Human Advocate — plus the independent observer. A missing or unknown
profile blocks the run.

- Optional reviewers: none
<!-- Optional, cross-track reviewers. Off by default. Allowed values (comma- or
     pipe-separated): Product Reviewer, Design Fidelity Reviewer, Security
     Reviewer, API Contract Reviewer. Each listed reviewer is added to the active
     set. A reviewer also auto-activates when its contract section is present
     (## Product Contract → Product Reviewer; ## Design Contract → Design Fidelity
     Reviewer; ## Security Contract → Security Reviewer; ## API Contract → API
     Contract Reviewer). Use `none` for no extras. An active optional reviewer
     must own a Documentation line below. -->

<!-- OPTIONAL per-spec override. Uncomment to name the EXACT reviewers to run,
     overriding the Review Profile above. The active set becomes the web floor
     (Web Architect + TypeScript & Code Quality Expert + Human Advocate) plus
     exactly these names. Each name must be a web-track persona or an optional
     reviewer; an off-track name is rejected. When set, Review Profile is ignored.
     Example (indented so this example is not itself parsed as the field):
       - Personas: Backend & Data Expert, API Contract Reviewer
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

- [ ] AC1: ...
- [ ] AC2: ...
- [ ] AC3: ...

---

## Surface Notes

| Area | Behavior |
|---|---|
| Server (RSC / route handler / action) | ... |
| Client (interactivity, state) | ... |
| Data (Prisma / DB / migration) | ... |
| i18n (locales, default) | ... |

Note where the work lives across the server/client boundary, any schema or
migration impact, and any responsive/accessibility requirements.

---

## Technical Approach

Describe the implementation strategy at a high level. Include:
- Which files will be created or modified
- Which libraries will be used (must already be in `package.json`)
- The data flow (server vs client state, fetching layer, caching/revalidation)
- Any route handlers, Server Actions, or DB queries/migrations involved

---

## Permissions

- New dependencies permitted: no
- Database migration permitted: no
- Network access required during implementation: no

List every approved dependency, migration, or change here. A `yes` without
details is not approval. (Web specs declare no native `ios/`/`android/`
permissions — those apply only to the React Native track.)

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
  - Security Reviewer: Security Contract
  - API Contract Reviewer: API Contract -->

Every active persona needs an ownership line — whether it is active via the
Review Profile, an explicit `- Personas:` list, or an optional reviewer. For
personas that are not active, use `none — not in profile`; use `none — [reason]`
when an active persona has no domain-relevant documentation.

---

<!-- OPTIONAL contract sections follow. Each is a top-level `## … Contract`
     heading (level 2 — auto-activation matches `^## `, so do NOT nest them).
     Delete the ones you don't need; fill in the ones you keep. -->

## Product Contract

> OPTIONAL. Auto-activates the **Product Reviewer** (and makes it own this
> contract). Delete the section if not needed.

- Product brief: ...
- Primary user outcome: ...
- Required user flow: ...
- Analytics events: ...
- Product owner: ...
- Product overrides design: yes | no

---

## Design Contract

> OPTIONAL. Auto-activates the **Design Fidelity Reviewer** (and makes it own
> this contract). Delete the section if not needed.

- Figma file / page: ...
- Frames: ...                  <!-- comma-separated screen names; visual capture covers Frames × Required states -->
- Version / export date: ...
- Design tokens / assets: ...
- Existing components to reuse: ...
- Required states: loading, empty, error, offline, disabled, accessibility
- Tolerance: 0.10              <!-- optional; max diff_pct a screen may differ and still pass (default 0.10) -->
- Supported viewport sizes: ...
- Approved deviations: ...

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

## API Contract

> OPTIONAL. Auto-activates the **API Contract Reviewer** (and makes it own this
> contract). Delete the section if not needed.

- Surface: ... (HTTP routes, RPC, shared schema, public module boundary)
- Endpoints / operations: ...
- Request / response shapes: ...
- Error model: ... (status codes / error types)
- Versioning & backward compatibility: ...
- Schema / contract file: ...

---

## Edge Cases

List the non-happy-path scenarios the implementation must handle:

- Offline / slow / failed network request
- Empty state (no data)
- Error state (API failure, validation error, permission denied)
- Interrupted flow (double-submit, refresh, navigate away mid-action)
- Unauthenticated vs authenticated user
- Large or malformed data sets
- [Add more specific to this feature]

---

## Test Plan

- First failing test or executable check: `npm test [target-test]`
<!-- Must be RED before the change. Net-new: name the not-yet-existing test (absent →
     red). MODIFYING an already-tested module (named test exists and passes at
     baseline): the engine auto-detects "modify-mode" — it does not block on the green
     baseline and instead proves red by overlaying the candidate's updated test files
     onto BASE production after implementation. Naming an existing test is fine. -->
- Unit tests for: [list functions/utilities to test]
- Component / integration tests for: [list components or flows]
- E2E test (if applicable): [describe the Playwright flow]
- Baseline validation commands (run before edits):
  1. `npx tsc --noEmit`
  2. `npm run lint`
  3. `npm test`
- Final validation commands (run in this order):
  1. `npx tsc --noEmit`
  2. `npm run lint`
  3. `npm test`
  4. `npm run build` (catches RSC/route/type errors only the build surfaces)
  5. `npm run test:e2e` (only when the change has user-facing flow impact)
- Expected evidence paths:
- Manual test checklist:
  - [ ] Test in a desktop browser
  - [ ] Test at a mobile breakpoint (responsive)
  - [ ] Test with keyboard-only navigation
  - [ ] Test with network throttling (slow 3G)
  - [ ] Test both locales (e.g. `pt-BR` and `en`)

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
