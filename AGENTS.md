# AGENTS.md — Workspace Router

> Read this first. Every time. It takes 2 minutes and prevents 2 hours of wrong decisions.

This file is the entry point for any AI agent (Claude Code, Codex, or subagent) working in this workspace. It tells you where things live, what tools to use, and what the rules are.

---

## What This Workspace Is

A multi-project development environment spanning two **tracks**: **React Native**
(mobile, iOS/Android — Expo or bare) and **web** (Next.js / React). The shared
stack is TypeScript; the developer works in Ghostty on macOS (Apple Silicon).
Each spec declares its track (`- Track: rn | web`, default `rn`), which selects
the review persona set and the validation checklist below. See the per-project
`CLAUDE.md` for a project's exact stack and commands.

---

## Directory Layout

```
~/work/
  AGENTS.md          ← you are here
  AGENT_LOOP.md      ← instructions for autonomous overnight runs
  NIGHT_SHIFT_HOWTO.md ← human guide: what to write first + how a run works
  TODO.md            ← ordered work queue; bugs are selected before features
  CHANGELOG.md       ← completed user-visible and workflow changes
  NIGHT_SHIFT_REVIEW.md ← validated observer review ledger
  scripts/night-shift.sh ← fixed-primary overnight orchestrator
  schemas/           ← machine-readable coordination/review contracts
  specs/             ← one markdown file per feature, before implementation starts
    _template.md     ← copy this for a React Native (rn-track) spec
    _template-web.md ← copy this for a web-track spec
  docs/
    review-personas.md     ← rn-track review personas and their checklists
    review-personas-web.md ← web-track review personas and their checklists
    dev-environment.md     ← shell, Node, Ghostty, Starship, zsh plugins
    codex-cli-setup.md     ← Codex CLI config, aliases, status line
    terminal-setup.md      ← zsh config, RN aliases, rninfo function
  [project-name]/    ← actual project directories (added as needed)
```

---

## Tools Available

| Tool | Command | Use for |
|---|---|---|
| Claude Code | `claude` | Implementation, refactoring, architecture decisions |
| Codex CLI | `c` (alias) | Parallel implementation, cross-review of Claude's output |
| Resume Codex | `cr` | Resume the last Codex session |
| Fork Codex | `cf` | Branch a Codex session for a variant |
| RN diagnostics | `rninfo` | Check Node, Xcode, ADB, Watchman status |
| Pods | `pods` | Install CocoaPods (runs from project root) |

---

## Before You Write Any Code

1. **Find the spec.** A selected spec is the implementation contract. It must
   contain repository path, base and feature branches, a review profile,
   validation commands, dependency/native permissions, documentation references,
   persona documentation ownership, and a test plan. Missing fields block the
   task.
2. **Route to the repository.** The workspace root is not assumed to be a Git
   repository. Resolve the spec's project path and run all Git and validation
   commands there.
3. **Check branch and worktrees.** Use `git status`, `git branch`, and
   `git worktree list`. Never work directly on the base branch.
4. **Preserve existing work.** Record the initial status. Do not clean, stash,
   reset, overwrite, or include pre-existing changes in a candidate commit.
5. **Read referenced docs.** Read workspace and project documentation named by
   the spec before planning.
6. **Run baseline validation.** Run the spec's validation commands before edits
   so pre-existing failures are distinguishable from regressions.
7. **Run `rninfo` when available.** If it is unavailable, record that fact. It
   is required before approved native work.

## Workspace Artifacts

- **Specs** define scope, permissions, acceptance criteria, validation, tests,
  repository routing, and documentation ownership. Selected incomplete specs
  are blockers, not prompts to guess.
- **`TODO.md`** is the task queue. Unfinished bug entries precede features.
  Every entry points to a spec.
- **`CHANGELOG.md`** records completed changes after validation and review.
- **`NIGHT_SHIFT_REVIEW.md`** contains only validated observer results and links
  finding IDs across amended candidate commits.
- **`.night-shift/`** is ignored transient state. Successful runs retain only a
  compact archive; blocked and failed runs retain full state for recovery.

---

## Running the night shift (cost & usage)

Launch unattended from a terminal (not a Claude session):

```sh
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test            # one-time pre-flight
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project PATH --spec specs/<name>.md
```

- **`NIGHT_SHIFT_ACCEPT_COSTS=YES`** is just a safety gate so live model calls
  are never made by accident. It is not a billing switch.
- **Candidate validation deps.** The isolated validation worktree symlinks the
  project's ignored dependency dirs so tests run without reinstalling. The default
  covers both the rn layout (`node_modules`, `ios/Pods`) and the web layout where
  deps live in sub-packages (`server/node_modules`, `web/node_modules`), so the
  viewer works out of the box. For a non-standard layout, set
  `NIGHT_SHIFT_DEPENDENCY_LINKS="<space-separated rel paths>"`.
