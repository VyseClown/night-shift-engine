# Spec Authoring — the structure that gets the best autonomous output

> How to write a spec so a night-shift run produces the best work the engine can
> deliver. The templates (`specs/_template.md`, `_template-web.md`,
> `_template-fullstack.md`) give you the *skeleton*; this doc explains what makes
> each section pull its weight, ranked by how the engine actually consumes it.
> Companion to `NIGHT_SHIFT_HOWTO.md` (how a run works) and `AGENTS.md` (rules).

The one-line thesis: **the spec is the only channel you have into an unattended
run.** The engine never asks questions mid-run — anything the spec leaves
ambiguous either becomes a `BLOCKED` stop (wasted night) or a guess by a model
you weren't watching (wasted morning). Everything below is about moving
information from "the agent must infer it" to "the spec states it".

---

## The three tiers of a spec

Every section of the template belongs to one of three tiers. Knowing which tier
a section is in tells you *who reads it* and therefore *how to write it*.

| Tier | Sections | Consumed by | Failure mode if weak |
|---|---|---|---|
| **1 — Mechanically validated** | Repository, Track + Review Profile, Permissions, Documentation owners, the three Test Plan fields | `validate_spec` (regex/grep, before any token is spent) | Run refuses to start — cheap, safe |
| **2 — Executed / parsed by the engine** | First failing test, Baseline + Final validation commands, `Workdir:`, `Personas:` / Optional reviewers, `## … Contract` sections (auto-activation, visual capture matrix, model bump) | The wrapper itself, verbatim via `bash -lc` | Wrong commands = wrong definition of "done"; the run can pass while the feature is broken |
| **3 — Judgment prose** | Summary, User Story, Acceptance Criteria, Technical Approach, Platform/Surface Notes, Edge Cases, Out of Scope, Open Questions | The opus planner, the persona reviewers, the observer | Ambiguity → `BLOCKED` at plan time, scope drift, or a candidate that solves the wrong problem |

Tier 1 is table stakes — the validator blocks placeholders, so you literally
cannot skip it. **Tiers 2 and 3 are where output quality is decided**, because
nothing checks them except the models themselves.

---

## Tier 2 — the fields the engine executes

### The Test Plan is the real acceptance gate

The run's definition of done is *your commands*, not the agent's judgment:

1. **Baseline commands** run before any edit (pre-existing failures recorded).
2. **First failing test** must be RED before implementation.
3. After implementation it must be GREEN.
4. **Final commands** run in an isolated worktree and must not regress baseline.

Rules that make this gate strong:

- **If you can't express "done" as a command that fails-then-passes, the spec
  isn't ready.** Rework the feature until you can name that command.
- **Name the first failing test precisely.** Net-new code: name the
  not-yet-existing test file (absent → red). Modifying an already-tested module:
  name the existing test — the engine auto-detects *modify-mode* and proves red
  by overlaying the candidate's updated tests onto BASE production.
- **Commands must be deterministic, non-interactive, and exit-code honest.** No
  watch mode (`--watchAll=false`), no prompts, no commands that "pass" by
  printing warnings. Order fastest-first (tsc → lint → test → build) so failures
  surface cheaply.
