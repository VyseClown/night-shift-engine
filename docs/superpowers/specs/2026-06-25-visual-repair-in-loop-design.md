# In-loop visual-repair — design

Date: 2026-06-25. Status: approved design (pre-plan). Repo: `night-shift-engine`.
Builds on the merged standalone auto-repair (PRs #26/#27) and the combined design
`docs/superpowers/specs/2026-06-24-visual-auto-repair-design.md` §4.5.

## 1. Summary

Make the night-shift engine's `visual_review` stage **auto-repair** over-tolerance
screens during a build, opt-in via `NIGHT_SHIFT_VISUAL_REPAIR=1`. It reuses the
**proven** standalone repair loop (the one the convergence smoke validated:
perturbed Home 0.136 → 0.091 in one attempt) by moving the repair orchestration
into the shared `scripts/lib/visual-repair.sh` so both surfaces run one code path.

Decisions (locked in brainstorming):
- **Engine-invoked** repair: `run_visual` runs the shared loop directly (spawns the
  `claude -p` repair agent), rather than routing back to the implement stage.
- **New repair commit**: repair edits the working tree; the engine commits a
  `fix(visual): auto-repair …` commit on top of the candidate and points the
  candidate at it, so the observer reviews the repaired tip.

Default **off** → with the flag unset, `run_visual` is byte-for-byte unchanged.

## 2. Goals / Non-goals

**Goals**
- One shared repair orchestration used by both the standalone tool and `run_visual`.
- `run_visual`, when enabled + over-tolerance + tooling present, repairs, commits a
  new candidate commit, refreshes the report, then hands the repaired tip to the
  observer.
- Clean SKIP (log + proceed to observer, never block) when the dev-build/Metro
  harness or capture tooling is unavailable.
- Default-off, byte-for-byte unchanged when disabled.

**Non-goals**
- Changing the observer, the stage machine beyond `run_visual`, or the standalone
  surface's external behavior (it stays "edits left uncommitted").
- Building native automatically beyond what `repair_metro_start` already does.
- A new convergence mechanism — the loop is the proven standalone one.

## 3. Background (current state, on `main`)

- `run_visual()` (`scripts/night-shift.sh`): reads the candidate commit, runs
  `run_visual_capture "$SPEC" "$candidate" "$RUN_ROOT/validated"`, classifies the
  report (valid/absent/malformed), then `set_stage observer_review`.
- `run_visual_capture` writes `<out>/visual-diff-<spec>.json`, screenshots under
  `<out>/screenshots/<candidate>/<screen>-<state>-<device>.png`, refs under
  `<out>/design/…`, diffs under `<out>/diffs/<candidate>/…`.
- Standalone repair lives entirely in `scripts/visual-review.sh`: `repair_agent`,
  `repair_validate`, `repair_metro_start/stop`, `_REPAIR_METRO_PID`, the Figma/matrix
  helpers (`figma_key_for`, `node_id_for`, `matrix_devices`, `device_label_to_name`),
  and an inline `repair_one` that calls `visual_repair_screen` with paths under
  `<OUT>/<specbase>/{design,screenshots/review,diffs/review}`.
- Shared lib `scripts/lib/visual-repair.sh` already holds the surface-agnostic loop
  primitives: `visual_repair_scope_check`, `_snapshot`/`_restore`, `_diff`,
  `visual_repair_screen`, `visual_repair_run`. `night-shift.sh` does NOT yet source it.
- `candidate_commits` in `$STATE` is already an array; `.candidate` is the current tip.

## 4. Architecture

### 4.1 Move repair orchestration into the shared lib

Relocate from `scripts/visual-review.sh` into `scripts/lib/visual-repair.sh`
(making them read a documented set of globals both callers set, matching the
existing lib style):
- `repair_agent`, `repair_validate`
- `repair_metro_start`, `repair_metro_stop`, `_REPAIR_METRO_PID`
- `figma_key_for`, `node_id_for`, `device_label_to_name`
- a new **per-spec** device helper `visual_repair_devices <spec>` =
  `visual_capture_screens "$spec" | awk -F'|' '{print $3}' | sort -u`. The existing
  `matrix_devices` in `visual-review.sh` (which iterates the `SPECS` array) becomes a
  thin wrapper that loops over `SPECS` calling `visual_repair_devices`; in-loop calls
  `visual_repair_devices "$SPEC"` directly (one spec per run).

Add one new orchestrator:

```
visual_repair_for_spec <spec> <project> <out_dir> <candidate_label> \
                       <report_path> <max_attempts> <allow_csv> <iteration_device>
```

It builds the failing-screens TSV from `<report_path>`
(`jq '.screens[]|select(.pass|not)|[.diff_pct,.screen,.state,.device]|@tsv'`),
then `visual_repair_run` with a `repair_one` that calls `visual_repair_screen`
injecting `repair_agent`/`visual_recapture_screen`/`repair_validate` and resolving
paths as `<out_dir>/design/<S>-<st>-<dev>.png`,
`<out_dir>/screenshots/<candidate_label>/<S>-<st>-<dev>.png`,
`<out_dir>/diffs/<candidate_label>/<S>-<st>-<dev>.png`. The `candidate_label`
parameter is the ONLY path difference between surfaces (standalone passes
`"review"`; in-loop passes the candidate SHA). Returns 0 if all repaired screens
end within tolerance.

`scripts/visual-review.sh` becomes a thin caller: source the lib (already does),
delete the moved definitions, and call the shared functions + `visual_repair_for_spec`
with `(out=<OUT>/<specbase>, candidate_label="review")`. Its external behavior is
unchanged (still `--repair`, still leaves edits uncommitted, still does the final
authoritative pass).

### 4.2 `run_visual` rewire (engine-invoked)

`night-shift.sh` sources `scripts/lib/visual-repair.sh`. Add the constant
`VISUAL_REPAIR="${NIGHT_SHIFT_VISUAL_REPAIR:-0}"` (near `VISUAL_CAPTURE`). In
`run_visual`, after the existing capture + `valid` classification:

```
if [ "$VISUAL_REPAIR" = "1" ] && <report has over-tolerance screens> && visual_capture_available; then
  iter_dev="$(visual_repair_devices "$SPEC" | head -n1)"   # e.g. iphone-16
  repair_metro_start "$(device_label_to_name "$iter_dev")"
  REPAIR_FILEKEY="$(figma_key_for "$SPEC")"; REPAIR_FALLBACK_NODE="$(node_id_for "$SPEC" "")"
  visual_repair_for_spec "$SPEC" "$PROJECT_DIR" "$RUN_ROOT/validated" "$candidate" \
    "$report" "${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" \
    "$([ "${NIGHT_SHIFT_VISUAL_REPAIR_SHARED:-0}" = 1 ] && echo 'src/features/,src/ui/' || echo 'src/features/')" \
    "$iter_dev"
  repair_metro_stop
  if ! git -C "$PROJECT_DIR" diff --quiet; then
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -q -m "fix(visual): auto-repair <screens over tolerance>"
    newsha="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    # append to candidate_commits + point .candidate at newsha (atomic state write)
    run_visual_capture "$SPEC" "$newsha" "$RUN_ROOT/validated"   # refresh report at the repaired tip
    report="$RUN_ROOT/validated/visual-diff-$(basename "$SPEC" .md).json"
  fi
fi
set_stage observer_review
```

`PROJECT_DIR` is the engine's target-project path (the dir capture/validation already
operate on). Re-running `run_visual_capture` at `$newsha` refreshes the report so the
observer sees the repaired diffs. `set_stage observer_review` is unchanged.

