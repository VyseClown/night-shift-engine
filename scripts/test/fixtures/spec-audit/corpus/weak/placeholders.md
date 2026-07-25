# Spec: Wire the settings screen

- Track: rn

## Acceptance Criteria
- [ ] AC1: Toggling `notifications` persists to storage.

## Technical Approach
- FIXME: decide the storage key naming.
- The migration is TBD.

## Test Plan
- First failing test or executable check: `pnpm exec jest src/settings.test.tsx`
- Final validation commands (run in this order):
  1. `pnpm exec jest src/settings.test.tsx`
