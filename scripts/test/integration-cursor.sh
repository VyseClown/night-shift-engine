#!/usr/bin/env bash
# integration-cursor.sh — the cursor implementer backend (Grok via cursor-agent):
# a happy path where post-plan primary turns actually run on cursor-agent while
# plan stays claude, and a bounded-retry -> sticky-claude-fallback path when
# cursor keeps failing. Same scripted-stub approach as integration-run.sh /
# integration-adverse.sh; nothing inside the engine is mocked.
# specs/cursor-implementer-backend.md — Task 2. Exit 0 + two "ok - cursor: ..."
# lines on success.
set -uo pipefail
FAIL_PREFIX=cursor
# shellcheck source=scripts/test/integration-lib.sh
. "$(dirname "$0")/integration-lib.sh"

# ── Scenario A: cursor happy path ─────────────────────────────────────────────
# Plan stays on the claude stub (scope "plan" is always claude); implement,
# candidate creation, the observer-request turn, and completion run on the
# cursor-agent stub. NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 so a real failure (none
# expected here) would not stall the harness.
integration_setup
write_stub happy
write_cursor_stub happy
if ! NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 \
  run_engine --spec "$SPEC"; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "cursor happy-path run exited non-zero"
fi
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                     || fail "cursor happy-path status is '$status', not complete"
[ -s "$WORK/.cursor-calls" ]                                   || fail "cursor-agent stub was never invoked"
events="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$events" ] && [ -f "$events" ]                           || fail "no archived journal (cursor happy path)"
jq -e 'select(.type=="run_started") | .payload.models.implement_backend=="cursor"' \
  "$events" >/dev/null                                         || fail "run_started does not journal implement_backend:cursor"
# The plan-stage turn must have gone to the claude stub, not cursor-agent: total
# primary turns (every accepted signal) outnumber cursor's own call count.
total_turns="$(jq -c 'select(.type=="signal_accepted")' "$events" | wc -l | tr -d ' ')"
cursor_calls="$(wc -l < "$WORK/.cursor-calls" | tr -d ' ')"
[ "$cursor_calls" -gt 0 ]                                      || fail "cursor-agent handled zero primary turns"
[ "$cursor_calls" -lt "$total_turns" ]                         || fail "cursor-agent handled ALL primary turns ($cursor_calls/$total_turns); the plan turn should have stayed on claude"
printf 'ok - cursor: happy path runs post-plan turns on cursor-agent, plan stays claude, run completes\n'

# ── Scenario B: bounded retries exhaust -> sticky fallback to claude ─────────
# cursor-agent fails every call with the verified stderr-only RetriableError
# shape; NIGHT_SHIFT_CURSOR_MAX_RETRIES=1 keeps the retry loop to one journaled
# backend_retry before the sticky fallback, so the run still completes (on
# claude, via write_stub happy) instead of exhausting the whole turn budget.
integration_setup
write_stub happy
write_cursor_stub cursor-fail
if ! NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 \
  NIGHT_SHIFT_CURSOR_MAX_RETRIES=1 run_engine --spec "$SPEC"; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "cursor-fallback run exited non-zero"
fi
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                     || fail "cursor-fallback status is '$status', not complete"
events="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$events" ] && [ -f "$events" ]                           || fail "no archived journal (cursor fallback)"
retry_count="$(jq -c 'select(.type=="backend_retry")' "$events" | wc -l | tr -d ' ')"
[ "$retry_count" -eq 1 ]                                       || fail "expected 1 backend_retry event (CURSOR_MAX_RETRIES=1), got $retry_count"
jq -e 'select(.type=="backend_fallback") | .payload.from=="cursor" and .payload.to=="claude"' \
  "$events" >/dev/null                                         || fail "journal missing backend_fallback{from:cursor,to:claude}"
# backend_retry must precede backend_fallback (retries exhaust, THEN fall back).
[ "$(jq -r 'select(.type=="backend_retry" or .type=="backend_fallback") | .type' "$events" | paste -sd, -)" \
  = "backend_retry,backend_fallback" ]                         || fail "journal order is not backend_retry then backend_fallback"
state="$(find "$PROJECT/.night-shift/archive" -name state.json | head -1)"
[ -n "$state" ] && [ -f "$state" ]                             || fail "no archived state.json (cursor fallback)"
[ "$(jq -r '.implement_backend_fallback' "$state")" = "claude" ] || fail "state.implement_backend_fallback is not 'claude' after the sticky fallback"
printf 'ok - cursor: bounded retries exhaust, sticky fallback to claude, run completes\n'
