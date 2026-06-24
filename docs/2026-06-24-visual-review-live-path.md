# Visual-review live path — bringing `visual-review.sh` end-to-end on iOS 26

Date: 2026-06-24. Target: `water-tracker-app` (`feat/water-tracker`). This records
the gaps found taking the design-fidelity pass from "half-built" (engine wrapper +
Design-Fidelity persona only) to **real simulator capture of seeded preview
screens**, and the engine changes that resulted.

## What was already there (PRs #17/#19/#21/#22/#23)

`scripts/visual-review.sh` (#22) + `scripts/lib/visual-capture.sh` parse each
spec's `## Design Contract`, stage Figma refs (REST, 429 backoff), drive each
screen, `odiff`-diff vs the reference, and emit `visual-diff-<spec>.json`. The
night-shift run had built the app but **never captured a pixel** — there was no
preview route to drive and no dev build.

## Failure modes found (and fixes)

1. **Engine working tree predated the tools** (HANDOFF §5.0). `feat/water-tracker-specs`
   lacked #21/#22/#23 — merged `origin/main` in. (Process, not code.)

2. **Test files in expo-router's `app/` break the Release bundle.** The harness
   night-shift spec put `app/preview.test.tsx` next to the route. expo-router's
   `require.context` regex (`_ctx.ios.js`) sweeps **every** `*.ts(x)` under `app/`
   into the bundle graph (excludes only `+api`/`+html`/`+middleware`; the `_`
   prefix only affects *routing*). That pulled the test → `@/data/testdb` →
   `node:sqlite` into the production bundle: `expo run:ios --configuration Release`
   failed with "Unable to resolve module node:sqlite". **Debug builds load JS from
   Metro and never embed a bundle, so the engine's tsc/eslint/jest gates — which
   never run a Release Metro bundle — could not catch it.** Fix (app):
   `5bf714e` moved the three `app/` tests to `__tests__/app/`.
   → **Engine gap:** a spec with a `## Design Contract` is built to be captured from
   a standalone bundle, but no gate ever produces one. *Recommended follow-up:* add
   a release-bundle smoke (`expo export --platform ios`) to the rn-track checklist
   for Design-Contract specs. (Not yet implemented.)

3. **iOS 16+ blocks the custom-scheme deep link.** `simctl openurl
   <scheme>://preview?...` pops a SpringBoard **"Open in app?"** confirmation, so
   capture screenshots the dialog, not the screen. The engine's *preferred*
   prompt-free path (`simctl launch <bid> --nightshift-preview "screen:state"`)
   needs the app to read a native launch argument — there is **no pure-JS API** for
   that in Expo. Fix: a third, JS-friendly drive mode (below).

## Engine change: `--drive file` (prompt-free, JS-only-harness capture)

`__visual_capture_screenshot` now supports three drive modes, most→least
prompt-proof:

| Mode | Trigger | How | Needs |
|---|---|---|---|
| **file** | `NIGHT_SHIFT_PREVIEW_FILE` + `_BUNDLE_ID` | write `"<screen>:<state>"` into the app's document dir, `simctl launch` | a JS file reader at boot |
| launcharg | `_BUNDLE_ID` only | `simctl launch … --nightshift-preview` | native arg reader |
| openurl | neither | custom-scheme deep link | nothing (but prompts on iOS 16+) |

`scripts/visual-review.sh` gains `--drive file|openurl` (default `openurl`) and
`--preview-file NAME`; `--drive file` exports the two env vars. Regression fixture:
`fixture_visual_capture_file_drive` (writes target + cold-launches, asserts no
`openurl` and no `--nightshift-preview`). Shellcheck-clean; full fixture suite green.

## App side: file-driven preview boot (water-tracker)

- `src/preview/bootTarget.ts` — `parsePreviewTarget` (pure, unit-tested) +
  `readPreviewTargetSync()` (sync `expo-file-system` `textSync`).
- `app/_layout.tsx` — when `EXPO_PUBLIC_PREVIEW === '1'` and the target file
  exists, render `PreviewHost` for that screen/state instead of the app. Gated so
  it is dead-code-eliminated from real builds.
- Build the capture app with `EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --configuration Release`.

## Running it

```bash
# 1. build + install the preview-enabled Release app on the matrix sims (engine
#    never builds native): EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --configuration Release …
#    then xcrun simctl install <other sims> <app>
# 2. references need a Figma token:
export FIGMA_TOKEN=<personal access token>
scripts/visual-review.sh --project ~/work/water-tracker-app --drive file --no-build
```

Verified 2026-06-24: file-drive cold launch renders the **seeded** Home/default
(1200 ml / 60% ring, seeded "Today" timeline) on iPhone 13 mini, prompt-free, no
Metro. Producing the `visual-diff-*.json` reports across the 3 sims is gated only
on `FIGMA_TOKEN` for reference export.

## Status

- App `feat/water-tracker`: `1f16634` harness, `5bf714e` test relocation,
  `ca30ba6` file-driven boot.
- Engine: `--drive file` + fixture (this change) — to be PR'd off `main`.
- Open: release-bundle smoke gate (failure mode 2); the diff reports themselves
  (need `FIGMA_TOKEN`).
