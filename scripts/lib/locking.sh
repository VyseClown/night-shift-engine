# shellcheck shell=bash
# scripts/lib/locking.sh
# ---------------------------------------------------------------------------
# Concurrency run-lock (F1)
# ---------------------------------------------------------------------------
# mkdir is atomic on POSIX filesystems and available in bash 3.2 without flock.
# One lock per --project directory prevents two concurrent runs from corrupting
# the shared $PROJECT/.night-shift/state.json. The lock directory lives at
# $PROJECT/.night-shift/run.lock; the owner PID is written inside it so we can
# distinguish a live holder from a stale lock left by a crashed run.
#
# Sourced by night-shift.sh. Depends (at runtime) on is_valid_int + die from the
# orchestrator and the $PROJECT global; device-registry.sh also calls
# lock_is_stale / atomic_lock_acquire, which is why they live in a shared lib.
#
# Pure predicate: return 0 (stale / reclaimable) if the PID stored in the lock dir
# belongs to a dead process, 1 (live) otherwise.  Extracted as a standalone
# function so the fixture can test the decision without running the full lock
# acquisition path.  (A prior revision added a process-start-time PID-reuse guard;
# it was removed — on a hardened host where /proc becomes unreadable mid-run the
# guard could misjudge a LIVE holder as reused and reclaim its lock, which is worse
# than the astronomically-rare PID-reuse it defended against. Plain liveness is the
# safe, proven check.)
lock_is_stale() {
  local lockdir="$1" stored_pid
  stored_pid="$(cat "$lockdir/pid" 2>/dev/null)" || return 0   # missing pid file → stale
  is_valid_int "$stored_pid" || return 0                        # garbage pid → stale
  kill -0 "$stored_pid" 2>/dev/null && return 1                 # process alive → NOT stale
  return 0                                                       # process dead → stale
}

# Atomically take ownership of <lockdir> for this process. Returns 0 iff we now
# own it. The ownership token is the pid FILE, created with O_EXCL via `set -C`
# (noclobber) — so a lock is never observable without its owner pid. This closes
# the mkdir->write-pid window a plain `mkdir` gate leaves: a concurrent claimant
# can no longer see a freshly-created, pid-less dir and wrongly judge it stale.
#
# A stale pid (dead owner) is reclaimed, but the reclaim is SERIALIZED by an atomic
# `mkdir` mutex. The destructive `rm -f pid` + recreate must be exclusive: without
# the mutex, two reclaimers both pass lock_is_stale, and the second's `rm -f` can
# clobber the first winner's freshly-created pid AFTER it returned 0 — so BOTH win
# and run concurrently against the shared state.json. Only the mkdir winner
# reclaims; the loser returns 1. (A crash between the mkdir and its rmdir orphans
# the mutex, which an operator clears exactly like any stale lock: remove the lock
# dir.) The re-create is O_EXCL too, belt-and-suspenders.
atomic_lock_acquire() {
  local lockdir="$1"
  mkdir -p "$lockdir" 2>/dev/null || return 1
  if ( set -C; printf '%s\n' "$$" >"$lockdir/pid" ) 2>/dev/null; then
    return 0
  fi
  if lock_is_stale "$lockdir" && mkdir "$lockdir/.reclaiming" 2>/dev/null; then
    rm -f "$lockdir/pid"
    if ( set -C; printf '%s\n' "$$" >"$lockdir/pid" ) 2>/dev/null; then
      rmdir "$lockdir/.reclaiming" 2>/dev/null || true
      return 0
    fi
    rmdir "$lockdir/.reclaiming" 2>/dev/null || true
  fi
  return 1
}

acquire_lock() {
  local lockdir="$PROJECT/.night-shift/run.lock"
  # Ensure the parent .night-shift directory exists before we try to take the
  # lock; initialize_run may not have run yet at this point.
  mkdir -p "$PROJECT/.night-shift"
  if atomic_lock_acquire "$lockdir"; then
    return 0
  fi
  # Another live process holds the lock — refuse to proceed.
  local holder_pid
  holder_pid="$(cat "$lockdir/pid" 2>/dev/null || printf 'unknown')"
  die "another run is already active for this project (PID $holder_pid); wait for it to finish or remove $lockdir if the process is gone"
}

release_lock() {
  local lockdir="${1:-${PROJECT:-}/.night-shift/run.lock}"
  # Only remove the lock if we own it (our PID is recorded inside). This
  # prevents an EXIT trap from clobbering a freshly reclaimed lock if the
  # original holder exits at the same moment.
  [ -f "$lockdir/pid" ] || return 0
  local stored_pid
  stored_pid="$(cat "$lockdir/pid" 2>/dev/null)" || return 0
  [ "$stored_pid" = "$$" ] || return 0
  rm -rf "$lockdir"
}
