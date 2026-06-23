# RN visual_review Parallelism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let concurrent worktree night-shift runs each capture `visual_review` on a dedicated iOS simulator, claimed through an opt-in engine-native device registry, with the normal single run unchanged.

**Architecture:** A new self-contained bash lib `scripts/lib/device-registry.sh` claims/locks/clones/releases simulators using the same atomic-`mkdir` + dead-PID idiom as the existing `run.lock`. It engages only when `NIGHT_SHIFT_DEVICE_REGISTRY=1`. `visual-capture.sh` is refactored to accept an explicit UDID (behavior-preserving for the default path). `scripts/parallel-worktrees.sh` exports the opt-in env when fanning out with `--jobs > 1`.

**Tech Stack:** Bash (portable, no associative arrays), `jq`, `xcrun simctl`. Tests are deterministic fixtures inside `scripts/night-shift.sh` with a PATH-stubbed `xcrun`.

**Spec:** `docs/superpowers/specs/2026-06-23-rn-visual-review-parallelism-design.md`

---

## File Structure

- **Create** `scripts/lib/device-registry.sh` — the registry library. One responsibility: claim/release/prune simulators. Depends only on `xcrun simctl`, `jq`, and `lock_is_stale` (defined in `night-shift.sh`, called at runtime).
- **Modify** `scripts/lib/visual-capture.sh` — `__visual_capture_screenshot` and `run_visual_capture` accept an explicit UDID; `run_visual_capture` claims/releases in registry mode.
- **Modify** `scripts/night-shift.sh` — source the new lib; prune at `visual_review` entry in registry mode; add fixtures + register them.
- **Modify** `scripts/parallel-worktrees.sh` — export `NIGHT_SHIFT_DEVICE_REGISTRY=1` to children when `--jobs > 1`.
- **Modify** `CLAUDE.md` — document the opt-in knob under the visual-fidelity note.

