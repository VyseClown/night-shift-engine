#!/usr/bin/env bash
# integration-adverse.sh — the paths the engine exists to survive: a run that
# BLOCKS (malformed-signal cap), a run that recovers from an observer BLOCK,
# --resume clearing a logic block, a primary envelope with no session_id, and a
# primary that rewrites the spec gating its own candidate.
# Same scripted-stub approach as integration-run.sh; nothing inside the engine
# is mocked. Exit 0 + five "ok - adverse: ..." lines on success.
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

# ── Scenario D: claude primary with no session_id → block_run (no retry) ─────
# write_stub's no-session mode: rc 0, a valid JSON envelope, but no
# session_id key at all. This pins invoke_primary's CLAUDE-path guard (the
# post-loop "primary emitted no resumable session ID" block_run) — the guard
# the cursor backend's own rc==0-but-no-session_id check
# (specs/cursor-implementer-backend.md) sits next to, for the vendor that had
# it first.
integration_setup
write_stub no-session
run_engine --spec "$SPEC" && fail "engine exited 0 despite the primary never emitting a session_id"
[ "$(jq -r .status "$PROJECT/.night-shift/state.json")" = "blocked" ]      || fail "status is not blocked (no-session)"
jq -r .block_reason "$PROJECT/.night-shift/state.json" | grep -q 'no resumable session ID' \
                                                               || fail "block_reason does not name the missing session_id"
printf 'ok - adverse: a claude primary envelope with no session_id blocks with an actionable reason\n'

# ── Scenario E: the primary rewrites the spec that gates its own candidate ───
# The spec is re-read at candidate time for the "Final validation commands"
# that judge the work, and the primary has unattended write access to the whole
# workspace in between — so an implementer that "updates the spec to match what
# it built" weakened the gate judging it, uncommitted, with nothing in the
# base..candidate diff to show for it. The spec is now integrity-anchored at
# run start and guarded before that re-read. Vendor-neutral: this is the claude
# primary doing it.
integration_setup
write_stub spec-tamper
spec_before="$(cat "$SPEC")"
run_engine --spec "$SPEC" && fail "engine exited 0 despite the primary rewriting the spec's final-validation gate"
[ "$(jq -r .status "$PROJECT/.night-shift/state.json")" = "blocked" ] || fail "status is not blocked (spec tamper)"
jq -r .block_reason "$PROJECT/.night-shift/state.json" | grep -q 'was modified outside the engine' \
                                                               || fail "block_reason does not name the out-of-band modification"
jq -r .block_reason "$PROJECT/.night-shift/state.json" | grep -q 'Final validation commands' \
                                                               || fail "block_reason does not say WHICH wrapper-owned file (the gating spec)"
ev="$PROJECT/.night-shift/events.jsonl"
jq -e 'select(.type=="integrity_violation") | .payload.label=="spec"' "$ev" >/dev/null \
                                                               || fail "journal missing integrity_violation{label:spec}"
# The guard restores the engine's copy, so the gate that would run is still the
# one the run started with — never the implementer's rewrite.
[ "$(cat "$SPEC")" = "$spec_before" ]                          || fail "the tampered spec was not restored from the anchor"
printf 'ok - adverse: a primary that rewrites its own final-validation gate is caught and the spec restored\n'
