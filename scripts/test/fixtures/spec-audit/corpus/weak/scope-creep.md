# Spec: Refactor the API layer

- Track: node

## Summary
Clean up the client, the cache, the retry logic, etc., and more as needed.

## Acceptance Criteria
- [ ] AC1: `src/api/client.ts` has no direct `fetch` calls; all go through `request()`.

## Test Plan
- First failing test or executable check: `pnpm exec vitest run src/api/client.spec.ts`
- Final validation commands (run in this order):
  1. `pnpm exec vitest run src/api/client.spec.ts`
