# QA Runbook — verifying a run, and the engine's own pre-release QA

> Summary: Two checklists. Part 1: how a human verifies a night-shift branch
> before merge (beyond the observer's APPROVE) and a reusable device-test
> template for issues static gates can't catch. Part 2: the exact commands to run
> before merging a change to the ENGINE itself, mapped to its four self-test
> layers. See `AGENTS.md` for process rules and `docs/SPEC-AUTHORING.md` for
> authoring.

An observer APPROVE means the candidate cleared an independent strong-model gate.
It does **not** mean the change is mergeable — the observer can't touch a physical
device, can't judge whether the diff matches what you actually wanted, and can't
know your product intent beyond the spec. This runbook is the human half of the
loop.

---

## Part 1 — Verifying a night-shift branch before merge

### Human pre-merge checklist

Run this against the feature branch the engine left behind, before you merge it:

- [ ] **Read `<project>/.night-shift/feedback.md`.** The run's own account of
      where the spec was ambiguous or where a stage looped — the fastest signal
      that the output may not match your intent even though it passed.
- [ ] **Diff scope matches the spec.** `git diff <base>...<branch> --stat`, then
      read the diff. Every changed file should trace to an Acceptance Criterion or
      the Technical Approach. Files touched that the spec never mentioned — new
      dependencies, native/`ios/` edits, migrations — are a red flag; cross-check
      the spec's **Permissions** section (a bare `yes` was never approval).
- [ ] **The observer actually APPROVED this commit.** Check
      `NIGHT_SHIFT_REVIEW.md` for the run's validated observer verdict and that its
      finding IDs are resolved. Only validated structured artifacts count — don't
      take a log line's word for it.
- [ ] **Confirm the smoke phase ran** (if the spec declared `- Smoke:`). Grep the
      journal: `jq 'select(.event=="smoke")' <project>/.night-shift/events.jsonl`
      (or the archived copy). A missing `smoke` event means the app was never
      booted — treat green tsc/lint/test as *not* proof it starts.
- [ ] **Spot-check the candidate commit.** `git show <candidate>` — one logical
      change, conventional-commit message, no `// TODO` left behind, no secrets /
      `.env` / `node_modules` / build artifacts committed.
- [ ] **Re-run the spec's final validation yourself** in the project (the engine
      ran it in an isolated worktree; a fresh run in your checkout catches
      environment drift). For `web`/`fullstack`, include `npm run build`.
- [ ] **Do the manual/device checks below** — the class of issue no static gate
      can catch.

### Manual / device-test checklist template

The observer repeatedly flags issues that are invisible to `tsc` / `eslint` /
`jest` because they only exist on a real device or in a real browser — on-device
icon/symbol rendering, real auth-state transitions, visual layout under a real
status bar, keyboard avoidance, gesture handling. Static gates *structurally*
can't see these. Drop a tailored version of this into the spec's `Manual test
checklist` (the templates already seed it) and actually walk it before merge:

**React Native (rn):**

```
- [ ] Runs on iOS simulator AND a physical device (icons/SF Symbols render;
      no red-box; safe-area/notch layout correct)
- [ ] Runs on Android emulator (Material ripple, back-button, status bar)
- [ ] Auth-state transitions by hand: logged-out → login → logged-in → logout
      (no stale screen, no flash of the wrong state)
- [ ] Network throttled to slow 3G: loading, empty, error, and offline states
      each render as specified
- [ ] Backgrounded mid-action, then resumed (interrupted-flow edge case)
- [ ] VoiceOver / TalkBack: every interactive element is reachable and labeled
```

**Web / fullstack:**

```
- [ ] Desktop browser AND a mobile breakpoint (responsive layout holds)
- [ ] Keyboard-only navigation: focus order, visible focus ring, no traps
- [ ] Network throttled: loading / empty / error / permission-denied states
- [ ] Unauthenticated vs authenticated views both correct
- [ ] (fullstack) Exercise the seam end-to-end against the real API; then kill
      the API mid-flow and confirm the UI degrades per the Edge Cases
- [ ] Both locales if localized
```

