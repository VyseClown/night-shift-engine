# Command Playbook — pick the command for the task

> Summary: Task → command index for Figma export, RN
> visual-review/repair/Maestro capture, running a night-shift, the
> design-extract/port-audit/test-audit CLIs, `--sweep-only`, and the opt-in
> Codex implement-stage engine. Start at the "Quick chooser" table; each row
> links to its `§N` section for the full command.

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
| Build a feature end-to-end (rn / web / node / fullstack) | `scripts/night-shift.sh --project <app> --spec <spec>` | §6 |
| Convert a Figma design into a web component | Figma MCP → web-track generate → visual review | §7 |
| Extract a design manifest (web or Figma) | `scripts/design-extract.sh …` | §8 |
| Audit how faithfully a port implements its design manifest | `scripts/port-audit.sh --project <app> --screen <s> --manifest <m>` | §9 |
| Review a whole branch before merge (verdict-only by default) | `scripts/night-shift.sh --sweep-only --project <path>` | §10 |
| Audit tests for false confidence (vacuous assertions, tautological round-trips) | `scripts/test-audit.sh --project <app> --tests <path...>` | §11 |
| Audit a spec's quality before launching a run (vague ACs, non-biting validation) | `scripts/spec-audit.sh --spec <spec> [--offline]` | §12 |
| Run a task's implement stage on Codex instead of Claude | `- Engines: implement=codex` in the spec's `## Review` section | §13 |
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

## §6 — Run a full night-shift (rn / web / node / fullstack)

```bash
# free deterministic pre-flight (no cost):
scripts/night-shift.sh --project <workspace>/<app> --spec specs/<name>.md --fixture-test --dry-run
# real (paid) run:
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <workspace>/<app> --spec specs/<name>.md
```
The spec's `- Track:` (`rn` | `web` | `node` | `fullstack`, default `rn`) selects the
review persona set, template, and validation checklist (`fullstack` = API + web UI in
one change: the web bench with Backend & Data Expert promoted into the always-run
floor, profiles `full`/`logic` only, template `specs/_template-fullstack.md`). Model tiering: `NIGHT_SHIFT_PLAN_MODEL`
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

## §8 — Extract a design manifest (web or Figma) → `scripts/design-extract.sh …`

A zero-dep CLI that pulls a `night-shift-design-manifest/1` JSON (per-element role,
text, typography, color, bounds, spacing, radius, plus a rollup palette/fonts/spacing/
radii/icons) out of either a live web page (real Chrome over CDP) or a committed Figma
node-dump — the SAME schema either way, so the two are directly diffable. Point a
spec's `- Design manifest:` field at the written JSON and the implement stage's prompt
gets an authoritative "Design ground truth" table built straight from it (see
`manifest_prompt_block` in `scripts/night-shift.sh`) instead of hand-typed tokens.

```bash
# web mode — drives a live page over CDP (needs a local Chrome):
scripts/design-extract.sh --mode web --screen dashboard --project <workspace>/<app> \
  --url http://localhost:3000/dashboard --cookie session=abc123

# figma mode — parses a committed node-dump + globals file (no chrome, no network):
scripts/design-extract.sh --mode figma --screen dashboard --project <workspace>/<app> \
  --nodes design/figma/dashboard.txt
```

Default `--out` is `<project>/design/manifest/`, writing `<screen>.json` (web mode
also `<screen>-<W>x<H>.png`). `--mode figma` defaults `--globals` to
`<dirname of --nodes>/_global-vars.txt` when not passed explicitly. Exit 0 on success,
2 on a usage error (e.g. `--mode web` without `--url`), or whatever the dispatched
extractor exits with on an extraction failure (1, one-line stderr).

## §9 — Audit port fidelity against a design manifest → `scripts/port-audit.sh …`

