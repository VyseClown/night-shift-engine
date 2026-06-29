# Command Playbook — pick the command for the task

A task → command index for the visual-fidelity / Figma / night-shift capabilities in
this repo. Written for both humans and a fresh Claude instance: **match the task to a
row, run the command.** Script paths (`scripts/…`) are relative to the engine repo
root (the `night-shift-engine/` directory); `--project` takes an app repo in the
workspace container (`<workspace>/<app>`).

> **Figma rule (always):** use the **Figma MCP** (`get_figma_data`,
> `download_figma_images`) for every Figma read/export. **Never** use `FIGMA_TOKEN` or
> the Figma REST API. See `docs/2026-06-24-visual-review-live-path.md`.

## Quick chooser

| Your task | Run | Section |
|---|---|---|
| Pull a Figma frame / export reference images | Figma MCP `get_figma_data` + `download_figma_images` | §1 |
| Check how close an RN screen is to its Figma design (diff %, overlay) | `scripts/visual-review.sh --project <app> --drive <mode>` | §2 |
| Auto-fix an RN screen until it matches the Figma design | `scripts/visual-review.sh … --repair` | §3 |
| Auto-fix design drift *during* a night-shift build | `NIGHT_SHIFT_VISUAL_REPAIR=1 … scripts/night-shift.sh …` | §4 |
| Capture by driving the **real** app (no preview harness) | `--drive maestro` (+ a per-screen flow) | §5 |
| Build a feature end-to-end (rn / web / node) | `scripts/night-shift.sh --project <app> --spec <spec>` | §6 |
| Convert a Figma design into a web component | Figma MCP → web-track generate → visual review | §7 |
| Free pre-flight of any night-shift (no cost) | append `--fixture-test --dry-run` | §6 |

---

## §1 — Pull a Figma frame / export references (MCP)

Find the `fileKey` and `nodeId` from the Figma URL
(`figma.com/design/<fileKey>/...?node-id=<nodeId>`; node ids use `1:1548`, not `1-1548`).

- **Structured data** (layout, text, styles — feeds component/flow generation):
  call the MCP tool `get_figma_data` with `{ fileKey, nodeId }`.
- **Reference image** (for pixel-diff or to view the design): call
  `download_figma_images` with `{ fileKey, nodes:[{nodeId, fileName:"Frame.png"}], localPath, pngScale:2 }`.
  `localPath` must be **inside the MCP image directory** (the workspace container); pass it relative
  (e.g. `water-tracker-app/.night-shift/refs`). Stage exports under a **gitignored**
  dir (`.night-shift/`) so they don't pollute `git status`.

## §2 — Review an RN screen's fidelity vs Figma (capture + diff %)

```bash
scripts/visual-review.sh --project <workspace>/<rn-app> --drive <mode> [--spec specs/<name>.md] [--no-refs] [--no-build]
```
Builds/installs the app on the Design-Contract device matrix, stages the Figma
references, captures each screen, pixel-diffs with `odiff`, and writes
`<app>/.night-shift/visual-review/validated/visual-diff-<spec>.json` (the viewer
renders ref / screenshot / diff-overlay / diff% / analysis). Exit 0 = all within
tolerance, 1 = something over, 2 = setup error.

- `--drive` modes (how a screen is put on-screen for capture):
  - **`maestro`** — drives the *real* app via a Maestro flow; **no preview harness**,
    works on a normal build (see §5). Best default on current iOS.
  - **`file`** — cold-launches a seeded preview route (needs the app's file-driven
    preview boot, built `EXPO_PUBLIC_PREVIEW=1`). Deterministic, prompt-free.
  - **`openurl`** — custom-scheme deep link; **iOS 16+ shows an "Open in app?" prompt
    that blocks unattended capture** — avoid on current sims.
- `--no-refs` reuses already-staged references under `<out>/design/`; `--no-build`
  reuses the installed app. Spec-less runs review every spec targeting the project
  that has a `## Design Contract`.

## §3 — Auto-fix an RN screen toward Figma (standalone)

```bash
scripts/visual-review.sh --project <workspace>/<rn-app> --repair[=N] [--repair-shared] --drive file
```
After the report, an agent edits each over-tolerance screen toward the Figma design,
re-captures (Metro fast-reload), and repeats up to `N` attempts/screen (default 3;
global cap 30). **Opt-in, default off.** Edits are scoped to `src/features/`
(`--repair-shared` also allows `src/ui/`), pass a tsc/eslint gate (an attempt that
breaks them is reverted), and are left **uncommitted** for review. Spawns paid
`claude` sessions. (`--repair` forces `--drive file` today; maestro + repair together
is not wired — drive a closeable-gap loop manually if you need maestro re-capture.)

> **Convergence reality:** the auto-fix only visibly converges when the gap is
> *closeable* (same design, off in styling). If the app is a *different* design from
> the Figma frame (its own design system), the diff stays large — that's a real
> fidelity signal, not a fault.

## §4 — Auto-fix design drift inside a night-shift build (in-loop)

