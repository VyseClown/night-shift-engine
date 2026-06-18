# Night Shift — How To Use It (Human Guide)

> The human-facing quickstart. `AGENTS.md` and `AGENT_LOOP.md` are written for the
> agent; **this file is for you**, the person running the workflow. It answers two
> questions: *what do I write first?* and *what actually happens on a run?*

---

## TL;DR

```
write a spec  →  list it in TODO.md  →  launch the script  →  review in the morning
```

The **spec** is the one document that drives everything: run, implement, and
validate. Nothing you author matters more — the whole loop reads from it.

---

## 1. The main doc you write: a spec

Copy a template into `specs/` and fill it in. **Pick the template by track:**

| Project kind | Template | Track |
|---|---|---|
| Web (Next.js / React, e.g. `web-app`) | `specs/_template-web.md` | `web` |
| React Native (e.g. `rn-sandbox`) | `specs/_template.md` | `rn` (default) |

```sh
cp specs/_template-web.md specs/my-feature.md   # web example
# then edit specs/my-feature.md
```

A spec is only valid once these are filled. The wrapper's `validate_spec`
enforces them — an **incomplete spec blocks the run** instead of guessing:

| Section | What `validate_spec` mechanically enforces | Drives… |
|---|---|---|
| **Repository** | project path, base branch, feature branch — all must be non-placeholder values | routing + branch safety |
| **Review** | valid `Track:` + valid `Review Profile:` for that track | which persona set/floor reviews |
| **Permissions** | `New dependencies permitted: yes/no - <details>`; `ios/`+`android/` lines on the `rn` track | what the agent may touch |
| **Documentation** | an owner line for each persona active in the chosen profile | review ownership |
| **Test Plan** | `First failing test or executable check:`, `Baseline validation commands`, `Final validation commands` — all present and non-placeholder | the run/implement/validate loop |

`validate_spec` checks **structural completeness only** — it does not read or evaluate the prose in **Summary**, **User Story**, or **Acceptance Criteria**. Those sections are evaluated by the review personas and the observer during the run.

### The Test Plan is the engine

The validation is *your commands*, not the agent's guesses. The wrapper:

1. runs your **baseline** commands before any edit (records pre-existing failures),
2. runs your **first failing test** to prove it fails before implementation,
3. after implementation, re-runs that test (**must now pass**),
4. runs your **final** commands in an isolated worktree (**must not regress** vs baseline).

If you can't express "done" as commands that fail-then-pass, the spec isn't ready.

### Review Profile (per track)

`Track:` selects the persona set; `Review Profile:` selects which of them run:

| Profile | rn | web |
|---|---|---|
| `full` | all 6 rn | all 6 web |
| `frontend` | floor + Mobile UX Designer + Performance Expert | floor + Web UX & Accessibility Designer + Performance Expert |
| `logic` | floor + Performance Expert | floor + Performance Expert |
| `native` (rn only) | floor + Mobile Domain Expert | ✗ rejected |
| `data` (web only) | ✗ rejected | floor + Backend & Data Expert |

Floor (always runs): **rn** = React Native Architect, TS & Code Quality, Human
Advocate · **web** = Web Architect, TS & Code Quality, Human Advocate. Use `full`
when unsure.

### List it in TODO.md

Add one line pointing at the spec. Bugs are selected before features:

```
- [ ] bug: Short title (`specs/my-feature.md`)
- [ ] feature: Short title (`specs/my-feature.md`)
```

---

## 2. The night-shift workflow

### Day shift — you (human)

1. Write the spec (right template for the track) and add the TODO entry.
2. In the **project repo**, create and check out the **feature branch** named in
   the spec. Never run on `main` — the wrapper refuses.
3. One-time pre-flight (proves the toolchain + Claude can run unattended):
   ```sh
   NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test
   ```
4. Launch from a terminal (not a Claude session):
   ```sh
   NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh \
     --project ~/work/web-app --spec specs/my-feature.md
   ```
   Omit `--spec` to let it pull the next `TODO.md` entry.