A zero-dep CLI that scores how faithfully an already-ported screen implements a
`night-shift-design-manifest/1` JSON (§8's output): a deterministic static extractor
(`scripts/lib/port-audit-static.js`) pulls tokens + resolved style-property usages out
of the scoped source, ONE bounded `claude -p` agent pass maps manifest elements to the
source lines that implement them, and a deterministic wrapper
(`scripts/lib/port-audit-normalize.sh`) computes every expected/actual/status/delta
value itself — the agent's reply is never trusted for arithmetic, only for the
element→evidence mapping.

```bash
scripts/port-audit.sh --project <app> --screen <name> --manifest <path> \
  [--scope src/features/<dir>] [--model sonnet] [--offline <canned-reply.json>]
```

Writes `<project>/.night-shift/port-audit/<screen>.json` — entries tagged `match` /
`off` / `missing` / `extra` / `unknown`, plus a `summary.pct` match rate. Exit 0 on
success, 2 on a usage/argument error (nothing written), 3 when the agent pass fails
twice (report still written with `entries:[]` + `summary.error`, so a caller always
has *a* report to read). `--offline <reply.json>` skips the paid call entirely for a
fully deterministic dry run.

**Engine wiring (opt-in, non-gating):** set `NIGHT_SHIFT_PORT_AUDIT=1` and give the
spec a Design Contract `- Design manifest:` field, and `night-shift.sh` runs this CLI
once per manifest (screen = the manifest's basename) right after the candidate is
validated, on the `NIGHT_SHIFT_PERSONA_MODEL` knob. Every report on disk (regardless
of exit status) is attached — indented, advisory, never authoritative — to the Design
Fidelity Reviewer's implementation-review bundle and the observer's evidence, and a
`port_audit` event (`{screen, pct}`, `pct:null` on `summary.error`) is journaled.
Missing tooling, a failed agent pass, or an unresolvable manifest path all skip
cleanly with a `WARN` log — this never blocks a candidate or fails a run.
`NIGHT_SHIFT_PORT_AUDIT_OFFLINE=<canned-reply-path>` routes the engine-invoked call
through `--offline` (fixture/dry-wire use).

## §10 — Review a whole branch before merge → `scripts/night-shift.sh --sweep-only --project <path>`

```bash
scripts/night-shift.sh --sweep-only --project <workspace>/<app>
```

One-shot, no run/queue, no `--spec`: builds the merge-base diff package
(`package.diff` + `package.meta.json`; refuses a default-branch tip — nothing
branch-shaped to review) and runs one whole-branch strong-model review
session (`NIGHT_SHIFT_SWEEP_MODEL`, default = `NIGHT_SHIFT_OBSERVER_MODEL`)
looking for what per-task reviews can't see — cross-task interactions,
accumulated minor findings, hygiene (neutral test fixtures, no company
identifiers, complete i18n key pairs), tests weakened rather than updated.
Writes `findings.md` (whose last line carries the verdict, e.g.
`SWEEP_FINDINGS: <n>`) and `verdict.txt` (the bare word only — `SWEEP_PASS` /
`SWEEP_FINDINGS` / `SWEEP_ERROR` on a session failure, no count) under a
printed `night-shift-sweep-<pid>` tmp dir.

**Verdict-only by default** — a bare invocation never touches the target
repo, regardless of `NIGHT_SHIFT_BRANCH_SWEEP`'s value elsewhere; on this
standalone surface only the literal `NIGHT_SHIFT_BRANCH_SWEEP=1` also runs a
capped fix cycle (`NIGHT_SHIFT_SWEEP_MAX_FIX`, default `1`): an
implement-model session fixes only the findings and commits directly to the
project's branch. **Caveat specific to `--sweep-only`:** the fix cycle's
re-validation + deterministic-revert safety net (final validation commands
re-run; a failed re-validation `git reset --hard`s back to the pre-fix tip)
needs both a spec and a live run root, neither of which this standalone
surface ever has — so here the fix commits land with no re-validation gate
and no revert net. The in-run sweep (below) gets the full safety net; treat
`NIGHT_SHIFT_BRANCH_SWEEP=1` on bare `--sweep-only` as "fix and review the
result yourself," not "fix and trust it." Exit `0` on `SWEEP_PASS`, `2` on
`SWEEP_FINDINGS` or `SWEEP_ERROR`.

The same review also runs automatically at the end of a normal night-shift
when `NIGHT_SHIFT_BRANCH_SWEEP` is `1` or `advisory` (`advisory` = findings
only, never the fix cycle, even on a `SWEEP_FINDINGS` verdict) — never gating
completion either way. `NIGHT_SHIFT_SWEEP_MAX_WAIT` (default `900`s) bounds
the sweep session's own rate-limit retry on both surfaces.

## §11 — Audit tests for false confidence → `scripts/test-audit.sh …`

A zero-dep-static + one-agent-pass CLI that finds tests which PASS while
asserting nothing meaningful — mirrors `port-audit.sh`'s two-layer
architecture. Evidence this matters: `expect(result.installmentGroupId)
.not.toBe("group-a")` passed vacuously because `installmentGroupId` doesn't
exist on `result` (`undefined !== "group-a"` is trivially true); only a
sibling positive assertion elsewhere exposed the bug. A deterministic static
scan (`scripts/lib/test-audit-static.js`) flags mechanical smells
(vacuous `.not.toBe(<literal>)`, asserts on a property absent from the
source, `toBe(true)` on constants, empty/expect-less test bodies, stale
`.skip`/`xit`); ONE bounded `claude -p` agent pass then judges each static
finding confirm/refute with a one-line reason and hunts judgment-tier smells
the static scan can't see (a mock tested against itself, a tautological
round-trip, a guard with no negative-case test). The agent's reply is never
trusted for arithmetic — every count is recomputed by the script (jq) from
the static findings + the agent's validated `{file,line,rule}` mapping.

```bash
scripts/test-audit.sh --project <app> --tests <path...> [--src <dir>] \
  [--model <name>] [--offline] [--out <json>]
```

Writes `<project>/.night-shift/test-audit/report.json` (default `--out`) plus
a sibling `.md`, schema `night-shift-test-audit/1`:
`summary.final_total = confirmed + unjudged + additional`. Exit `0` when
`final_total == 0`, `2` when it's `> 0` (findings exist — this is the common,
non-error outcome), `3` only on an infra/usage error (nothing written).
`--offline` skips the paid call entirely (static-only; every finding stays
unjudged) for a fully deterministic, zero-cost dry run. An agent-pass failure
(missing `claude`, non-zero exit, an unparseable reply after one retry) is
NEVER an exit-3 condition either — it degrades to "every static finding stays
unjudged" (noted in `agent_note`), same fail-open-on-evidence posture as
`port-audit.sh`.