- **Subscription vs API key.** If the `claude` CLI is logged in with a Claude
  Pro/Max account (no `ANTHROPIC_API_KEY` set), runs consume your plan's **usage
  limits**, not extra dollars. If an API key is set, calls are **billed
  per-token**. Check with `echo "$ANTHROPIC_API_KEY"` (empty = subscription).
- **Heavy workload.** One task = primary + the active personas × two stages +
  observer, across many turns. `full` is six personas per stage; the scoped
  profiles (`frontend`/`logic`/`native`/`data`) run four to five to cut cost, and
  an explicit `- Personas:` list trims to just the floor plus the specialists you
  name. Note optional reviewers *add* cost (each opt-in is another reviewer ×
  stages). On **Pro** a `full` task can still exhaust the 5-hour usage limit
  mid-run.
- **Limit behavior is safe.** If Claude returns a structured session-limit 429,
  the wrapper waits until the reported reset time plus a safety buffer, pauses
  its elapsed-time budgets, and resumes the same explicit primary session.
  Other API failures still stop via `block_run`. Nothing is pushed or merged.

---

## Validation Checklist (run in this order)

Use the checklist for the spec's **Track**. The actual commands a night-shift run
executes come from the spec's own `Baseline`/`Final validation commands`; these
are the defaults a project's `CLAUDE.md` may refine. Every run must pass all
steps before committing.

**React Native track (`Track: rn`):**

```bash
npx tsc --noEmit                       # 1. Type errors
npx eslint . --max-warnings 0          # 2. Lint warnings
npm test -- --watchAll=false           # 3. Test suite (all passing)
npx react-native-community-cli doctor  # 4. RN environment (if native changes)
```

**Web track (`Track: web`):**

```bash
npx tsc --noEmit               # 1. Type errors
npm run lint                   # 2. Lint warnings
npm test                       # 3. Test suite (all passing)
npm run build                  # 4. Build (catches RSC/route/type errors)
npm run test:e2e               # 5. E2E (when the change has user-facing flow impact)
```

If any step fails: fix it, re-run from step 1. Do not commit with failures.

---

## Commit Rules

- One logical change per commit.
- Message format: `type(scope): short description` — types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Never commit: `.env`, secrets, `node_modules/`, `ios/Pods/`, build artifacts.
- Never force-push to `main`.

---

## Review

The spec's **Track** selects the persona set — `docs/review-personas.md` for
`rn`, `docs/review-personas-web.md` for `web` — and its **Review Profile** selects
which of those personas review the plan and implementation (see the chosen file
for the profile→persona table). The mandatory floor runs in every profile and
differs by track: for `rn` it is React Native Architect, TypeScript & Code
Quality Expert, and Human Advocate; for `web` it is Web Architect, TypeScript &
Code Quality Expert, and Human Advocate. `full` runs all six in the track. Each
active persona owns its corresponding documentation assessment. Every finding is
a blocker; progress requires an approval from each active persona. A fresh,
independent Claude observer session then reviews the candidate commit in every
profile. Only validated structured review artifacts count.

**Optional reviewers** (cross-track, off by default): Product Reviewer, Design
Fidelity Reviewer, Security Reviewer, API Contract Reviewer. A spec opts in via an
`- Optional reviewers:` line or by including the matching `## … Contract` section
(`Product` / `Design` / `Security` / `API`); each active optional reviewer must
own a Documentation line. **Per-spec override:** a `- Personas:` line names the
exact specialists to run, replacing the profile preset (the floor is always kept,
and an off-track name is rejected) — the finest control over token burn. See
`docs/review-personas.md` → *Optional Personas* and *Per-spec persona override*.

---

## What NOT To Do

- Do not install new packages without noting them in the spec or asking first.
- Do not modify `ios/` or `android/` native files unless the spec explicitly calls for it.
- Do not add `// TODO` comments — if something is unfinished, stop and report it.
- Do not skip tests for new logic. Every exported function gets a test.
- Do not assume a library is available — check `package.json` first.
- Do not switch the primary model during a night-shift run.
- Do not use implicit session selectors such as `--continue` or `--last`.
- Do not push, merge, force-push, clean, reset, or perform destructive Git
  operations during an autonomous run.

---

## If You Are Stuck

Stop. Do not hallucinate a solution. Write a short block to the human:

```
BLOCKED: [what you were trying to do]
REASON:  [what you tried and why it did not work]
NEED:    [what information or decision would unblock you]
```

---

## Related Files

- `NIGHT_SHIFT_HOWTO.md` — human guide: what to write first and how a run works
- `AGENT_LOOP.md` — step-by-step process for overnight autonomous runs
- `specs/_template.md` / `specs/_template-web.md` — how to write a feature spec (rn / web)
- `docs/review-personas.md` / `docs/review-personas-web.md` — how to run a review pass (rn / web)
