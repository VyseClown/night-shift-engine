# shellcheck shell=bash
# scripts/lib/sweep.sh
# Branch sweep (NIGHT_SHIFT_BRANCH_SWEEP): one whole-branch strong-model
# review at run end, plus a capped fix cycle on its findings. See
# docs/superpowers/specs/2026-07-11-agentic-gaps-tranche-design.md §A/§B.
# Sourced by night-shift.sh after events/recovery/integrity libs.

# Print merge-base; write package.diff + package.meta.json into $2.
# Refuses to sweep a default-branch tip (nothing branch-shaped to review).
sweep_build_package() {
  local project="$1" out="$2" head branch mb default
  mkdir -p "$out" || return 1
  branch="$(git -C "$project" branch --show-current)"
  default="$(git -C "$project" rev-parse --verify -q main >/dev/null 2>&1 && echo main || echo master)"
  [ -n "$branch" ] && [ "$branch" != "$default" ] || {
    printf 'sweep: project is on %s — no feature branch to sweep\n' "${branch:-detached}" >&2
    return 1
  }
  head="$(git -C "$project" rev-parse HEAD)"
  mb="$(git -C "$project" merge-base "$default" HEAD)" || return 1
  [ "$mb" != "$head" ] || { printf 'sweep: branch has no commits over %s\n' "$default" >&2; return 1; }
  {
    printf '## commits\n'; git -C "$project" log --oneline "$mb..HEAD"
    printf '\n## stat\n';  git -C "$project" diff --stat "$mb..HEAD"
    printf '\n## diff\n';  git -C "$project" diff -U10 "$mb..HEAD"
  } >"$out/package.diff"
  jq -n --arg branch "$branch" --arg base "$mb" --arg head "$head" \
    --argjson commit_count "$(git -C "$project" rev-list --count "$mb..HEAD")" \
    '{branch:$branch, base:$base, head:$head, commit_count:$commit_count}' \
    >"$out/package.meta.json"
  # Wrapper-owned evidence, same as run_validation_commands' STATE seeding:
  # anchor the package the sweep session (and any later --sweep-only re-read)
  # is judged against. No-op when RUN_ROOT is unset (e.g. --sweep-only has no
  # run to anchor into; integrity_put itself also guards on RUN_ROOT/RUN_ID).
  [ -z "${RUN_ROOT:-}" ] || { integrity_put "$out/package.diff"; integrity_put "$out/package.meta.json"; }
  printf '%s\n' "$mb"
}

# stdin: session text -> stdout: SWEEP_PASS | SWEEP_FINDINGS. Contract: only
# the LAST non-empty line of the session text is the verdict line, matched
# anchored (^SWEEP_PASS$ or ^SWEEP_FINDINGS(: [0-9]+)?$). An earlier
# anywhere-in-text `grep -q SWEEP_PASS` misread a finding sentence that merely
# NAMED the word (e.g. "this is not a SWEEP_PASS situation") as a pass, even
# when the session's actual last line was SWEEP_FINDINGS. Fail-closed: the
# last line not matching the PASS shape (including a well-formed FINDINGS
# line, or garbage) always yields SWEEP_FINDINGS.
sweep_parse_verdict() {
  local last
  last="$(awk 'NF { line = $0 } END { print line }')"
  case "$last" in
    SWEEP_PASS) printf 'SWEEP_PASS\n' ;;
    *) printf 'SWEEP_FINDINGS\n' ;;
  esac
}

