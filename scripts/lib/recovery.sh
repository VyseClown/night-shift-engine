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