### 4.3 Harness precondition + clean skip

Repair needs the agent's edits live before re-capture → a **dev build + Metro**
(`repair_metro_start`, shared, builds-if-needed). In-loop repair is therefore gated
on the same capture availability as the stage itself. If `repair_metro_start` fails
(no dev build possible) or `visual_capture_available` is false, repair is **skipped
with a log line and the stage proceeds to the observer with the unrepaired report** —
it never blocks the run. (This matches the existing "capture cleanly SKIPs" contract.)

### 4.4 Commit semantics

A new commit on the target project's feature branch:
`fix(visual): auto-repair <comma-list of repaired screens>`. Append its SHA to
`$STATE.candidate_commits` and set `$STATE.candidate` to it via the engine's existing
atomic state-write helper. The observer then reviews the repaired tip with no change
to the observer. The commit lists the screens it touched; the diff is auditable.

## 5. Reporting

No schema change. The refreshed `visual-diff-<spec>.json` (captured at the repaired
tip) carries the post-repair diffs + the `attempts[]`/`unmet_brief` the loop records.
The `run_visual` log notes repaired/remaining screen counts before handing to the
observer.

## 6. Testing

Deterministic fixtures (engine `--fixture-test`, mock `xcrun`/`git`/the agent):
- **default-off**: with `NIGHT_SHIFT_VISUAL_REPAIR` unset, `run_visual` takes the
  exact existing path (no repair branch entered) — assert the call sequence is
  unchanged.
- **gated skip**: flag on but `visual_capture_available` false → repair skipped, log
  emitted, `set_stage observer_review` still reached, no commit.
- **`visual_repair_for_spec` path parameterization**: candidate_label drives the
  screenshot/diff sub-path (`screenshots/<label>/…`); assert the failing-TSV is built
  from the report and `repair_one` receives the right paths (inject stub
  `visual_repair_screen`).
- **commit + candidate update**: when the working tree changed, a commit is made and
  `candidate_commits`/`.candidate` updated (mock `git`, assert state write).
- Standalone parity: `visual-review.sh --repair` still works after the extraction
  (its existing fixtures + a re-source check).

Real in-loop smoke (manual, documented follow-up): a night-shift run with
`NIGHT_SHIFT_VISUAL_REPAIR=1` on a project with a closeable-gap screen, asserting a
`fix(visual): auto-repair …` commit lands and the observer receives the repaired
report. Convergence itself is already proven by the standalone smoke (same loop).

## 7. Risks / open questions

- **Refactor regression risk** (moving functions across files): mitigated by the
  standalone fixtures + a re-source parity check; the extraction must keep
  `visual-review.sh` byte-for-byte equivalent in behavior.
- **Committing inside a stage**: the engine otherwise commits candidates via the
  implement agent (CREATE_CANDIDATE). Engine-invoked repair adds a second commit
  path; it must use the same atomic state-write + never run on the wrong branch
  (guard: only commit on the project's current feature branch, never main).
- **Path-layout coupling**: the `candidate_label` parameter is the single point that
  reconciles the two surfaces' layouts; the fixture pins it.
- **Metro in the engine context**: building a dev client inside a stage is a heavy
  side effect; gated behind the opt-in flag and the clean-skip fallback.

## 8. Out of scope / future

- Auto-repair for non-rn tracks.
- Parallel-worktree in-loop repair (the standalone Metro harness is single-run).
- A viewer affordance for the auto-repair commit.
