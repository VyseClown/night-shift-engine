# Spec: Port the promo banner to native

- Track: rn

## Summary
The banner must be pixel-perfect and match the Figma exactly.

## Acceptance Criteria
- [ ] AC1: `PromoBanner` renders the headline and CTA.

## Test Plan
- First failing test or executable check: `pnpm exec jest src/promo/Banner.test.tsx`
- Final validation commands (run in this order):
  1. `pnpm exec jest src/promo/Banner.test.tsx`
