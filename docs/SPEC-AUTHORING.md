# Spec Authoring — how to write a spec that produces great work

> Summary: The craft of writing a night-shift spec the engine executes well —
> picking a track, writing testable acceptance criteria, and (most of all)
> validation commands that actually BITE so broken work can't pass. Read
> `AGENTS.md` for the process rules and `docs/COMMAND-PLAYBOOK.md` for the
> command index; this is the authoring guide behind them.

The engine executes your spec literally. It plans, implements, reviews, and gates
against exactly what you wrote — no more, no less. A great spec is the single
highest-leverage input to a run; everything downstream (model tiering, personas,
the observer) only enforces the contract you handed it. This doc is how to write
that contract well.

Start from a template — copy the one for your track (below) into
`specs/<feature-name>.md` and fill in *every* section. Ambiguous or
underspecified specs produce wrong or mediocre work **at full run cost** — you
pay for the whole plan/implement/review/observe loop whether the spec was good or
not. The cheapest place to fix a run is before it starts.

---

## Why the spec is everything

`validate_spec` mechanically gates structural completeness before a single model
call: repository path, base branch, feature branch (all non-placeholder), a valid
Review Profile for the track, dependency/native permissions in `yes/no - <details>`
form, a documentation-owner line per active persona, and all three Test Plan
fields. Missing or placeholder values block the run. That gate catches *structure*
— it cannot catch a spec that is complete but vague. "Make the dashboard look
better" passes `validate_spec` and produces junk.

The prose sections (Summary, User Story, Acceptance Criteria) are *not* checked by
the validator — they're read by the review personas and the observer during the
run. So they are where your intent lives or dies. Write them as if the
implementer has never seen the app and will do exactly what the words say, because
that is the situation.

---

## Choosing a track

A spec declares its track with `- Track: rn | web | node | fullstack` (default
`rn`, so an rn spec may omit it — but state it anyway for clarity). The track
selects three things at once: the **review persona set**, the **spec template**,
and the **validation checklist** in `AGENTS.md`.

| Track | For | Copy this template |
|---|---|---|
| `rn` | React Native (mobile, iOS/Android) | `specs/_template.md` |
| `web` | Next.js / React web + its data/API layer | `specs/_template-web.md` |
| `node` | plain Node / CLI / backend, no UI surface | `specs/_template.md`, set `- Track: node` |
| `fullstack` | one change spanning an API surface AND a web UI surface (e.g. a monorepo touching `apps/api` and `apps/web` together) | `specs/_template-fullstack.md` |

The `node` track reuses the web/backend personas (Backend & Data Expert stands in
for the architecture role) and offers only the `full` and `logic` profiles — no UX
persona, because there's no UI to review. The `fullstack` track runs the web bench
with Backend & Data Expert promoted into the always-run floor, so a light profile
can't silently drop one side of the stack; it too offers only `full`/`logic`. If a
change is narrow enough to drop a side, it belongs on `web` or `node`, not
`fullstack`.

Within a track the **Review Profile** trims which personas run (`full` /
`frontend` / `logic` / `native` / `data`, per track) so small tasks don't pay for
irrelevant reviewers. The template's Review section has the profile→persona table;
`full` is the safe default when unsure.

---

## Scope that isn't ambiguous

Acceptance Criteria are the spec's teeth for scope. The template says it plainly:
*each criterion is binary — pass or fail.* Write them so a reviewer can point at
the running app (or a test) and say yes/no without a judgment call.

