# Optional Personas — Implementation Brief (self-contained)

This is a complete, standalone spec for one change to the night-shift workflow.
Implement exactly this. Do not assume any prior conversation context.

## Background

`~/work/scripts/night-shift.sh` (~2053 lines) is a bash
orchestrator that drives `claude -p` to implement a spec autonomously: plan → six
persona sub-agent reviews → test-first implementation → six persona reviews →
candidate commit → independent observer → done.

The persona system today (read the live code; these names are exact):
- `PERSONAS_RN`, `PERSONAS_WEB` — the six-persona set per track.
- `PERSONAS` — the union of all persona names; used by the `persona-review`
  schema membership check (`json_schema_basic`).
- `PERSONA_FLOOR_RN`, `PERSONA_FLOOR_WEB` — personas that always run.
- `DEFAULT_TRACK=rn`; `spec_track` reads `- Track: rn|web`.
- `valid_profiles_for_track`, `profile_personas(profile, track)` — profiles:
  rn = full|frontend|logic|native, web = full|frontend|logic|data.
- `resolve_active_personas(specfile)` — resolves track → profile → active set,
  then asserts the track floor is a subset (guard). Used by `primary_prompt`,
  the `run_personas` gate, and `validate_spec` (doc-ownership is required only
  for ACTIVE personas).
- Schemas live in `schemas/` and are **vendored (byte-identical copies)** in
  `night-shift-viewer/schemas/`. `persona-review.json` has a `persona` enum.

## Goal

Add two **optional, cross-track** personas that activate only when a spec opts
in, with **zero behavior change** when a spec does not. Text/traceability review
only — no screenshots (see Out of Scope).

## The two optional personas

### Product Reviewer
- **Focus:** product outcome, user flows, analytics, scope discipline.
- **Documentation owner:** Product Contract (outcome, flows, analytics events,
  non-goals, product-vs-design priority).
- **Plan-stage checklist:** plan satisfies the primary user outcome; every
  required flow maps to an acceptance criterion; analytics events are specified
  and mapped to interactions; non-goals are respected (no scope creep); when
  product and design conflict, the declared `Product overrides design` priority
  is applied.
- **Implementation-stage checklist:** analytics events fire at the right points;
  the built flow achieves the stated outcome; no scope creep beyond non-goals.

### Design Fidelity Reviewer
- **Focus:** conformance to a specific design (Figma) and the design system.
- **Documentation owner:** Design Contract (Figma frames/states, tokens, assets,
  components to reuse, required states, approved deviations, viewport sizes).
- **Plan-stage checklist:** every Figma frame/state maps to an AC and a
  reuse-or-new component decision; all required states present
  (loading/empty/error/offline/disabled/accessibility); tokens/assets/fonts
  identified; viewport sizes covered.
- **Implementation-stage checklist:** reuses design-system components/tokens
  (not re-created); **if** implementation screenshots and reference images are
  present, visual differences are within the Comparison tolerance and
  spacing/type/color/touch-targets/states match and approved deviations are
  honored; **if no screenshots exist (no simulator), perform static checks only
  and state that pixel validation is deferred** (do not block on missing pixels).

**Boundary vs the existing UX Designer persona:** UX Designer = qualitative
interaction/accessibility/platform conventions; Design Fidelity = quantitative
conformance to a specific design contract. Keep both distinct in the docs.

## Activation design ("optional")

1. Add `PERSONAS_OPTIONAL="Product Reviewer|Design Fidelity Reviewer"`.
2. Add both names to the `PERSONAS` union (so the schema membership check and the
   `persona-review` enum accept them).
3. In `resolve_active_personas`, after computing the profile set and asserting
   the floor, **union in** any optional personas that are EITHER:
   - listed in a new spec field `- Optional reviewers: <comma-or-pipe list>`
     (each entry must be a member of `PERSONAS_OPTIONAL`, else fail with
     "unknown optional reviewer: X"), OR
   - auto-activated by section presence: a `## Product Contract` heading →
     Product Reviewer; a `## Design Contract` heading → Design Fidelity Reviewer.
   Deduplicate, preserve order. The resulting set is the active set used
   everywhere (prompt, gate, doc-ownership).
