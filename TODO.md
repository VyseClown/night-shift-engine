# TODO

Night-shift selection uses unfinished entries in file order, with all `bug`
entries selected before `feature` entries. Every entry must link to a complete
spec.

<!-- Format (examples indented so the `^- [ ]` task selector ignores them):
     - [ ] bug: Short description (`specs/example.md`)
     - [ ] feature: Short description (`specs/example.md`)
-->

- [x] feature: Toggle todo done state offline (`specs/toggle-todo.md`)
- [x] feature: Greeting helper demo (`specs/greeting-demo.md`)
- [x] feature: Visual Validation panel (`specs/visual-validation.md`)
- [x] feature: In-viewer spec editor (`specs/spec-editor.md`)
- [x] feature: Sum helper demo (`specs/sum-demo.md`)
- [x] feature: Web app logic audit (`specs/web-audit.md`)
- [x] bug: Web app P1 correctness fixes (`specs/web-p1-fixes.md`)
- [ ] feature: Web app call-site resilience (HUMAN-001 follow-up) (`specs/web-resilience.md`)

## Engine self-improvement backlog

> Issue-specs for the engine itself (target repo: `night-shift-engine`), from the
> 2026-06-30 architecture/loop-engineering audit. They live under `docs/proposals/`
> (tracked/publishable) rather than `specs/` (which is gitignored, local-only,
> per-project detail). The `engine:` prefix is ignored by night-shift task
> selection (which matches only `bug:`/`feature:`), so these are tracked here
> without being auto-selected against sibling app projects. Index:
> `docs/proposals/2026-06-30-engine-audit.md`.

- [ ] engine (HIGHEST): Enforce persona-review provenance — close the self-report hole (`docs/proposals/engine-persona-provenance.md`)
- [ ] engine (HIGH): Give the observer a wrapper-controlled evidence anchor (`docs/proposals/engine-observer-evidence-anchor.md`)
- [ ] engine (HIGH): Fix visual-repair hyphen hazard, global-cap over-count, default drift (`docs/proposals/engine-visual-repair-fixes.md`)
- [ ] engine (MEDIUM): Harden durability/concurrency edges (`docs/proposals/engine-durability-hardening.md`)
- [ ] engine (MEDIUM): Reduce hand-synced duplication + add config inventory (`docs/proposals/engine-reduce-hand-sync.md`)