**Engine wiring (opt-in, non-gating):** set `NIGHT_SHIFT_TEST_AUDIT=1` and
`night-shift.sh` runs this CLI once per candidate, scoped to ONLY the test
files the candidate diff touched (skips cleanly when the diff touches none),
on the `NIGHT_SHIFT_TEST_AUDIT_MODEL` knob (default `sonnet`). Every report on
disk is attached — indented, advisory, never authoritative — to the
implementation-review bundle and the observer's evidence, and a `test_audit`
event (`{files, final_total}`) is journaled. A failed or missing report is a
`WARN` log only — this never blocks a candidate or fails a run.

## §12 — Audit a spec's quality before launching → `scripts/spec-audit.sh …`

A zero-dep-static + one-agent-pass CLI that catches a weak spec **before** it
burns a run — the pre-run analog of §11's test-audit. The engine executes a
spec literally, so an ambiguous or underspecified spec produces mediocre work
at full cost; run this while drafting and iterate until it's clean.
`validate_spec` answers "is this spec *valid*?" (structural); spec-audit
answers "is this spec *good*?" (quality). A deterministic static scan
(`scripts/lib/spec-audit-static.js`) flags mechanical smells (unfilled
placeholders, missing/empty acceptance criteria, vague weasel-worded ACs,
open-ended scope markers, a Test Plan with no test-runner in its validation,
missing final-validation, visual-intent language with no Design Contract);
ONE bounded `claude -p` pass then judges each static finding confirm/refute
with a reason and hunts judgment-tier smells the scan can't see (acceptance
criteria that aren't actually testable, validation commands that wouldn't
exercise the described change, edge cases the spec implies but omits, scope
under-specified for the goal). The agent's reply is never trusted for
arithmetic — every count is recomputed by the script (jq) from the static
findings + the agent's validated `{rule,line}` mapping.

```bash
scripts/spec-audit.sh --spec <spec> [--project <dir>] \
  [--model <name>] [--offline] [--out <json>]
```

Schema `night-shift-spec-audit/1`:
`summary.final_total = confirmed + unjudged + additional`. Exit `0` when
`final_total == 0` (a clean spec), `2` when it's `> 0` (findings — the common,
non-error outcome), `3` only on an infra/usage error (bad args, missing spec,
static-scanner failure — nothing written). `--offline` skips the paid call
entirely (static-only; every finding stays unjudged) for a fully
deterministic, zero-cost author-time pass — iterate `--offline` until the
static layer is clean, then run once without it for the judgment pass. An
agent-pass failure (missing `claude`, non-zero exit, an unparseable reply
after one retry) is NEVER an exit-3 condition either — it degrades to "every
finding stays unjudged" (noted in `agent_note`), the same fail-open-on-evidence
posture as `test-audit.sh`.

