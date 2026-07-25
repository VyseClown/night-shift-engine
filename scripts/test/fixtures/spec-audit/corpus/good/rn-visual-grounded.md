# Spec: Native profile header — pixel-perfect port

## Repository
- Project path: `~/proj`
- Base branch: `main`
- Feature branch: `feat/native-profile-header`

## Review
- Track: rn
- Review Profile: frontend

## Acceptance Criteria
- [ ] AC1: `ProfileHeader` renders the title at `28/34` and the subtitle at `15/20`, tokens from `typography.*`.
- [ ] AC2: The hero gradient uses the two stops from the manifest, no hardcoded colors.

## Design Contract
The header must be pixel-perfect against the web reference.

## Design source
- Manifest source: web

## Test Plan
- First failing test or executable check: `pnpm exec jest src/profile/Header.test.tsx`
- Final validation commands (run in this order):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec jest src/profile/Header.test.tsx`