# Distill this run's journal into feedback for the human who authors specs
# and runs the engine — a separate, always-on concern from the sweep above
# (that one reviews the branch's code; this one reviews the RUN itself: spec
# ambiguities, loops, validation friction). Runs unconditionally at completion
# regardless of BRANCH_SWEEP (see complete_run's call site, which sits before
# the sweep block). By completion the stage-scoped sessions are already gone,
# so this is a short FRESH implementer-backend session (dispatched on the
# active backend below, same as invoke_primary), fed the spec path + the tail
# of events.jsonl + the review-round count rather than asked to explore the
# repo itself.
# Every failure mode (no run context, session error, empty/unparsable reply,
# no bullet lines, an unwritable feedback.md) warns and returns 0 — feedback
# must never block or delay completion. Guards every run-scoped global with
# ${VAR:-} (set -u is in effect for the whole orchestrator).
write_run_feedback() {
  local project="$1" out feedback raw rc=0 tail_events round result bullets lines prompt_text
  [ -n "${RUN_ROOT:-}" ] && [ -n "${SPEC:-}" ] && [ -f "${STATE:-}" ] || {
    log "WARN: run feedback skipped (no run context — RUN_ROOT/SPEC/STATE unset)"
    return 0
  }
  [ -f "${RUN_ROOT}/events.jsonl" ] || {
    log "WARN: run feedback skipped (no events.jsonl at $RUN_ROOT)"
    return 0
  }
  out="$RUN_ROOT/feedback"
  mkdir -p "$out" || { log "WARN: run feedback skipped (mkdir failed for $out)"; return 0; }
  feedback="$project/.night-shift/feedback.md"
  tail_events="$(tail -n 200 "$RUN_ROOT/events.jsonl" 2>/dev/null)"
  round="$(jq -r '.review_round // 0' "$STATE" 2>/dev/null)" || round=""
  [ -n "$round" ] || round=0
  raw="$out/session.json"
  # Prompt built once into a variable so both backend branches below pipe the
  # identical text on stdin (`printf '%s'` — command substitution already
  # stripped the trailing newline, which the model does not care about).
  prompt_text="$(
    printf 'Spec: %s\n' "$SPEC"
    printf 'Review rounds completed: %s\n\n' "$round"
    printf 'Write 5-15 bullet lines of feedback for the human who authors specs and\n'
    printf 'runs this engine: spec ambiguities you can infer from the journal below,\n'
    printf 'stages that looped, validation friction, anything a better spec would\n'
    printf 'have prevented. Plain `- ` bullets only, no headings.\n\n'
    printf '## events.jsonl (last 200 lines)\n%s\n' "$tail_events"
  )"
  # Dispatch on the active implementer backend (scripts/lib/implementer.sh):
  # this session is advisory and read-only-ish (no -f — feedback needs no file
  # edits), so a cursor failure here takes NO retry/fallback machinery of its
  # own; it just falls through to the existing "rc != 0" WARN-and-return path
  # below, same as any other feedback-session failure.
  if implement_backend_active; then
    (cd "$project" && printf '%s' "$prompt_text" |
      cursor-agent -p --output-format json --model "$CURSOR_IMPLEMENT_MODEL" --trust) >"$raw" 2>"$raw.err" || rc=$?
  else
    # model computed only on this branch — the cursor branch above passes its
    # own $CURSOR_IMPLEMENT_MODEL and never reads it, so resolving it up front
    # for both branches was dead work on the cursor path. The feedback step
    # model (FEEDBACK_MODEL, empty follows IMPLEMENT_MODEL) comes from the
    # shared step_model table. claude_model_args intentionally word-splits
    # into `--model X` (or nothing); same idiom as sweep_run/invoke_observer_once.
    # shellcheck disable=SC2046
    (cd "$project" && printf '%s' "$prompt_text" |
      claude -p $(claude_model_args "$(step_model feedback)") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log "WARN: run feedback session failed (rc=$rc; see $raw.err)"
    return 0
  fi
  result="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  [ -n "$result" ] || {
    log "WARN: run feedback skipped (empty/unparsable model reply, see $raw)"
    return 0
  }
  bullets="$(printf '%s\n' "$result" | grep -E '^- ')"
  [ -n "$bullets" ] || {
    local dropped
    dropped="$(printf '%s\n' "$result" | grep -c '.')"
    log "WARN: run feedback skipped (reply had $dropped lines but no \`- \` bullets — dropped, see $raw)"
    return 0
  }
  lines="$(printf '%s\n' "$bullets" | grep -c '^- ')"
  mkdir -p "$project/.night-shift" || {
    log "WARN: run feedback skipped (mkdir failed for $project/.night-shift)"
    return 0
  }
  {
    printf '\n## run %s — %s — %s\n\n' "$RUN_ID" "$(now_iso)" "$(basename "$SPEC")"
    printf '%s\n' "$bullets"
  } >>"$feedback" || {
    log "WARN: run feedback append to $feedback failed"
    return 0
  }
  emit_event run_feedback "$(jq -cn --argjson n "$lines" '{lines:$n}')"
  return 0
}

