# Spec: Fix negative-subtotal rounding in the invoice total

## Repository
- Project path: `~/proj`
- Base branch: `main`
- Feature branch: `fix/invoice-rounding`

## Review
- Track: node
- Review Profile: logic

## Acceptance Criteria
- [ ] AC1: `computeInvoiceTotal([{cents:-150}])` returns `-2` (round-half-away-from-zero), not `-1`.
- [ ] AC2: `computeInvoiceTotal([])` returns `0`.

## Test Plan
- First failing test or executable check: `pnpm exec vitest run src/invoice/total.spec.ts`
- Final validation commands (run in this order):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec vitest run src/invoice/total.spec.ts`
