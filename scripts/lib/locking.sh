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
# Best-effort process start time, used to detect PID reuse. Linux: field 22
# (starttime, clock ticks since boot) of /proc/<pid>/stat — read the substring
# after the LAST ')' so a comm containing spaces/parens cannot shift the fields.
# BSD/macOS: `ps -o lstart=` (a stable wall-clock start string). Empty/non-zero
# when unavailable, in which case lock_is_stale falls back to a liveness-only check.
proc_start_time() {
  local pid="$1" rest st
  if [ -r "/proc/$pid/stat" ]; then
    rest="$(sed -E 's/^.*\) //' "/proc/$pid/stat" 2>/dev/null)"
    st="$(printf '%s' "$rest" | awk '{print $20}')"
    case "$st" in ''|*[!0-9]*) ;; *) printf '%s' "$st"; return 0 ;; esac
  fi
  st="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"
  [ -n "$st" ] && { printf '%s' "$st"; return 0; }
  return 1
}

# Pure predicate: return 0 (stale / reclaimable) if the PID stored in the lock dir
# belongs to a dead process — OR to a DIFFERENT process that reused the number
# (its recorded start time no longer matches) — and 1 (live) otherwise. Extracted
# as a standalone function so the fixture can test the decision without running the
# full lock acquisition path.
lock_is_stale() {
  local lockdir="$1" stored_pid stored_start cur_start
  stored_pid="$(cat "$lockdir/pid" 2>/dev/null)" || return 0   # missing pid file → stale
  is_valid_int "$stored_pid" || return 0                        # garbage pid → stale
  kill -0 "$stored_pid" 2>/dev/null || return 0                 # process dead → stale
  # Process number is alive. Guard against PID REUSE on a busy host: if we recorded
  # the holder's start time at acquire and it no longer matches the live PID's start
  # time, the original holder is gone and an unrelated process inherited the number.
  stored_start="$(cat "$lockdir/start" 2>/dev/null)" || return 1   # no record → cannot disprove liveness
  [ -n "$stored_start" ] || return 1
  cur_start="$(proc_start_time "$stored_pid")" || return 1         # start time unreadable → assume live
  [ -n "$cur_start" ] || return 1
  [ "$stored_start" = "$cur_start" ] && return 1                   # same process → live
  return 0                                                          # PID reused → stale
}

# Atomically take ownership of <lockdir> for this process. Returns 0 iff we now
# own it. The ownership token is the pid FILE, created with O_EXCL via `set -C`
# (noclobber) — so a lock is never observable without its owner pid. This closes
# the mkdir->write-pid window a plain `mkdir` gate leaves: a concurrent claimant
# can no longer see a freshly-created, pid-less dir and wrongly judge it stale.
# The dir is just a metadata container (run_id/clone live beside pid); `mkdir -p`
# on it is idempotent and confers nothing. A stale pid (dead owner) is reclaimed;
# the reclaim's re-create is also O_EXCL, so only one racing reclaimer wins.
atomic_lock_acquire() {
  local lockdir="$1"
  mkdir -p "$lockdir" 2>/dev/null || return 1
  if ( set -C; printf '%s\n' "$$" >"$lockdir/pid" ) 2>/dev/null; then
    proc_start_time "$$" >"$lockdir/start" 2>/dev/null || true   # auxiliary: PID-reuse guard
    return 0
  fi
  if lock_is_stale "$lockdir"; then
    rm -f "$lockdir/pid" "$lockdir/start"
    if ( set -C; printf '%s\n' "$$" >"$lockdir/pid" ) 2>/dev/null; then
      proc_start_time "$$" >"$lockdir/start" 2>/dev/null || true
      return 0
    fi
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
