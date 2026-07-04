#!/usr/bin/env bash
# integration-run.sh — full-orchestration smoke test.
#
# Drives the REAL engine (scripts/night-shift.sh) through the entire node-track
# stage machine — planning -> plan_review -> implementation -> implementation_review
# -> implementation_ready -> observer_review -> completion — using a SCRIPTED `claude`
# stub on PATH. Nothing is mocked inside the engine: real main_run loop, real stage
# transitions + session handoff, real engine-spawned persona gate, the real TDD
# candidate gate (verify_candidate: red->green proof + isolated-worktree validation),
# the real observer gate, and real git. Only the model is scripted, so this needs no
# paid calls and no `--permission-mode bypassPermissions` (the stub ignores it) — it
# runs anywhere, including CI as root, where a live run cannot.
#
# Exit 0 + "ok - integration: ..." on success; non-zero + a diagnostic otherwise.
set -uo pipefail
# shellcheck source=scripts/test/integration-lib.sh
. "$(dirname "$0")/integration-lib.sh"

integration_setup
write_stub happy

# --- run the real engine end-to-end ------------------------------------------
log="$WORK/run.log"
if ! run_engine --spec "$SPEC"; then
  # Evidence retention: this harness has failed intermittently (~1 in many
  # runs) and a one-line tail + deleted workdir left nothing to diagnose.
  # Keep the full log at a stable path and print a real tail.
  keep="${TMPDIR:-/tmp}/ns-integration-failure-$$.log"
  cp "$log" "$keep" 2>/dev/null || true
  tail -15 "$log" >&2 || true
  fail "engine exited non-zero (full log kept at $keep)"
fi

# --- assertions: the full pipeline actually happened + the candidate is correct -
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                    || fail "run status is '$status', not complete"
[ "$(grep -c 'personas .*APPROVE' "$log")" -ge 2 ]           || fail "persona gate did not run for both stages"
grep -q 'candidate .* validated' "$log"                       || fail "TDD candidate gate did not run"
grep -q 'observer: APPROVE' "$log"                            || fail "observer gate did not run"
[ -f "$PROJECT/add.js" ]                                      || fail "candidate did not create add.js"
( cd "$PROJECT" && node --test add.test.js >/dev/null 2>&1 )  || fail "candidate test is not green"
grep -q 'null byte' "$log"                                    && fail "unexpected 'null byte' warning in the run"

# --- behavioral journal assertions: the emit sites FIRE on a real run ---------
# (the fixture suite's grep-wiring proves the strings exist; this proves the
# events land, in order, with their payloads, and survive archiving)
events="$(find "$PROJECT/.night-shift/archive" -name events.jsonl | head -1)"
[ -n "$events" ] && [ -f "$events" ]                          || fail "archived events.jsonl is missing"
jq -e . "$events" >/dev/null 2>&1                             || fail "events.jsonl has an unparseable line"
for t in run_init run_started stage_transition signal_accepted persona_verdict \
  candidate_validated observer_verdict run_complete; do
  jq -e --arg t "$t" 'select(.type==$t)' "$events" >/dev/null || fail "journal is missing a $t event"
done
jq -e 'select(.type=="run_init") | .payload.branch != null and .payload.branch != ""' \
  "$events" >/dev/null                                        || fail "run_init does not record the feature branch"
jq -e 'select(.type=="observer_verdict") | .payload | has("finding_ids")' \
  "$events" >/dev/null                                        || fail "observer_verdict lacks finding_ids"
[ "$(jq -r 'select(.type=="run_init") | .ts' "$events" | head -1)" \
  = "$(jq -r .ts "$events" | sort | head -1)" ]               || fail "run_init is not the earliest journal entry"
# run.log is archived and mirrors the stderr log (same completion line).
runlog="$(find "$PROJECT/.night-shift/archive" -name run.log | head -1)"
{ [ -n "$runlog" ] && grep -q 'complete; compact archive' "$runlog"; } \
                                                              || fail "archived run.log is missing or incomplete"

printf 'ok - integration: full node-track run reaches completion (personas + TDD gate + observer, candidate green, journal + run.log archived)\n'