4. `validate_spec`: the `- Optional reviewers:` field is OPTIONAL (absent = no
   error). If present, validate each entry ∈ `PERSONAS_OPTIONAL`. Documentation
   ownership for active optional personas is already enforced because they are in
   the active set returned by `resolve_active_personas`.
5. No change to floors or to the existing track/profile resolution. A spec with
   no optional reviewers and no contract sections must resolve to exactly the
   same active set as today (verify with a fixture).

## Schema + sync

- Add `"Product Reviewer"` and `"Design Fidelity Reviewer"` to the `persona`
  enum in **both** `schemas/persona-review.json` and
  `night-shift-viewer/schemas/persona-review.json`. They must remain
  byte-identical (`diff` them; must be empty).

## Docs + template

- `docs/review-personas.md`: add the two persona entries (focus, documentation
  owner, plan + implementation checklists, and a line: "Optional — activates when
  listed in `Optional reviewers` or when its contract section is present").
- `specs/_template.md`:
  - Under the Review section add: `- Optional reviewers: none` (with a comment
    listing the allowed values).
  - Add two OPTIONAL sections, each with a note that its presence auto-activates
    the matching reviewer:
    - `## Product Contract` — Product brief, Primary user outcome, Required user
      flow, Analytics events, Product owner, `Product overrides design: yes/no`.
    - `## Design Contract` — Figma file, Page, Frames, Version/export date,
      Assets, Design tokens, Existing components to reuse, Required states,
      Supported viewport/device sizes, Approved deviations.

## Fixtures (add to the deterministic `--fixture-test --dry-run` suite)

Add fixtures and register them in `run_dry_fixtures`:
1. **optional via field**: a temp spec with `- Optional reviewers: Product Reviewer`
   → `resolve_active_personas` includes "Product Reviewer" and the full floor.
2. **optional via contract section**: a temp spec with a `## Design Contract`
   heading (and no Optional reviewers field) → active set includes
   "Design Fidelity Reviewer".
3. **unknown optional reviewer rejected**: `- Optional reviewers: Bogus Persona`
   → `resolve_active_personas`/validation fails.
4. **no optional → unchanged**: a spec with neither field nor contract → active
   set equals the plain profile set (no optional personas added).
5. **schema membership**: `json_schema_basic persona-review` ACCEPTS a record
   with `"persona":"Product Reviewer"` (and one with `"Design Fidelity Reviewer"`).

Each new persona resolution fixture should build its temp spec from the same
minimal valid shape the existing spec-validation fixture uses (Track, Review
Profile, Repository/Permissions/Documentation/Test Plan fields, and the floor
persona doc-owner lines). Mirror the existing fixtures' style.

## Out of scope (document as a follow-up, do NOT implement)

Screenshot capture, a pixel-diff tool, a `visual-diff` evidence schema, and
observer visual packets. These need a running simulator (full Xcode / Android
SDK) which this environment lacks. Add a short "## Follow-up: visual validation"
note at the end of `docs/review-personas.md` describing this as the next phase.

## Verification (must all pass; do NOT run live/paid tests)

1. `bash -n scripts/night-shift.sh` → no syntax errors.
2. `scripts/night-shift.sh --fixture-test --dry-run` → all fixtures pass,
   including the 5 new ones.
3. `diff schemas/persona-review.json night-shift-viewer/schemas/persona-review.json`
   → empty (in sync).
4. Existing fixtures must still pass (no regressions).

## Reporting

Do NOT git-commit. When done, report: the files changed, how activation works,
the new fixture names + that they pass, confirmation the schemas are in sync, and
anything you had to deviate from in this brief.
