# Spec: Enforce persona-review provenance (close the self-report hole)

> Engine self-improvement issue-spec. Target repo: **this repo**
> (`VyseClown/night-shift-engine`), not a sibling app project.
> Priority: **HIGHEST** — this is the single largest integrity gap in the gating layer.

---

## Status

- [x] Draft
- [ ] Ready for implementation
- [ ] In progress
- [ ] Done — branch: `feat/engine-persona-provenance`

---

## Repository

- Project path: `night-shift-engine/` (the engine itself)
- Base branch: `main`
- Feature branch: `feat/engine-persona-provenance`
- Track: node (bash/CLI; validated by shellcheck + `--fixture-test`)

---

## Problem

The persona-review gate is **self-reported by the primary**. The engine validates
only the result *files the primary lists in its signal* — their shape, set, count,
and status — never that real independent persona sub-agents actually ran on
`NIGHT_SHIFT_PERSONA_MODEL`.

A cost-cutting or misbehaving primary (running on the cheaper `sonnet` implement
model) could author all N persona-review JSONs itself, stamp each `APPROVE`, list
them as artifacts, and pass every persona gate without a single real reviewer
running. The independent observer is then the **only** truly wrapper-enforced LLM
gate in the pipeline.

## Evidence (file:line, approximate ±3)

- `scripts/night-shift.sh:1152` `run_personas` — collects results via
  `collect_persona_results` from `jq -r '.artifacts[]' "$signal"` (the
  **primary-listed** artifact paths).
- `scripts/night-shift.sh:1135` `collect_persona_results` — reads + normalizes
  those files; no provenance/authenticity check.
- `scripts/night-shift.sh:~1180-1188` — the gate asserts count, exact persona
  set, stage, and status **shape** only.
- `schemas/persona-review.json` — defines the result shape but is never executed
  at runtime and carries no provenance field.

## Impact

The persona layer's independence is **nominal**: it depends on the primary's good
behavior, exactly the assumption the actor/critic separation principle exists to
remove. Defeats the purpose of model-tiering personas as a cheap-but-trusted gate.

---

## Proposed approach

**Primary fix (A — wrapper-spawned personas):** Have the *engine* run the persona
sub-agents itself, not the primary. The wrapper issues its own
`claude -p --model "$NIGHT_SHIFT_PERSONA_MODEL"` calls from a controlled context
(persona system prompt + the wrapper-computed `base..candidate` diff + the spec),
writes the result files under a wrapper-owned path the primary cannot pre-stage,
and feeds those into `collect_persona_results`. The primary's role shrinks to
emitting `RUN_PERSONAS`; it no longer supplies the review content. This mirrors how
the observer is already invoked (`invoke_observer_once`) and makes the gate
genuinely enforced.

**Interim fix (B — provenance nonce):** If (A) is too large for one change, at
minimum:
1. On entering a review round, the wrapper generates a per-round random nonce and
   writes it to a wrapper-owned file the primary is told to copy verbatim into a
   `provenance` field of each persona result (and ideally have each persona echo it
   back from its own fresh session).
2. `collect_persona_results` / the gate rejects any result whose `provenance` does
   not match the current round's nonce.
   This does not fully prove an independent sub-agent ran, but it forecloses
   blind fabrication and replay of stale rounds.

Recommend implementing (A). Keep (B)'s nonce even after (A) as a tamper check.

## Acceptance criteria

- [ ] AC1: A run where the primary fabricates persona-review JSONs with `APPROVE`
  is **blocked** (or its fabricated content is ignored in favor of wrapper-run
  reviews).
- [ ] AC2: Persona sub-agents demonstrably run on `NIGHT_SHIFT_PERSONA_MODEL` from
  a context the primary does not control (fix A), or each result carries a
  current-round nonce the primary cannot forge (fix B).
- [ ] AC3: The track→persona-set selection (rn/web/node) and review profiles are
  unchanged in behavior.
- [ ] AC4: `schemas/persona-review.json` gains a `provenance` field and the inline
  jq validator enforces it.

## Validation

- `shellcheck` clean (repo `.shellcheckrc` gate).
- `scripts/night-shift.sh --fixture-test --dry-run` passes; add a fixture that
  feeds fabricated persona results and asserts the gate blocks / overrides them.
- A live fixture (where permitted) confirming wrapper-spawned personas run.

## Out of scope

- Changing which personas exist or the review-profile taxonomy.
- The observer evidence-anchor work (tracked in
  `specs/engine-observer-evidence-anchor.md`).

## Related

- Audit recommendation #1 (HIGHEST).
- `specs/engine-observer-evidence-anchor.md` (companion gate-hardening).
