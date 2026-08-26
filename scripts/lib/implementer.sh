# shellcheck shell=bash
# scripts/lib/implementer.sh
# Implementer-backend seam: opt-in cursor-agent (Grok) for the primary's
# post-plan work. Pure predicates + cursor helpers only — invoke_primary keeps
# the loop. Sourced by night-shift.sh AFTER the knob block. Claude stays the
# only planner/observer/persona vendor; see specs/cursor-implementer-backend.md.
# Only ever sourced by night-shift.sh, so state_set/emit_event/log/
# spec_has_design_contract (defined there) are safe to call here at runtime.

# Seam for fixtures: is the Cursor CLI available? (Same rationale as
# codex_available — command -v inline would make the missing-CLI path
# untestable on machines that have cursor-agent installed.)
cursor_available() { command -v cursor-agent >/dev/null 2>&1; }

# 0 iff the cursor backend should currently drive post-plan primary work:
# knob is "cursor" AND no design-contract latch (below) AND this run has not
# already fallen back to Claude (.implement_backend_fallback, sticky per run).
# Design-Contract force is RUN-scoped, not per-task: the first activation
# check that sees a spec with a ## Design Contract latches
# .implement_backend_design_latch=true in run state, and every later check
# honors the latch even after NEXT_TASK swaps $SPEC to a contract-free spec —
# design-fidelity builds are judgment work pinned to Claude, and a mid-run
# vendor flip-back is exactly the per-scope sandwich the spec rules out.
# Tolerates unset STATE/SPEC (standalone --sweep-only has no run state; the
# live spec check still applies there, just without persistence).
implement_backend_active() {
  [ "${IMPLEMENT_BACKEND:-claude}" = "cursor" ] || return 1
  if [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ] &&
    [ "$(jq -r '.implement_backend_design_latch // empty' "$STATE" 2>/dev/null)" = "true" ]; then
    return 1
  fi
  if spec_has_design_contract "${SPEC:-}"; then
    # First sighting this run: latch it (run-scoped, survives resume). No
    # journal event — the latch is a derived fact, not a run occurrence.
    if [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ]; then
      state_set '.implement_backend_design_latch=true'
    fi
    return 1
  fi
  [ -z "${STATE:-}" ] || [ ! -f "${STATE:-}" ] ||
    [ "$(jq -r '.implement_backend_fallback // empty' "$STATE" 2>/dev/null)" != "claude" ] || return 1
  return 0
}

# Pure-ish: the backend for a session scope. Plan is always Claude (planning
# quality bounds the run); everything post-plan follows the active backend.
implement_scope_backend() {
  case "${1:-}" in
    implement|visual|observe|complete)
      if implement_backend_active; then printf 'cursor'; else printf 'claude'; fi ;;
    *) printf 'claude' ;;
  esac
}

# The vendor that produced (or will produce) the candidate the observer is
# about to review — feeds the observer-review wire contract's `primary` field
# (schemas/observer-review.json) so its expected value tracks the ACTIVE
# backend rather than being hard-coded to claude. Prefers the recorded
# .implement_backend_used marker (set once by invoke_primary after any turn
# that actually succeeded on cursor; TASK-scoped — start_next_task's per-task
# reset nulls it so a chained task's verdict never inherits the previous
# task's attribution) over the live implement_backend_active
# predicate: a candidate that was partly built by cursor before a later turn
# fell back to claude must still attribute cursor, which the live predicate
# alone cannot see (it would read the CURRENT — post-fallback — state and
# report claude). Falls back to the live predicate when the marker is absent,
# e.g. a resumed run's first turn, or --sweep-only where STATE is unset.
candidate_primary_vendor() {
  local used
  if [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ]; then
    used="$(jq -r '.implement_backend_used // empty' "$STATE" 2>/dev/null)"
    [ -z "$used" ] || { printf '%s' "$used"; return 0; }
  fi
  if implement_backend_active; then printf 'cursor'; else printf 'claude'; fi
}

# Record the sticky per-run fallback to Claude after cursor retries are
# exhausted: state flag AND session null in ONE atomic state_set (the
# handle_per_model_limit idiom — a crash between separate writes would leave
# backend=claude pinned to a CURSOR session id, and every relaunch would then
# run `claude -p --resume <cursor-uuid>` into the same non-429 failure),
# journal, log. Survives resume; integrity-guarded like every state write.
# Never fails the run itself. Callers must not re-null .session_id separately.
implement_backend_fallback_set() {
  local reason="${1:-}" rc="${2:-0}"
  state_set '.implement_backend_fallback="claude" | .session_id=null | .updated_at=$now' \
    --arg now "$(now_iso)"
  emit_event backend_fallback "$(jq -cn --arg r "$reason" --argjson rc "$rc" \
    '{from:"cursor", to:"claude", reason:$r, rc:$rc}')"
  log "cursor backend: falling back to claude for the rest of the run ($reason, rc=$rc)"
}
