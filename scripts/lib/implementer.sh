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
# knob is "cursor" AND the spec has no ## Design Contract (design-fidelity
# builds are judgment work pinned to Claude) AND this run has not already
# fallen back to Claude (.implement_backend_fallback, sticky per run).
# Tolerates unset STATE/SPEC (standalone --sweep-only has no run state).
implement_backend_active() {
  [ "${IMPLEMENT_BACKEND:-claude}" = "cursor" ] || return 1
  ! spec_has_design_contract "${SPEC:-}" || return 1
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
# backend rather than being hard-coded to claude. Mirrors implement_backend_active's
# own logic rather than implement_scope_backend's (no session-scope concept here).
candidate_primary_vendor() {
  if implement_backend_active; then printf 'cursor'; else printf 'claude'; fi
}

# Record the sticky per-run fallback to Claude after cursor retries are
# exhausted: state flag (survives resume; state_set is integrity-guarded by
# the caller's flow), journal, log. Never fails the run itself.
implement_backend_fallback_set() {
  local reason="${1:-}" rc="${2:-0}"
  state_set '.implement_backend_fallback="claude"'
  emit_event backend_fallback "$(jq -cn --arg r "$reason" --argjson rc "$rc" \
    '{from:"cursor", to:"claude", reason:$r, rc:$rc}')"
  log "cursor backend: falling back to claude for the rest of the run ($reason, rc=$rc)"
}
