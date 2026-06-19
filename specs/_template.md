# Spec: [Feature Name]

> Copy this file to `specs/feature-name.md` before starting implementation.
> Fill in every section. Ambiguous specs produce wrong implementations.

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

- Review Profile: full | frontend | logic | native

The profile selects which review personas run, so review depth matches the work
and small tasks don't pay for irrelevant reviewers. Pick one:

| Profile    | Personas                                                                 | Use for |
|------------|--------------------------------------------------------------------------|---------|
| `full`     | all six (default)                                                        | broad or risky changes; when unsure |
| `frontend` | floor + Mobile UX Designer + Performance Expert                          | design/UI-heavy work |
| `logic`    | floor + Performance Expert                                               | logic/business-rule work, no UI |
| `native`   | floor + Mobile Domain Expert                                             | native module / platform work |

Floor (always runs, every profile): React Native Architect, TypeScript & Code
Quality Expert, Human Advocate — plus the independent observer. A missing or
unknown profile blocks the run.

- Optional reviewers: none
<!-- Optional, cross-track reviewers. Off by default. Allowed values (comma- or
     pipe-separated): Product Reviewer, Design Fidelity Reviewer, Security
     Reviewer, API Contract Reviewer. Each listed reviewer is added to the active
     set. A reviewer also auto-activates when its contract section below is
     present (## Product Contract → Product Reviewer; ## Design Contract → Design
     Fidelity Reviewer; ## Security Contract → Security Reviewer; ## API Contract
     → API Contract Reviewer). Use `none` for no extras. -->

An active optional reviewer must own its documentation section below, exactly like
any other active persona.

<!-- OPTIONAL per-spec override. Uncomment to name the EXACT reviewers to run,
     overriding the Review Profile above. The active set becomes the track floor
     (Architect + TypeScript & Code Quality Expert + Human Advocate) plus exactly
     these names. Use this to minimize token burn on focused changes. Each name
     must belong to this spec's track persona set or the optional reviewers list;
     an off-track name is rejected. When set, Review Profile is ignored. Example
     (indented so this example is not itself parsed as the field):
       - Personas: Performance Expert, Security Reviewer
-->

Every persona that ends up active (whether via profile, explicit `- Personas:`,
or an optional reviewer) must own a line under "Documentation owned by each
review persona" below.

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

## Platform Notes

| Platform | Behavior |
|---|---|
| iOS | ... |
| Android | ... |
| Both | ... |

Note any differences in interaction, permissions, or native behavior between platforms.

---

## Technical Approach

Describe the implementation strategy at a high level. Include:
- Which files will be created or modified
- Which libraries will be used (must already be in `package.json`)
- The data flow (where state lives, how it moves)
- Any API calls or async operations

---

## Permissions

- New dependencies permitted: no
- Native `ios/` changes permitted: no
- Native `android/` changes permitted: no
- Network access required during implementation: no

List every approved dependency or native change here. A `yes` without details is
not approval.

---

## Documentation

- Required workspace docs:
- Required project docs:
- Documentation owned by each review persona:
  - Mobile UX Designer:
  - React Native Architect:
  - Mobile Domain Expert:
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

## Product Contract

> OPTIONAL. Including this section auto-activates the **Product Reviewer**
> persona (and makes it own this contract). Delete the section if not needed.

- Product brief: ...
- Primary user outcome: ...
- Required user flow: ...
- Analytics events: ...
- Product owner: ...
- Product overrides design: yes | no

---

## Design Contract

> OPTIONAL. Including this section auto-activates the **Design Fidelity
> Reviewer** persona (and makes it own this contract). Delete the section if not
> needed.

- Figma file: ...
- Page: ...
- Frames: ...                  <!-- comma-separated screen names; visual capture covers Frames × Required states -->
- Devices: iphone-15                  <!-- comma-separated iOS device names; grid = Frames × Required states × Devices -->
- Version / export date: ...
- Assets: ...
- Design tokens: ...
- Existing components to reuse: ...
- Required states: loading, empty, error, offline, disabled, accessibility
- Tolerance: 0.10              <!-- optional; max diff_pct a screen may differ and still pass (default 0.10) -->
- Supported viewport / device sizes: ...
- Approved deviations: ...

---

## Security Contract

> OPTIONAL. Including this section auto-activates the **Security Reviewer**
> persona (and makes it own this contract). Delete the section if not needed.

- Trust boundary: ... (what untrusted input crosses into this change)
- Sensitive data touched: ... (PII, credentials, tokens, financial, none)
- Authn / authz changes: ...
- Secrets handling: ... (where secrets live; never in source/logs/bundles)
- Threats considered: ...
- Accepted risks: ...

---

## API Contract

> OPTIONAL. Including this section auto-activates the **API Contract Reviewer**
> persona (and makes it own this contract). Delete the section if not needed.

- Surface: ... (HTTP routes, RPC, shared schema, public module boundary)
- Endpoints / operations: ...
- Request shape(s): ...
- Response shape(s): ...
- Error model: ... (status codes / error types)
- Versioning & backward compatibility: ...
- Schema / contract file: ...

---

## Edge Cases

List the non-happy-path scenarios the implementation must handle:

- Offline / no network
- Empty state (no data)
- Error state (API failure, permission denied)
- Interrupted flow (app backgrounded mid-action)
- First-time use vs. returning user
- [Add more specific to this feature]

---

## Test Plan

- First failing test or executable check: `npm test -- --watchAll=false [target-test]`
- Unit tests for: [list functions/hooks to test]
- Component tests for: [list components with interaction logic]
- Integration test (if applicable): [describe the flow to test end-to-end]
- Baseline validation commands (run before edits):
  1. `npx tsc --noEmit`
  2. `npx eslint . --max-warnings 0`
  3. `npm test -- --watchAll=false`
- Final validation commands (run in this order):
  1. `npx tsc --noEmit`
  2. `npx eslint . --max-warnings 0`
  3. `npm test -- --watchAll=false`
  4. `npx react-native-community-cli doctor` (only for approved native changes)
- Expected evidence paths:
- Manual test checklist:
  - [ ] Test on iOS simulator
  - [ ] Test on Android emulator
  - [ ] Test on physical device (if native behavior involved)
  - [ ] Test with network throttling (slow 3G)
  - [ ] Test with VoiceOver / TalkBack enabled

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
