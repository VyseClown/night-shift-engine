# Launch Readiness & Preflight — design

**Date:** 2026-06-21
**Status:** approved (design), pending implementation plan
**Repos touched:** engine (`~/work`, `VyseClown/night-shift-engine`) and viewer (`night-shift-viewer/`, `VyseClown/night-shift-viewer`)

## Context

This is **sub-project A** of a broader "launch + operations UX" theme for the viewer.
The full theme decomposes into:

- **A. Launch readiness & preflight** (this doc) — get a project/spec into a
  launchable state and validate before spending money.
- **B. Self-targeting & multi-spec concurrency** — viewer targets itself; worktree-
  per-spec concurrency (lifts "one run per project").
- **C. Run lifecycle & queueing** — resume/retry/return-to-implement; spec queue.
- **D. Observability** — per-run cost from `costs.jsonl`, structured spec/run views.

A is the foundation: B and C both assume a run can be started cleanly. A is built
first.

## Problem

Launching a real run from the viewer has manual, easy-to-miss prerequisites. The
engine's `check_branch_and_worktree` (`scripts/night-shift.sh:2197`) is a *guard*:
it requires the target project to already be **on the spec's feature branch** (not
the base), with no conflicting worktree, and `block_run`s otherwise. `validate_spec`
likewise blocks an incomplete spec — but only ~30 seconds into a paid run. Today the
user must hand-create the branch and has no way to see "is this launchable?" before
paying.

## Decisions (from brainstorming)

1. **UX shape:** a readiness checklist in the Launch panel plus an explicit
   **Prepare** button. Branch mutation is one click but visible — not folded
   silently into Launch.
2. **Ownership (hybrid):** the engine owns a read-only `--preflight` check (reuses
   `validate_spec` + branch-guard logic, single source of truth, CLI users benefit);
   the viewer owns the one git mutation via `simple-git` (already a dependency). This
   preserves the engine's deliberate "never create/switch branches on the run path"
   safety posture.
3. **Gating:** the mutating prepare reuses **`NSV_ALLOW_LAUNCH`** (+ `csrfGuard`).
   Branch prep is part of the launch capability, and a real run mutates the project
   far more than creating a branch does. Preflight itself is read-only and ungated.
4. **Dirty-tree refusal:** prepare refuses when the working tree is dirty, so it
   never disturbs uncommitted work.
5. **Scope:** existing scanned projects only; viewer self-targeting is sub-project B.

## Design

### 1. Engine — `--preflight` (read-only, JSON)

`night-shift.sh --preflight --project PATH --spec PATH` always exits 0 and prints a
report, reusing `validate_spec` (capture its stderr as `errors`) and the
`check_branch_and_worktree` field logic (reported, not used as a guard):

```json
{
  "spec":   { "valid": false, "errors": ["missing: First failing test or executable check:"] },
  "branch": { "base": "main", "feature": "feat/x", "current": "main",
              "onFeature": false, "onBase": true, "worktreeConflict": false },
  "tree":   { "clean": false, "dirtyCount": 3 },
  "gitignore": { "nightShiftIgnored": true },
  "ready": false,
  "blockers": ["not on feature branch feat/x", "spec invalid", "working tree dirty"]
}
```

`ready` is true only when the spec is valid, the project is on the feature branch
(not base), the tree is clean, `.night-shift/` is gitignored, and there is no
worktree conflict. The command is read-only (no run-lock, no state writes).

### 2. Viewer server

- **`GET /api/preflight?project=&spec=`** — execs `night-shift.sh --preflight`,
  returns the JSON. Read-only, ungated (like `/api/optional-personas`). Validates
  `project ∈ PROJECTS` and a safe spec path; on exec/parse failure returns
  `{ unavailable: true }` so the UI degrades.
- **`POST /api/prepare`** `{ project, spec }` — the single mutation, gated by
  `NSV_ALLOW_LAUNCH` + `csrfGuard`. Reads `base`/`feature` from the spec, **refuses
  with 409 if the tree is dirty**, then via `simple-git`: if `feature` exists, check
  it out; else create it from `base`. A worktree conflict returns 409. Responds with
  the post-state (or a fresh preflight) so the UI updates. Confined to the validated
  project; never runs arbitrary git.

### 3. Viewer web — Launch panel

When mode = real and a project + spec are selected, fetch preflight and render a
**readiness checklist** (✓/✗ per item: on feature branch, clean tree, `.night-shift`
ignored, spec valid) with the `blockers` list. A **Prepare** button appears when the
branch is the fixable blocker → `POST /api/prepare` → re-fetch preflight. **Launch**
is enabled only when `ready` is true. A small pure `readiness.js` mapper turns the
preflight JSON into checklist rows (unit-testable, no React). When `--preflight` is
unavailable (older engine → `unavailable: true`), the panel shows "preflight
unavailable" and Launch behaves exactly as today.

### 4. Gating & safety

Prepare reuses `NSV_ALLOW_LAUNCH` + `csrfGuard`. Dirty-tree refusal protects
uncommitted changes. Preflight is read-only/ungated. The viewer never runs arbitrary
git — only create/checkout of the spec's declared `feature` from its declared `base`,
in a validated project.

### 5. Edge cases

- Dirty tree → Prepare 409; checklist says "commit or stash first."
- Feature branch exists but not checked out → checkout it.
- Feature branch checked out in another worktree → 409 (mirror the guard).
- `base == feature` → preflight flags it (the engine already rejects this).
- Spec invalid → Prepare can't help; blockers say to fix the spec.
- Old engine without `--preflight` → `unavailable`, Launch unchanged.

### 6. Error handling & degradation

Preflight exec/parse failure → `{ unavailable: true }`, panel hidden behind a note,
Launch as today. Prepare failures map to clear HTTP codes (403 disabled / 403
cross-origin / 409 dirty-or-conflict / 500 git error) without leaking paths.

## Testing

- **Engine:** a deterministic fixture for `--preflight` — a valid spec on its feature
  branch reports `ready: true`; on-base and/or invalid-spec reports `ready: false`
  with the matching blockers.
- **Server:** `app.request` tests for `/api/preflight` (shape) and `/api/prepare`
  gating (403 disabled, 403 cross-origin, 409 dirty/conflict) against a temp git repo.
- **Web:** `node --test` unit tests for the pure `readiness.js` mapper (preflight JSON
  → checklist rows + Prepare-applicability).

## Out of scope (this sub-project)

- Viewer self-targeting and worktree-per-spec concurrency (sub-project B).
- Resume/retry/queueing (sub-project C); cost/observability (D).
- Auto-prepare-and-launch in one click (rejected: branch mutation stays explicit).
- Committing/stashing on the user's behalf (Prepare refuses a dirty tree instead).