sweep_prompt() {
  local out="$1"
  cat <<'EOF'
You are the final whole-branch reviewer for an overnight autonomous run.
Per-task reviews already passed; you look for what they cannot see:
cross-task interactions, regressions between commits, accumulated minor
findings that add up, removed-behavior gaps, hygiene (test fixtures must be
neutral stand-ins, no company identifiers, i18n key pairs complete), and
tests weakened rather than updated. Read the package file below fully.
The package file is the AUTHORITATIVE diff scope for this review — it is
already scoped to the exact branch range under review. Do NOT reconstruct
the diff range yourself from git (e.g. `main...HEAD`); the branch's `main`
may have advanced since the package was built, which would silently review
the wrong range. If you cannot read the package file, that failure is your
ONLY finding: report it and end your reply with exactly `SWEEP_FINDINGS: 1`.
Otherwise, for each finding: severity (Critical/Important/Minor), file:line,
a concrete failure scenario, and the concrete fix. End your reply with
exactly one line: either `SWEEP_PASS` or `SWEEP_FINDINGS: <count>`.
EOF
  printf '\nPackage: %s/package.diff (read it with your file tools; you have\n' "$out"
  printf 'been granted access to this directory)\n'
}

# Run the sweep session. Writes $out/findings.md + $out/verdict.txt; emits
# sweep event. Never propagates failure (advisory contract) — a session
# error yields verdict SWEEP_ERROR in verdict.txt and a warn log.
sweep_run() {
  local project="$1" out="$2" raw rc=0 model verdict
  model="$(resolve_effective_model "$SWEEP_MODEL")"
  raw="$out/session.json"
  # model_flag intentionally word-splits into `--model X` (or nothing); same
  # idiom as invoke_observer_once. --add-dir "$out" is required: $out lives
  # outside $project (e.g. --sweep-only's own tmp dir), and the session is
  # sandboxed to the cwd it was launched in with no other grant — without
  # this it cannot read package.diff at all and was observed to silently
  # reconstruct the diff itself via `main...HEAD` instead (wrong scope once
  # main has advanced; proven live). See sweep_prompt's authoritative-scope
  # instruction above, which this flag makes actually satisfiable.
  # reviewer_isolation_args word-splits the same way: hooks off + no MCP for
  # this whole-branch REVIEW session under NIGHT_SHIFT_MEMORY /
  # NIGHT_SHIFT_REVIEWER_ISOLATION=1 (it is a reviewer, like the observer);
  # nothing otherwise. The rate-limit retry below spawns with the SAME argv.
  # shellcheck disable=SC2046
  (cd "$project" && sweep_prompt "$out" |
    claude -p $(model_flag "$model") $(reviewer_isolation_args) --add-dir "$out" --output-format json) >"$raw" 2>"$raw.err" || rc=$?
  if [ "$rc" -ne 0 ] && command -v is_rate_limit_response >/dev/null 2>&1 && is_rate_limit_response "$raw"; then
    # Bound the wait. This session runs at the very tail of an otherwise-
    # successful run (or standalone via --sweep-only) — it is advisory, never
    # gates anything — so unconditionally calling handle_rate_limit_wait here
    # (as every OTHER 429 call site correctly does, because THEIR work is
    # gating) would let a wait of up to RATE_LIMIT_MAX_WAIT_SECONDS (hours,
    # default 6h — and past that cap, wait_for_rate_limit_reset itself calls
    # block_run, hard-failing the whole run over an advisory review) hang the
    # process for no benefit proportional to the review. Cheapest correct
    # gate: peek at the SAME reset math wait_for_rate_limit_reset uses
    # (rate_limit_reset_epoch off the raw 429 response, plus the same
    # RATE_LIMIT_BUFFER_SECONDS buffer it applies) WITHOUT committing to the
    # sleep, and only retry if that reset is within NIGHT_SHIFT_SWEEP_MAX_WAIT
    # seconds (default 900s — comfortably under the 6h cap, so this gate is
    # always the binding one for sweep, and wait_for_rate_limit_reset's own
    # block_run path is unreachable from here under default configuration —
    # see the SWEEP_MAX_WAIT comment in night-shift.sh for the OTHER block_run,
    # inside handle_rate_limit_wait itself, that this gate does not shield).
    # An unparsable reset, or one further out than the cap, skips the retry
    # and falls through to SWEEP_ERROR — fail-closed, same direction as a
    # session failure with no rate-limit shape at all. Also require a run
    # context (`$STATE` set): handle_rate_limit_wait reads/writes "$STATE"
    # unguarded, which only exists for an in-run sweep (end-of-run or
    # --sweep-only's own future run) — a standalone `--sweep-only` invocation
    # has no STATE at all, so retrying there would crash on an unbound
    # variable instead of the advertised SWEEP_ERROR; skip the retry and fall
    # through the same as an out-of-cap reset.
    local reference reset_epoch wait_seconds=""
    reference="$(file_mtime_epoch "$raw" 2>/dev/null)" || reference="$(now_epoch)"
    if reset_epoch="$(rate_limit_reset_epoch "$raw" "$reference" 2>/dev/null)"; then
      wait_seconds=$((reset_epoch + RATE_LIMIT_BUFFER_SECONDS - $(now_epoch)))
    fi
    if [ -n "${STATE:-}" ] && [ -n "$wait_seconds" ] && [ "$wait_seconds" -le "$SWEEP_MAX_WAIT" ]; then
      handle_rate_limit_wait "$raw" subagent || true
      rc=0
      # Same argv as the first spawn, isolation included — a retried reviewer
      # must not be the one session that sees the user's hooks/MCP.
      # shellcheck disable=SC2046
      (cd "$project" && sweep_prompt "$out" |
        claude -p $(model_flag "$model") $(reviewer_isolation_args) --add-dir "$out" --output-format json) >"$raw" 2>"$raw.err" || rc=$?
    else
      log "WARN: branch sweep rate-limited; reset wait exceeds NIGHT_SHIFT_SWEEP_MAX_WAIT (${SWEEP_MAX_WAIT}s), could not be parsed, or no run context (STATE unset, e.g. standalone --sweep-only) — skipping retry (advisory)"
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'SWEEP_ERROR\n' >"$out/verdict.txt"
    [ -z "${RUN_ROOT:-}" ] || integrity_put "$out/verdict.txt"
    log "WARN: branch sweep session failed (rc=$rc, advisory; see $raw.err)"
    emit_event sweep "$(jq -cn '{verdict:"SWEEP_ERROR"}')"
    return 0
  fi
  jq -r '.result // empty' "$raw" >"$out/findings.md" 2>/dev/null || cp "$raw" "$out/findings.md"
  verdict="$(sweep_parse_verdict <"$out/findings.md")"
  printf '%s\n' "$verdict" >"$out/verdict.txt"
  [ -z "${RUN_ROOT:-}" ] || { integrity_put "$out/findings.md"; integrity_put "$out/verdict.txt"; }
  emit_event sweep "$(jq -cn --arg v "$verdict" '{verdict:$v}')"
  log "branch sweep verdict: $verdict"
  return 0
}

