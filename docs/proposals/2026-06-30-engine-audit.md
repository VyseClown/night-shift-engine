# Night-shift engine audit — findings & proposals (2026-06-30)

An architecture / error-recovery / capability audit of `scripts/night-shift.sh`
and its libs, benchmarked against 2024–2026 agentic-loop engineering literature
(Anthropic *Building Effective Agents* / *Effective Context Engineering* /
*multi-agent research system*; HumanLayer *12-Factor Agents*; Cognition *Don't
Build Multi-Agents*; Reflexion / TDD-agent work). Findings were produced by a
multi-agent pass and independently re-verified against source.

## Overall rating: 8/10

| Dimension | Score |
|---|---|
| Loop control & termination | 9/10 |
| Error recovery & durability | 9/10 |
| State management | 9/10 |
| Cost control | 9/10 |
| Context engineering | 8/10 |
| Concurrency safety | 8/10 |
| Code quality & maintainability | 8/10 |
| Quality gates (review/observer/TDD) | 7/10 |
| Observability | 7/10 |

**Why 8:** a genuinely well-engineered loop whose central insight — the engine
owns every stage transition, so the model can *request* but never *drive* forward
motion (`transition_allowed` is one pure table; every `set_stage` is wrapper code)
— is exactly right. Error recovery, cost control, and state management are
standout, verified line-by-line. It loses points mainly for one structural
integrity gap (persona review is self-reported), primary-curated observer evidence,
a handful of low-probability durability edges, and a real visual-repair bug.

## Proposals (this directory)

| Priority | Proposal | File |
|---|---|---|
| HIGHEST | Enforce persona-review provenance (close the self-report hole) | `engine-persona-provenance.md` |
| HIGH | Give the observer a wrapper-controlled evidence anchor | `engine-observer-evidence-anchor.md` |
| HIGH | Fix visual-repair hyphen hazard, global-cap over-count, default drift | `engine-visual-repair-fixes.md` |
| MEDIUM | Harden durability/concurrency edges | `engine-durability-hardening.md` |
| MEDIUM | Reduce hand-synced duplication + add a config inventory | `engine-reduce-hand-sync.md` |

Lower-priority items not yet written up as proposals: per-stage in-session
compaction for long implement stages; an aspect-ratio sanity check before the
`odiff` resize (`visual-capture.sh:~255`); a structured event/trace stream
alongside the per-turn files.

## Loop-engineering alignment (summary)

Embodies most of the modern canon: a literal read–act–observe loop with
engine-owned control flow; durable externalized `state.json` + file-mediated stage
handoff ("durable queryable records"); stage-scoped fresh sessions to avoid context
rot; role-tiered models; an independent strong-model critic (observer) and a
test-gated `verify_candidate` (red→green in an isolated worktree); single-threaded
writer with read-only fan-out only for persona breadth.

Diverges / shows its age: no in-loop compaction or just-in-time retrieval within a
stage (context curation is coarse, whole-file per scope); no Reflexion-style
persisted verbal self-critique conditioning retries; the persona gate violates the
"independent verifier the actor can't influence" principle it otherwise exemplifies
via the observer; no first-class human-in-the-loop checkpoint (every ambiguity
becomes block-for-manual-resume).
