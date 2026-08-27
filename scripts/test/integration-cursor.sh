#!/usr/bin/env bash
# integration-cursor.sh — the cursor implementer backend (Grok via cursor-agent):
# a happy path where post-plan primary turns actually run on cursor-agent while
# plan stays claude, a bounded-retry -> sticky-claude-fallback path when cursor
# keeps failing outright, and the same fallback path when cursor exits 0 but
# the envelope carries no session_id (drift, not a CLI failure). Same
# scripted-stub approach as integration-run.sh / integration-adverse.sh;
# nothing inside the engine is mocked. A fourth scenario covers cursor's
# in-band failure shape: rc 0, a complete envelope, "is_error":true, and a
# fifth covering the stranding a fallen-back run used to suffer (blocked with
# no session, over a dirty tree, resumable by neither relaunch path).
# specs/cursor-implementer-backend.md — Task 2 fix wave. Exit 0 + five
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
# --add-dir "$WORKSPACE_ROOT" on EVERY primary cursor invocation: primary_prompt
# orders reads of AGENTS.md / AGENT_LOOP.md / the spec / schemas/ and the TODO.md
# edit, all outside the --trust'd $PROJECT. A stub cannot fail on a missing flag
# (it just reads fewer files), so the flag has to be asserted from the recorded
# argv. Both the fresh-start and the --resume branch must carry it, which is why
# this counts EVERY recorded call rather than grepping for one hit.
argv_calls="$(wc -l < "$WORK/.cursor-argv" | tr -d ' ')"
[ "$argv_calls" -eq "$cursor_calls" ]                          || fail ".cursor-argv recorded $argv_calls calls but .cursor-calls recorded $cursor_calls"
argv_with_dir="$(grep -cF -- "--add-dir $ENGINE_DIR" "$WORK/.cursor-argv")"
[ "$argv_with_dir" -eq "$cursor_calls" ]                       || fail "only $argv_with_dir of $cursor_calls primary cursor invocations passed --add-dir $ENGINE_DIR (the workspace root the prompt orders reads from)"
# The observer-review wire contract (specs/cursor-implementer-backend.md's
# "Wire contract" section): candidate_primary_vendor computes "cursor" here
# (implement_backend_active, no fallback), observer_prompt tells the observer
# to emit primary:"cursor", and the claude stub echoes back whatever vendor
# it found in the prompt — so the archived verdict is real end-to-end proof,
# not just a hard-coded stub value.
# -path '*/validated/*' disambiguates from observer-history-<spec>.json (a
# run-root summary file that also matches 'observer-*.json' by basename) —
# without it, find's traversal order could hand `head -1` the wrong file
# (Task 4 review carry-forward, F4).
obs_verdict="$(find "$PROJECT/.night-shift/archive" -path '*/validated/*' -name 'observer-*.json' | head -1)"
[ -n "$obs_verdict" ] && [ -f "$obs_verdict" ]                 || fail "no archived observer verdict (cursor happy path)"
[ "$(jq -r '.primary' "$obs_verdict")" = "cursor" ]            || fail "archived observer verdict .primary is not 'cursor'"
# The positive attribution marker (night-shift.sh ~1702, a mutation survivor
# without this check): a successful cursor turn stamps state.implement_backend_used
# so the candidate is attributed to cursor even past a later fallback.
state="$(find "$PROJECT/.night-shift/archive" -name state.json | head -1)"
[ -n "$state" ] && [ -f "$state" ]                             || fail "no archived state.json (cursor happy path)"
[ "$(jq -r '.implement_backend_used' "$state")" = "cursor" ]   || fail "state.implement_backend_used is not 'cursor' after the happy path"
# The advisory run-feedback session (write_run_feedback, unconditional at
# completion) must also have dispatched to the cursor stub, not silently
# stayed on claude — proof the backend knob reaches non-primary sessions too.
[ -s "$WORK/.cursor-nonprimary-calls" ]                        || fail "cursor-agent stub's non-primary path (write_run_feedback) was never invoked"
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

# ── Scenario D: rc==0 + complete envelope + is_error:true -> same fallback ───
# cursor-agent's in-band failure shape: a clean exit, a valid envelope, a real
# session_id, and "is_error":true. Neither the rc!=0 branch nor the missing-
# session_id guard can see it, and the stub writes its stage files and signal
# first — so a run that treats the envelope as a success completes looking
# perfectly healthy, on cursor, with zero retries and zero fallback. The retry
# and fallback assertions below are therefore the whole test: they fail if the
# is_error routing in invoke_primary is reverted.
integration_setup
write_stub happy
write_cursor_stub cursor-is-error
if ! NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 \
  NIGHT_SHIFT_CURSOR_MAX_RETRIES=1 run_engine --spec "$SPEC"; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "cursor is_error run exited non-zero"
