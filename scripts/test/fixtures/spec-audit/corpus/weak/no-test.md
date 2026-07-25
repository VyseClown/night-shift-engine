# Spec: Add a discount field

- Track: node

## Acceptance Criteria
- [ ] AC1: `applyDiscount(100, 0.1)` returns `90`.

## Test Plan
- First failing test or executable check: `pnpm exec tsc --noEmit`
- Final validation commands (run in this order):
  1. `pnpm exec eslint .`
  2. `pnpm exec tsc --noEmit`