```bash
NIGHT_SHIFT_VISUAL_CAPTURE=1 NIGHT_SHIFT_VISUAL_REPAIR=1 NIGHT_SHIFT_ACCEPT_COSTS=YES \
  scripts/night-shift.sh --project <workspace>/<rn-app> --spec specs/<name>.md
```
The engine's `visual_review` stage auto-repairs over-tolerance screens *during* the
build: capture → repair → commit `fix(visual): auto-repair …` on the feature branch →
refresh the report → hand the repaired tip to the observer. **Default OFF**,
**never on `main`/`master`**, **clean-SKIP** if the harness/tooling is missing. The
spec must declare a `## Design Contract`. Knobs: `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS`
(3), `NIGHT_SHIFT_VISUAL_REPAIR_SHARED=1`, `NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP` (30).

## §5 — Maestro: drive the real app for capture

Use when there's **no preview harness** — Maestro navigates the real app to the
scenario, then the pipeline screenshots it.

1. **Java is required.** Maestro is at `~/.maestro/bin/maestro`; point it at a JRE:
   ```bash
   export JAVA_HOME=/opt/homebrew/opt/openjdk@17 PATH="$JAVA_HOME/bin:$HOME/.maestro/bin:$PATH"
   ```
2. **One flow per screen-state**, at `$NIGHT_SHIFT_MAESTRO_DIR/<Screen>-<state>.yaml`
   (default `<project>/.maestro`, but keep it **outside** the app's repo — e.g.
   `/tmp/flows` — if running a `--repair` loop, so the flow file isn't an out-of-scope
   `git status` change). Each flow: `appId:` + `---` + `launchApp` + navigation to the
   scenario, ending in an `assertVisible:` anchor. **No `takeScreenshot`** (the
   pipeline shoots). Sample: `docs/examples/maestro/Home-default.yaml`.
3. Run review with `--drive maestro`:
   ```bash
   scripts/visual-review.sh --project <workspace>/<rn-app> --drive maestro --maestro-dir <flows-dir>
   ```

**Auto-generate a flow from a Figma frame:** dispatch an agent with (a) the Figma
frame via `get_figma_data` + the downloaded frame image, and (b) the app's screen +
navigation files; have it infer which screen/state the frame depicts and write the
`<Screen>-<state>.yaml`. Anchor on a *stable* text (not a time-of-day greeting).

## §6 — Run a full night-shift (rn / web / node)

```bash
# free deterministic pre-flight (no cost):
scripts/night-shift.sh --project <workspace>/<app> --spec specs/<name>.md --fixture-test --dry-run
# real (paid) run:
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <workspace>/<app> --spec specs/<name>.md
```
The spec's `- Track:` (`rn` | `web` | `node`, default `rn`) selects the review persona
set, template, and validation checklist. Model tiering: `NIGHT_SHIFT_PLAN_MODEL`
(opus), `NIGHT_SHIFT_IMPLEMENT_MODEL` (sonnet), `NIGHT_SHIFT_OBSERVER_MODEL` (opus),
`NIGHT_SHIFT_PERSONA_MODEL` (sonnet); set any to `inherit` for the CLI's startup model.
The target repo must gitignore `.night-shift/` and be on the spec's feature branch.

## §7 — Convert a Figma design into a web component (web track)

No single script; it's an MCP-fed, agent-driven flow:

1. **Pull the design** (§1): `get_figma_data { fileKey, nodeId }` for layout/text/style
   tokens, and `download_figma_images` for the frame image (the visual target).
2. **Generate the component** with an agent given the Figma data + image + the
   `web-app/` conventions (`web-app/CLAUDE.md` — Next.js 16 / React 19 / Tailwind).
   Ask it to produce the component from the design, mapping Figma styles to the
   project's tokens. For a full feature, write a `- Track: web` spec and run §6.
3. **Verify fidelity** by rendering the component and pixel-diffing it against the
   downloaded frame image with `odiff` (the same diff the rn path uses), iterating
   until close. (A web capture harness is not yet a single command — render + screenshot
   the route, then `odiff <figma-frame.png> <screenshot.png> <diff.png> --parsable-stdout`.)

## Prerequisites & environment

| Need | For | Install / set |
|---|---|---|
| Xcode + an iOS simulator | all rn capture | Xcode |
| `odiff` on PATH | every pixel-diff | `brew install odiff` (or `NIGHT_SHIFT_VISUAL_DIFF_TOOL`) |
| Figma MCP configured | every Figma read | the Figma MCP server (NOT a token) |
| Java (JRE) | `--drive maestro` only | `export JAVA_HOME=/opt/homebrew/opt/openjdk@17` |
| `NIGHT_SHIFT_ACCEPT_COSTS=YES` | any paid run | env on the command |

> iOS-26 gotcha (already fixed in the engine, but if you script `simctl` yourself):
> `status_bar override --time` wants a plain `09:41`, **not** an ISO datetime — iOS 26
> rejects the latter silently. See `docs/` history / the engine `visual-capture.sh`.
