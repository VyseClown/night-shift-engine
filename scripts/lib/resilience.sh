# shellcheck shell=bash
# scripts/lib/resilience.sh
# Self-recovery primitives for the paid Claude calls: a portable wall-clock
# guard around one `claude -p` (a hung CLI or MCP otherwise holds the run open
# past every budget — the stage/task caps are only evaluated BETWEEN turns),
# pre-minted session ids so a killed attempt stays resumable, and the
# failure-classification helpers invoke_primary's bounded retry uses.
# Sourced by night-shift.sh; uses STATE, MAX_STAGE_SECONDS, TURN_TIMEOUT and
# now_epoch at runtime. Pure/portable: bash 3.2, GNU or BSD userland, no
# GNU `timeout` dependency.

# Run a command under a wall-clock deadline of $1 seconds (0 = no guard).
#
# Deliberately NOT GNU `timeout`: it setpgid()s its child into a new process
# group, so every pgid-based kill in the engine (reap_persona_workers, the
# block_run/Ctrl-C paths) would stop reaching a running session — orphaned
# paid reviews billing to the deadline. Instead the command is backgrounded
# in THIS process group (job control forced off for the spawn, so no new
# group), a watchdog subshell TERMs then KILLs it at the deadline, and an
# INT/TERM/HUP of this shell is forwarded to the child (an async child
# ignores SIGINT when job control is off — without the forward, Ctrl-C would
# orphan the primary). The explicit `<&0` keeps stdin: an async command's
# stdin otherwise defaults to /dev/null, and every call site pipes the
# prompt in. The watchdog also signals the child's own children (pkill -P,
# best-effort): the motivating hang is a wedged MCP server the CLI spawned,
# and a TERM to the CLI alone can leave it running. A shell FUNCTION named
# by $2 (the fixture suite's `claude()` stubs) is run directly — a test seam
# never hangs. Exit status on a deadline kill: 143 (TERM) or 137 (KILL);
# turn_timeout_hit recognizes both plus the external-wrapper shapes 124/142.
run_with_turn_timeout() {
  local secs="$1"; shift
  case "$secs" in ''|*[!0-9]*|0) "$@"; return ;; esac
  if [ "$(type -t "$1" 2>/dev/null)" = "function" ]; then "$@"; return; fi
  local had_m=0 pid wd rc=0
  case "$-" in *m*) had_m=1 ;; esac
  set +m
  "$@" <&0 &
  pid=$!
  (
    sp=""
    trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; exit 0' TERM INT HUP
    sleep "$secs" & sp=$!
    wait "$sp"
    ! command -v pkill >/dev/null 2>&1 || pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    # The grace period is an interruptible job too, so the parent's TERM to
    # this watchdog (right after the child is reaped) ends it immediately
    # instead of stalling every deadline kill by the full grace.
    sleep 5 & sp=$!
    wait "$sp"
    ! command -v pkill >/dev/null 2>&1 || pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  ) &
  wd=$!
  # shellcheck disable=SC2064  # $pid is expanded NOW on purpose: it is the child to forward the signal to
  trap "turn_interrupt_child $pid" INT TERM HUP
  wait "$pid" || rc=$?
  # An interrupt returns from `wait` before the child has exited; wait again
  # so the caller (block_run's cleanup, a state write) never runs alongside a
  # session still writing into the project. turn_interrupt_child armed a
  # KILL timer, so this wait is bounded.
  [ "$rc" -lt 128 ] || wait "$pid" 2>/dev/null || true
  trap - INT TERM HUP
  kill -TERM "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$had_m" -eq 0 ] || set -m
  return "$rc"
}

# The forwarding trap's body: TERM the child and its own children (a wedged
# MCP server), with a bounded KILL escalation so an interrupt can never hang
# on a TERM-ignoring session.
turn_interrupt_child() {
  local pid="$1"
  ! command -v pkill >/dev/null 2>&1 || pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  ( sleep 5; ! command -v pkill >/dev/null 2>&1 || pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null ) &
}

