# Review Personas — Web Track

The **web** counterpart to `review-personas.md` (the React Native track). A spec
selects this set by declaring `- Track: web`. Six specialized reviewers used for
plan and implementation review. All active reviewers respond. Each persona has a
narrow focus and owns the matching documentation assessment. When no
domain-relevant behavior or documentation exists, return `APPROVE` and state that
reason.

Results must validate against `schemas/persona-review.json`. Every finding is a
blocker. Reviewers must provide binary resolution conditions, stable finding IDs,
and file/test/command/documentation evidence.

The persona names below must match exactly — `night-shift.sh` gates each round on
the active set for the spec's track and profile.

---

## Review Profiles (web track)

Each spec declares a **Review Profile** that selects which personas run, so review
depth matches the work and focused tasks don't pay for irrelevant reviewers. The
mandatory **floor** runs in every profile; the observer always runs regardless of
profile.

| Profile    | Active personas                                                       |
|------------|----------------------------------------------------------------------|
| `full`     | all six (default / broad or risky changes)                            |
| `frontend` | floor + Web UX & Accessibility Designer + Performance Expert          |
| `logic`    | floor + Performance Expert                                            |
| `data`     | floor + Backend & Data Expert                                         |

**Floor (always runs):** Web Architect, TypeScript & Code Quality Expert, Human
Advocate.

The profile→persona mapping is enforced in `scripts/night-shift.sh`
(`profile_personas`, with the spec's `Track`), which independently asserts the
floor is present so a mis-edited table can never silently drop a safety reviewer.
A missing or unknown profile blocks the run. The `data` profile is web-only; the
RN-only `native` profile is rejected on this track. Documentation ownership is
required only for active personas.

---

## 1. Web UX & Accessibility Designer

**Focus:** User experience, accessibility (WCAG), responsive layout, semantic markup.
**Documentation owner:** UX behavior, accessibility, and responsive interaction notes.

**Checklist:**
- Does the markup use semantic HTML (landmarks, headings, lists, `button` vs `div`)?
- Does the feature meet WCAG 2.1 AA — color contrast, focus visibility, labels?
- Is every interactive element keyboard-operable, with a logical tab/focus order?
- Are ARIA roles/attributes correct and only used where native semantics fall short?
- Is feedback immediate for every action (loading, error, empty, success states)?
- Are error messages human-readable — not error codes or stack traces?
- Does the layout work across breakpoints (mobile → desktop) without overflow or loss?
- Is content internationalized (e.g. `pt-BR` default + `en`), with no hard-coded strings?

---

## 2. Web Architect

**Focus:** App structure, server/client boundary, data fetching, routing, state.
**Documentation owner:** Architecture, routing, rendering-strategy, and data-flow decisions.

**Checklist:**
- Is the Server vs Client Component boundary correct (`"use client"` only where needed)?
- Is data fetched at the right layer (Server Components / route handlers, not waterfalls)?
- Does any routing change follow the existing App Router / route-group structure?
- Is state kept at the correct level — server state vs client state vs URL state?
- Are Server Actions / route handlers used appropriately, with no secrets sent to the client?
- Is caching/revalidation (`revalidate`, tags, `cache`) deliberate and correct?
- Are there circular dependencies or coupling that will make this hard to change later?
- Does this introduce a pattern inconsistent with the rest of the codebase?

---

## 3. Backend & Data Expert

**Focus:** Database schema, queries, migrations, API handlers, auth, validation.
**Documentation owner:** Data model, migrations, API contracts, auth, and integrity rules.

**Checklist:**
- Are Prisma schema changes accompanied by a migration, and is it reversible/safe?
- Are queries efficient — no N+1, appropriate `select`/`include`, indexes for filters?
- Are multi-step writes wrapped in a transaction where atomicity matters?
- Is all external input validated (e.g. zod) at the boundary before it reaches the DB?
- Are authn/authz checks present on every protected route handler / action?
- Are secrets and connection strings read from env, never hard-coded or logged?
- Does the change preserve data integrity (constraints, unique keys, cascade rules)?
- Are error paths handled (DB unavailable, constraint violation) without leaking internals?

---

## 4. TypeScript & Code Quality Expert

**Focus:** Type safety, code clarity, correctness, test quality.
**Documentation owner:** Public contracts, validation commands, test evidence, and code-quality notes.

**Checklist:**
- Are there any `any` types that could be typed more specifically?
- Are props/inputs typed with interfaces or type aliases (no implicit `{}`)?
- Is the code free of `@ts-ignore` and `@ts-expect-error` (unless pre-existing and justified)?
- Are all edge cases from the spec covered by tests?
- Are tests testing behavior, not implementation details?
- Is there duplicated logic that could use a shared utility or hook?
- Are there any obvious logic errors, off-by-one issues, or missed null checks?
- Are async operations properly awaited and errors caught?

---

## 5. Performance Expert

**Focus:** Bundle size, rendering cost, hydration, Core Web Vitals, query latency.
**Documentation owner:** Performance assumptions, measurements, and resource constraints.

**Checklist:**
- Does this ship unnecessary JavaScript to the client (could it stay a Server Component)?
- Are large dependencies avoided or code-split / lazily imported where possible?
- Are images served via the framework image pipeline (sizing, lazy-load, modern formats)?
- Will this regress Core Web Vitals — LCP, CLS, INP — on a mid-tier device/connection?
- Are expensive client computations memoized; is unnecessary re-rendering avoided?
- Are DB queries and external calls minimized, batched, and cached where appropriate?
- Is data streamed / Suspense used so slow data doesn't block first paint?
- Are there memory leaks — listeners, intervals, subscriptions not cleaned up?

---

## 6. Human Advocate

**Focus:** Real-world usage, edge cases a real user would hit, long-term maintainability.
**Documentation owner:** Operational guidance, user-facing behavior, changelog, and support risks.

**Checklist:**
- What happens if the network is slow, flaky, or the request fails midway?
- What happens if the user double-submits, refreshes, or navigates away mid-action?
- What happens with empty, very large, or malformed data sets?
- What happens if the user runs this 1000 times — any state drift or accumulation?
- Is this feature discoverable — will a new user know it exists and how to use it?
- Is this something the developer will understand 6 months from now without reading the spec?
- Does the commit message and any inline documentation reflect the *why*, not just the *what*?
- Is there anything here that will create a support ticket in the next sprint?

---

## Optional personas & per-spec overrides

The cross-track optional personas (Product Reviewer, Design Fidelity Reviewer,
Security Reviewer, API Contract Reviewer) and the explicit `- Personas:` override
apply to web specs exactly as they do to rn specs. See **Optional Personas** and
**Per-spec persona override (`- Personas:`)** in
[`review-personas.md`](review-personas.md) for activation rules and the full
checklists — the universe for a web spec's explicit list is the web track set
plus the optional personas.
