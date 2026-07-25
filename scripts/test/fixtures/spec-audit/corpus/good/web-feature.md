# Spec: Add a CSV export button to the reports page

## Repository
- Project path: `~/proj`
- Base branch: `main`
- Feature branch: `feat/reports-csv`

## Review
- Track: web
- Review Profile: full

## Acceptance Criteria
- [ ] AC1: A button labelled `Export CSV` renders in `ReportsToolbar`; clicking it downloads `reports-<date>.csv`.
- [ ] AC2: The CSV has a header row `id,name,amount` and one row per visible report.

## Test Plan
- First failing test or executable check: `pnpm exec jest src/reports/export.test.ts`
- Final validation commands (run in this order):
  1. `pnpm exec tsc --noEmit`
  2. `pnpm exec jest src/reports/export.test.ts`
