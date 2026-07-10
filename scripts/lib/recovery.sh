# shellcheck shell=bash
# shellcheck disable=SC2153
# ^ STATE is the orchestrator's run-state path global (night-shift.sh), not a
#   misspelling of a local `state`; this lib reads it at runtime.
# scripts/lib/recovery.sh
# Rate-limit detection + reset-time math, and run-recovery state predicates.
# Sourced by night-shift.sh; uses now_iso/now_epoch/log/block_run and the STATE
# global (+ RATE_LIMIT_MAX_WAIT_SECONDS) at runtime from the orchestrator.

# Recognizes Claude's structured session-limit response: HTTP 429 plus a result
# string carrying a 12-hour clock reset time and an IANA (slash) timezone, e.g.
# "...resets 5:40am (America/Sao_Paulo)". This is deliberately strict: anything
# we cannot parse with confidence (abbreviated timezones like "UTC"/"PST",
# 24-hour times, or weekly limits phrased as a weekday) returns false, so the
# caller falls through to block_run for safe manual resume rather than guessing.
# NOTE: the .api_error_status field name and message wording are the live CLI
# contract — verify against a real 429 capture if the CLI version changes.
is_rate_limit_response() {
  local raw="$1"
  jq -e '
    .api_error_status == 429 and
    (.result | type == "string" and
      test("resets [0-9]{1,2}:[0-9]{2}(am|pm) \\([A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+\\)"))
  ' "$raw" >/dev/null 2>&1
}

# Recognizes the OTHER live 429 shape: a PER-MODEL usage cap ("You've reached
# your <Model> limit. Run /usage-credits to continue or switch models with
# /model."). Unlike the session limit it carries NO reset timestamp, which is
# exactly why is_rate_limit_response rejects it — waiting on a parsed reset is
# impossible, only a model switch (or the quota window) clears it. Deliberately
# mutually exclusive with is_rate_limit_response so the battle-tested
# session-limit wait path can never be shadowed: a response matching BOTH
# phrasings is treated as a session limit.
is_per_model_limit_response() {
  local raw="$1"
  is_rate_limit_response "$raw" && return 1
  jq -e '
    .is_error == true and
    .api_error_status == 429 and
    (.result | type == "string" and test("reached your .* limit"; "i"))
  ' "$raw" >/dev/null 2>&1
}

# Pure: the model to fall back to when a per-model usage cap hits. The ladder
# only ever steps DOWN in scarcity (fable -> opus -> sonnet) so a fallback can
# never burn a scarcer budget than the one that just capped. sonnet (and any
# unknown name) has no successor: echo unchanged + return 1, and the caller
# blocks for manual resume rather than guessing.
successor_model() {
  case "$1" in
    claude-fable-5|fable*) printf 'opus' ;;
    opus|opus-*|claude-opus-*) printf 'sonnet' ;;
    *) printf '%s' "$1"; return 1 ;;
  esac
}

# Map a configured model through the run's persisted `.model_fallbacks` in
# state (written by handle_per_model_limit under NIGHT_SHIFT_MODEL_FALLBACK=1),
# so every consumer of a model knob — primary, personas, observer, port-audit —
# honors a fallback recorded earlier in the run. Follows chains (fable->opus
# recorded, then opus->sonnet later) with a small hop bound so a corrupt cyclic
# map cannot loop. No state / no mapping -> echoes the input unchanged.
resolve_effective_model() {
  local model="$1" mapped hops=0
  [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ] || { printf '%s' "$model"; return 0; }
  while [ "$hops" -lt 4 ]; do
    mapped="$(jq -r --arg m "$model" '.model_fallbacks[$m] // empty' "$STATE" 2>/dev/null)"
    { [ -n "$mapped" ] && [ "$mapped" != "$model" ]; } || break
    model="$mapped"
    hops=$((hops + 1))
  done
  printf '%s' "$model"
}

rate_limit_reset_fields() {
  local raw="$1"
  jq -r '.result // empty' "$raw" 2>/dev/null |
    sed -nE 's/.*resets ([0-9]{1,2}):([0-9]{2})(am|pm) \(([A-Za-z0-9._+-]+(\/[A-Za-z0-9._+-]+)+)\).*/\1|\2|\3|\4/p'
}

