# shellcheck shell=bash
# scripts/lib/events.sh
# The run's decision journal. emit_event appends one compact JSON line —
# {ts, run, stage, type, payload} — to $RUN_ROOT/events.jsonl at every decision
# point: run start/recovery, stage transitions, accepted AND rejected signals
# (with the rejection reason), persona verdicts with attempt counts and retry
# reasons, worker reaps, candidate validation, observer verdicts, integrity
# violations, rate-limit waits, session refreshes, block and completion. The
# journal exists so a finished (or wrecked) run can be replayed
# decision-by-decision afterwards; it is ADDITIVE to the human log lines, never
# a replacement, and is archived on success alongside costs.jsonl.
#
# Sourced by night-shift.sh; uses now_iso and the RUN_ROOT/RUN_ID/STATE globals
# at runtime. Safe as a no-op before a run is initialized. The payload is
# parsed as JSON when possible and recorded as a plain string otherwise —
# emitting must never fail the engine.
emit_event() {
  local type="$1" payload="${2:-null}" stage=""
  [ -n "${RUN_ROOT:-}" ] && [ -n "${RUN_ID:-}" ] || return 0
  [ ! -f "${STATE:-}" ] || stage="$(jq -r '.stage // empty' "$STATE" 2>/dev/null)" || stage=""
  jq -cn --arg ts "$(now_iso)" --arg run "$RUN_ID" --arg stage "$stage" --arg type "$type" \
    --argjson payload "$payload" \
    '{ts:$ts, run:$run, stage:$stage, type:$type, payload:$payload}' \
    >>"$RUN_ROOT/events.jsonl" 2>/dev/null ||
    jq -cn --arg ts "$(now_iso)" --arg run "$RUN_ID" --arg stage "$stage" --arg type "$type" \
      --arg payload "$payload" \
      '{ts:$ts, run:$run, stage:$stage, type:$type, payload:$payload}' \
      >>"$RUN_ROOT/events.jsonl" 2>/dev/null || true
}
