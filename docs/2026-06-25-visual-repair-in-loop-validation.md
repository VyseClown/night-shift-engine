# In-loop visual-repair — validation record

Date: 2026-06-25. Branch `feat/visual-repair-in-loop` (PR #28). This records the
real, end-to-end smoke of the engine-invoked in-loop repair wiring.

## What was validated

The **exact** `run_visual_inloop_repair` function from `scripts/night-shift.sh`
(copied verbatim into a targeted driver) was driven against a **real** perturbed
candidate, with **real** git, a **real** `claude -p` repair agent, and a **real**
iOS-simulator + Metro harness — to prove the new engine wiring: first capture →
over-tolerance → repair → **commit `fix(visual): auto-repair …`** → append
`candidate_commits` + repoint `.candidate` → **refresh the report** for the observer.

Setup (closeable-gap, so a real agent actually edits and the wiring fires):
- reference = a capture of the **correct** Home (self-reference);
- candidate = the same screen perturbed (`WaterRing.tsx` `RING_SIZE 220→120`),
  committed on a throwaway branch `smoke-inloop` (off `feat/water-tracker`);
- `repair_agent` **overridden** to a reference-matching `claude -p` agent. The loop
  injects `repair_agent` by name, so this is a legitimate swap for testing the
  **wiring** — the production Figma-matching agent's invocation is already proven by
  PR #27, and water-tracker structurally diverges from its generic Figma frame so the
  production agent cannot converge on it. Convergence of the loop itself is already
  proven by the standalone convergence smoke.

## Result (all green)

| Check | Result |
|---|---|
| First capture of the perturbed candidate | Home `diff_pct=0.1359` (> 0.12 tolerance), `pass=false` |
| `run_visual_inloop_repair` ran the repair | agent restored the ring; `rc=0` |
| `fix(visual): auto-repair Home` commit landed on top of the candidate | ✅ `ccdb77b` |
| `.candidate` repointed to the repaired tip | ✅ (`ccdb77b`, ≠ the candidate SHA) |
| `candidate_commits` appended (insertion-order dedupe) | ✅ length 2 |
| Report refreshed at the repaired tip | ✅ Home `diff_pct 0.1359 → 0.0004` (converged) |
| Working tree clean (repair committed, not left dirty) | ✅ |
| Never-on-`main` guard | ✅ ran on `smoke-inloop`, refused-on-main path covered separately |

Note: the driver's `fix(visual) commit landed?` line printed a false `NO` — a
`git log --oneline | grep -q … ` + `set -o pipefail` SIGPIPE artifact in the *verify
script*, not a real failure. The commit is present in `git log` (`ccdb77b`), and
every downstream check (`.candidate`, `candidate_commits`, refreshed report)
confirms the commit landed.

## Conclusion

The engine-invoked in-loop repair path works end-to-end: it captures, repairs the
over-tolerance screen, commits the fix as a new candidate commit, updates the run
state, and refreshes the report so the observer reviews the repaired tip — exactly
as designed (§4.2/§4.4 of the design). water-tracker was restored to
`feat/water-tracker` (clean) afterward; the smoke is non-destructive.