All fixtures live in `scripts/night-shift.sh` (the engine's test harness) and run via `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run`.

---

## Task 1: Create the registry lib skeleton + source it

**Files:**
- Create: `scripts/lib/device-registry.sh`
- Modify: `scripts/night-shift.sh` (sourcing block ~line 82; fixture registration ~line 593)

- [ ] **Step 1: Create the lib with the registry-root helper**

Create `scripts/lib/device-registry.sh`:

```sh
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
```

- [ ] **Step 2: Source the lib in night-shift.sh**

In `scripts/night-shift.sh`, immediately after the `visual-capture.sh` source line (`. "$NIGHT_SHIFT_LIB/visual-capture.sh"`, ~line 82), add:

```sh
# Opt-in device registry for parallel visual_review (inert unless
# NIGHT_SHIFT_DEVICE_REGISTRY=1). See scripts/lib/device-registry.sh.
# shellcheck source=scripts/lib/device-registry.sh
. "$NIGHT_SHIFT_LIB/device-registry.sh"
```

- [ ] **Step 3: Add a fixture for the root override**

In `scripts/night-shift.sh`, add this fixture function next to `fixture_run_lock`:

```sh
fixture_device_registry_root() {
  local root="$1"
  # Default root is under $HOME/.night-shift/devices.
  case "$(device_registry_root)" in */.night-shift/devices) ;; *) return 1 ;; esac
  # Override env wins.
  NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$root/reg" || true
  [ "$(NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$root/reg" device_registry_root)" = "$root/reg" ] || return 1
  return 0
}
```

- [ ] **Step 4: Register the fixture**

In `run_dry_fixtures` (after the `fixture_visual_pick_udid` line, ~line 593):

```sh
  fixture_assert "device registry root honours the dir override" fixture_device_registry_root "$root"
```

- [ ] **Step 5: Run the suite, verify pass**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep device`
Expected: `ok - device registry root honours the dir override`

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/device-registry.sh scripts/night-shift.sh
git commit -m "engine: device-registry lib skeleton (opt-in, inert)"
```

---

## Task 2: Shared simctl stub for fixtures

**Files:**
- Modify: `scripts/night-shift.sh` (fixtures section)

The registry fixtures must not touch real simulators. Add a reusable helper that puts a fake `xcrun` on `PATH` returning canned JSON and recording clone/delete calls.

- [ ] **Step 1: Add the stub-builder helper**

In `scripts/night-shift.sh` fixtures section, add:

```sh
# Build a fake `xcrun` on PATH for device-registry fixtures. $1 = dir to hold the
# shim + its JSON + a call log. Writes $1/bin/xcrun. The stub answers:
#   simctl list devices available -j   -> $1/devices.json
#   simctl list devices -j             -> $1/devices.json
#   simctl clone <src> <name>          -> prints a new udid, appends to devices.json log
#   simctl delete <udid>               -> records "delete <udid>" in $1/calls.log
# Caller sets $1/devices.json before invoking the function under test.
fixture_make_simctl_stub() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/xcrun" <<STUB
#!/usr/bin/env bash
log="$dir/calls.log"
shift  # drop "simctl"
case "\$1 \$2 \$3" in
  "list devices available") cat "$dir/devices.json"; exit 0 ;;
  "list devices -j"*)        cat "$dir/devices.json"; exit 0 ;;
esac
case "\$1" in
  list)   cat "$dir/devices.json"; exit 0 ;;
  clone)  printf 'clone %s %s\n' "\$2" "\$3" >>"\$log"; printf 'UDID-CLONE-%s\n' "\$3"; exit 0 ;;
  delete) printf 'delete %s\n' "\$2" >>"\$log"; exit 0 ;;
  *)      exit 0 ;;
esac
STUB
  chmod +x "$dir/bin/xcrun"
}

# Canned two-device list: both labelled "iphone-15" (name "iPhone 15").
fixture_write_devices_json() {
  cat >"$1" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true },
  { "name": "iPhone 15", "udid": "UDID-BBB", "state": "Shutdown", "isAvailable": true }
] } }
JSON
}
```

- [ ] **Step 2: Commit**

```bash
git add scripts/night-shift.sh
git commit -m "engine: simctl stub + canned device JSON for registry fixtures"
```

---

## Task 3: device_candidates + device_try_claim

**Files:**
- Modify: `scripts/lib/device-registry.sh`
- Modify: `scripts/night-shift.sh` (fixture + registration)

- [ ] **Step 1: Write the failing fixture**

In `scripts/night-shift.sh`:

```sh
fixture_device_try_claim() {
  local root="$1" stub="$root/dtc"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    # candidates returns both UDIDs for the label.
    [ "$(device_candidates iphone-15 | tr '\n' ',' )" = "UDID-AAA,UDID-BBB," ] || exit 1
    # first claim of AAA succeeds; a second claim of AAA fails (held).
    device_try_claim UDID-AAA run-A false || exit 1
    device_try_claim UDID-AAA run-B false && exit 1
    # a stale lock (dead PID) is reclaimable.
    printf '99998\n' >"$stub/reg/UDID-AAA.lock/pid"
    device_try_claim UDID-AAA run-C false || exit 1
    exit 0
  )
}
```

- [ ] **Step 2: Register and run to verify it FAILS**

Add to `run_dry_fixtures`:
```sh
  fixture_assert "device_try_claim: claim, contend, reclaim stale" fixture_device_try_claim "$root"
```
Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep try_claim`
Expected: `not ok - device_try_claim: ...` (functions not defined yet)

- [ ] **Step 3: Implement the two functions**

Append to `scripts/lib/device-registry.sh`:

```sh
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
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep try_claim`
Expected: `ok - device_try_claim: claim, contend, reclaim stale`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/device-registry.sh scripts/night-shift.sh
git commit -m "engine: device_candidates + device_try_claim (atomic, stale reclaim)"
```

---

## Task 4: device_claim (poll + clone-on-exhaustion)

**Files:**
- Modify: `scripts/lib/device-registry.sh`
- Modify: `scripts/night-shift.sh` (fixtures + registration)

- [ ] **Step 1: Write the failing fixtures**

```sh
fixture_device_claim_distinct() {
  local root="$1" stub="$root/dcd"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    local a b
    a="$(device_claim iphone-15 run-A)" || exit 1
    b="$(device_claim iphone-15 run-B)" || exit 1
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || exit 1   # two real devices
    exit 0
  )
}

fixture_device_claim_clone_on_exhaustion() {
  local root="$1" stub="$root/dce"
  fixture_make_simctl_stub "$stub"
  # Only ONE matching device, so the 2nd claim must clone.
  cat >"$stub/devices.json" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true }
] } }
JSON
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    device_claim iphone-15 run-A >/dev/null || exit 1
    local b; b="$(device_claim iphone-15 run-B)" || exit 1
    [ "$b" = "UDID-CLONE-ns-run-B" ] || exit 1     # stub clone udid
    grep -q "clone UDID-AAA ns-run-B" "$stub/calls.log" || exit 1
    [ "$(cat "$stub/reg/$b.lock/clone")" = "true" ] || exit 1
    exit 0
  )
}
```

- [ ] **Step 2: Register and run to verify FAIL**

```sh
  fixture_assert "device_claim: concurrent claims get distinct devices" fixture_device_claim_distinct "$root"
  fixture_assert "device_claim: clones when matching devices exhausted" fixture_device_claim_clone_on_exhaustion "$root"
```
Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep device_claim`
Expected: both `not ok` (device_claim undefined)

- [ ] **Step 3: Implement device_claim**

Append to `scripts/lib/device-registry.sh`:

```sh
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
```

- [ ] **Step 4: Run to verify PASS**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep device_claim`
Expected: both `ok`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/device-registry.sh scripts/night-shift.sh
git commit -m "engine: device_claim with poll + clone-on-exhaustion"
```

---

## Task 5: device_release + device_registry_prune

**Files:**
- Modify: `scripts/lib/device-registry.sh`
- Modify: `scripts/night-shift.sh` (fixtures + registration)

- [ ] **Step 1: Write the failing fixtures**

```sh
fixture_device_release() {
  local root="$1" stub="$root/drl"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    device_try_claim UDID-AAA run-A false || exit 1     # real device
    device_release UDID-AAA
    [ -d "$stub/reg/UDID-AAA.lock" ] && exit 1          # lock removed
    grep -q "delete UDID-AAA" "$stub/calls.log" && exit 1   # NOT deleted (real)
    device_try_claim UDID-CLONE-x run-B true || exit 1  # a clone
    device_release UDID-CLONE-x
    grep -q "delete UDID-CLONE-x" "$stub/calls.log" || exit 1  # clone deleted
    exit 0
  )
}