# One capped fix cycle: hand findings to an implement-model session inside the
# project, re-run final validation, re-sweep once. Deterministic revert if
# Re-validate the post-fix tip the SAME way the run's own final gate does:
# verify_candidate validates a detached worktree at the candidate commit (never
# the live working tree), then re-runs the smoke phase and regresses it against
# the baseline. sweep_fix_cycle must match that or a "successful" fix could ship
# a tip that only passes because of live-tree state absent from a clean checkout
# (e.g. a gitignored file present locally). Builds a detached worktree at HEAD,
# links dependencies NON-blockingly (a link failure degrades to a conservative
# revert, never a run-killing block_run — sweep is advisory), runs the final
# validation commands + smoke there, and returns 0 iff the fixed tip passes.
# In-run only (needs RUN_ROOT for per-command logs + the baseline smoke ref);
# --sweep-only never reaches this.
sweep_revalidate_isolated() {
  local project="$1" out="$2" cycles="$3" vcmds="$4" tip wt rc=0 rel src dst pnpm=0
  tip="$(git -C "$project" rev-parse HEAD)"
  wt="$(tmp_base)/night-shift-sweepfix-${RUN_ID:-x}-${cycles}-${tip}"
  prepare_validation_worktree "$project" "$wt" "$tip" || return 1
  # Non-blocking mirror of link_worktree_dependencies (which block_runs on
  # failure — unacceptable for an advisory sweep). Covers DEPENDENCY_LINKS, the
  # pnpm workspace package dirs, and the Nx cache; anything missing is skipped.
  # pnpm node_modules go through the SAME entry-wise isolation production uses
  # (link_node_modules_isolated): a whole-dir symlink would make pnpm's relative
  # workspace links resolve back to the LIVE project sources, silently defeating
  # the isolation this whole path exists for.
  [ ! -f "$project/pnpm-workspace.yaml" ] || pnpm=1
  # shellcheck disable=SC2046,SC2086
  for rel in $DEPENDENCY_LINKS $(pnpm_workspace_links 2>/dev/null); do
    src="$project/$rel"; dst="$wt/$rel"
    { [ -e "$src" ] && [ ! -e "$dst" ]; } || continue
    mkdir -p "$(dirname "$dst")" 2>/dev/null || continue
    if [ "$pnpm" -eq 1 ] && [ "$(basename "$rel")" = "node_modules" ]; then
      link_node_modules_isolated "$src" "$dst" "$wt" 2>/dev/null || true
    else
      ln -s "$src" "$dst" 2>/dev/null || true
    fi
  done
  [ ! -d "$project/.nx/cache" ] ||
    { mkdir -p "$wt/.nx" 2>/dev/null && ln -s "$project/.nx/cache" "$wt/.nx/cache" 2>/dev/null || true; }
  if [ -n "$vcmds" ]; then
    run_validation_commands sweepfix "$out/revalidation-$cycles.json" "$vcmds" "$wt" || rc=1
    if [ "$rc" -eq 0 ] && jq -e 'any(.[]; .exit_status != 0)' "$out/revalidation-$cycles.json" >/dev/null; then rc=1; fi
  fi
  # Smoke re-run in the same worktree, regressed against the run's baseline smoke
  # — exactly verify_candidate's contract. A spec with no Smoke field makes
  # run_smoke_phase a silent no-op (writes nothing), so this cleanly skips.
  if [ "$rc" -eq 0 ]; then
    run_smoke_phase sweepfix "$out/smoke-sweepfix-$cycles.json" "$wt"
    if [ -s "$out/smoke-sweepfix-$cycles.json" ] && [ -f "$RUN_ROOT/validated/smoke-baseline.json" ]; then
      validation_not_regressed "$RUN_ROOT/validated/smoke-baseline.json" "$out/smoke-sweepfix-$cycles.json" || rc=1
    fi
  fi
  git -C "$project" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$project" worktree prune 2>/dev/null || true
  return "$rc"
}