5. **Or launch from the viewer** (a UI over the same script — no terminal):
   ```sh
   cd ~/work/night-shift-viewer/server && NSV_ALLOW_EDIT=1 NSV_ALLOW_LAUNCH=1 NSV_ALLOW_REAL=1 npm run dev:real
   cd ~/work/night-shift-viewer/web && npm run dev      # second terminal
   ```
   Open http://127.0.0.1:5173 → **Specs** tab to read/edit specs, **Launch** tab →
   *Real run* → pick the project + spec → watch it stream. The project must be on
   the spec's feature branch and gitignore `.night-shift/` first (the script
   refuses otherwise). The viewer scans `rn-sandbox`, `web-app`,
   `nightshift-demo` only.

> `NIGHT_SHIFT_ACCEPT_COSTS=YES` is a safety gate so live model calls aren't made
> by accident — not a billing switch. On a Claude Pro/Max login it consumes plan
> usage; with `ANTHROPIC_API_KEY` set it bills per token. See `AGENTS.md`
> ("Running the night shift") for cost details.

### Night shift — autonomous (wrapper + stage-scoped Claude sessions)

> Each stage scope (plan → implement → observe) runs in a fresh Claude session
> that hands off through files on disk — the plan at `.night-shift/control/plan.md`,
> persona findings, candidate evidence, and the working tree — rather than one
> pinned session replaying its whole history every turn. Set
> `NIGHT_SHIFT_SESSION_SCOPE=run` for the legacy single pinned session.


1. Validate spec → resolve **Track + Review Profile** → active persona set.
2. Baseline validation; run the first-failing test (must fail).
3. Plan → **plan-stage persona review** (every finding is a blocker; needs an
   APPROVE from each active persona).
4. Implement test-first, one acceptance criterion at a time.
5. **Implementation-stage persona review** (loop until all APPROVE).
6. Create a local **candidate commit** — only run-owned files, never your
   pre-existing dirty work.
7. Validate the candidate in an **isolated git worktree**: first-failing test now
   passes, final commands pass, no regression vs baseline.
8. **Independent Claude observer** (fresh session, neutral cwd, can't see the
   repo) reviews the candidate → APPROVE or BLOCK.
9. On APPROVE: write `CHANGELOG.md`, append the verdict to
   `NIGHT_SHIFT_REVIEW.md`, check off the TODO entry → next task or COMPLETE.

It runs unattended: it never asks questions. If it can't proceed safely it emits
a `BLOCKED` next-action and stops for you. It **never** pushes, merges, resets, or
switches models.

### Day shift — you again (morning)

1. Review the stacked candidate commits, `CHANGELOG.md`, and the
   `NIGHT_SHIFT_REVIEW.md` ledger.
2. Manually test the change.
3. If something's off, fix the **root cause in the spec / docs / validations
   first**, not just the code — so the next run is better.

---

## What's enforced for you (safety rails)

- Works only on the spec's **feature branch**; refuses `main`.
- Candidate commits **exclude** your pre-existing dirty files.
- A finding that stays materially unchanged for **3 rounds** blocks the run.
- Per-stage and per-task **turn/time budgets** stop runaways.
- Rate-limit (429) aware: waits for reset and resumes the **same** session.
- No push / merge / force-push / reset during a run.

---

## Two-track note

The only thing that differs between web and RN in *your* part is **step 1**: which
template you copy / what `Track:` you set. That auto-selects the right reviewers
and the matching Validation Checklist in `AGENTS.md`. The launch command, the run
loop, the observer, and every safety rail are identical for both tracks.

---

## Related files

- `AGENTS.md` — workspace router; cost/usage details; validation checklists per track.
- `AGENT_LOOP.md` — the agent's step-by-step overnight procedure.
- `specs/_template.md` / `specs/_template-web.md` — the spec templates.
- `docs/review-personas.md` / `docs/review-personas-web.md` — the reviewer personas.
- `TODO.md` — the work queue (bugs before features).
- `CHANGELOG.md` — completed changes.
- `NIGHT_SHIFT_REVIEW.md` — the validated observer-review ledger.