Bad (unfalsifiable — a reviewer can't disprove it):

```
- [ ] AC1: The settings screen looks polished and modern.
- [ ] AC2: Saving feels fast.
```

Good (concrete, testable):

```
- [ ] AC1: The settings screen renders a section list with Account, Notifications,
      and About rows; each row shows its label left and a chevron right.
- [ ] AC2: Tapping "Notifications" pushes the Notifications screen; the back button
      returns to Settings with scroll position preserved.
- [ ] AC3: Saving a changed toggle persists across an app restart (read back from
      storage on next launch).
```

Each good criterion names the element, the interaction, and the observable
outcome. Put everything the implementer must *not* touch in **Out of Scope** —
it's as load-bearing as the criteria. Resolve **Open Questions** before launch: an
unanswered question is the engine guessing on your behalf.

---

## Validation commands that BITE

This is the most important section in your spec, and the one most often written
too weakly. The Test Plan is the engine — not decoration.

**How the engine uses the three Test Plan fields:**

- **`First failing test or executable check`** must be RED before the change.
  For net-new code, name the not-yet-existing test (absent ⇒ red at baseline). For
  a feature that *modifies* an already-tested module, the engine auto-detects
  "modify-mode": it doesn't block on the green baseline, and proves red by
  overlaying the candidate's updated test files onto BASE production after
  implementation (they must fail there). Either way, this is the proof that the
  test actually exercises the new behavior — a test that's green at baseline and
  green after proves nothing.
- **`Baseline validation commands (run before edits)`** run against the
  untouched tree so pre-existing failures are distinguishable from regressions the
  run introduces. Baseline is allowed to be RED — that's the point.
- **`Final validation commands (run in this order)`** run in an isolated
  validation worktree and must pass without regressing vs baseline. This is the
  gate the candidate has to clear.

**Why vacuous validation is the enemy.** If your final validation doesn't actually
execute the changed code, broken work passes the gate. A spec that adds a
`computeInvoiceTotal` function but whose final validation is only `tsc + eslint`
has no test that *calls* `computeInvoiceTotal` — the engine can ship a function
that returns the wrong number and every gate stays green. The validation set has
to touch the change.

Non-biting vs biting, for that example:

```
# Non-biting — types and lint pass on wrong logic:
- Final validation commands (run in this order):
  1. `npx tsc --noEmit`
  2. `npx eslint . --max-warnings 0`

# Biting — a test asserts the actual computed value, and it's named as the red check:
- First failing test or executable check: `npm test -- --watchAll=false src/billing/invoice.test.ts`
- Final validation commands (run in this order):
  1. `npx tsc --noEmit`
  2. `npx eslint . --max-warnings 0`
  3. `npm test -- --watchAll=false`   # includes invoice.test.ts asserting computeInvoiceTotal([...]) === 4207
```

Rules of thumb: name a first-failing test that fails *because the feature is
missing*, not because of a typo you'll fix; make sure the final test suite
actually includes a test that asserts the new behavior's output; and keep the
commands in the exact order the app needs them (typecheck → lint → test →
build/e2e). The `web`/`fullstack` templates put `npm run build` in final
validation deliberately — it catches RSC/route/type errors that `tsc` alone
misses.

> Opt-in backstop: `NIGHT_SHIFT_TEST_AUDIT=1` runs a false-confidence pass over
> only the test files the candidate touched — a static scan for vacuous-assertion
> smells plus one agent judgment pass (self-testing mocks, tautological
> round-trips). It's non-gating (attached to the observer's evidence), but it's
> the tool that catches a test that looks like it bites and doesn't. See
> `docs/COMMAND-PLAYBOOK.md` §11.

---

## Smoke fields — prove the app BOOTS

Green `tsc` + `eslint` + `jest` do not prove the app starts. The motivating
evidence class: a Release-bundle break that passed every one of those static
checks — e.g. a stray import that only resolves under Metro, or a file that breaks
the production bundle while every unit test stays green. Static gates
structurally can't see it.

The optional smoke phase runs the app for real, right alongside baseline and final
validation, on both the initial task and any chained one. Two modes:

```
# Exit mode — the command must exit 0 within the timeout (a CLI, --help, a build):
- Smoke: `npm run build && node dist/cli.js --help`

# Server mode — start it, poll the loopback URL for HTTP 200, then kill the group:
- Smoke: `npm start`
- Smoke URL: `http://127.0.0.1:8081/`
```

Rules the engine enforces at spec selection (malformed ⇒ fails loudly, same
dialect as `- Workdir:`):

- **Backticks are required** around both field values.
- The **Smoke URL must be loopback-only** — `http://127.0.0.1` or
  `http://localhost`. Anything else is rejected.
- The **port must be exclusive to the run**: something already listening there
  before boot fails the phase rather than racing it.
- Prefer a boot command that does **not** daemonize/detach — a self-daemonizing
  dev server can outlive the engine's process-group kill.

Baseline never blocks on its own smoke result (recorded, judged only for
regression); final regresses the candidate exactly like the ordinary
final-validation gate. Default timeout is `NIGHT_SHIFT_SMOKE_TIMEOUT` (120s).

---

## Design-fidelity specs

If the work must match a Figma design pixel-for-pixel, add a `## Design Contract`
section (and a `## Design source`). Including `## Design Contract` auto-activates
the **Design Fidelity Reviewer** persona, which then owns that contract, and — with
`NIGHT_SHIFT_VISUAL_CAPTURE=1` on an `rn` spec — enables the `visual_review` stage
(Figma-MCP reference + iOS-simulator capture + `odiff` pixel-diff + agent
auto-repair).