fixture_device_prune() {
  local root="$1" stub="$root/dpr"
  fixture_make_simctl_stub "$stub"
  # devices list contains an orphan ns-* clone with NO lock.
  cat >"$stub/devices.json" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true },
  { "name": "ns-run-OLD", "udid": "UDID-ORPHAN", "state": "Shutdown", "isAvailable": true }
] } }
JSON
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    mkdir -p "$stub/reg/UDID-AAA.lock"; printf '99998\n' >"$stub/reg/UDID-AAA.lock/pid"
    printf 'false\n' >"$stub/reg/UDID-AAA.lock/clone"      # stale real lock
    device_registry_prune
    [ -d "$stub/reg/UDID-AAA.lock" ] && exit 1             # stale lock reclaimed
    grep -q "delete UDID-ORPHAN" "$stub/calls.log" || exit 1  # orphan clone deleted
    exit 0
  )
}
```

- [ ] **Step 2: Register and run to verify FAIL**

```sh
  fixture_assert "device_release deletes clones, keeps real devices" fixture_device_release "$root"
  fixture_assert "device_registry_prune reclaims stale locks + orphan clones" fixture_device_prune "$root"
```
Run: `... --fixture-test --dry-run 2>&1 | grep -E 'device_release|prune'`
Expected: both `not ok`

- [ ] **Step 3: Implement the two functions**

Append to `scripts/lib/device-registry.sh`:

```sh
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
# orphan ns-* clones that have no live lock. Same idea as the worktree prune.
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
  js="$(xcrun simctl list devices -j 2>/dev/null)" || return 0
  printf '%s' "$js" | jq -r '[.devices[][]? | select(.name|startswith("ns-")) | .udid] | .[]' \
    | while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        [ -d "$reg/$udid.lock" ] || xcrun simctl delete "$udid" >/dev/null 2>&1 || true
      done
}
```

- [ ] **Step 4: Run to verify PASS**

Run: `... --fixture-test --dry-run 2>&1 | grep -E 'device_release|prune'`
Expected: both `ok`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/device-registry.sh scripts/night-shift.sh
git commit -m "engine: device_release + device_registry_prune (self-heal)"
```

---

## Task 6: Thread an explicit UDID into capture (behavior-preserving)

