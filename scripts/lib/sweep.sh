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
# so this is a short FRESH `claude -p` session, same idiom as sweep_run, fed
# the spec path + the tail of events.jsonl + the review-round count rather
# than asked to explore the repo itself.
# Every failure mode (no run context, session error, empty/unparsable reply,
# no bullet lines, an unwritable feedback.md) warns and returns 0 — feedback
# must never block or delay completion. Guards every run-scoped global with
# ${VAR:-} (set -u is in effect for the whole orchestrator).
write_run_feedback() {
  local project="$1" out feedback model raw rc=0 tail_events round result bullets lines
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
  model="$(resolve_effective_model "${IMPLEMENT_MODEL:-sonnet}")"
  raw="$out/session.json"
  # model_flag intentionally word-splits into `--model X` (or nothing); same
  # idiom as sweep_run/invoke_observer_once.
  # shellcheck disable=SC2046
  (cd "$project" && {
    printf 'Spec: %s\n' "$SPEC"
    printf 'Review rounds completed: %s\n\n' "$round"
    printf 'Write 5-15 bullet lines of feedback for the human who authors specs and\n'
    printf 'runs this engine: spec ambiguities you can infer from the journal below,\n'
    printf 'stages that looped, validation friction, anything a better spec would\n'
    printf 'have prevented. Plain `- ` bullets only, no headings.\n\n'
    printf '## events.jsonl (last 200 lines)\n%s\n' "$tail_events"
  } | claude -p $(model_flag "$model") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARN: run feedback session failed (rc=$rc; see $raw.err)"
    return 0
  fi
  result="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  [ -n "$result" ] || {
    log "WARN: run feedback skipped (empty/unparsable claude reply, see $raw)"
    return 0
  }
  bullets="$(printf '%s\n' "$result" | grep -E '^- ')"
  [ -n "$bullets" ] || {
    log "WARN: run feedback skipped (reply had no \`- \` bullet lines, see $raw)"
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
For each finding: severity (Critical/Important/Minor), file:line, a concrete
failure scenario, and the concrete fix. End your reply with exactly one line:
either `SWEEP_PASS` or `SWEEP_FINDINGS: <count>`.
EOF
  printf '\nPackage: %s/package.diff (read it with your file tools)\n' "$out"
}

# Run the sweep session. Writes $out/findings.md + $out/verdict.txt; emits
# sweep event. Never propagates failure (advisory contract) — a session
# error yields verdict SWEEP_ERROR in verdict.txt and a warn log.
sweep_run() {
  local project="$1" out="$2" raw rc=0 model verdict
  model="$(resolve_effective_model "$SWEEP_MODEL")"
  raw="$out/session.json"
  # model_flag intentionally word-splits into `--model X` (or nothing); same
  # idiom as invoke_observer_once.
  # shellcheck disable=SC2046
  (cd "$project" && sweep_prompt "$out" |
    claude -p $(model_flag "$model") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
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
      # shellcheck disable=SC2046
      (cd "$project" && sweep_prompt "$out" |
        claude -p $(model_flag "$model") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
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
# re-validation fails: reset --hard to the recorded tip (never trust the agent
# to undo its own commits). Always returns 0 — sweep is advisory end to end.
# The verdict gate below only ever proceeds on the literal string
# "SWEEP_FINDINGS" — SWEEP_PASS (nothing to fix) and SWEEP_ERROR (nothing
# coherent to fix; the session itself failed) both fall through untouched.
sweep_fix_cycle() {
  local project="$1" out="$2" tip_before vcmds cycles=0
  [ "$(cat "$out/verdict.txt" 2>/dev/null)" = "SWEEP_FINDINGS" ] || return 0
  while [ "$cycles" -lt "$SWEEP_MAX_FIX" ]; do
    cycles=$((cycles + 1))
    tip_before="$(git -C "$project" rev-parse HEAD)"
    # The fix session's own exit status is not the gate — re-validation below
    # is (a session that "succeeds" but leaves the build red is caught the
    # same as one that crashes outright; both revert). model_flag intentionally
    # word-splits, same idiom as sweep_run/invoke_observer_once.
    # shellcheck disable=SC2046
    (cd "$project" && {
      printf 'Fix ONLY the findings below on the current branch. Commit in\n'
      printf 'logical chunks. Run the covering tests for what you change.\n\n'
      cat "$out/findings.md"
    } | claude -p $(model_flag "$(resolve_effective_model "$IMPLEMENT_MODEL")") \
      --permission-mode acceptEdits --output-format json) \
      >"$out/fix-session-$cycles.json" 2>"$out/fix-session-$cycles.err" || true
    emit_event sweep_fix "$(jq -cn --argjson c "$cycles" '{cycle:$c}')"
    # Re-validation needs BOTH a spec to read commands from AND a run to run
    # them inside: run_validation_commands writes its per-command logs under
    # "$RUN_ROOT/raw/..." unguarded, so a standalone --sweep-only invocation
    # (SPEC may be set via --spec, but there is no RUN_ROOT — no run/queue at
    # all) would crash on an unbound variable rather than skip cleanly.
    # Revalidation is in-run-only; --sweep-only never revalidates.
    vcmds=""
    if [ -n "${SPEC:-}" ] && [ -n "${RUN_ROOT:-}" ]; then
      vcmds="$(extract_validation_commands "$SPEC" "Final validation commands")"
    fi
    if [ -n "$vcmds" ]; then
      if ! run_validation_commands sweepfix "$out/revalidation-$cycles.json" "$vcmds" ||
         jq -e 'any(.[]; .exit_status != 0)' "$out/revalidation-$cycles.json" >/dev/null; then
        git -C "$project" reset --hard "$tip_before" >/dev/null
        emit_event sweep_fix_reverted "$(jq -cn --argjson c "$cycles" '{cycle:$c}')"
        log "WARN: sweep fix cycle $cycles failed re-validation — reverted to $tip_before"
        return 0
      fi
    fi
    sweep_run "$project" "$out"
    [ "$(cat "$out/verdict.txt")" = "SWEEP_FINDINGS" ] || return 0
  done
  log "branch sweep: residual findings after $cycles fix cycle(s) — see $out/findings.md"
  return 0
}