- **Match the track checklist** in `AGENTS.md` and the project's own `CLAUDE.md`
  — the spec's commands override the defaults, so keep them at least as strict
  (web specs include `npm run build`; add `test:e2e` only when a user-facing
  flow changes, it's the slowest step).
- **Fill `Expected evidence paths`** when the run should produce artifacts
  (coverage output, screenshots, generated files) — the observer can then check
  they exist instead of trusting prose.
- **Trust boundary:** these commands run *verbatim* under
  `--permission-mode bypassPermissions`. A spec is executable code. Only run
  specs you wrote or fully reviewed.

### Acceptance Criteria drive the implement loop

`AGENT_LOOP.md` implements **one criterion at a time**: add a failing check for
the next AC → smallest change to pass → typecheck → next. So the ACs are not
documentation — they are the loop's iteration variable. Write them so the loop
converges:

- **Binary, observable, and test-mapped.** Every AC should be checkable by a
  command or a concrete manual step. "AC3: works well on slow networks" is a
  wish; "AC3: with a 5s-delayed API response the list shows the skeleton loader
  and no layout shift (`HomeList.loading.test.tsx`)" is a criterion.
- **3–7 criteria.** Fewer usually means the feature is under-specified; more
  usually means the spec should be split (see *Right-sizing* below).
- **Ordered by dependency.** The agent implements top-down; put the criterion
  the others build on first (schema → logic → UI → polish).
- **Each edge case you care about should surface as an AC or a named test** —
  the Edge Cases section is advisory prose; an AC is enforced.

### Review configuration is your cost/depth dial

Active personas = floor (always) + profile or explicit list + optional
reviewers. Each active persona reviews **twice** (plan + implementation), so
this is the biggest cost knob after model choice:

- **Default deep, trim consciously.** `full` when the change is broad, risky,
  or you're unsure. Scoped profiles (`frontend`/`logic`/`native`/`data`) when
  the work clearly fits. An explicit `- Personas:` line is the finest control —
  floor + exactly the specialists you name.
- **Opt into an optional reviewer by writing its contract**, not just its name.
  `## Design Contract` / `## Security Contract` / `## API Contract` /
  `## Product Contract` auto-activate the matching reviewer *and* give it
  something concrete to hold the work against. A named optional reviewer with
  an empty contract is cost without depth.
- Contract headings must stay top-level (`## `) — auto-activation matches
  `^## `; nesting silently deactivates the reviewer.
- Specs touching money math, wire contracts, or engine safety invariants keep
  plan AND observer on the strongest available model even when implement stays
  `sonnet` (see the Model ruling table in `CLAUDE.md`).

### Contract sections change engine behavior, not just review

- A `## Design Contract` bumps the implement grind to
  `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` (default `opus`) and — with
  `NIGHT_SHIFT_VISUAL_CAPTURE=1` — enables the `visual_review` stage. Its
  `Frames × Required states × Devices` lines *are* the capture matrix and
  `Tolerance:` is the pass threshold, so list exactly the screens/states you
  want pixel-checked, and state in prose any design detail a flat image can't
  carry (e.g. "the ring is two layered wave nodes").
- `- Workdir: `apps/<app>`` (backticks required) scopes every validation phase
  to a monorepo subdirectory; it's validated at selection (must exist, tracked,
  no symlink escape).

---

## Tier 3 — prose that the planner and reviewers amplify

The plan stage runs on the strongest model you have; its output quality bounds
the whole run. Feed it well:

- **Summary**: one paragraph — what, why, who for. This is the reviewers' anchor
  for "does the diff serve the goal".
- **Technical Approach**: name the files to touch, the libraries to use (already
  in `package.json` — the agent is forbidden to assume otherwise), where state
  lives, and the data flow. **State intent and constraints, not keystrokes** —
  over-specifying line-level detail forbids the planner from finding a better
  design; under-specifying invites architecture the reviewers will then block.
  The sweet spot: "extend `useHydration` rather than adding a second store;
  persistence stays in the existing `storage.ts` layer".
- **Edge Cases**: enumerate the non-happy paths (the template's list is a
  starting floor, not the ceiling). Every one you list, the Human Advocate and
  observer will look for; every one you omit is a coin flip.
- **Out of Scope**: the cheapest section in the spec and the highest-leverage
  guard against scope creep. List the adjacent things the agent might "helpfully"
  do — refactors, renames, extra screens, dependency bumps — and forbid them.
  An autonomous agent with a night of turns *will* find adjacent work unless
  told not to.
- **Open Questions must be empty (all answered) before the run.** Planning
  step 4 is explicit: any ambiguity on an acceptance criterion → `BLOCKED`. An
  open question in a launched spec is a scheduled failure. Use the section
  during drafting; resolve it before flipping Status to *Ready*.
- **Documentation**: point each active persona at the *real* docs it should
  hold the work against (project `CLAUDE.md`, an ADR, a schema file). "none —
  [reason]" is honest and fine; a stale pointer is worse than none.

---

## Right-sizing: one spec = one night = one candidate

The engine runs per-stage turn/time budgets and produces one reviewed candidate
commit per spec. Specs that try to do too much hit budget walls mid-implement;
specs that do too little waste a full persona bench on a one-liner.

- **Good size:** one user-visible behavior change, 3–7 ACs, a diff one observer
  can judge in a single review. Roughly "one focused PR".
- **Too big? Split into a sequenced suite.** (Execution topologies for a suite —
  the one-launch sequential chain, parallel worktree fan-out, and the hybrid —
  live in `docs/PARALLEL-AND-SEQUENCING.md`.) Give each part its own spec with
  its own branch-able validation story, order them in `TODO.md` (the queue is
  ordered; bugs before features), and link them via each spec's `Related:`
  section. Sequencing rules that matter:
  - `NEXT_TASK` chaining only happens on runs started **without** `--spec` and
    only to same-project TODO specs — so a queue in `TODO.md` is the native way
    to run a multi-spec night.
  - Make each spec independently green: spec N must not need spec N+1's code to
    pass its final validation, because each candidate is validated in isolation.
  - A later spec may name an earlier spec's branch as its `Base branch:` when
    stacking is genuinely required — but prefer landing N before starting N+1.
