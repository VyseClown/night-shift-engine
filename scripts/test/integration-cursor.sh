#!/usr/bin/env bash
# integration-cursor.sh — the cursor implementer backend (Grok via cursor-agent):
# a happy path where post-plan primary turns actually run on cursor-agent while
# plan stays claude, a bounded-retry -> sticky-claude-fallback path when cursor
# keeps failing outright, and the same fallback path when cursor exits 0 but
# the envelope carries no session_id (drift, not a CLI failure). Same
# scripted-stub approach as integration-run.sh / integration-adverse.sh;
# nothing inside the engine is mocked.
# specs/cursor-implementer-backend.md — Task 2 fix wave. Exit 0 + three
# "ok - cursor: ..." lines on success.
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
# Vacuous-vs-cursor-invocation-regressions hardening: a happy run must never
# journal a retry or a fallback (that would mean cursor silently misbehaved
# and got bailed out rather than genuinely succeeding), and must actually have
# driven the implementation stage through cursor-agent (not just SOME stage).
retry_count="$(jq -c 'select(.type=="backend_retry")' "$events" | wc -l | tr -d ' ')"
[ "$retry_count" -eq 0 ]                                       || fail "happy path journaled $retry_count backend_retry event(s); cursor should not need retries"
fallback_count="$(jq -c 'select(.type=="backend_fallback")' "$events" | wc -l | tr -d ' ')"
[ "$fallback_count" -eq 0 ]                                    || fail "happy path journaled $fallback_count backend_fallback event(s); cursor should never fall back on the happy path"
grep -qx 'implementation' "$WORK/.cursor-calls"                || fail ".cursor-calls is missing an 'implementation' stage line"
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

# ── Scenario C: rc==0 but no session_id (envelope drift) -> same fallback ───
# cursor-agent exits CLEANLY (rc 0, no stderr) on every call but the envelope
# never carries a session_id — a real headless-CLI drift, not an invocation
# failure. invoke_primary must treat this exactly like Scenario B's outright
# failure (bounded retries -> sticky fallback), not the unrelated "primary
# emitted no resumable session ID" block_run.
integration_setup
write_stub happy
write_cursor_stub cursor-empty
if ! NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 \
  NIGHT_SHIFT_CURSOR_MAX_RETRIES=1 run_engine --spec "$SPEC"; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "cursor-empty-envelope run exited non-zero"
fi
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                     || fail "cursor-empty-envelope status is '$status', not complete"
events="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$events" ] && [ -f "$events" ]                           || fail "no archived journal (cursor empty-envelope)"
blocked="$(jq -c 'select(.type=="run_blocked")' "$events" | wc -l | tr -d ' ')"
[ "$blocked" -eq 0 ]                                           || fail "envelope drift produced $blocked run_blocked event(s); it must retry/fall back, not block"
retry_count="$(jq -c 'select(.type=="backend_retry")' "$events" | wc -l | tr -d ' ')"
[ "$retry_count" -eq 1 ]                                       || fail "expected 1 backend_retry event (CURSOR_MAX_RETRIES=1), got $retry_count"
jq -e 'select(.type=="backend_fallback") | .payload.from=="cursor" and .payload.to=="claude"' \
  "$events" >/dev/null                                         || fail "journal missing backend_fallback{from:cursor,to:claude} for the envelope-drift path"
state="$(find "$PROJECT/.night-shift/archive" -name state.json | head -1)"
[ -n "$state" ] && [ -f "$state" ]                             || fail "no archived state.json (cursor empty-envelope)"
[ "$(jq -r '.implement_backend_fallback' "$state")" = "claude" ] || fail "state.implement_backend_fallback is not 'claude' after the envelope-drift fallback"
printf 'ok - cursor: rc==0 envelope with no session_id retries then falls back, run completes\n'
