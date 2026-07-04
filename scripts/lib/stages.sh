# shellcheck shell=bash
# scripts/lib/stages.sh
# The stage machine + turn/time budgets: enforce_limits / enforce_elapsed_limits
# (pre- and post-turn budget gates) and set_stage (the ONLY stage-transition
# verb — fresh per-entry wall clocks, session-scope boundary clearing, per-scope
# review-round reset, and the stage_transition journal event). Sourced by
# night-shift.sh; uses STATE, MAX_* caps, SESSION_SCOPE, state_set/state_int,
# session_boundary/stage_session_scope, block_run, log and emit_event from the
# orchestrator at runtime.

enforce_limits() {
  local now stage_elapsed task_elapsed stage_turns task_turns
  local stage_started task_started
  now="$(now_epoch)"
  # Validate each field into a local before doing arithmetic or comparisons.
  # state_int returns non-zero on null/corrupt input; a plain assignment's exit
  # status IS the $(...) exit status, so || fires in THIS shell — block_run is
  # reached in the parent, not swallowed by a subshell.  Declare locals
  # separately from the guarded assignments so `local x="$(...)"` does not
  # mask the exit status (local always returns 0 in bash/dash/sh).
  stage_started="$(state_int '.stage_started_at')" ||
    block_run "state field .stage_started_at is not a valid integer; state may be corrupt"
  task_started="$(state_int '.task_started_at')" ||
    block_run "state field .task_started_at is not a valid integer; state may be corrupt"
  stage_turns="$(state_int '.stage_turns')" ||
    block_run "state field .stage_turns is not a valid integer; state may be corrupt"
  task_turns="$(state_int '.task_turns')" ||
    block_run "state field .task_turns is not a valid integer; state may be corrupt"
  stage_elapsed=$((now - stage_started))
  task_elapsed=$((now - task_started))
  if limit_exceeded "$stage_turns" "$stage_elapsed" "$task_turns" "$task_elapsed"; then
    block_run "turn/time limit reached (stage ${stage_turns}/${MAX_STAGE_TURNS}, task ${task_turns}/${MAX_TASK_TURNS})"
  fi
}

enforce_elapsed_limits() {
  local now stage_elapsed task_elapsed
  local stage_started task_started
  now="$(now_epoch)"
  # Same pattern as enforce_limits: validate into locals first, then do
  # arithmetic on the validated values in the parent shell.
  stage_started="$(state_int '.stage_started_at')" ||
    block_run "state field .stage_started_at is not a valid integer; state may be corrupt"
  task_started="$(state_int '.task_started_at')" ||
    block_run "state field .task_started_at is not a valid integer; state may be corrupt"
  stage_elapsed=$((now - stage_started))
  task_elapsed=$((now - task_started))
  if [ "$stage_elapsed" -ge "$MAX_STAGE_SECONDS" ] ||
    [ "$task_elapsed" -ge "$MAX_TASK_SECONDS" ]; then
    block_run "time limit reached after the completed primary turn"
  fi
}

set_stage() {
  # Each stage ENTRY gets a fresh wall-clock start, so the per-stage time budget
  # measures time in this entry — not stale time from an earlier visit (stages
  # are re-entered on review blocks, and a long run/resume gap would otherwise
  # restore an ancient start and trip the elapsed limit immediately). Turn counts
  # still accumulate per stage via stage_counters.
  local old_stage session_clear='' scope_reset=''
  old_stage="$(jq -r '.stage' "$STATE")"
  # Crossing a session-scope boundary clears the pinned session so the next
  # primary turn starts fresh and hands off through files (see SESSION_SCOPE).
  if session_boundary "$old_stage" "$1" "$SESSION_SCOPE"; then
    session_clear=' | .session_id=null'
    log "stage $old_stage → $1: starting a fresh stage session"
  fi
  # Persona review rounds are numbered PER stage scope: run_personas writes/reads
  # round-$((review_round+1)) and the primary writes the latest round of the
  # current stage. review_round must therefore reset to 0 when the stage SCOPE
  # changes — otherwise a plan re-review round leaves the counter ahead, so the
  # implementation gate reads an empty round-N dir the primary never wrote to (its
  # results are in round-1) and blocks; --resume only bumps the counter further.
  # Scope-based (via stage_session_scope), not session-based, so it also holds in
  # SESSION_SCOPE=run. Carried re-review pending belongs to the old scope, so drop
  # it too. (GH #18)
  if [ "$(stage_session_scope "$old_stage")" != "$(stage_session_scope "$1")" ]; then
    scope_reset=' | .review_round=0 | del(.pending_personas, .pending_stage)'
  fi
  state_set "
    .stage_counters[.stage]=.stage_turns |
    .stage=\$stage |
    .stage_turns=(.stage_counters[\$stage] // 0) |
    .stage_started_at=\$epoch |
    .stage_started[\$stage]=\$epoch |
    .updated_at=\$now${session_clear}${scope_reset}
  " \
    --arg stage "$1" --argjson epoch "$(now_epoch)" --arg now "$(now_iso)"
  emit_event stage_transition "$(jq -cn --arg from "$old_stage" --arg to "$1" \
    --argjson sc "$([ -n "$session_clear" ] && printf true || printf false)" \
    '{from:$from, to:$to, session_cleared:$sc}')"
}
