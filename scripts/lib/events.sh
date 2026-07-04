# shellcheck shell=bash
# scripts/lib/events.sh
# The run's decision journal. emit_event appends one compact JSON line —
# {ts, run, stage, type, payload} — to $RUN_ROOT/events.jsonl at every decision
# point: run init (spec/base/branch, before the baseline gate), start,
# recovery, stage transitions, accepted AND rejected signals (with the
# rejection reason), persona verdicts with attempt counts and retry reasons,
# observer retries, worker reaps, candidate validation, observer verdicts,
# integrity violations, rate-limit waits (in-loop and recovery-path), session
# refreshes, block and completion. The journal exists so a finished (or
# wrecked) run can be replayed decision-by-decision afterwards; it is ADDITIVE
# to the human log lines (which also persist to $RUN_ROOT/run.log), never a
# replacement, and is archived on success alongside costs.jsonl and run.log.
#
# Sourced by night-shift.sh; uses now_iso and the RUN_ROOT/RUN_ID/STATE globals
# at runtime. Safe as a no-op before a run is initialized. The payload is
# parsed as JSON when possible and recorded as a plain string otherwise —
# emitting must never fail the engine.
emit_event() {
  local type="$1" payload="${2:-null}" stage="" line=""
  [ -n "${RUN_ROOT:-}" ] && [ -n "${RUN_ID:-}" ] || return 0
  [ ! -f "${STATE:-}" ] || stage="$(jq -r '.stage // empty' "$STATE" 2>/dev/null)" || stage=""
  # Build the line in memory FIRST, then append once: jq writing the file
  # directly could flush partial bytes before dying (disk full), and the
  # string-form fallback would then land on the same torn line.
  line="$(jq -cn --arg ts "$(now_iso)" --arg run "$RUN_ID" --arg stage "$stage" --arg type "$type" \
    --argjson payload "$payload" \
    '{ts:$ts, run:$run, stage:$stage, type:$type, payload:$payload}' 2>/dev/null)" ||
    line="$(jq -cn --arg ts "$(now_iso)" --arg run "$RUN_ID" --arg stage "$stage" --arg type "$type" \
      --arg payload "$payload" \
      '{ts:$ts, run:$run, stage:$stage, type:$type, payload:$payload}' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >>"$RUN_ROOT/events.jsonl" 2>/dev/null || return 0
  # Tamper-evidence: the journal sits in the agent-writable project tree just
  # like state.json, so re-anchor after every append; integrity_guard verifies
  # it at completion. No-op when the integrity lib isn't loaded (bare sourcing).
  ! command -v integrity_put >/dev/null 2>&1 || integrity_put "$RUN_ROOT/events.jsonl"
}
