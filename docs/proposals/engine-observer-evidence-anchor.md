# Spec: Give the observer a wrapper-controlled evidence anchor

> Engine self-improvement issue-spec. Target repo: **this repo**.
> Priority: **HIGH**.

---

## Status

- [x] Draft
- [ ] Ready for implementation
- [ ] In progress
- [ ] Done — branch: `feat/engine-observer-evidence-anchor`

---

## Repository

- Project path: `night-shift-engine/`
- Base branch: `main`
- Feature branch: `feat/engine-observer-evidence-anchor`
- Track: node (bash/CLI; shellcheck + `--fixture-test`)

---

## Problem

The independent observer's **judgment** is genuinely independent — it runs as a
fresh strong-model session from a neutral empty cwd in non-bypass permission mode —
but its **evidence** is partly curated by the primary. The wrapper independently
supplies the spec text and the wrapper-collected persona-review summaries, but the
*supplementary* evidence (e.g. the diff and test output the observer reasons over)
comes from the `.artifacts[]` list the primary chooses to attach. A primary that
omits or shades that supplementary evidence shapes what the "independent" gate sees.

So independence of judgment is real; independence of *evidence* is not.

## Evidence (file:line, approximate ±3)

- `scripts/night-shift.sh:1504` `run_observer` — builds observer context:
  - `~1511-1520`: wrapper-added spec text + wrapper-collected persona summaries
    (independent — good).
  - `~1521`: the additional `.artifacts[]` are **primary-selected**.
- `scripts/night-shift.sh:1407` `invoke_observer_once` — neutral empty cwd, no
  `--permission-mode bypassPermissions`, runs `OBSERVER_MODEL`. The observer has
  **no repo access by design**, so it cannot independently pull the diff/tests; it
  sees only what is handed in.
- `scripts/night-shift.sh:1271` `verify_candidate` already produces a
  wrapper-owned, trustworthy candidate commit + isolated-worktree validation
  output that is *not* currently routed to the observer as a first-class anchor.

## Impact

The strongest backstop in the system can be partially blinded by the actor it is
meant to check. Combined with the persona self-report hole
(`specs/engine-persona-provenance.md`), more of the gating depends on primary good
behavior than the architecture intends.

---

## Proposed approach

Give the observer at least one evidence anchor the primary cannot have curated:

1. The wrapper computes `git -C "$PROJECT" diff <base_commit>..<candidate_commit>`
   itself and writes it to a wrapper-owned file included in the observer context
   unconditionally (truncated/elided only by the wrapper, with the elision noted).
2. The wrapper attaches the **wrapper-run** final validation output it already has
   (`$RUN_ROOT/validated/*.json` from `verify_candidate`) — the actual test/tsc/lint
   results by exit status — rather than relying on the primary to summarize them.
3. The observer prompt (`observer_prompt`, ~1374) is updated to state these two
   inputs are authoritative and primary-supplied artifacts are supplementary.

This keeps the observer's no-repo-access isolation while ensuring the diff and the
test verdict it judges are ground truth.

## Acceptance criteria

- [ ] AC1: Every observer invocation receives a wrapper-computed `base..candidate`
  diff and the wrapper-run validation results, regardless of the primary's
  `.artifacts[]`.
- [ ] AC2: A primary that attaches a misleading/empty artifact set still presents
  the observer with the true diff + true validation verdict.
- [ ] AC3: Observer isolation is preserved (neutral cwd, non-bypass, fresh
  session); the change does not give the observer repo write access.
- [ ] AC4: Existing fail-closed normalization (`normalize_observer_output` defaults
  to BLOCK) is unchanged.

## Validation

- `shellcheck` clean.
- `--fixture-test --dry-run` passes; add a fixture where the primary supplies a
  thin artifact set and assert the observer context still contains the
  wrapper-computed diff + validation JSON.

## Out of scope

- Granting the observer live repo access (deliberately avoided).
- Persona provenance (separate spec).

## Related

- Audit recommendation #2 (HIGH).
- `specs/engine-persona-provenance.md`.