# Pure: exit 0 when an exit status is one of the shapes a killed turn leaves.
turn_timeout_hit() {
  case "${1:-0}" in 124|137|142|143) return 0 ;; esac
  return 1
}

# Seconds left in the CURRENT stage's time budget (may be negative once it is
# spent). Reads .stage_started_at from STATE; without a usable value reports
# the whole budget.
stage_seconds_remaining() {
  local started="" now
  # state_int is the engine's validated reader; a missing/corrupt clock is
  # DELIBERATELY lenient here (whole budget) rather than a block: this feeds a
  # deadline, and enforce_limits — which does block on corrupt state — runs
  # before every turn anyway.
  if command -v state_int >/dev/null 2>&1 && [ -f "${STATE:-}" ]; then
    started="$(state_int '.stage_started_at' 2>/dev/null)" || started=""
  fi
  case "$started" in ''|*[!0-9]*) printf '%s' "${MAX_STAGE_SECONDS:-3600}"; return 0 ;; esac
  now="$(now_epoch)"
  printf '%s' $(( ${MAX_STAGE_SECONDS:-3600} - (now - started) ))
}

# The deadline for ONE paid turn: the smaller of the per-turn cap
# (NIGHT_SHIFT_TURN_TIMEOUT, default 1800s; 0 = no per-turn cap) and the
# STAGE's remaining time budget plus a 60s grace, floored at 300s so a stage
# entered near its cap still gets a real turn. The per-turn cap is what makes
# a hang RECOVERABLE: bounded by the stage clock alone, a kill would land only
# once the budget was spent and nothing would be left to retry in (that case
# still exists — invoke_primary then blocks immediately with the real reason
# instead of sleeping into enforce_limits' generic limit block). The stage
# term keeps it from ever being a false kill: a turn that outlives its stage
# could not have produced a usable result (enforce_elapsed_limits would block
# it on return).
turn_timeout_seconds() {
  local cap="${TURN_TIMEOUT:-1800}" remaining floor=300
  remaining=$(( $(stage_seconds_remaining) + 60 ))
  case "$cap" in ''|*[!0-9]*|0) ;; *) [ "$remaining" -le "$cap" ] || remaining="$cap" ;; esac
  [ "$remaining" -ge "$floor" ] || remaining="$floor"
  printf '%s' "$remaining"
}

# Pre-mint a session id for a FRESH claude start (`--session-id`). A turn
# killed by its deadline or a crashed CLI never prints its JSON envelope, so
# without this the engine would not know the session that already edited
# files and committed, and a retry would start blind over its work. Prints a
# lowercase UUID, or returns 1 when the host has no UUID source (the caller
# then starts fresh, exactly the pre-existing behavior).
mint_session_id() {
  local id=""
  if command -v uuidgen >/dev/null 2>&1; then id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  elif [ -r /proc/sys/kernel/random/uuid ]; then id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  fi
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  printf '%s' "$id"
}

# Pure: "--session-id ID" or nothing for an empty id (word-split at the call
# site, like model_flag).
session_id_flag() {
  [ -n "${1:-}" ] || return 0
  printf -- '--session-id %s' "$1"
}

# One line naming WHY a claude turn failed, for the retry log + journal:
# the deadline, else the CLI's own error line (its JSON envelope's .result,
# then the stderr tail), else the bare exit status. $1 = rc, $2 = raw stdout
# file, $3 = stderr file, $4 = the deadline that was in force.
claude_failure_reason() {
  local rc="$1" raw="${2:-}" err="${3:-}" deadline="${4:-0}" msg=""
  if turn_timeout_hit "$rc"; then
    printf 'turn exceeded its %ss wall-clock deadline (rc=%s)' "$deadline" "$rc"
    return 0
  fi
  [ ! -s "$raw" ] || msg="$(jq -r 'select(.is_error == true) | .result // empty' "$raw" 2>/dev/null | head -c 200)"
  [ -n "$msg" ] || [ ! -s "$err" ] || msg="$(tail -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
  [ -n "$msg" ] || msg="no error text captured"
  printf 'exit %s: %s' "$rc" "$msg"
}