fi
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                     || fail "cursor is_error status is '$status', not complete"
events="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$events" ] && [ -f "$events" ]                           || fail "no archived journal (cursor is_error)"
blocked="$(jq -c 'select(.type=="run_blocked")' "$events" | wc -l | tr -d ' ')"
[ "$blocked" -eq 0 ]                                           || fail "an is_error envelope produced $blocked run_blocked event(s); it must retry/fall back, not block"
retry_count="$(jq -c 'select(.type=="backend_retry")' "$events" | wc -l | tr -d ' ')"
[ "$retry_count" -eq 1 ]                                       || fail "expected 1 backend_retry event for the is_error envelope (CURSOR_MAX_RETRIES=1), got $retry_count — an is_error:true envelope was accepted as a successful turn"
jq -e 'select(.type=="backend_fallback") | .payload.from=="cursor" and .payload.to=="claude"' \
  "$events" >/dev/null                                         || fail "journal missing backend_fallback{from:cursor,to:claude} for the is_error path"
[ "$(jq -r 'select(.type=="backend_retry" or .type=="backend_fallback") | .type' "$events" | paste -sd, -)" \
  = "backend_retry,backend_fallback" ]                         || fail "journal order is not backend_retry then backend_fallback (is_error path)"
state="$(find "$PROJECT/.night-shift/archive" -name state.json | head -1)"
[ -n "$state" ] && [ -f "$state" ]                             || fail "no archived state.json (cursor is_error)"
[ "$(jq -r '.implement_backend_fallback' "$state")" = "claude" ] || fail "state.implement_backend_fallback is not 'claude' after the is_error fallback"
# The candidate was finished by claude, so the run must not attribute it to
# cursor: no cursor turn ever SUCCEEDED, so the positive attribution marker
# must never have been stamped.
[ "$(jq -r '.implement_backend_used // "null"' "$state")" = "null" ] || fail "state.implement_backend_used was stamped despite every cursor turn reporting is_error"
printf 'ok - cursor: an is_error:true envelope at rc 0 retries then falls back, run completes on claude\n'

# ── Scenario E: a fallen-back run that then BLOCKS is still resumable ────────
# The stranding this closes, end to end. The sticky fallback nulls .session_id
# in the same atomic write as the flag, so a block during the fallback turn
# leaves status=blocked + session_id=null over a tree that is dirty for the
# whole implementation scope by design. Before the fix BOTH relaunch paths
# refused: --resume because resumable_blocked_state demanded a non-empty
# session, and a bare relaunch because of the dirty tree — the night's work was
# orphaned. And resuming under the stored backend ran straight into the cursor
# availability/auth dies, which is what caused the fallback in the first place.
#
# Setup: plan succeeds on claude, the implementation turn goes to cursor, cursor
# fails its whole retry budget, the fallback turn runs claude — which writes its
# work and then fails, blocking the run.
integration_setup
write_stub plan-then-impl-fail
write_cursor_stub cursor-fail
NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor NIGHT_SHIFT_CURSOR_RETRY_BACKOFF=0 \
  NIGHT_SHIFT_CURSOR_MAX_RETRIES=1 run_engine --spec "$SPEC" \
  && fail "setup: the fallback-then-fail run unexpectedly succeeded"
ns="$PROJECT/.night-shift"
[ "$(jq -r .status "$ns/state.json")" = "blocked" ]            || fail "setup: run is not blocked"
[ "$(jq -r '.implement_backend_fallback' "$ns/state.json")" = "claude" ] \
                                                               || fail "setup: the run never took the sticky fallback"
[ "$(jq -r '.session_id' "$ns/state.json")" = "null" ]         || fail "setup: the blocked run still has a pinned session (the stranding shape needs none)"
[ -n "$(git -C "$PROJECT" status --porcelain)" ]               || fail "setup: the tree is clean; the stranding shape needs uncommitted work"
# A bare relaunch is (correctly) refused — the work in the tree is real.
run_engine --spec "$SPEC" && fail "a bare relaunch over a dirty blocked tree must not start a fresh run"
grep -q 're-run with --resume' "$WORK/run.log"                 || fail "the bare-relaunch refusal does not point at --resume"
# Now the escape that used to be closed: --resume, still on the cursor backend,
# with cursor-agent GONE from PATH (the logged-out/unavailable state that
# caused the fallback). The run needs cursor for nothing and must finish.
rm -f "$BIN/cursor-agent"
write_stub happy
if ! NIGHT_SHIFT_IMPLEMENT_BACKEND=cursor run_engine --resume; then
  tail -20 "$WORK/run.log" >&2 || true
  fail "--resume of a fallen-back run failed (cursor-agent absent)"
fi
ev="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$ev" ] && [ -f "$ev" ]                                   || fail "no archived journal after the fallback resume"
jq -e 'select(.type=="run_recovered") | .payload.resumed_block==true' "$ev" >/dev/null \
                                                               || fail "journal missing run_recovered{resumed_block:true} for the null-session resume"
jq -e 'select(.type=="run_complete")' "$ev" >/dev/null          || fail "the resumed fallen-back run did not complete"
grep -q 'already pinned to claude' "$WORK/run.log"              || fail "the cursor startup guards were not skipped for the fallen-back run"
printf 'ok - cursor: a fallen-back run that blocked resumes with cursor-agent gone (null session + guards skipped)\n'
