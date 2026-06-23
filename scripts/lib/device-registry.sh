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

# Try to claim one UDID via an atomic mkdir lock. $3 = "true" if a clone.
# Reclaims a lock whose owner PID is dead (lock_is_stale, from night-shift.sh).
device_try_claim() {
  local udid="$1" run_id="$2" clone="$3" reg lock
  reg="$(device_registry_root)"; mkdir -p "$reg"
  lock="$reg/$udid.lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$"     >"$lock/pid"
    printf '%s\n' "$run_id">"$lock/run_id"
    printf '%s\n' "$clone" >"$lock/clone"
    return 0
  fi
  if lock_is_stale "$lock"; then
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$"      >"$lock/pid"
      printf '%s\n' "$run_id" >"$lock/run_id"
      printf '%s\n' "$clone"  >"$lock/clone"
      return 0
    fi
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
  local deadline udid src clone_udid
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    for udid in $(device_candidates "$label" 2>/dev/null); do
      if device_try_claim "$udid" "$run_id" false; then
        printf '%s\n' "$udid"; return 0
      fi
    done
    src="$(device_candidates "$label" 2>/dev/null | head -n 1)"
    if [ -n "$src" ]; then
      clone_udid="$(xcrun simctl clone "$src" "ns-$run_id" 2>/dev/null)" || clone_udid=""
      if [ -n "$clone_udid" ] && device_try_claim "$clone_udid" "$run_id" true; then
        printf '%s\n' "$clone_udid"; return 0
      fi
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { printf ''; return 1; }
    sleep "$poll"
  done
}
