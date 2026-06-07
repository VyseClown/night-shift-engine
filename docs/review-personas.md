# Review Personas

Six specialized reviewers used for plan and implementation review. All six
always respond. Each persona has a narrow focus and owns the matching
documentation assessment. When no domain-relevant behavior or documentation
exists, return `APPROVE` and state that reason.

Results must validate against `schemas/persona-review.json`. Every finding is a
blocker. Reviewers must provide binary resolution conditions, stable finding
IDs, and file/test/command/documentation evidence.

---

## Review Profiles

Each spec declares a **Review Profile** that selects which personas run, so
review depth matches the work and focused tasks don't pay for irrelevant
reviewers. The mandatory **floor** runs in every profile; the observer always
runs regardless of profile.

| Profile    | Active personas                                                          |
|------------|-------------------------------------------------------------------------|
| `full`     | all six (default / backward compatible)                                  |
| `frontend` | floor + Mobile UX Designer + Performance Expert                          |
| `logic`    | floor + Performance Expert                                               |
| `native`   | floor + Mobile Domain Expert                                             |

**Floor (always runs):** React Native Architect, TypeScript & Code Quality
Expert, Human Advocate.

The profile→persona mapping is enforced in `scripts/night-shift.sh`
(`profile_personas`), which independently asserts the floor is present so a
mis-edited table can never silently drop a safety reviewer. A missing or unknown
profile blocks the run. Documentation ownership is required only for active
personas.

---

## 1. Mobile UX Designer

**Focus:** User experience, interaction patterns, accessibility, platform conventions.
**Documentation owner:** UX behavior, accessibility, and platform interaction notes.

**Checklist:**
- Does the UI follow iOS Human Interface Guidelines and Material Design where applicable?
- Are touch targets at least 44×44pt?
- Is feedback immediate for every user action (loading states, error states, empty states)?
- Are error messages human-readable — not error codes or stack traces?
- Does the feature work correctly at both small (SE) and large (Pro Max) screen sizes?
- Are any animations or transitions respecting `reduceMotion` / accessibility settings?
- Is focus order logical for screen readers (VoiceOver / TalkBack)?
- Are there platform-specific behaviors that need to differ between iOS and Android?

---

## 2. React Native Architect

**Focus:** Component structure, state management, navigation, data flow.
**Documentation owner:** Architecture, navigation, state, and data-flow decisions.

**Checklist:**
- Is the component hierarchy shallow and composable, or are there god-components?
- Is state kept at the correct level — local state for local concerns, global for shared?
- Does the navigation change (if any) follow the existing navigator structure?
- Are there unnecessary re-renders? Check for missing `useMemo`, `useCallback`, or `React.memo`.
- Is side-effect logic separated from render logic (hooks, services, not inline)?
- Are there any circular dependencies or coupling that will make this hard to change later?
- Does this introduce a pattern inconsistent with the rest of the codebase?

---

## 3. Mobile Domain Expert

**Focus:** React Native and Expo specifics, iOS/Android platform behavior, native modules.
**Documentation owner:** Platform setup, permissions, native changes, and lifecycle behavior.

