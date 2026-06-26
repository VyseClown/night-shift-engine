# Visual-repair Metro reuse — design

Date: 2026-06-26. Repo: `night-shift-engine`. Fixes the Metro collision found by the
offline design-fidelity revalidation ([[visual-repair-metro-collision]]) so
`visual-review.sh --repair` actually converges instead of silently no-op'ing.

## 1. Problem (proven)

In a `visual-review.sh --no-build --repair` run:
- The initial capture (`review_spec`) runs first and needs a Metro on `:8081`.
- The `--repair` block then calls `repair_metro_start`, which **unconditionally** runs a
  second `npx expo start`. With a Metro already on `:8081`, expo prompts *"Port 8081 is
  running this app in another window — Use port 8082 instead?"* (interactive, in a
  non-interactive run).
- The repair's re-captures then don't reflect the agent's edits → every attempt captures
  an identical diff → keep-best reverts to baseline → **no convergence**.
- `repair_metro_stop` does a blanket `pkill -f "expo start"`, which would also kill a
  reused / pre-existing Metro.

Proven the agent + the rest of the engine are fine: the opus repair agent edits
correctly, and capturing the edited screen improved the diff **0.383 → 0.3645** — only
the repair-loop Metro handoff is broken.

## 2. Goal / non-goals

**Goal:** `visual-review.sh --repair` drives the keep-best loop with each opus edit
reflected in the re-capture, on a single engine-owned Metro — no collision, no
pre-started Metro required.

**Non-goals:** the structural diff-noise floor (debug banner, the test-locked Quick-Add
row, the 750×1624 frame vs the taller iphone-16 capture) — a separate masking follow-up;
the build path (`expo run:ios`) behavior is unchanged.

## 3. Changes

### 3.1 `metro_is_up` helper (`scripts/lib/visual-repair.sh`)

```bash
# True when a Metro bundler is already answering on :8081.
metro_is_up() {
  curl -s -o /dev/null "http://localhost:${NIGHT_SHIFT_METRO_PORT:-8081}/status" 2>/dev/null
}
```

### 3.2 `repair_metro_start` reuses an existing Metro

Reuse when one is already up; only start (and track) one otherwise:

```bash
repair_metro_start() {
  local device="$1"
  if [ "$NO_BUILD" -ne 1 ]; then
    log "repair: building dev client on '$device' (slow, once)…"
    ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --device "$device" >/dev/null 2>&1 ) \
      || { log "repair: dev build failed (build manually + re-run with --no-build)"; return 1; }
  fi
  _REPAIR_METRO_STARTED=0
  if metro_is_up; then
    log "repair: reusing the Metro already on :${NIGHT_SHIFT_METRO_PORT:-8081}"
    return 0
  fi
  log "repair: starting Metro (EXPO_PUBLIC_PREVIEW=1)…"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start >/tmp/visual-repair-metro.log 2>&1 ) &
  _REPAIR_METRO_PID=$!
  _REPAIR_METRO_STARTED=1
  local i=0; until metro_is_up; do
    i=$((i+1)); [ "$i" -ge 30 ] && { log "WARN: Metro did not come up after 60s"; break; }; sleep 2; done
}
```

### 3.3 `repair_metro_stop` only stops an engine-started Metro

Drop the blanket `pkill -f "expo start"`; kill only the tracked PID, and only if the
engine started it:

```bash
repair_metro_stop() {
  [ "${_REPAIR_METRO_STARTED:-0}" = "1" ] || return 0
  [ -n "${_REPAIR_METRO_PID:-}" ] && kill "$_REPAIR_METRO_PID" 2>/dev/null || true
  _REPAIR_METRO_PID=""; _REPAIR_METRO_STARTED=0
}
```

### 3.4 The engine owns one Metro for the whole `--repair` run (`scripts/visual-review.sh`)

Move `repair_metro_start` (+ the EXIT trap) to **before** the initial capture loop in the
`--repair` path, so the same Metro serves the initial capture AND the repair. The run
order becomes:

```bash
[ "$NO_BUILD" -eq 1 ] || build_and_install
if [ "$REPAIR" -eq 1 ]; then
  trap 'repair_metro_stop' EXIT
  iter_dev="$(visual_repair_devices "${SPECS[0]}" | head -n1)"
  repair_metro_start "$(device_label_to_name "$iter_dev")" || die "repair: could not start Metro"
fi
rc=0
for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done
if [ "$REPAIR" -eq 1 ]; then
  base="$(basename "${SPECS[0]}" .md)"
  visual_repair_for_spec "${SPECS[0]}" "$PROJECT" "$OUT/$base" "review" \
    "$OUT/$base/visual-diff-$base.json" "$MAX_ATTEMPTS" \
    "$([ "$REPAIR_SHARED" -eq 1 ] && echo 'src/features/,src/ui/' || echo 'src/features/')" "$iter_dev"
  log "repair: final authoritative pass…"; rc=0; for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done
  repair_metro_stop; trap - EXIT
fi
```

`iter_dev` is now set in the first `if`-block but consumed in the second; both run only
when `REPAIR=1`, so it is always defined where used. (A non-repair run is unchanged: no
engine Metro management; the caller provides Metro as today.)

## 4. Testing

Deterministic fixtures (stub binaries on PATH):
- **reuse when up:** stub `curl` to exit 0 (Metro up) + stub `npx` that records a call;
  `repair_metro_start somedev` → `npx` is **not** called, `_REPAIR_METRO_STARTED` is `0`.
  (Set `NO_BUILD=1` so the build branch is skipped.)
- **start when down:** stub `curl` to exit non-zero first then 0 (so the wait loop ends),
  stub `npx` recording the call → `repair_metro_start` calls `npx` and sets
  `_REPAIR_METRO_STARTED=1`.
- **stop only an engine-started Metro:** with `_REPAIR_METRO_STARTED=0`, `repair_metro_stop`
  is a no-op (no kill); with `=1` + a fake `_REPAIR_METRO_PID`, it kills it and resets.
- **call order (structural):** in `scripts/visual-review.sh`, `repair_metro_start`
  appears **before** the `for s in "${SPECS[@]}"; do review_spec` capture loop within the
  `REPAIR` path (assert the `repair_metro_start` line number precedes the first
  `review_spec` loop line).

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 5. Validation

After the fix, re-run the offline loop (pre-seeded cache + staged ref, `--no-build
--no-refs --repair=N`, opus repair model) and confirm the per-attempt diffs now **change**
(the keep-best loop makes progress) and the final diff drops below the 0.383 baseline.