The contract fields (see the template) name the Figma file/page, `Frames:`,
`Required states:`, `Devices:`, `Tolerance:`, and the assets/tokens. Two fields
back the capture with the real node tree rather than a flat image:

```
- Design manifest: `design/manifest/dashboard.json`   # path(s) under the project, comma-separated
- Manifest source: figma                              # web | figma — how design-extract.sh extracted it
```

State design details a flat screenshot misses (e.g. a ring built from two layered
wave nodes) in the contract prose — the repair agent honors `## Design Contract`
and `## Design source`. Keep the spec tight here and lean on
`docs/COMMAND-PLAYBOOK.md` for the full visual pipeline (capture drives, Maestro
flows, in-loop auto-repair, the device registry for parallel runs).

---

## Monorepo targets

Point `--project` at the **repo root**. To keep every validation phase (baseline,
first-failing-test red/green, final, smoke) running inside one app's subdirectory,
declare:

```
- Workdir: `apps/api`
```

Validation rules the engine enforces at spec selection (malformed ⇒ fails loudly):
the directory **must exist under the project**, be **tracked at HEAD**, and
**resolve inside the project** (no symlink escapes). **Backticks are required** — a
bare value fails.

For a pnpm workspace you need no `NIGHT_SHIFT_DEPENDENCY_LINKS` override: each
workspace package's `node_modules` (from `pnpm-workspace.yaml`) plus `.nx/cache`
are auto-linked into the isolated validation worktree. Alternatively, skip
`- Workdir:` and write every command to run from the root, filtered to the touched
projects — e.g. `pnpm nx run-many -t typecheck lint test build --projects
app-api,app-web`. In a build-graph monorepo, rebuild consumed packages before
typechecking their consumers when imports resolve through a built `dist/`.

Describe the monorepo generically in the spec (e.g. "a shared `ui-core` package
consumed by `apps/web`"); the spec is the executable contract, so keep it precise
about paths but neutral about product.

---

## Permissions & documentation ownership

The engine treats the spec as a hard boundary on what the implementer may add:

```
## Permissions
- New dependencies permitted: no
- Native `ios/` changes permitted: no       # rn template
- Native `android/` changes permitted: no    # rn template
- Database migration permitted: no            # web / fullstack templates
- Network access required during implementation: no
```

A bare `yes` is **not** approval — you must list every approved dependency,
migration, or native change with details. The implementer will not install a
package or touch native code that isn't named here.

Every **active** review persona must own a line under *Documentation owned by each
review persona* — this is validated. For a persona that isn't active in your
profile, use `none — not in profile`; for an active persona with no
domain-relevant docs, use `none — <reason>`. An active optional reviewer (via
`- Optional reviewers:` or an auto-activating `## … Contract` section) needs an
ownership line too.

---

## Close the loop: read feedback.md first

Run feedback is **on by default** (`NIGHT_SHIFT_RUN_FEEDBACK=1`). At every run's
completion a short session distills the run's journal into 5–15 bullets for
whoever authors specs — spec ambiguities, stages that looped, validation friction
— appended to `<project>/.night-shift/feedback.md` (a persistent, cross-run file
that survives success archival).

**Read that file before authoring the next spec for the same project.** It exists
for exactly this purpose: it tells you which parts of your last spec the engine
found ambiguous, where it wheel-spun, and which validation commands fought it. The
cheapest spec improvement is the one the previous run already diagnosed for you.

---

## Pre-flight checklist

Before you launch a real run:

- [ ] Copied the right **template** for the track and filled *every* section.
- [ ] Acceptance Criteria are binary; Out of Scope and Open Questions are done.
- [ ] Final validation includes a test that **asserts the new behavior's output**,
      and the first-failing test is genuinely RED at baseline.
- [ ] Considered a `- Smoke:` field if a broken boot could pass static checks.
- [ ] Permissions list every approved dependency/native/migration change explicitly.
- [ ] Read `<project>/.night-shift/feedback.md` from the last run.
- [ ] Target repo **gitignores `.night-shift/`** and is on the spec's **feature
      branch** (not the base branch).
- [ ] Ran a free deterministic pre-flight:
      `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <path> --spec specs/<name>.md --fixture-test --dry-run`
      (or `scripts/night-shift.sh --preflight --project <path> --spec specs/<name>.md`
      for the read-only launch-readiness report).

When those pass, launch:
`NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <path> --spec specs/<name>.md`.
Then verify the result with `docs/QA-RUNBOOK.md`.
