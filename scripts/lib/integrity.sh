# shellcheck shell=bash
# scripts/lib/integrity.sh
# Engine-private integrity anchor for wrapper-owned files (state.json + the
# engine-run validated/* evidence). Sourced by night-shift.sh; uses tmp_base,
# log, block_run, emit_event, record_cost-adjacent globals (RUN_ID/RUN_ROOT/
# STATE) at runtime from the orchestrator.

# ---------------------------------------------------------------------------
# Wrapper-owned file integrity (engine-private anchor)
# ---------------------------------------------------------------------------
# state.json and the engine-run validated/* evidence are wrapper-owned, but they
# live inside $PROJECT/.night-shift — where the primary runs unattended with
# bypassPermissions. Nothing filesystem-level stops an in-distribution "helpful"
# edit (rewriting approvals, the stage, or the red/green record) from being
# trusted by the engine on its next read. The engine therefore keeps a private
# byte-for-byte copy of each wrapper-owned file outside the project and compares
# at the trust points (primary-turn return, the candidate gate, the observer's
# evidence). This is the same principle that moved persona reviews from
# self-reported to engine-spawned, applied to the engine's own ledgers.
#
# NOT cryptographic: a process running with the user's privileges could hunt
# down and tamper the private copies too — the anchor raises the bar from
# "accidental in-tree edit" (in-distribution for an LLM working in the repo) to
# "deliberate out-of-tree hunt" (outside the stated threat model, like the
# engine's trust in the OS generally). A missing private copy (a reboot cleared
# tmp before a --resume) degrades to seed-on-first-check with a log line — never
# a block. The anchor dir is kept on a blocked run so --resume retains
# integrity continuity; it is removed only on successful completion.
# The anchor dir is a run constant: resolve it ONCE per RUN_ID into
# INTEGRITY_DIR (tmp_base forks a `cd && pwd -P`), in the calling shell —
# state_set runs dozens of times per turn and every journal event goes
# through here, so the per-call `$(integrity_dir)` fork storm added up.
integrity_dir_resolve() {
  if [ "${INTEGRITY_DIR_FOR:-}" != "${RUN_ID:-}" ] || [ -z "${INTEGRITY_DIR:-}" ]; then
    INTEGRITY_DIR="$(tmp_base)/night-shift-auth-${RUN_ID:-}"
    INTEGRITY_DIR_FOR="${RUN_ID:-}"
  fi
}
integrity_dir() { integrity_dir_resolve; printf '%s' "$INTEGRITY_DIR"; }

# Pure string op for a RUN_ROOT path (the common case); basename otherwise.
integrity_key() {
  local file="$1"
  case "$file" in
    "$RUN_ROOT"/*) printf '%s' "${file#"$RUN_ROOT"/}" ;;
    *) printf '%s' "${file##*/}" ;;
  esac
}

integrity_put() {
  [ -n "${RUN_ID:-}" ] && [ -n "${RUN_ROOT:-}" ] && [ -f "${1:-}" ] || return 0
  local dst
  integrity_dir_resolve
  dst="$INTEGRITY_DIR/$(integrity_key "$1")"
  mkdir -p "${dst%/*}" 2>/dev/null || return 0
  cp "$1" "$dst" 2>/dev/null || true
}

# Append-only twin of integrity_put for the journal: re-anchoring events.jsonl
# with a full cp after EVERY append made journal bookkeeping O(n²) over a long
# run. Append the same line to the private copy instead; a missing copy (a
# reboot cleared tmp, first event) falls back to the full copy. Divergence is
# still caught by integrity_guard at completion, exactly as before.
# Self-healing: the per-append cp it replaced re-established anchor == file
# on every event, so a single torn/failed mirror write could never persist;
# here a failed append falls back to a full copy at once, and every
# INTEGRITY_RESYNC_EVERY-th append does a full copy regardless — so a
# divergence from an earlier partial write is bounded to that window
# instead of surfacing as a false integrity_violation at completion.
INTEGRITY_RESYNC_EVERY=50
integrity_append() {
  [ -n "${RUN_ID:-}" ] && [ -n "${RUN_ROOT:-}" ] && [ -f "${1:-}" ] || return 0
  local dst
  integrity_dir_resolve
  dst="$INTEGRITY_DIR/$(integrity_key "$1")"
  INTEGRITY_APPEND_N=$(( ${INTEGRITY_APPEND_N:-0} + 1 ))
  if [ ! -f "$dst" ] || [ $(( INTEGRITY_APPEND_N % INTEGRITY_RESYNC_EVERY )) -eq 0 ]; then
    integrity_put "$1"
    return 0
  fi
  printf '%s\n' "$2" >>"$dst" 2>/dev/null || integrity_put "$1"
}

integrity_check() {
  [ -n "${RUN_ID:-}" ] && [ -n "${RUN_ROOT:-}" ] && [ -f "${1:-}" ] || return 0
  local auth
  integrity_dir_resolve
  auth="$INTEGRITY_DIR/$(integrity_key "$1")"
  if [ ! -f "$auth" ]; then
    log "integrity: no private copy of $(integrity_key "$1") (fresh seed or cleared tmp); seeding"
    integrity_put "$1"
    return 0
  fi
  cmp -s "$auth" "$1"
}

integrity_cleanup() {
  [ -n "${RUN_ID:-}" ] || return 0
  rm -rf "$(integrity_dir)" 2>/dev/null || true
}

# On an integrity mismatch: preserve the divergent project copy under raw/ for
# forensics, then RESTORE the engine's last write from the anchor. Without the
# restore, block_run's own status write would launder the out-of-band content
# into the anchor and a later --resume would proceed from the edited state.
integrity_quarantine() {
  local file="$1" label="$2"
  cp "$file" "$RUN_ROOT/raw/tampered-$label.$$.json" 2>/dev/null || true
  cp "$(integrity_dir)/$(integrity_key "$file")" "$file" 2>/dev/null || true
}

# THE verb every trust point uses. check -> quarantine -> block is a security
# invariant (the quarantine restore MUST precede block_run, or block_run's own
# state write launders the tampered content into the anchor); owning the
# ordering here means a future trust point cannot get it wrong. Missing file =
# nothing to verify (the consumer's own read will fail loudly if it matters).
integrity_guard() {
  local file="$1" label="$2" what="$3"
  [ -f "$file" ] || return 0
  integrity_check "$file" && return 0
  # Quarantine BEFORE journaling: emit_event stamps the envelope's stage from
  # $STATE, and when the tampered file IS state.json the restore must happen
  # first or the forensic event records an attacker-chosen stage.
  integrity_quarantine "$file" "$label"
  emit_event integrity_violation "$(jq -cn --arg f "$(integrity_key "$file")" --arg l "$label" '{file:$f, label:$l}')"
  block_run "wrapper-owned $what was modified outside the engine (divergent copy kept under raw/)"
}

