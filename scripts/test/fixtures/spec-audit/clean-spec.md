# Spec: Invoice Rounding Helper

> Well-formed spec fixture for scripts/lib/spec-audit-static.js — must score
> ZERO findings on all 7 static rules (concrete grep-able ACs, a biting
> vitest command, a real Final validation list, no placeholders, no weasel or
> open-ended-scope wording). Track is `rn` — the default track — and the body
> below carries no fidelity-related trigger wording and no Design Contract
> section, so the missing-contract rule scores zero because it genuinely has
> nothing to fire on, not because the node-track early-return dodged it.

---

## Status

- [x] Done — branch: `feat/invoice-rounding-helper`

---

## Repository

- Project path: `~/work/example/invoice-service`
- Base branch: `main`
- Feature branch: `feat/invoice-rounding-helper`

---

## Review

- Track: rn
- Review Profile: logic

---

## Summary

Invoice subtotal rounding currently truncates instead of rounding
half-to-even, producing a one-cent drift on totals ending in `.005`. This
adds a `roundHalfEven` helper in `src/math/invoice.ts` and routes every
subtotal calculation through it.

---

## Acceptance Criteria

- [ ] AC1: `roundHalfEven(2.005)` returns `2.00`, and `roundHalfEven(2.015)`
      returns `2.02` (half-to-even, not half-up).
- [ ] AC2: `calculateSubtotal` in `src/math/invoice.ts` calls
      `roundHalfEven` exactly once per line item, verified by a spy in
      `src/math/invoice.spec.ts`.
- [ ] AC3: The 12 golden-total fixtures in
      `src/math/__fixtures__/totals.json` still match byte-for-byte.

---

## Out of Scope

- Currency conversion.
- Refund recalculation.

---

## Technical Approach

- Add `roundHalfEven(value: number): number` to `src/math/invoice.ts`.
- Replace the three `Math.round` call sites in `calculateSubtotal` with it.
- No new dependency; pure function, no I/O.

---

## Test Plan

- First failing test or executable check: `pnpm exec vitest run src/math/invoice.spec.ts`
- Unit tests for: `roundHalfEven`, `calculateSubtotal`
- Baseline validation commands (run before edits):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec vitest run src/math/invoice.spec.ts`
- Final validation commands (run in this order):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec eslint src/math --max-warnings 0`
  3. `pnpm exec vitest run src/math/invoice.spec.ts`
