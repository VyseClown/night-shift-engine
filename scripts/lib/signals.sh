# shellcheck shell=bash
# scripts/lib/signals.sh
# The primary's signal contract, end to end: archive_old_signal (one signal per
# turn), validate_signal (the schema/task/evidence gate), signal_has_valid_evidence
# + evidence_rejection_reason (the CREATE_CANDIDATE artifact checks),
# signal_rejection_reason (the exact correction feedback a rejected turn gets),
# and handle_signal (the accepted-action dispatcher). Sourced by night-shift.sh;
# uses RUN_ROOT/STATE/SPEC, the wire-contract constants (NEXT_ACTION_*,
# EXECUTION_EVIDENCE_KEYS, TEST_FIRST_KEYS), json_schema_basic,
# action_artifact_requirement, transition_allowed, resolve_artifact, the stage
# verbs and block_run/log from the orchestrator at runtime.

archive_old_signal() {
  local signal="$RUN_ROOT/control/next-action.json"
  if [ -f "$signal" ]; then
    mkdir -p "$RUN_ROOT/control/previous"
    mv "$signal" "$RUN_ROOT/control/previous/$(date -u '+%Y%m%dT%H%M%SZ').json"
  fi
}

validate_signal() {
  local signal="$RUN_ROOT/control/next-action.json"
  [ -f "$signal" ] || return 2
  json_schema_basic next-action "$signal" || return 1
  [ "$(jq -r '.task' "$signal")" = "$SPEC" ] || return 1
  # An action whose artifact requirement (per the action_artifact_requirement
  # table) is unmet is rejected HERE, where the malformed-signal correction
  # machinery feeds the reason back to the primary — not deep in the handler,
  # whose gate (kept as defense in depth) is a terminal block the primary never
  # gets to fix. A live model reliably mis-shapes the evidence on the first try
  # (exit_code for exit_status, missing task, a flat test_first); that must
  # cost a correction turn, not the run.
  case "$(action_artifact_requirement "$(jq -r '.action' "$signal")")" in
    execution-evidence) signal_has_valid_evidence "$signal" || return 1 ;;
  esac
}

# True when any artifact in the signal is a schema-valid execution-evidence file
# whose task matches the current spec (the same two checks verify_candidate makes).
signal_has_valid_evidence() {
  local signal="$1" artifact resolved
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    resolved="$(resolve_artifact "$artifact")" || continue
    if json_schema_basic execution-evidence "$resolved" &&
      [ "$(jq -r '.task' "$resolved")" = "$SPEC" ]; then
      return 0
    fi
  done <<EOF
$(jq -r '.artifacts[]' "$signal" 2>/dev/null)
EOF
  return 1
}

# Specific reason an execution-evidence file fails the schema, in check order.
evidence_rejection_reason() {
  local f="$1" keys
  if ! jq -e . "$f" >/dev/null 2>&1; then
    printf 'the file is not valid JSON'
    return 0
  fi
  keys="$(jq -c 'if type == "object" then (keys | sort) else type end' "$f")"
  if [ "$keys" != "$EXECUTION_EVIDENCE_KEYS" ]; then
    printf 'top-level keys must be EXACTLY %s; the file has %s' "$EXECUTION_EVIDENCE_KEYS" "$keys"
    return 0
  fi
  if [ "$(jq -r '.task' "$f")" != "$SPEC" ]; then
    printf '"task" must equal %s exactly' "$SPEC"
    return 0
  fi
  keys="$(jq -c '.test_first | if type == "object" then (keys | sort) else type end' "$f")"
  if [ "$keys" != "$TEST_FIRST_KEYS" ]; then
    printf '"test_first" keys must be EXACTLY %s (failing AND passing evidence, not a single exit_code/output pair); the file has %s' "$TEST_FIRST_KEYS" "$keys"
    return 0
  fi
  printf 'baseline/final_validation must be non-empty arrays of {"command","exit_status","output"} (integer exit_status >= 0), test_first needs failing_exit_status > 0 with non-empty failing_output and passing_exit_status == 0 with non-empty passing_output'
}