# re-validation fails: reset --hard to the recorded tip (never trust the agent
# to undo its own commits). Always returns 0 — sweep is advisory end to end.
# The verdict gate below only ever proceeds on the literal string
# "SWEEP_FINDINGS" — SWEEP_PASS (nothing to fix) and SWEEP_ERROR (nothing
# coherent to fix; the session itself failed) both fall through untouched.
sweep_fix_cycle() {
  local project="$1" out="$2" tip_before vcmds cycles=0 fix_prompt
  [ "$(cat "$out/verdict.txt" 2>/dev/null)" = "SWEEP_FINDINGS" ] || return 0
  while [ "$cycles" -lt "$SWEEP_MAX_FIX" ]; do
    cycles=$((cycles + 1))
    tip_before="$(git -C "$project" rev-parse HEAD)"
    # The fix session's own exit status is not the gate — re-validation below
    # is (a session that "succeeds" but leaves the build red is caught the
    # same as one that crashes outright; both revert). --add-dir "$out" for
    # both backends for the same reason as sweep_run: $out sits outside
    # $project, and this session may need to consult other sweep artifacts
    # alongside the findings already piped into its prompt (e.g. package.diff
    # for fuller context) — cursor-agent takes the same --add-dir flag
    # (verified in `cursor-agent --help`, build 2026.08.25-3e8eec8: "--add-dir
    # <path>  Add an additional workspace root directory (can be specified
    # multiple times)").
    fix_prompt="$(
      printf 'Fix ONLY the findings below on the current branch. Commit in\n'
      printf 'logical chunks. Run the covering tests for what you change.\n\n'
      cat "$out/findings.md"
    )"
    # Dispatch on the active implementer backend (scripts/lib/implementer.sh).
    # This session edits (-f for cursor; acceptEdits for claude), so unlike
    # write_run_feedback above a cursor failure here is not merely advisory —
    # but it still gets NO retry/fallback machinery of its own: the existing
    # gate below (dirty-tree check, then isolated re-validation) already
    # `git reset --hard`s back to the pre-fix tip on any failure, cursor
    # crashes and stalls included, so degrading through that gate is
    # sufficient without duplicating invoke_primary's cursor retry/fallback.
    if implement_backend_active; then
      (cd "$project" && printf '%s' "$fix_prompt" |
        cursor-agent -p --output-format json --model "$CURSOR_IMPLEMENT_MODEL" --trust -f --add-dir "$out") \
        >"$out/fix-session-$cycles.json" 2>"$out/fix-session-$cycles.err" || true
    else
      # claude_model_args intentionally word-splits, same idiom as
      # sweep_run/invoke_observer_once. The sweep_fix step model
      # (SWEEP_FIX_MODEL, empty follows IMPLEMENT_MODEL) comes from the shared
      # step_model table.
      # shellcheck disable=SC2046
      (cd "$project" && printf '%s' "$fix_prompt" |
        claude -p $(claude_model_args "$(step_model sweep_fix)") \
        --add-dir "$out" --permission-mode acceptEdits --output-format json) \
        >"$out/fix-session-$cycles.json" 2>"$out/fix-session-$cycles.err" || true
    fi
    emit_event sweep_fix "$(jq -cn --argjson c "$cycles" '{cycle:$c}')"
    # The fix session must commit everything it changed. A dirty tree here
    # (uncommitted edits or untracked files) means re-validation below — which
    # runs against the LIVE working tree — would green-light content that is in
    # no commit and would fail a clean checkout (the untracked-file gap from
    # PR#46). Refuse to trust partial work: revert and stop, same as a failed
    # re-validation.
    if [ -n "$(git -C "$project" status --porcelain 2>/dev/null)" ]; then
      git -C "$project" reset --hard "$tip_before" >/dev/null 2>&1
      emit_event sweep_fix_reverted "$(jq -cn --argjson c "$cycles" '{cycle:$c, reason:"dirty_tree"}')"
      log "WARN: sweep fix cycle $cycles left the tree dirty (uncommitted/untracked) — reverted to $tip_before"
      return 0
    fi
    # Re-validation needs BOTH a spec to read commands from AND a run to run
    # them inside: run_validation_commands + run_smoke_phase write per-command
    # logs under "$RUN_ROOT/raw/..." unguarded, so a standalone --sweep-only
    # invocation (SPEC may be set via --spec, but there is no RUN_ROOT — no
    # run/queue at all) would crash on an unbound variable rather than skip
    # cleanly. Revalidation is in-run-only; --sweep-only never revalidates.
    vcmds=""
    if [ -n "${SPEC:-}" ] && [ -n "${RUN_ROOT:-}" ]; then
      # Same trust point as verify_candidate's final-validation re-read, for the
      # same reason: the fix session above just had unattended write access to
      # the workspace, and these commands decide whether its commits survive.
      # Re-reading the spec here without the guard left the identical weakening
      # vector open on this path. Anchored in initialize_run / recover_run /
      # start_next_task; unreachable from --sweep-only (no RUN_ROOT).
      integrity_guard "$SPEC" spec "the spec whose Final validation commands gate the sweep fix cycle"
      vcmds="$(extract_validation_commands "$SPEC" "Final validation commands")"
    fi
    # Isolated (worktree) re-validation + smoke re-run at the fixed tip — parity
    # with verify_candidate's final gate, never the live tree. A failure or an
    # un-buildable worktree reverts to the pre-fix tip.
    if [ -n "${RUN_ROOT:-}" ] && { [ -n "$vcmds" ] || [ -f "$RUN_ROOT/validated/smoke-baseline.json" ]; }; then
      if ! sweep_revalidate_isolated "$project" "$out" "$cycles" "$vcmds"; then
        git -C "$project" reset --hard "$tip_before" >/dev/null
        emit_event sweep_fix_reverted "$(jq -cn --argjson c "$cycles" '{cycle:$c, reason:"revalidation"}')"
        log "WARN: sweep fix cycle $cycles failed isolated re-validation — reverted to $tip_before"
        return 0
      fi
    fi
    # Rebuild the package before re-reviewing: the fix session added commits, so
    # the pre-fix package.diff no longer describes HEAD. Without this the re-sweep
    # (which is told the package IS the authoritative scope) re-reads stale code,
    # re-reports the same findings, and never sees the fix — leaving the verdict
    # stuck at SWEEP_FINDINGS on a genuinely-fixed branch.
    sweep_build_package "$project" "$out" >/dev/null 2>&1 || return 0
    sweep_run "$project" "$out"
    [ "$(cat "$out/verdict.txt")" = "SWEEP_FINDINGS" ] || return 0
  done
  log "branch sweep: residual findings after $cycles fix cycle(s) — see $out/findings.md"
  return 0
}
