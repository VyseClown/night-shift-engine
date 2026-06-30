# Spec: Reduce hand-synced duplication and add a config inventory

> Engine self-improvement issue-spec. Target repo: **this repo**.
> Priority: **MEDIUM** (maintainability). Low runtime risk; pays down a real
> maintenance tax.

---

## Status

- [x] Draft
- [ ] Ready for implementation
- [ ] In progress
- [ ] Done — branch: `feat/engine-reduce-hand-sync`

---

## Repository

- Project path: `night-shift-engine/`
- Base branch: `main`
- Feature branch: `feat/engine-reduce-hand-sync`
- Track: node (bash; shellcheck + `--fixture-test`)
- Files: `scripts/night-shift.sh`, `schemas/*.json`, docs

---

## Problem

Several places must be kept in sync by hand; drift between them is silent and only
surfaces as a runtime bug.

1. **Transition table duplicated.** `transition_allowed` (`~1017`) and
   `expected_action` (`~1029`) encode the same stage→action mapping in two `case`
   blocks, kept aligned by a "keep in sync" comment (`~1024/1028`). A change to one
   that misses the other lets the prompt advertise an action the gate then rejects
   (or vice versa).
2. **Redundant gating.** `handle_signal` re-checks `.stage == completion` for
   `NEXT_TASK` (`~1750`) and `COMPLETE` (`~1765`) even though `transition_allowed`
   already restricts those actions to the `completion` stage.
3. **Schemas not executed.** The runtime validator `json_schema_basic` (`~209`) is
   a hand-written jq reimplementation of `schemas/*.json`; the JSON Schema files are
   referenced only in comments and never run, so the two can diverge.
4. **Config sprawl.** ~40 `NIGHT_SHIFT_*` knobs have defaults scattered across six
   files with no single discoverable inventory or `--list-config`/`--help` dump.

## Impact

Each is a latent correctness/maintainability hazard: the duplicated table is the
load-bearing safety invariant of the whole loop, and silent schema drift weakens
signal validation. The config sprawl makes the engine hard to operate and audit.

---

## Proposed approach

1. **Single source for transitions:** derive `expected_action` **from**
   `transition_allowed` (e.g. one associative mapping `stage→action` that both the
   gate and the prompt read), or generate both from one table. Remove the
   keep-in-sync comment once they can't diverge.
2. **Drop redundant checks:** remove `handle_signal`'s `stage == completion`
   re-checks for `NEXT_TASK`/`COMPLETE`, relying on the `transition_allowed` gate
   already run at `~1742`.
3. **Schema drift:** either (a) run `schemas/*.json` through a JSON-Schema
   validator at runtime (if a portable one is acceptable as a dependency), or
   (b) generate the inline jq validator from the schema files at build/test time so
   they cannot drift, or at minimum (c) add a test that asserts the jq validator and
   the schema agree on a corpus of valid/invalid samples.
4. **Config inventory:** add a `--list-config` (and richer `--help`) that prints
   every `NIGHT_SHIFT_*` knob, its default, and a one-line meaning, generated from a
   single declared table that the code reads its defaults from.

## Acceptance criteria

- [ ] AC1: A change to the legal stage→action mapping requires editing exactly one
  place; the prompt and the gate cannot disagree.
- [ ] AC2: Removing the redundant `handle_signal` completion checks changes no
  observable behavior (covered by fixtures for `NEXT_TASK`/`COMPLETE` from non-
  completion stages still blocking).
- [ ] AC3: There is an automated check that the runtime signal validator and
  `schemas/*.json` agree (or the schemas are the runtime source).
- [ ] AC4: `scripts/night-shift.sh --list-config` lists all `NIGHT_SHIFT_*` knobs
  with defaults, and the listed defaults match the values the code actually uses.

## Validation

- `shellcheck` clean.
- `--fixture-test --dry-run` passes; add fixtures for the transition-table
  single-source behavior and the schema-agreement check.

## Out of scope

- Functional changes to the state machine itself.
- Gate-integrity work (persona/observer specs).

## Related

- Audit recommendation #5 (MEDIUM).
