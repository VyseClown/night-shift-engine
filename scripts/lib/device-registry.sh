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
