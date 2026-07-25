# Spec: Speed up the report query

- Track: node

## Summary
Make the report query faster.

## Test Plan
- First failing test or executable check: `pnpm exec vitest run src/report/query.spec.ts`
- Final validation commands (run in this order):
  1. `pnpm exec vitest run src/report/query.spec.ts`
