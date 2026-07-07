# Scaling a night — sequential chain vs parallel fan-out

> How to run more than one spec's worth of work unattended, what each topology
> can and cannot do, and how to choose. Written for humans and agents; every
> constraint below is enforced by engine code (`scripts/lib/preflight.sh`,
> `scripts/lib/locking.sh`, `scripts/parallel-worktrees.sh`), not convention.
> Companion to `docs/SPEC-AUTHORING.md` (how to slice a feature into specs).

**The one decision rule:** *does this spec need a sibling spec's landed code to
pass its own validation?*

- **Yes** → it belongs in the **sequential chain** (one shared feature branch,
  candidates stack, each task builds on the last).
- **No** → it is eligible for **parallel fan-out** (one branch per spec, one
  worktree per spec, merged by you in the morning).

A big feature usually wants both: chain the dependent core, fan out the
independent tail (see *Hybrid* below).

---

## Topology A — sequential chain (`NEXT_TASK`, built into the engine)

One launch, N specs, strictly in order, all on **one shared feature branch**.

```sh
# TODO.md — ordered queue, bugs before features, every entry points to a spec:
#   - [ ] feature: Part 1 — data layer (`specs/feature-1-data.md`)
#   - [ ] feature: Part 2 — screens    (`specs/feature-2-ui.md`)
#   - [ ] feature: Part 3 — polish     (`specs/feature-3-polish.md`)

cd <project> && git checkout -b feat/my-feature   # ONE branch, named in EVERY spec
cd <engine>  && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --project <project>
#                                            ^ no --spec: the engine pulls from TODO.md
```

How it works (from `start_next_task` in the engine):

1. On completing a task the engine checks off its TODO entry, then walks the
   unchecked queue for the **next spec belonging to the same project** —
   other projects' specs are skipped; a run is pinned to one `--project`.
2. The next spec is `validate_spec`-checked, then **baselined at current HEAD**
   — i.e. on top of the previous task's candidate commit. Later specs build on
   earlier landed work; that is the point of the chain.
3. The full per-task cycle repeats: baseline → red test → plan → implement →
   persona reviews → candidate → isolated-worktree validation → observer.
4. When no same-project unchecked spec remains, the run completes and archives.

Hard constraints (all enforced, all block rather than guess):

| Constraint | Why / where enforced |
|---|---|
| Every chained spec must declare the **same feature branch** — the one the project is already on | the engine never switches branches; `check_branch_and_worktree` requires *current branch == spec's feature branch* for every next task |
| Same project only | `validate_spec_project` filters the queue; a run cannot switch `--project` |
| A `BLOCKED` anywhere stops the whole chain | later queue entries wait for the next launch; landed candidates are kept |
| `--spec` runs do not chain | an explicit `--spec` run is a single task: on `NEXT_TASK` it exits 0, so an external wrapper can own cross-spec sequencing |
| The completed entry must be checked off before the next is picked | the engine does this itself; a mismatch blocks (`NEXT_TASK requires the completed TODO entry to be checked off`) |

**Choose the chain when:** slices are dependent (schema → logic → UI), you want
zero morning merge work, or you're on a single Pro/Max plan (one run = no
usage-limit contention; 429s pause and resume the same session).

---

## Topology B — parallel fan-out (`scripts/parallel-worktrees.sh`)

N **independent** engine runs at once, one git worktree per spec, each spec on
**its own feature branch**.

```sh
# free rehearsal first — creates the worktrees, runs engine --preflight only:
scripts/parallel-worktrees.sh --project <workspace>/<app> --dry-run \
    specs/part-a.md specs/part-b.md specs/part-c.md

# real fan-out (paid; the wrapper sets NIGHT_SHIFT_ACCEPT_COSTS itself):
scripts/parallel-worktrees.sh --project <workspace>/<app> --jobs 2 \
    specs/part-a.md specs/part-b.md specs/part-c.md
```

How it works (from the wrapper):

1. For each spec it reads `- Base branch:` / `- Feature branch:` and creates
   (or reuses) a worktree at `<project>/../.ns-worktrees/<branch>`, cutting the
   feature branch from the spec's base branch if it doesn't exist yet.
2. Each worktree gets its **own `.night-shift/`** — state, decision journal,
   and run-lock — so N runs coexist with zero contention. Per-run logs land at
   `<worktree>.log`.
3. `--jobs N` bounds concurrency (default **2** — paid runs + rate limits);
   excess specs queue. With jobs > 1 it auto-sets `NIGHT_SHIFT_DEVICE_REGISTRY=1`
   so concurrent `visual_review` stages each claim a dedicated iOS simulator
   (registry mode needs pre-bundled preview builds — no Metro).
4. Worktrees are **kept** by default (each is a first-class checkout you can
   attach another Claude Code instance to); `--prune` removes clean ones.

Hard constraints:

| Constraint | Why / where enforced |
|---|---|
| One **distinct feature branch per spec** — never shared | git refuses the same branch in two worktrees, and `check_branch_and_worktree` rejects a branch held by another worktree |
| Explicit spec list on the command line | the wrapper does **not** read `TODO.md`; fan-out has no queue semantics |
| Each candidate validates against **its own base**, never against siblings | cross-spec conflicts surface only when *you* merge the branches — fan out only disjoint file surfaces |
| The morning includes an integration step | N observer-approved branches → you merge them (the engine never pushes or merges) |
| Branch fields must be **backticked** | both the wrapper's parser and the engine's routing check match only `` - Feature branch: `feat/x` `` — a bare value reads as empty and the spec is skipped/blocked (the templates already backtick these) |
| One subscription = one shared usage pool | more jobs ≠ more throughput on a Pro/Max login; concurrent runs 429 together. Default `--jobs 2` is deliberate; go wider only on an API key |

**Choose fan-out when:** specs are independent in both code surface and
validation, wall-clock matters, and you accept the morning merge.

---

## Hybrid — chain the core, fan out the tail (recommended for big features)

```text
Night 1  (chain):    specs 1→4, all on `feat/my-feature`, launched without --spec
Night 2  (fan-out):  specs 5–8, each `Base branch: feat/my-feature`,
                     own feature branches (`feat/mf-segments`, `feat/mf-nav`, …)
Morning:             merge the tail branches back into `feat/my-feature`
```

The tail specs' `Base branch:` pointing at the trunk feature branch is what
lets them build on the chained core while still running in isolation.

---

## What is NOT possible today

Stated explicitly so nobody (human or agent) goes looking for a knob that
doesn't exist:

- **No parallelism inside a single run.** One run = one spec at a time, stages
  in order, one AC at a time. That's by design — each AC builds on the last.
- **No two runs in the same checkout.** The run-lock
  (`$PROJECT/.night-shift/run.lock`, atomic `mkdir` + owner PID, stale-lock
  reclaim) hard-refuses a second run; **worktrees are the unit of parallelism**.
- **No parallel runs sharing one feature branch** (see Topology B constraints).
- **No TODO-driven fan-out.** The queue is sequential-only; the wrapper takes
  an explicit spec list.
- **No branch switching mid-chain.** The chain lives and dies on the branch it
  started on.

---

## Related

- `docs/SPEC-AUTHORING.md` — slicing a feature into right-sized specs (the
  input this doc consumes)
- `docs/COMMAND-PLAYBOOK.md` §8 — the quick-chooser row for these commands
- `scripts/parallel-worktrees.sh -h` — authoritative wrapper flags
- `NIGHT_SHIFT_HOWTO.md` — what one run does, stage by stage
- `AGENTS.md` → *Running the night shift* — cost/usage and rate-limit behavior
