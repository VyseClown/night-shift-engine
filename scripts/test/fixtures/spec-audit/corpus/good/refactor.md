# Spec: Extract the retry helper into a shared module

## Repository
- Project path: `~/proj`
- Base branch: `main`
- Feature branch: `refactor/retry-helper`

## Review
- Track: node
- Review Profile: logic

## Acceptance Criteria
- [ ] AC1: `withRetry` moves from `src/api/client.ts` to `src/util/retry.ts`; behavior byte-identical.
- [ ] AC2: `grep -rn "function withRetry" src/api` returns nothing; the two call sites import from `src/util/retry.ts`.

## Test Plan
- First failing test or executable check: `pnpm exec vitest run src/util/retry.spec.ts`
- Final validation commands (run in this order):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec vitest run src/util/retry.spec.ts`