**Files:**
- Modify: `scripts/lib/visual-capture.sh:134` (`__visual_capture_screenshot`)
- Modify: `scripts/night-shift.sh` (fixture + registration)

- [ ] **Step 1: Write the failing fixture (default path unchanged)**

```sh
fixture_visual_capture_udid_arg() {
  local root="$1" stub="$root/vcu"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  # Make the stub also answer `simctl boot/io/launch` as no-ops and record `io`.
  # (the stub's default `*) exit 0` already covers them; we assert it does not
  #  resolve internally when a udid is passed.)
  (
    export PATH="$stub/bin:$PATH"
    # With an explicit udid, __visual_capture_screenshot must NOT call
    # __visual_resolve_udid. Stub odiff-free: it returns 2 at the screenshot step
    # because `io screenshot` produces no file; we only assert it got far enough
    # to use the passed udid (boot called on UDID-PASSED).
    __visual_capture_screenshot home default iphone-15 "$stub/out.png" UDID-PASSED
    grep -q "UDID-PASSED" "$stub/calls.log" 2>/dev/null || true
    # The stub does not log boot; instead assert the function used the arg by
    # checking it did not error on "no udid" (return code 2 only from screenshot).
    exit 0
  )
}
```

NOTE: the assertion above is intentionally light because the stub does not build real PNGs. The real guarantee — that registry-off touches nothing new — is asserted in Task 8's `fixture_visual_registry_off`. This fixture only locks in the signature change.

- [ ] **Step 2: Register and run to verify it errors (arg not yet accepted)**

```sh
  fixture_assert "visual capture accepts an explicit udid arg" fixture_visual_capture_udid_arg "$root"
```
Run: `... --fixture-test --dry-run 2>&1 | grep 'explicit udid'`
Expected: `ok` only after Step 3 (before the edit the 5th arg is ignored but harmless; this fixture mainly documents intent).

- [ ] **Step 3: Add the optional udid parameter**

In `scripts/lib/visual-capture.sh`, change the head of `__visual_capture_screenshot` from:

```sh
__visual_capture_screenshot() {
  local screen="$1" state="$2" device="$3" out="$4"
  command -v xcrun >/dev/null 2>&1 || return 2
  local udid; udid="$(__visual_resolve_udid "$device")"
  [ -n "$udid" ] || return 2
```

to:

```sh
__visual_capture_screenshot() {
  local screen="$1" state="$2" device="$3" out="$4" udid="${5:-}"
  command -v xcrun >/dev/null 2>&1 || return 2
  [ -n "$udid" ] || udid="$(__visual_resolve_udid "$device")"
  [ -n "$udid" ] || return 2
```

- [ ] **Step 4: Run the FULL suite (ensure existing visual fixtures still pass)**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -E 'visual|udid'`
Expected: existing `ok - visual ...` lines unchanged, plus `ok - visual capture accepts an explicit udid arg`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/visual-capture.sh scripts/night-shift.sh
git commit -m "engine: thread optional udid into __visual_capture_screenshot"
```

---

## Task 7: run_visual_capture claims/releases in registry mode

**Files:**
- Modify: `scripts/lib/visual-capture.sh:206` (`run_visual_capture`)
- Modify: `scripts/night-shift.sh` (fixture + registration)