- **Bug specs**: smallest of all — the first failing test *is* the bug
  reproduction, and that's most of the spec's value. One repro test + the fix
  scope + out-of-scope ("do not refactor the module") is a complete bug spec.

---

## Worked example — the sharp parts

The difference between a weak and strong spec is concentrated in ~15 lines.
Weak:

```markdown
- [ ] AC1: Users can filter the history list
- First failing test or executable check: `npm test`
```

Strong:

```markdown
- [ ] AC1: `filterEntries(entries, range)` returns only entries within `range`,
      inclusive of boundary timestamps (`src/lib/filterEntries.test.ts`)
- [ ] AC2: History screen shows a range picker defaulting to "7 days"; changing
      it re-renders the list without refetching (`HistoryScreen.test.tsx`)
- [ ] AC3: An empty filtered result shows the existing `EmptyState` component
      with copy "No entries in this period" (`HistoryScreen.empty.test.tsx`)

- First failing test or executable check:
  `npm test -- --watchAll=false src/lib/filterEntries.test.ts`
```

The strong version tells the loop exactly what to build first, names the red
test the engine will verify, reuses a named existing component (blocking a
gratuitous new one), and makes every claim observable.

---

## Pre-launch checklist

Run down this list before flipping Status to *Ready for implementation*:

1. Copied the **right template for the track** (`rn` / `web` / `fullstack`;
   `node` reuses the web/backend structure per `AGENTS.md`).
2. Repository block real: project path resolves, base branch correct, feature
   branch named — and the project repo is **on that branch** and gitignores
   `.night-shift/`.
3. Every AC is binary, observable, and maps to a named test or check.
4. First failing test named precisely; you know whether it's net-new (absent →
   red) or modify-mode (exists, green at baseline).
5. Baseline/final commands are deterministic, non-interactive, ordered
   fastest-first, and at least as strict as the track checklist. You have
   **run them yourself** — a baseline that's already red for unrelated reasons
   muddies every downstream signal.
6. Permissions are explicit: every `yes` carries details; everything else `no`.
7. Review profile (or `- Personas:`) matches the work; every active persona —
   including auto-activated optional reviewers — has a Documentation owner line.
8. Any contract section you kept is filled, top-level, and the ones you don't
   need are deleted.
9. Out of Scope names the tempting adjacent work.
10. Open Questions is empty. `TODO.md` has the entry pointing at the spec.
11. Optional free dress rehearsal: `NIGHT_SHIFT_ACCEPT_COSTS=YES
    scripts/night-shift.sh --fixture-test --dry-run` — proves the toolchain
    without spending tokens.

---

## Anti-patterns that reliably degrade output

| Anti-pattern | What actually happens |
|---|---|
| Placeholder left anywhere in a Tier-1 field | `validate_spec` blocks — best case; worst case a "creative" placeholder passes the regex and routes the run wrong |
| "Improve/clean up/polish X" as an AC | Unfalsifiable → the implement loop can't converge and the observer can't judge; expect churn until a budget wall |
| `npm test` alone as the first failing test | It's red for the wrong reasons and green before the feature works; the red→green proof becomes noise |
| Watch-mode / interactive validation commands | The unattended run hangs until the stage time budget kills it |
| One spec, three features | Budget wall mid-implement; a half-done candidate the observer must BLOCK |
| Open question left in a launched spec | Guaranteed `BLOCKED` at plan time — the night is spent |
| `Optional reviewers: Security Reviewer` with no `## Security Contract` content | Extra reviewer cost, nothing concrete to review against |
| Over-specified Technical Approach (line-by-line pseudo-code) | The opus planner is reduced to a typist; you paid for judgment and forbade it |
| Vague Permissions (`yes`) | Validator blocks on format — and if it didn't, you've pre-approved anything |
| Skipping Out of Scope | The agent finds adjacent work; morning review inherits an unrequested refactor |

---

## Related

- `specs/_template.md` / `_template-web.md` / `_template-fullstack.md` — the skeletons
- `docs/SPEC-INTAKE-PROMPT.md` — the reusable prompt that produces a spec suite from a feature ticket
- `docs/PARALLEL-AND-SEQUENCING.md` — running a multi-spec suite: chain, fan-out, hybrid
- `NIGHT_SHIFT_HOWTO.md` — what happens on a run, stage by stage
- `AGENTS.md` — validation checklists per track; review floor and profiles
- `AGENT_LOOP.md` — the loop your ACs drive
- `docs/review-personas.md` / `review-personas-web.md` — who reviews what
- `CLAUDE.md` → *Model ruling* — which model each role should carry per spec type