epoch_clock_fields() {
  local epoch="$1" timezone="$2"
  TZ="$timezone" date -r "$epoch" '+%H|%M|%S' 2>/dev/null ||
    TZ="$timezone" date -d "@$epoch" '+%H|%M|%S' 2>/dev/null
}

rate_limit_reset_epoch() {
  local raw="$1" reference_epoch="$2" fields hour minute meridiem timezone
  local current_fields current_hour current_minute current_second target_minutes current_minutes delta
  local old_ifs
  fields="$(rate_limit_reset_fields "$raw")"
  [ -n "$fields" ] || return 1
  old_ifs="$IFS"; IFS='|'
  read -r hour minute meridiem timezone <<EOF
$fields
EOF
  IFS="$old_ifs"
  case "$hour:$minute:$meridiem" in
    [1-9]:[0-5][0-9]:am|[1-9]:[0-5][0-9]:pm|1[0-2]:[0-5][0-9]:am|1[0-2]:[0-5][0-9]:pm) ;;
    *) return 1 ;;
  esac
  hour=$((10#$hour))
  minute=$((10#$minute))
  [ "$meridiem" = "am" ] && [ "$hour" -eq 12 ] && hour=0
  [ "$meridiem" = "pm" ] && [ "$hour" -ne 12 ] && hour=$((hour + 12))
  current_fields="$(epoch_clock_fields "$reference_epoch" "$timezone")" || return 1
  old_ifs="$IFS"; IFS='|'
  read -r current_hour current_minute current_second <<EOF
$current_fields
EOF
  IFS="$old_ifs"
  current_hour=$((10#$current_hour))
  current_minute=$((10#$current_minute))
  current_second=$((10#$current_second))
  target_minutes=$((hour * 60 + minute))
  current_minutes=$((current_hour * 60 + current_minute))
  delta=$((target_minutes - current_minutes))
  [ "$delta" -ge 0 ] || delta=$((delta + 1440))
  printf '%s\n' $((reference_epoch - current_second + delta * 60))
}

file_mtime_epoch() {
  # GNU first (Linux/CI), then BSD (macOS). Order matters: GNU `stat -f` means
  # `--file-system` and treats `%m` as an unknown specifier — it prints the literal
  # "%m" and EXITS 0, so a BSD-first `stat -f '%m' || stat -c '%Y'` never reaches the
  # GNU fallback and poisons the caller with non-numeric junk. The numeric guard is
  # belt-and-suspenders: any non-integer result fails the function so the caller's
  # `|| now_epoch` fallback fires.
  local m
  m="$(stat -c '%Y' "$1" 2>/dev/null)" || m="$(stat -f '%m' "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$m" ;; esac
}

recoverable_rate_limit_state() {
  local state="$1" raw="$2" status session emitted
  [ -f "$state" ] && [ -f "$raw" ] || return 1
  status="$(jq -r '.status' "$state")"
  case "$status" in blocked|waiting) ;; *) return 1 ;; esac
  is_rate_limit_response "$raw" || return 1
  session="$(jq -r '.session_id // empty' "$state")"
  emitted="$(jq -r '.session_id // empty' "$raw")"
  [ -n "$session" ] && [ "$emitted" = "$session" ] || return 1
  if [ "$status" = "blocked" ] && [ "$(jq -r '.rate_limit_reset_at // empty' "$state")" = "" ]; then
    case "$(jq -r '.block_reason // empty' "$state")" in
      "primary command failed with status "*) ;;
      *) return 1 ;;
    esac
  fi
}

# True when an explicit `--resume` may re-enter a logic-blocked run: status is
# "blocked", it is NOT a rate-limit block (no rate_limit_reset_at), and a session_id
# is present. The primary match is enforced by the caller. Operator-gated — never
# consulted unless --resume was passed, so a recurring block cannot auto-loop.
resumable_blocked_state() {
  local state="$1"
  [ "$(jq -r '.status' "$state")" = "blocked" ] || return 1
  [ "$(jq -r '.rate_limit_reset_at // empty' "$state")" = "" ] || return 1
  [ -n "$(jq -r '.session_id // empty' "$state")" ] || return 1
}

wait_for_rate_limit_reset() {
  local raw="$1" reference reset_epoch deadline now wait_seconds stage_active task_active
  reference="$(file_mtime_epoch "$raw")" || reference="$(now_epoch)"
  reset_epoch="$(rate_limit_reset_epoch "$raw" "$reference")" ||
    block_run "Claude returned HTTP 429 but its reset time could not be parsed"
  deadline=$((reset_epoch + RATE_LIMIT_BUFFER_SECONDS))
  now="$(now_epoch)"
  wait_seconds=$((deadline - now))
  [ "$wait_seconds" -gt 0 ] || wait_seconds=0
  # Guard against a misparsed reset time producing a runaway sleep (e.g. a
  # day-rollover on bad input). Block for manual resume instead.
  [ "$wait_seconds" -le "$RATE_LIMIT_MAX_WAIT_SECONDS" ] ||
    block_run "computed rate-limit wait ${wait_seconds}s exceeds the ${RATE_LIMIT_MAX_WAIT_SECONDS}s cap; reset time likely misparsed — resume manually once the limit clears"
  # Capture the ACTIVE elapsed (now - started_at) before waiting. On resume we
  # rebase started_at to now-minus-this, so neither the wait nor any offline gap
  # (a killed-and-recovered process) is counted against the stage/task time caps.
  # Prefer values already recorded on a prior entry, since recovery re-enters here
  # with a stale started_at.
  stage_active="$(jq -r '.rate_limit_stage_elapsed // empty' "$STATE")"
  task_active="$(jq -r '.rate_limit_task_elapsed // empty' "$STATE")"
  if [ -z "$stage_active" ] || [ -z "$task_active" ]; then
    # Route through state_int: a null/corrupt started_at would otherwise
    # silently produce garbage arithmetic under no set -e, disabling the cap.
    # Validate into locals first — state_int returns non-zero on bad input, and
    # a simple assignment's exit status propagates from the $(...), so || fires
    # in THIS shell (not a subshell), which is what block_run requires.
    local stage_started task_started
    stage_started="$(state_int '.stage_started_at')" ||
      block_run "state field .stage_started_at is not a valid integer; state may be corrupt"
    task_started="$(state_int '.task_started_at')" ||
      block_run "state field .task_started_at is not a valid integer; state may be corrupt"
    stage_active=$((now - stage_started))
    task_active=$((now - task_started))
    [ "$stage_active" -ge 0 ] || stage_active=0
    [ "$task_active" -ge 0 ] || task_active=0
  fi
  state_set '
    .status="waiting" |
    .rate_limit_reset_at=$reset |
    .rate_limit_stage_elapsed=$se |
    .rate_limit_task_elapsed=$te |
    .updated_at=$iso
  ' --argjson reset "$reset_epoch" --argjson se "$stage_active" \
    --argjson te "$task_active" --arg iso "$(now_iso)"
  if [ "$wait_seconds" -gt 0 ]; then
    log "Claude session limit reached; waiting ${wait_seconds}s until reset plus ${RATE_LIMIT_BUFFER_SECONDS}s buffer"
    sleep "$wait_seconds"
  else
    log "Claude session limit reset has passed; retrying the pinned session now"
  fi
  # Rebase budgets: only active time counts, regardless of wait/offline duration.
  now="$(now_epoch)"
  state_set '
    .status="running" |
    .stage_started_at=($now - $se) |
    .task_started_at=($now - $te) |
    .stage_started[.stage]=($now - $se) |
    del(.block_reason,.rate_limit_reset_at,.rate_limit_stage_elapsed,.rate_limit_task_elapsed,.rate_limit_budget_paused_until) |
    .updated_at=$iso
  ' --argjson now "$now" --argjson se "$stage_active" \
    --argjson te "$task_active" --arg iso "$(now_iso)"
}

# The session-limit 429 wait path, extracted verbatim from invoke_primary's
# retry loop (behavior-preserving refactor; this path recovered real 429s in
# production — do not change its behavior). Increments the PERSISTED
# consecutive-429 counter (state carries it across crashes and across loop
# iterations — invoke_primary persists it every pass, so re-reading here equals
# the old local), blocks at the cap to prevent an infinite sleep-and-retry
# spiral, pins the emitted session, journals the wait, and sleeps until the
# reported reset. $1 = the raw 429 JSON response file. $2 = mode, "primary"
# (default, backward compat) or "subagent". The counter/cap/event/wait happen
# in BOTH modes; the `.session_id` PIN happens only in primary mode. A
# sub-agent call site (handle_persona_rate_limits, validated_observer_retry)
# passes a persona/observer raw whose session_id belongs to the REVIEWER, not
# the primary — pinning it into `.session_id` would contaminate the primary's
# pinned session (the next `--resume` would continue the primary inside a
# reviewer's session). In subagent mode the caller re-pins its own local
# variable to the raw's session_id and retries; state's `.session_id` (the
# primary's) is left untouched.
handle_rate_limit_wait() {
  local raw="$1" mode="${2:-primary}" rate_limit_cap=5 consecutive_429 emitted
  consecutive_429="$(jq -r '.rate_limit_consecutive // 0' "$STATE" 2>/dev/null)"
  is_valid_int "$consecutive_429" || consecutive_429=0
  consecutive_429=$((consecutive_429 + 1))
  # Guard against an infinite sleep spiral: if the rate limit is not
  # clearing after $rate_limit_cap consecutive resets with no successful
  # turn in between, block for manual resume. This catches a misbehaving
  # session that keeps hitting the limit after each wait completes.
  [ "$consecutive_429" -lt "$rate_limit_cap" ] ||
    block_run "rate limit not clearing after $consecutive_429 consecutive resets; resume manually once the limit clears"
  if [ "$mode" = "primary" ]; then
    emitted="$(jq -r '.session_id // empty' "$raw" 2>/dev/null)"
    state_set '.session_id=$session | .rate_limit_consecutive=$n | .updated_at=$now' \
      --arg session "$emitted" --argjson n "$consecutive_429" --arg now "$(now_iso)"
  else
    state_set '.rate_limit_consecutive=$n | .updated_at=$now' \
      --argjson n "$consecutive_429" --arg now "$(now_iso)"
  fi
  emit_event rate_limit_wait "$(jq -cn --argjson n "$consecutive_429" '{consecutive:$n}')"
  wait_for_rate_limit_reset "$raw"
}

# A PER-MODEL usage cap (is_per_model_limit_response) has no reset time to wait
# on, so the wait path above cannot help — this is the incident where a run
# pinned to a per-model-capped model hard-blocked and --resume could not escape.
# Default posture: block with an actionable reason (name the capped model, quote
# the CLI's own line, say which knob to change). Opt-in via
# NIGHT_SHIFT_MODEL_FALLBACK=1: record the fallback in state's .model_fallbacks
# map (resolve_effective_model consults it for every model consumer), null the
# session (the next turn starts FRESH on the successor — a resume would re-pin
# the capped model), journal a model_fallback event, and return 0 so the caller
# retries. No successor (sonnet is the floor) still blocks.
# $3 = mode, "primary" (default, backward compat) or "subagent". The
# `.model_fallbacks` record + event happen in BOTH modes (every model consumer
# must see the fallback); the `.session_id=null` happens ONLY in primary mode —
# a sub-agent call site (handle_persona_rate_limits, validated_observer_retry)
# passes a persona/observer raw, and unconditionally nulling `.session_id`
# there would force-refresh the PRIMARY's session for no reason (the sub-agent
# path re-spawns its own fresh worker regardless).
handle_per_model_limit() {
  local raw="$1" model="$2" mode="${3:-primary}" line successor
  line="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  if [ "${NIGHT_SHIFT_MODEL_FALLBACK:-0}" != "1" ]; then
    block_run "per-model usage cap hit on model '$model' ($line); set the affected NIGHT_SHIFT_*_MODEL knob to another model (e.g. opus) and re-run with --resume, or wait for the model's quota"
  fi
  successor="$(successor_model "$model")" ||
    block_run "per-model usage cap hit on model '$model' ($line); NIGHT_SHIFT_MODEL_FALLBACK=1 but '$model' has no fallback successor — set the affected NIGHT_SHIFT_*_MODEL knob to another model (e.g. opus) and re-run with --resume, or wait for the model's quota"
  if [ "$mode" = "primary" ]; then
    state_set '.model_fallbacks[$from]=$to | .session_id=null | .updated_at=$now' \
      --arg from "$model" --arg to "$successor" --arg now "$(now_iso)"
  else
    state_set '.model_fallbacks[$from]=$to | .updated_at=$now' \
      --arg from "$model" --arg to "$successor" --arg now "$(now_iso)"
  fi
  emit_event model_fallback "$(jq -cn --arg from "$model" --arg to "$successor" '{from:$from,to:$to}')"
  log "per-model usage cap on '$model'; falling back to '$successor' (NIGHT_SHIFT_MODEL_FALLBACK=1) with a fresh session"
}