# Human-readable reason the last next-action signal was rejected, mirroring
# validate_signal/json_schema_basic checks in order of likelihood. Fed back into
# the correction turn (primary_prompt) so the model learns exactly what to fix —
# without it the re-prompt is indistinguishable from the original and a weaker
# model can loop the same mistake into the malformed cap.
signal_rejection_reason() {
  local signal="$1" rc="$2" keys
  if [ "$rc" -eq 2 ] || [ ! -f "$signal" ]; then
    printf 'no signal file was written to .night-shift/control/next-action.json before the turn ended'
    return 0
  fi
  if ! jq -e . "$signal" >/dev/null 2>&1; then
    printf 'the file is not valid JSON'
    return 0
  fi
  keys="$(jq -c 'if type == "object" then (keys | sort) else type end' "$signal")"
  if [ "$keys" != "$NEXT_ACTION_KEYS" ]; then
    printf 'top-level keys must be EXACTLY %s (no more, no fewer); the file has %s' "$NEXT_ACTION_KEYS" "$keys"
    return 0
  fi
  if ! jq -e --arg actions "$NEXT_ACTION_ACTIONS" '.action as $a | ($actions | split("|")) | index($a) != null' "$signal" >/dev/null 2>&1; then
    printf '"action" %s is not one of %s' "$(jq -c '.action' "$signal")" "$NEXT_ACTION_ACTIONS"
    return 0
  fi
  if [ "$(jq -r '.task' "$signal")" != "$SPEC" ]; then
    printf '"task" must equal %s exactly; the file has %s' "$SPEC" "$(jq -c '.task' "$signal")"
    return 0
  fi
  if ! jq -e '(.stage | type == "string" and length > 0) and (.reason | type == "string" and length > 0)' "$signal" >/dev/null 2>&1; then
    printf '"stage" and "reason" must both be non-empty strings'
    return 0
  fi
  if [ "$(action_artifact_requirement "$(jq -r '.action' "$signal")")" = "execution-evidence" ] &&
    ! signal_has_valid_evidence "$signal"; then
    local first resolved
    first="$(jq -r '.artifacts[0] // empty' "$signal")"
    if [ -z "$first" ]; then
      printf '%s must list the execution-evidence file in "artifacts"' "$(jq -r '.action' "$signal")"
      return 0
    fi
    if ! resolved="$(resolve_artifact "$first")"; then
      printf 'the execution-evidence artifact %s is missing from the project (or unsafe: absolute/"..")' "$first"
      return 0
    fi
    printf 'the execution-evidence artifact %s failed schema validation (%s/execution-evidence.json): %s' \
      "$first" "$SCHEMA_DIR" "$(evidence_rejection_reason "$resolved")"
    return 0
  fi
  printf '"artifacts" must be an array of unique, non-empty, project-relative paths (no absolute paths, no "..")'
}

handle_signal() {
  local signal="$RUN_ROOT/control/next-action.json" action
  action="$(jq -r '.action' "$signal")"
  log "signal: $action — $(jq -r '.reason' "$signal")"
  transition_allowed "$(jq -r '.stage' "$STATE")" "$action" ||
    block_run "action $action is invalid from stage $(jq -r '.stage' "$STATE")"
  case "$action" in
    RUN_PERSONAS) run_personas ;;
    CREATE_CANDIDATE) verify_candidate ;;
    REQUEST_OBSERVER) run_observer "$signal" ;;
    RUN_VISUAL) run_visual ;;
    NEXT_TASK)
      # NEXT_TASK is legal only from the completion stage — already enforced by the
      # transition_allowed gate above (no redundant re-check here).
      # An explicit `--spec` run is a single task — the caller (e.g. a wrapper that
      # owns cross-spec sequencing + per-spec branch routing) advances to the next
      # spec itself. Treat NEXT_TASK as COMPLETE so the run exits 0 cleanly instead
      # of trying to chain to another TODO entry whose branch isn't checked out.
      if [ "${EXPLICIT_SPEC:-0}" = "1" ]; then
        log "explicit --spec run: task complete; not chaining to the next TODO entry"
        complete_run
      else
        start_next_task
      fi
      ;;
    BLOCKED) block_run "primary reported: $(jq -r '.reason' "$signal")" ;;
    COMPLETE)
      # COMPLETE is legal only from the completion stage — enforced by the
      # transition_allowed gate above.
      complete_run
      ;;
    *) block_run "unsupported action $action" ;;
  esac
}
