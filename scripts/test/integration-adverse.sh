#!/usr/bin/env bash
# integration-adverse.sh — the paths the engine exists to survive: a run that
# BLOCKS (malformed-signal cap) and a run that recovers from an observer BLOCK.
# Same scripted-stub approach as integration-run.sh; nothing inside the engine
# is mocked. Exit 0 + two "ok - adverse: ..." lines on success.
set -uo pipefail
FAIL_PREFIX=adverse
# shellcheck source=scripts/test/integration-lib.sh
. "$(dirname "$0")/integration-lib.sh"

# ── Scenario A: five malformed signals → blocked, full state retained ────────
integration_setup
write_stub malformed
run_engine --spec "$SPEC" && fail "engine exited 0 despite the malformed-signal cap"
ns="$PROJECT/.night-shift"
[ "$(jq -r .status "$ns/state.json")" = "blocked" ]            || fail "status is not blocked"
jq -r .block_reason "$ns/state.json" | grep -q 'malformed'     || fail "block_reason does not name the cause"
[ -d "$ns/archive/$(jq -r .run_id "$ns/state.json")" ] && fail "blocked run must NOT be compacted"
ev="$ns/events.jsonl"
jq -e 'select(.type=="signal_rejected") | .payload.consecutive==5' "$ev" >/dev/null \
                                                               || fail "journal missing the 5th rejection"
jq -e 'select(.type=="run_blocked")' "$ev" >/dev/null          || fail "journal missing run_blocked"
jq -e 'select(.type=="run_init")' "$ev" >/dev/null             || fail "journal missing run_init (early-block coverage)"
grep -q 'malformed' "$ns/run.log"                              || fail "run.log does not tell the block story"
printf 'ok - adverse: blocked run keeps full state + journals its own demise\n'

# ── Scenario B: observer BLOCK → fresh implement session → APPROVE ───────────
integration_setup
write_stub block-then-approve
if ! run_engine --spec "$SPEC"; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "recovery run exited non-zero"
fi
ev="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$ev" ]                                                   || fail "no archived journal"
[ "$(jq -r 'select(.type=="observer_verdict") | .payload.status' "$ev" | paste -sd, -)" = "BLOCK,APPROVE" ] \
                                                               || fail "journal must show BLOCK then APPROVE"
jq -e 'select(.type=="observer_verdict") | select(.payload.status=="BLOCK") | .payload.finding_ids==["OBS-001"]' "$ev" >/dev/null \
                                                               || fail "BLOCK verdict lacks finding_ids"
jq -e 'select(.type=="stage_transition") | select(.payload.from=="observer_review" and .payload.to=="implementation") | .payload.session_cleared==true' "$ev" >/dev/null \
                                                               || fail "BLOCK must return to a FRESH implement session"
[ "$(jq -r 'select(.type=="candidate_validated") | .payload.commit' "$ev" | sort -u | wc -l | tr -d ' ')" = "2" ] \
                                                               || fail "expected two distinct validated candidates"
printf 'ok - adverse: observer BLOCK returns to a fresh implement session and the repaired candidate completes\n'

# ── Scenario C: --resume re-enters a logic-blocked run and completes ─────────
# resumable_blocked_state (lib/recovery.sh) requires status=blocked, no
# rate_limit_reset_at, and a session_id — all true after Scenario A's
# malformed-signal block. --resume takes no --spec: the task comes from state.
integration_setup
write_stub malformed
run_engine --spec "$SPEC" && fail "setup: malformed run unexpectedly succeeded"
[ "$(jq -r .status "$PROJECT/.night-shift/state.json")" = "blocked" ] || fail "setup: not blocked"
write_stub happy
if ! run_engine --resume; then
  tail -15 "$WORK/run.log" >&2 || true
  fail "--resume run exited non-zero"
fi
ev="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$ev" ]                                                   || fail "no archived journal after resume"
jq -e 'select(.type=="run_recovered") | .payload.resumed_block==true' "$ev" >/dev/null \
                                                               || fail "journal missing run_recovered{resumed_block:true}"
jq -e 'select(.type=="run_complete")' "$ev" >/dev/null         || fail "resumed run did not complete"
printf 'ok - adverse: --resume clears a logic block and the run completes\n'
