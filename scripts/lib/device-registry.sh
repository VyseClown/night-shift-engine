# scripts/lib/device-registry.sh
# Opt-in iOS simulator claim registry for parallel visual_review runs.
# Engages only when NIGHT_SHIFT_DEVICE_REGISTRY=1; a normal single run never
# calls into here. Mirrors the run.lock idiom (atomic mkdir + dead-PID reclaim):
# lock_is_stale() is defined in night-shift.sh and called at runtime, so sourcing
# order does not matter. Registry is machine-global (one set of simulators), not
# per-worktree, so concurrent worktrees see each other's claims.

# Machine-global registry root; overridable for tests.
device_registry_root() {
  printf '%s' "${NIGHT_SHIFT_DEVICE_REGISTRY_DIR:-$HOME/.night-shift/devices}"
}

# Print one UDID per line for every available simulator matching <label>
# (label = device name lowercased, spaces -> hyphens; matches __visual_pick_udid).
device_candidates() {
  local label="$1" js
  js="$(xcrun simctl list devices available -j 2>/dev/null)" || return 1
  printf '%s' "$js" | jq -r --arg d "$label" '
    [.devices[][]? | {udid, label:(.name|ascii_downcase|gsub(" ";"-"))}]
    | map(select(.label==$d)) | .[].udid'
}

# Try to claim one UDID. $3 = "true" if a clone. Ownership is taken atomically
# via atomic_lock_acquire (night-shift.sh): an O_EXCL pid file, so there is no
# window where the lock dir exists without an owner pid for a concurrent claimant
# to misjudge as stale. A dead owner is reclaimed there. Metadata (run_id/clone)
# is written only after we own the lock.
device_try_claim() {
  local udid="$1" run_id="$2" clone="$3" reg lock
  reg="$(device_registry_root)"; mkdir -p "$reg"
  lock="$reg/$udid.lock"
  if atomic_lock_acquire "$lock"; then
    printf '%s\n' "$run_id" >"$lock/run_id"
    printf '%s\n' "$clone"  >"$lock/clone"
    return 0
  fi
  return 1
}

# Claim a device for <label>, cloning a matching one if all are taken. Polls up
# to NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT seconds, then prints empty + returns 1
# (caller SKIPs). Prints the claimed UDID on success.
device_claim() {
  local label="$1" run_id="$2"
  local timeout="${NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT:-300}"
  local poll="${NIGHT_SHIFT_DEVICE_POLL_SECONDS:-5}"
  local reg deadline udid src clone_udid clone_name creating
  reg="$(device_registry_root)"
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    for udid in $(device_candidates "$label" 2>/dev/null); do
      if device_try_claim "$udid" "$run_id" false; then
        printf '%s\n' "$udid"; return 0
      fi
    done
    src="$(device_candidates "$label" 2>/dev/null | head -n 1)"
    if [ -n "$src" ]; then
      local clone_name="ns-nightshift-${run_id}-${label}"
      local creating="$reg/.creating-${clone_name}"
      if atomic_lock_acquire "$creating"; then
        clone_udid="$(xcrun simctl clone "$src" "$clone_name" 2>/dev/null)" || clone_udid=""
        if [ -n "$clone_udid" ] && device_try_claim "$clone_udid" "$run_id" true; then
          rm -rf "$creating"; printf '%s\n' "$clone_udid"; return 0
        fi
        rm -rf "$creating"
      fi
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { printf ''; return 1; }
    sleep "$poll"
  done
}

# Release a claimed device: delete it if it was a clone; remove the lock only if
# we own it (PID match), mirroring release_lock.
device_release() {
  local udid="$1" reg lock
  reg="$(device_registry_root)"; lock="$reg/$udid.lock"
  [ -d "$lock" ] || return 0
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] || return 0
  if [ "$(cat "$lock/clone" 2>/dev/null)" = "true" ]; then
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$lock"
}

# Startup self-heal: reclaim dead-PID locks (deleting their clones) and delete
# orphan ns-nightshift-* clones that have no live lock. Same idea as the worktree prune.
device_registry_prune() {
  local reg lock udid js
  reg="$(device_registry_root)"
  [ -d "$reg" ] || return 0
  for lock in "$reg"/*.lock; do
    [ -d "$lock" ] || continue
    if lock_is_stale "$lock"; then
      udid="$(basename "$lock" .lock)"
      [ "$(cat "$lock/clone" 2>/dev/null)" = "true" ] && xcrun simctl delete "$udid" >/dev/null 2>&1 || true
      rm -rf "$lock"
    fi
  done
  for lock in "$reg"/.creating-*; do
    [ -d "$lock" ] || continue
    lock_is_stale "$lock" && rm -rf "$lock"
  done
  js="$(xcrun simctl list devices -j 2>/dev/null)" || return 0
  printf '%s' "$js" | jq -r '[.devices[][]? | select(.name|startswith("ns-nightshift-")) | "\(.udid)\t\(.name)"] | .[]' \
    | while IFS="$(printf '\t')" read -r udid name; do
        [ -n "$udid" ] || continue
        [ -d "$reg/$udid.lock" ] && continue
        [ -d "$reg/.creating-$name" ] && continue
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
      done
}