**Not engine-wired (by design):** this is a standalone author-time tool. A
subjective spec-quality call should not silently block a launch, so spec-audit
does not gate a run — wiring it into preflight as an advisory warning is a
deliberate follow-up.

## §13 — Run a task's implement stage on Codex instead of Claude → `- Engines:` spec field

Opt-in, per spec, narrower than the old (removed) Codex-everywhere path: only
the `implement` stage scope may run on codex; `plan`/`observer`/personas always
stay Claude — the independent Claude observer gates a codex-implemented
candidate exactly like a Claude-implemented one. Add one line to the spec's
`## Review` section (same bare-token dialect as `- Track:` — no backticks):

```
- Engines: implement=codex review=codex
```

- `implement` ∈ `claude` (default) | `codex` — the vendor for the implement
  stage grind only.
- `review` ∈ `codex` | `off` — per-spec override of the existing
  `NIGHT_SHIFT_CODEX_REVIEW` advisory-review knob; the spec wins over the env
  var in BOTH directions. Omit the role entirely to leave the env knob as-is.
- `plan=codex` / `observer=codex` are rejected outright at spec selection
  ("plan and observer are Claude-only (the judgment gates that make a second
  vendor safe)").
- `implement=codex` with no `codex` CLI on PATH fails at spec selection, not
  mid-run (same fail-loud posture as an invalid `- Workdir:`/`- Smoke:`).
- `implement=codex` under `NIGHT_SHIFT_CODEX_SANDBOX=workspace-write` fails at
  spec selection too: codex keeps `.git` read-only under that sandbox with no
  config escape hatch, so a workspace-write implement run could never `git
  commit` a candidate — proven live, not a theoretical stricter posture.
  `danger-full-access` (the default) is the only sandbox that works today;
  `workspace-write` is kept as an accepted value for a future codex version
  that lifts the restriction.
- `implement=codex` also requires `NIGHT_SHIFT_SESSION_SCOPE=stage` (the
  default): session ids are vendor-specific and never cross vendors (`codex
  exec resume <claude-uuid>` is meaningless), and `SESSION_SCOPE=run` only
  nulls the session at scope boundaries a single-task run may never reach.

Run exactly like any other night-shift task — nothing else about the command
changes:

```bash
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <app> --spec <spec-with-Engines-field>
```

Knobs: `NIGHT_SHIFT_CODEX_SANDBOX` (default `danger-full-access` — parity with
the Claude primary's own `--permission-mode bypassPermissions`; the engine's
real safety layer — feature-branch confinement, wrapper-forbidden git ops,
`integrity_guard`, the independent observer gate — is vendor-agnostic, not the
sandbox flag; `workspace-write` is also accepted but CANNOT complete the
implement pipeline today, see above), `NIGHT_SHIFT_CODEX_IMPLEMENT_MODEL`
(default empty = codex's own configured default, passed on both the fresh AND
the resume invocation — codex re-resolves its model per call, unlike `claude
--resume`), `NIGHT_SHIFT_CODEX_MAX_RETRY` (default `2` extra attempts, 60s
apart, before `block_run` — no Claude-shaped 429 handling for codex in v1).
`NIGHT_SHIFT_REVIEW.md` and the observer's own verdict then honestly show
`"primary": "codex"` for that task instead of always `"claude"`.

## Prerequisites & environment

| Need | For | Install / set |
|---|---|---|
| Xcode + an iOS simulator | all rn capture | Xcode |
| `odiff` on PATH | every pixel-diff | `brew install odiff` (or `NIGHT_SHIFT_VISUAL_DIFF_TOOL`) |
| Figma MCP configured | every Figma read | the Figma MCP server (NOT a token) |
| Java (JRE) | `--drive maestro` only | `export JAVA_HOME=/opt/homebrew/opt/openjdk@17` |
| `NIGHT_SHIFT_ACCEPT_COSTS=YES` | any paid run | env on the command |
| `codex` CLI on PATH | `- Engines: implement=codex` only | see the Codex CLI's own install docs |

> iOS-26 gotcha (already fixed in the engine, but if you script `simctl` yourself):
> `status_bar override --time` wants a plain `09:41`, **not** an ISO datetime — iOS 26
> rejects the latter silently. See `docs/` history / the engine `visual-capture.sh`.