If a check is genuinely N/A for the change, strike it with a reason — don't
silently drop it.

---

## Part 2 — Engine pre-release QA (before merging a change to the ENGINE itself)

The engine tests itself with **four free, deterministic layers** — no model calls,
no network. Run all of them, plus the static checks, before any engine commit or
PR. They gate CI (`.github/workflows/ci.yml`), so a green local run should match
CI.

### Layer 1 — Offline fixture suite

```sh
NIGHT_SHIFT_ACCEPT_COSTS=YES bash scripts/night-shift.sh --fixture-test --dry-run
```

Behavioral where possible (`fx "label" cmd` inside a fixture names the failing
sub-check), structural (`declare -f` / grep wiring) only where behavior is
unfakeable. A `(FLAKY)` label on a failure means it passed an immediate rerun —
still fix it, but skip the bisect.

### Layer 2 — Integration + gherkin scenarios

```sh
bash scripts/test/integration-run.sh       # happy-path: real engine end-to-end on a scripted claude stub
bash scripts/test/integration-adverse.sh   # malformed-signal block + observer-BLOCK → fresh-session recovery
bash scripts/test/scenario-run.sh --all     # executable QA procedures in scripts/test/scenarios/*.feature
```

`integration-run.sh` asserts both outcomes and the decision journal; on failure it
preserves the full run log and a timestamped `bash -x` trace at a printed path —
read the trace tail first.

### Layer 3 — Mutation harness

```sh
bash scripts/test/mutate.sh --run --sample 10 --seed <pinned-seed>
```

Enumerates deterministic single-edit mutants of `scripts/lib/*.sh` and the
static-scan `.js` libs, runs the fixture suite per mutant, and requires each to be
**killed** (the suite must go red). Use the same seed CI pins — `MUTATE_SEED` in
`.github/workflows/ci.yml` — so a local run matches the baselined
`surviving-mutants.txt`; an arbitrary seed selects a different, un-baselined sample
that surfaces unratcheted survivors and looks broken on a clean tree. The
exhaustive `mutate.sh --full` is local/overnight-only.

### Layer 4 — Coverage + survivors ratchets

Shrink-only guardrails, enforced automatically by the suites above — you don't run
them separately, but know what they mean when they fire:

- `scripts/test/untested-allowlist.txt` — the fixture suite fails if a **new
  function has zero test references**. Adding a function means adding a test (or,
  deliberately, an allowlist entry).
- `scripts/test/surviving-mutants.txt` — the mutation run fails if a mutant
  **survives that isn't already on the (shrinking) allowlist**. Never grow this
  list to make a run green; kill the mutant with a test instead.

### Static checks (same CI job)

```sh
shellcheck scripts/**/*.sh .cursor/*.sh     # pinned via .cursor/install.sh; honors .shellcheckrc
node --check <changed>.js                   # JS syntax for the static-scan libs
bash scripts/doc-summaries.sh --check        # every top-level docs/*.md opens with `> Summary:` in its first 7 lines
```

`.shellcheckrc` disables only categorical false positives; intentional cases carry
visible inline pragmas. If you added or edited a top-level `docs/*.md`,
`doc-summaries.sh --check` must pass — the `> Summary:` opener is required (this
runbook and the authoring guide both have one).

### One-liner gate

Before opening an engine PR, all of the following must be green:

```sh
NIGHT_SHIFT_ACCEPT_COSTS=YES bash scripts/night-shift.sh --fixture-test --dry-run && \
bash scripts/test/integration-run.sh && \
bash scripts/test/integration-adverse.sh && \
bash scripts/test/scenario-run.sh --all && \
bash scripts/test/mutate.sh --run --sample 10 --seed "$(sed -n 's/.*MUTATE_SEED: *"\([0-9]*\)".*/\1/p' .github/workflows/ci.yml)" && \
bash scripts/doc-summaries.sh --check
```

Then run `shellcheck` and `node --check` over anything you touched. When it's all
green, the change is ready for the adversarial review pass (`/code-review`) and the
PR.