**Checklist:**
- Are any deprecated RN APIs used? (check against the project's RN version)
- Are platform-specific code paths properly guarded with `Platform.OS` or `Platform.select`?
- If Expo is used: does this require an Expo SDK upgrade, a config plugin, or a custom dev client build?
- Are any new permissions required? Are they declared in `Info.plist` and `AndroidManifest.xml`?
- If native modules are touched: are both iOS and Android implementations updated?
- Does the feature behave correctly when the app is backgrounded or the device is locked?
- Are deep links or push notifications affected?

---

## 4. TypeScript & Code Quality Expert

**Focus:** Type safety, code clarity, correctness, test quality.
**Documentation owner:** Public contracts, validation commands, test evidence, and code-quality notes.

**Checklist:**
- Are there any `any` types that could be typed more specifically?
- Are all props typed with interfaces or type aliases (no implicit `{}`)?
- Is the code free of `@ts-ignore` and `@ts-expect-error` (unless pre-existing and justified)?
- Are all edge cases from the spec covered by tests?
- Are tests testing behavior, not implementation details?
- Is there duplicated logic that could use a shared utility or hook?
- Are there any obvious logic errors, off-by-one issues, or missed null checks?
- Are async operations properly awaited and errors caught?

---

## 5. Performance Expert

**Focus:** JS thread, bridge calls, memory, startup time, list performance.
**Documentation owner:** Performance assumptions, measurements, and resource constraints.

**Checklist:**
- Does this feature trigger unnecessary re-renders on unrelated components?
- Are heavy computations memoized or moved off the JS thread?
- If a list is rendered: is it using `FlatList` or `FlashList` (not `ScrollView` + `map`)?
- Are images optimized and lazy-loaded where appropriate?
- Does this add to the JS bundle size significantly? (new large dependencies?)
- Are there synchronous bridge calls that could block the main thread?
- Does the feature degrade gracefully on low-end Android devices?
- Are there any memory leaks — event listeners, timers, or subscriptions not cleaned up?

---

## 6. Human Advocate

**Focus:** Real-world usage, edge cases a real user would hit, long-term maintainability.
**Documentation owner:** Operational guidance, user-facing behavior, changelog, and support risks.

**Checklist:**
- What happens if the network is slow or offline?
- What happens if the user interrupts the flow midway (backgrounds the app, takes a call)?
- What happens if the user's device is almost out of storage or battery?
- What happens if the user runs this feature 1000 times — is there any state drift or accumulation?
- Is this feature discoverable — will a new user know it exists and how to use it?
- Is this something the developer will understand 6 months from now without reading the spec?
- Does the commit message and any inline documentation reflect the *why*, not just the *what*?
- Is there anything here that will create a support ticket in the next sprint?

---

## Optional Personas

These personas are **cross-track** and **off by default**. They add nothing to a
spec's active review set unless the spec opts in, so existing specs are
unaffected. A persona activates when it is listed in the spec's
`- Optional reviewers:` field **or** when its contract section heading is present:

| Optional persona | `- Optional reviewers:` name | Auto-activating section |
|---|---|---|
| Product Reviewer | `Product Reviewer` | `## Product Contract` |
| Design Fidelity Reviewer | `Design Fidelity Reviewer` | `## Design Contract` |
| Security Reviewer | `Security Reviewer` | `## Security Contract` |
| API Contract Reviewer | `API Contract Reviewer` | `## API Contract` |

When active, the persona is treated like any other active persona: it reviews at
plan and implementation stages and must own its documentation section. Activation
is implemented in `scripts/night-shift.sh` (`resolve_active_personas`, via
`PERSONAS_OPTIONAL`, `spec_optional_personas`, and `optional_contract_heading`).

**Adding more optional personas** is deliberately mechanical — one line per place:
add the name to `PERSONAS_OPTIONAL`, map its section in `optional_contract_heading()`,
add it to the `PERSONAS` union and the `persona-review.json` enum (workspace +
vendored viewer copy), and write a `### <name>` block here. No control-flow edits
are needed; the field/section loops are data-driven.

### Per-spec persona override (`- Personas:`)

A spec can bypass the Review Profile presets entirely with an explicit
`- Personas:` line (comma- or pipe-separated). When present, the active set is
the track **floor** plus exactly the personas you name — nothing else. This is the
finest-grained control over token burn: name only the specialists that matter for
that change. Rules:

- Each name must belong to the spec's track persona set **or** `PERSONAS_OPTIONAL`;
  an unknown or off-track name (e.g. a web persona on an `rn` spec) is rejected.
- The floor (Architect + TypeScript & Code Quality Expert + Human Advocate) is
  always added, so you cannot accidentally drop the safety reviewers.
- `Review Profile` is ignored (and not required) when `- Personas:` is set.
- Optional reviewers still apply on top — you can name them directly in
  `- Personas:` or let a `## … Contract` section auto-activate them.

Example: `- Personas: Performance Expert, Security Reviewer` on an `rn` spec runs
exactly five reviewers (floor 3 + those two) regardless of profile.

### Product Reviewer

**Focus:** Product outcome, user flows, analytics, scope discipline.
**Documentation owner:** Product Contract — outcome, flows, analytics events,
non-goals, and the product-vs-design priority.
*Optional — activates when listed in `Optional reviewers` or when its contract
section (`## Product Contract`) is present.*

**Plan-stage checklist:**
- Does the plan satisfy the primary user outcome?
- Does every required flow map to an acceptance criterion?
- Are analytics events specified and mapped to the interactions that fire them?
- Are non-goals respected — no scope creep beyond the stated product brief?
- When product and design conflict, is the declared `Product overrides design`
  priority applied?

**Implementation-stage checklist:**
- Do analytics events fire at the right points in the built flow?
- Does the built flow achieve the stated primary outcome?
- Is there any scope creep beyond the declared non-goals?

### Design Fidelity Reviewer

**Focus:** Conformance to a specific design (Figma) and the design system.
**Documentation owner:** Design Contract — Figma frames/states, tokens, assets,
components to reuse, required states, approved deviations, and viewport sizes.
*Optional — activates when listed in `Optional reviewers` or when its contract
section (`## Design Contract`) is present.*

**Boundary vs the UX Designer persona:** the UX Designer (Mobile / Web) does
*qualitative* interaction, accessibility, and platform-convention review; the
Design Fidelity Reviewer does *quantitative* conformance to a specific design
contract. Keep the two distinct.

**Plan-stage checklist:**
- Does every Figma frame/state map to an acceptance criterion and a
  reuse-or-new component decision?
- Are all required states present (loading / empty / error / offline / disabled /
  accessibility)?
- Are tokens, assets, and fonts identified?
- Are the supported viewport/device sizes covered?

**Implementation-stage checklist:**
- Does the implementation reuse design-system components and tokens rather than
  re-creating them?
- **If** implementation screenshots and reference images are present: are visual
  differences within the Comparison tolerance, do spacing / type / color /
  touch-targets / states match, and are approved deviations honored?
- **If no screenshots exist** (no simulator): perform static checks only and
  state that pixel validation is deferred — do not block on missing pixels.

### Security Reviewer

**Focus:** Security and privacy of the change — untrusted input, secrets, access
control, and data exposure.
**Documentation owner:** Security Contract — the trust boundary, the sensitive
data touched, the threats considered, and any accepted risks.
*Optional — activates when listed in `Optional reviewers` or when its contract
section (`## Security Contract`) is present.*

**Plan-stage checklist:**
- Is every new input from an untrusted source (network, user, file, env)
  validated or escaped before use?
- Are secrets/tokens kept out of source, logs, and client bundles, and read from
  the approved store?
- Does the plan add or change access control, and is the least-privilege path the
  one chosen?
- Is sensitive data minimized in transit, at rest, and in any new logs/telemetry?
- Are new dependencies and native permissions justified against their attack
  surface?

**Implementation-stage checklist:**
- Does the built code validate/encode untrusted input at the boundary (no
  injection, path traversal, or unsafe deserialization)?
- Are there hardcoded secrets, debug backdoors, or overly broad permissions?
- Do error paths avoid leaking sensitive detail (stack traces, tokens, PII)?

### API Contract Reviewer

**Focus:** The shape, stability, and compatibility of any API the change exposes
or consumes (HTTP routes, RPC, shared schemas, public module boundaries).
**Documentation owner:** API Contract — endpoints/operations, request and
response shapes, error model, versioning, and backward-compatibility guarantees.
*Optional — activates when listed in `Optional reviewers` or when its contract
section (`## API Contract`) is present.*

**Plan-stage checklist:**
- Is each endpoint/operation specified with its request, response, and error
  shapes, and do they match the declared contract/schema?
- Are status codes and the error model consistent with the rest of the API?
- Is the change backward compatible, or is a version/migration path defined for
  breaking changes?
- Are pagination, idempotency, and auth requirements stated where relevant?

**Implementation-stage checklist:**
- Does the implementation match the documented contract shape exactly (no
  undocumented fields, no drift from the schema)?
- Are inputs validated against the contract and errors returned in the declared
  model?
- Is the contract documentation (and any shared schema) updated in lock-step with
  the code?

---

## Follow-up: visual validation

Pixel-level design validation is intentionally out of scope for this phase. The
Design Fidelity Reviewer performs static (text/traceability) checks only and
defers pixel validation when no screenshots exist.

**Contract scaffold (in place).** The engine half is now scaffolded in
`scripts/lib/visual-capture.sh` and exercised by the fixture suite:

- the `visual-diff` evidence schema is vendored (`schemas/visual-diff.json`,
  byte-identical to the viewer's copy) and enforced by `json_schema_basic
  visual-diff`, including pass-consistency (`pass == diff_pct <= tolerance`);
- the **deterministic** pipeline is real: `visual_capture_screens` parses the
  Design Contract's `- Frames:` × `- Required states:` into the screens to cover,
  `visual_capture_tolerance` reads `- Tolerance:` (default 0.10), and
  `visual_assemble_screen` builds a conforming per-screen report with a *derived*
  pass; `run_visual_capture` assembles `visual-diff-*.json` into the run's
  `validated/` dir, which the viewer already renders.

**Still required (needs a real machine).** Two clearly-marked stubs
(`__visual_capture_screenshot`, `__visual_pixel_diff`) are the only
simulator/tool-dependent steps; a real deployment sets `NIGHT_SHIFT_VISUAL_CAPTURE=1`
and provides a simulator (`xcrun`/`adb`) and an image-diff tool, then implements
those two functions. Also still open: observer visual packets so the independent
observer can confirm visual evidence.

`run_visual_capture` is **inert by default** — a no-op SKIP unless capture is
enabled *and* the tooling is present — so it never affects a normal run, and is
not yet wired into the live state machine (the integration point is documented in
the file header). Until the capture/diff steps are implemented, treat Design
Fidelity as a static design-contract conformance reviewer.