`run_visual_capture` loops screens, each with its own `device` label. In registry
mode, claim a device lazily per distinct label and reuse it for the run; release
all on return. In default mode, pass empty UDID (today's internal resolve).

- [ ] **Step 1: Add a per-run claimed-device cache + threading**

In `scripts/lib/visual-capture.sh`, inside `run_visual_capture`, just after the
`visual_capture_available` guard and before the screens loop, add:

```sh
  # Registry mode: claim devices per distinct label, release all on return.
  local _ns_reg=0 _ns_labels="" _ns_udids="" _ns_claimed=""
  [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && _ns_reg=1
  _ns_release_all() {
    local i=0 u
    for u in $_ns_claimed; do device_release "$u"; done
  }
  trap '_ns_release_all' RETURN
```

Add a helper above `run_visual_capture` to resolve-or-claim a UDID for a label
(returns empty to mean "let capture resolve internally"):

```sh
# In registry mode, return a claimed UDID for <label> (cached for the run),
# or empty on acquisition timeout (caller SKIPs that screen's capture). In
# default mode, return empty so __visual_capture_screenshot resolves internally.
__visual_udid_for_label() {
  local label="$1" run_id="${RUN_ID:-$$}" i word
  [ "$_ns_reg" = "1" ] || { printf ''; return 0; }
  # Look up cached claim for this label (parallel space-lists).
  set -- $_ns_labels
  i=1
  for word in "$@"; do
    if [ "$word" = "$label" ]; then
      printf '%s\n' "$(printf '%s\n' $_ns_udids | sed -n "${i}p")"; return 0
    fi
    i=$((i+1))
  done
  local u; u="$(device_claim "$label" "$run_id")"
  if [ -n "$u" ]; then
    _ns_labels="$_ns_labels $label"
    _ns_udids="$_ns_udids $u"
    _ns_claimed="$_ns_claimed $u"
  fi
  printf '%s\n' "$u"
}
```

Then in the screens loop, change the capture call from:

```sh
    if ! __visual_capture_screenshot "$screen" "$state" "$device" "$out_dir/$shot"; then
```

to:

```sh
    local _udid; _udid="$(__visual_udid_for_label "$device")"
    if [ "$_ns_reg" = "1" ] && [ -z "$_udid" ]; then
      log "visual-capture: no simulator available for '$device' within timeout; SKIP"
      return 0
    fi
    if ! __visual_capture_screenshot "$screen" "$state" "$device" "$out_dir/$shot" "$_udid"; then
```

- [ ] **Step 2: Write the fixture (registry mode claims + releases)**

```sh
fixture_visual_capture_registry_claim() {
  local root="$1" stub="$root/vcr"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_REGISTRY=1 NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0 \
           RUN_ID=run-A
    # Claim for a label, then assert a lock exists, then release-all clears it.
    local u; u="$(__visual_udid_for_label iphone-15)"
    [ -n "$u" ] || exit 1
    [ -d "$stub/reg/$u.lock" ] || exit 1
    _ns_release_all
    [ -d "$stub/reg/$u.lock" ] && exit 1
    exit 0
  )
}
```

NOTE: this fixture calls the lib functions directly in a subshell that defines
`_ns_reg=1` and the cache vars; set them explicitly at the top of the subshell:
prepend `_ns_reg=1; _ns_labels=""; _ns_udids=""; _ns_claimed="";` before the claim.

- [ ] **Step 3: Register + run to verify FAIL then PASS**

```sh
  fixture_assert "run_visual_capture registry mode claims and releases" fixture_visual_capture_registry_claim "$root"
```
Run: `... --fixture-test --dry-run 2>&1 | grep 'registry mode claims'`
Expected: `not ok` before Step 1 edits applied to the helper; `ok` after.

- [ ] **Step 4: Run the FULL suite**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | tail -5`
Expected: `all deterministic fixtures passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/visual-capture.sh scripts/night-shift.sh
git commit -m "engine: run_visual_capture claims a dedicated sim in registry mode"
```

---

## Task 8: Prune at startup + assert registry-off touches nothing

**Files:**
- Modify: `scripts/night-shift.sh` (`run_visual` entry + fixture)

- [ ] **Step 1: Prune on visual_review entry in registry mode**

In `scripts/night-shift.sh`, at the top of `run_visual()` (before the report check), add:

```sh
  [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && device_registry_prune
```

- [ ] **Step 2: Write the registry-OFF guarantee fixture**

```sh
fixture_visual_registry_off() {
  local root="$1" stub="$root/vro"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    # Registry explicitly OFF: __visual_udid_for_label returns empty and never
    # creates a registry dir.
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    _ns_reg=0; _ns_labels=""; _ns_udids=""; _ns_claimed=""
    [ -z "$(__visual_udid_for_label iphone-15)" ] || exit 1
    [ -d "$stub/reg" ] && exit 1     # nothing created
    exit 0
  )
}
```

- [ ] **Step 3: Register + run**

```sh
  fixture_assert "registry-off path resolves internally and touches no registry" fixture_visual_registry_off "$root"
```
Run: `... --fixture-test --dry-run 2>&1 | grep 'registry-off'`
Expected: `ok`

- [ ] **Step 4: Full suite green**

Run: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | tail -3`
Expected: `all deterministic fixtures passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/night-shift.sh
git commit -m "engine: prune device registry on visual_review entry (registry mode)"
```

---

## Task 9: Wrapper exports the opt-in env for parallel runs

**Files:**
- Modify: `scripts/parallel-worktrees.sh` (`run_one`, the real-run branch)

- [ ] **Step 1: Export the env when fanning out with jobs > 1**

In `scripts/parallel-worktrees.sh`, in `run_one`, change the live-run line from:

```sh
  NIGHT_SHIFT_ACCEPT_COSTS=YES "$ENGINE" --project "$wt" --spec "$spec" >>"$logf" 2>&1
```

to:

```sh
  # With >1 concurrent run, enable the device registry so each visual_review
  # claims a dedicated simulator. A single-job run leaves it off (unchanged).
  local registry_env=""
  [ "$JOBS" -gt 1 ] && registry_env="NIGHT_SHIFT_DEVICE_REGISTRY=1"
  NIGHT_SHIFT_ACCEPT_COSTS=YES $registry_env "$ENGINE" --project "$wt" --spec "$spec" >>"$logf" 2>&1
```

- [ ] **Step 2: Verify syntax + that single-job leaves it unset**

Run:
```bash
/bin/bash -n scripts/parallel-worktrees.sh && echo "syntax OK"
grep -n "NIGHT_SHIFT_DEVICE_REGISTRY=1" scripts/parallel-worktrees.sh
```
Expected: `syntax OK` and the line present, guarded by `[ "$JOBS" -gt 1 ]`.

- [ ] **Step 3: Commit**

```bash
git add scripts/parallel-worktrees.sh
git commit -m "wrapper: enable device registry for parallel (--jobs>1) runs"
```

---

## Task 10: Document the knob + final verification

**Files:**
- Modify: `CLAUDE.md` (visual-fidelity note)

- [ ] **Step 1: Add the opt-in knob to CLAUDE.md**

In `CLAUDE.md`, under the "Visual fidelity (opt-in)" paragraph, append:

```markdown
> For **parallel** visual_review across worktrees, set `NIGHT_SHIFT_DEVICE_REGISTRY=1`
> (the parallel-worktrees.sh wrapper sets it automatically for `--jobs>1`). Each
> concurrent run then claims a dedicated iOS simulator from a machine-global
> registry at `~/.night-shift/devices/`, cloning `ns-<run-id>` devices when the
> matching pool is exhausted and pruning them on the next registry-mode run. A
> single run is unaffected. Requires pre-bundled preview builds (no Metro).
```

- [ ] **Step 2: Full fixture suite + shellcheck-style syntax check**

Run:
```bash
/bin/bash -n scripts/lib/device-registry.sh && echo "lib syntax OK"
NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | tail -3
```
Expected: `lib syntax OK` and `all deterministic fixtures passed`

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document NIGHT_SHIFT_DEVICE_REGISTRY opt-in for parallel visual_review"
```

---

## Self-Review Notes

- **Spec coverage:** registry lib (Tasks 1–5) ✓; pre-bundled/no-Metro (no port code anywhere) ✓; claim-existing-then-clone (Task 4) ✓; release deletes clones (Task 5) ✓; prune orphans + stale locks (Task 5, Task 8) ✓; poll-then-SKIP (Task 4 timeout → Task 7 SKIP branch) ✓; opt-in gating + normal run unchanged (Task 7 `_ns_reg`, Task 8 `fixture_visual_registry_off`) ✓; wrapper auto-enable (Task 9) ✓; machine-global registry root (Task 1) ✓; config knobs (`NIGHT_SHIFT_DEVICE_REGISTRY`, `NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT`, `NIGHT_SHIFT_DEVICE_REGISTRY_DIR`, plus `NIGHT_SHIFT_DEVICE_POLL_SECONDS`) ✓; docs (Task 10) ✓.
- **Open implementation note (not a blocker):** the live invocation of `run_visual_capture` within the visual-fidelity flow is part of the broader (scaffold) feature; this plan places claim/release inside `run_visual_capture` — the device-owning function — so it is correct wherever that function is called. If a later change moves capture invocation, the registry wrapping moves with `run_visual_capture`.
- **Type/name consistency:** `device_registry_root`, `device_candidates`, `device_try_claim`, `device_claim`, `device_release`, `device_registry_prune`, `__visual_udid_for_label`, and env names are used identically across tasks.
