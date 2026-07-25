<!--
Deliberately BAD spec fixture for scripts/lib/spec-audit-static.js.
Each of the 7 static rules fires exactly once; line-to-rule map:
  rule 1 -> Technical Approach, the rounding-mode bullet (unfilled marker)
  rule 2 -> Acceptance Criteria heading (section present, no checkbox items)
  rule 3 -> Summary, the second sentence (unsubstantiated claim, no specifics)
  rule 4 -> Out of Scope, first bullet (open-ended list)
  rule 5 -> Test Plan (no runner named anywhere in the plan)
  rule 6 -> Test Plan (validation list intentionally omitted)
  rule 7 -> Technical Approach, the rendering-fidelity bullet
-->

# Spec: Invoice Subtotal Rounding

---

## Status

- [ ] Draft

---

## Repository

- Project path: `~/work/example/invoice-service`
- Base branch: `main`
- Feature branch: `feat/invoice-rounding`

---

## Review

- Track: rn
- Review Profile: logic

---

## Summary

This change fixes rounding drift in the invoice subtotal calculator.
The service works correctly once wired in.

---

## Acceptance Criteria

No formal checklist yet; see the Summary above for the expected behavior.

---

## Out of Scope

- Tax rules, currency conversion, refunds, etc.
- Refund recalculation.

---

## Technical Approach

- Add a `roundHalfEven` helper to `src/math/invoice.ts`.
- TBD: pick the exact rounding mode for negative subtotals.
- The final summary screen should be pixel-perfect against the reference.

---

## Test Plan

- First failing test or executable check: `npx eslint . --max-warnings 0`
- Baseline validation commands (run before edits):
  1. `npx tsc --noEmit`
  2. `npx eslint . --max-warnings 0`
