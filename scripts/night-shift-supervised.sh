#!/usr/bin/env bash
# shellcheck shell=bash
#
# night-shift-supervised.sh — run a night-shift chain with bounded auto-resume.
#
# Bare `scripts/night-shift.sh` EXITS on a block, preserving state for `--resume`,
# but it never resumes itself — so any block halts the whole chain until an
# operator intervenes. This supervisor runs the chain and, on a recoverable
# block, `--resume`s it automatically. It STOPS (escalates) only when a block
# REPEATS with no progress — the signature of a genuinely-stuck run that needs a
# human or a code fix — or when a safety cap on total resumes is hit. Rate-limit
# waits happen INSIDE the engine (it sleeps and continues), so they never reach
# this loop and never count as blocks.
#
# Usage:
#   scripts/night-shift-supervised.sh --project DIR [night-shift args…]
#
# Supervisor options (consumed here; everything else passes through to the engine):
#   --max-resumes N     safety cap on total auto-resumes (default 12)
#   --on-escalate CMD   shell command to run when the run escalates (e.g. a
#                       notification); the block reason is exported as
#                       NS_ESCALATE_REASON. Runs before exit.
#   -h, --help
#
# The first invocation passes your args straight through (so a no-`--spec` run
# auto-chains the TODO queue, exactly as a normal launch). Resumes are always
# `--project DIR --resume`.
#
# Exit: 0 when the chain completes; 3 when it escalates (stuck / cap / hard exit).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '[supervisor] %s\n' "$*" >&2; }

# shellcheck source=scripts/lib/supervisor.sh
. "$SCRIPT_DIR/lib/supervisor.sh"

# ---- args: split supervisor flags from engine pass-through ------------------
PROJECT="" MAX_RESUMES=12 ON_ESCALATE=""
PASS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)      PROJECT="${2:-}"; PASS+=("$1" "${2:-}"); shift 2 ;;
    --max-resumes)  MAX_RESUMES="${2:-}"; shift 2 ;;
    --on-escalate)  ON_ESCALATE="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '4,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              PASS+=("$1"); shift ;;
  esac
done

[ -n "$PROJECT" ] || { log "ERROR: --project is required"; exit 2; }
case "$MAX_RESUMES" in ''|*[!0-9]*) log "ERROR: --max-resumes must be an integer"; exit 2 ;; esac
# The engine to drive; override for testing. Default is the sibling night-shift.sh.
ENGINE="${NIGHT_SHIFT_ENGINE:-$SCRIPT_DIR/night-shift.sh}"

state_field() {
  local sd="$PROJECT/.night-shift/state.json"
  [ -f "$sd" ] || { printf ''; return 0; }
  jq -r --arg f "$1" '.[$f] // empty' "$sd" 2>/dev/null
}
# A token that changes whenever the run makes real progress: the feature-branch
# HEAD (advances on each candidate commit) plus the current task (advances when
# the chain moves to the next spec).
progress_token() {
  printf '%s|%s' "$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || echo none)" "$(state_field task)"
}
escalate() {
  log "ESCALATE — $*"
  log "  the run is preserved; inspect $PROJECT/.night-shift, then resume manually with:"
  log "    scripts/night-shift.sh --project $PROJECT --resume"
  if [ -n "$ON_ESCALATE" ]; then
    NS_ESCALATE_REASON="$*" bash -c "$ON_ESCALATE" || log "  (--on-escalate command failed)"
  fi
  exit 3
}

# ---- supervise --------------------------------------------------------------
log "starting supervised run (max-resumes=$MAX_RESUMES) — engine args: ${PASS[*]}"
"$ENGINE" "${PASS[@]}"; rc=$?

last_reason="" last_progress="" resumes=0
while [ "$rc" -ne 0 ]; do
  reason="$(state_field block_reason)"
  [ -n "$reason" ] && [ "$reason" != "null" ] ||
    escalate "engine exited $rc with no preserved block (a hard error, not a resumable block)"
  progress="$(progress_token)"
  case "$(supervisor_next "$reason" "$progress" "$last_reason" "$last_progress" "$resumes" "$MAX_RESUMES")" in
    escalate:stuck)
      escalate "same block twice with no progress — genuinely stuck: \"$reason\"" ;;
    escalate:resume-cap-*)
      escalate "hit the auto-resume cap ($MAX_RESUMES); last block: \"$reason\"" ;;
  esac
  last_reason="$reason"; last_progress="$progress"; resumes=$((resumes + 1))
  log "auto-resume #$resumes (block: \"$reason\")"
  "$ENGINE" --project "$PROJECT" --resume; rc=$?
done

log "run completed cleanly (exit 0) after $resumes auto-resume(s)."
