# Spec: Fix visual-repair hyphen hazard, global-cap over-count, and default drift

> Engine self-improvement issue-spec. Target repo: **this repo**.
> Priority: **HIGH**. Contains a ready-to-apply concrete patch for the hyphen bug.

---

## Status

- [x] Draft
- [ ] Ready for implementation
- [ ] In progress
- [ ] Done — branch: `feat/engine-visual-repair-fixes`

---

## Repository

- Project path: `night-shift-engine/`
- Base branch: `main`
- Feature branch: `feat/engine-visual-repair-fixes`
- Track: node (bash; shellcheck + `--fixture-test`)
- Files: `scripts/lib/visual-repair.sh`, `scripts/visual-review.sh`,
  `scripts/night-shift.sh`, plus docs

---

## Problem

Three defects in the opt-in visual auto-repair path:

### 1. Hyphen/space screen-name hazard (correctness + injection) — primary bug

The per-screen Figma node id is passed from `_repair_one` to `repair_agent` through
a **dynamically-named global variable** built from the raw screen name:

- `_repair_one` (visual-repair.sh:397): `eval "REPAIR_NODE_$sc=\"...\""`
- `repair_agent` (visual-repair.sh:349):
  `node="$REPAIR_NODE_${screen}"; node="${!node:-$REPAIR_FALLBACK_NODE}"`

For any screen/frame name containing a hyphen or space — the **common** Figma
frame-naming case (`Home-Detail`, `Sign Up`) — `REPAIR_NODE_Home-Detail` is not a
valid shell identifier. So:
- the `eval` assignment fails at runtime (error on stderr; nothing assigned), and
- the `${!node}` indirection resolves to nothing and silently falls back to
  `REPAIR_FALLBACK_NODE` (the spec's first/default node) instead of this screen's
  node id.

It is also an `eval` with an interpolated, externally-derived name — an injection
surface. (Today `repair_agent` happens not to consume `$node` in its prompt, so the
*visible* repair output may be unaffected — but it is a live error path under
`set -u` and a booby-trap that silently feeds the wrong node the moment `$node` is
wired in. Fix it now.)

### 2. Global-cap over-count

`_repair_one` always reports `$max` as attempts consumed (visual-repair.sh:407),
but `visual_repair_run` treats that last stdout line as the real count and charges
it against `NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP` (visual-repair.sh:424-426). A
screen that converges on attempt 1 still bills `$max`, so the global cap (default
30) trips far earlier than intended — fewer screens get repaired than the operator
budgeted for. The true count is available: `visual_repair_screen` records every
attempt (repairs numbered from 2) in the screen object it prints.

### 3. Default-attempts drift (code 6 vs docs 3)

Code defaults to 6 attempts; the documented contract says 3:
- `scripts/visual-review.sh:74` `MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-6}"`
- `scripts/night-shift.sh:1484` `"${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-6}"`
- `CLAUDE.md:128` and `docs/COMMAND-PLAYBOOK.md:69` say **default 3**.

Each attempt is a paid `opus` repair call, so the drift silently doubles cost
versus the published default.

---

## Concrete fix (ready to apply)

`scripts/lib/visual-repair.sh` runs under `set -u` (it is sourced by
`night-shift.sh` / `visual-review.sh`); the patch below is `set -u`-safe.

**A. Replace the dynamic var + eval with one fixed-name var.**

In `repair_agent` (~line 349):

```diff
-  key="$REPAIR_FILEKEY"; node="$REPAIR_NODE_${screen}"; node="${!node:-$REPAIR_FALLBACK_NODE}"
+  # Per-screen node id is set by _repair_one as a single fixed-name var. The old
+  # REPAIR_NODE_${screen} dynamic name + ${!node} indirection built an INVALID
+  # identifier for any screen name with a hyphen/space (the common Figma frame
+  # case), failing under set -u and silently degrading to the fallback node.
+  key="$REPAIR_FILEKEY"; node="${REPAIR_NODE_CURRENT:-$REPAIR_FALLBACK_NODE}"
```

In `_repair_one` (~line 397):

```diff
-    eval "REPAIR_NODE_$sc=\"$(node_id_for "$spec" "$sc")\""
+    # No eval / dynamic var name: works for any screen name and removes the
+    # eval-injection surface. repair_agent reads REPAIR_NODE_CURRENT.
+    REPAIR_NODE_CURRENT="$(node_id_for "$spec" "$sc")"
```

**B. Report attempts actually consumed (fix the global cap).**

In `_repair_one` (~lines 403-407):

```diff
-    visual_repair_screen "$project" "$out_dir/_rsnap" "$out_dir" "$sc" "$st" "$dv" \
-      "$out_dir/design/$sc-$st-$dv.png" "$out_dir/screenshots/$candidate_label/$sc-$st-$dv.png" \
-      "$out_dir/diffs/$candidate_label/$sc-$st-$dv.png" "$(visual_capture_tolerance "$spec")" \
-      "$max" repair_agent repair_recapture_screen repair_validate "$allow_csv" >/dev/null
-    printf '%s\n' "$max"
+    # Capture the assembled screen object so we report attempts ACTUALLY consumed
+    # (repairs are numbered from attempt 2), not the per-screen max — otherwise the
+    # global cap is charged $max per screen and trips early. On parse failure fall
+    # back to $max (conservative over-count, never an under-count).
+    local _screen_json _consumed
+    _screen_json="$(visual_repair_screen "$project" "$out_dir/_rsnap" "$out_dir" "$sc" "$st" "$dv" \
+      "$out_dir/design/$sc-$st-$dv.png" "$out_dir/screenshots/$candidate_label/$sc-$st-$dv.png" \
+      "$out_dir/diffs/$candidate_label/$sc-$st-$dv.png" "$(visual_capture_tolerance "$spec")" \
+      "$max" repair_agent repair_recapture_screen repair_validate "$allow_csv")"
+    _consumed="$(printf '%s' "$_screen_json" | jq -r '[.attempts[]?|select(.attempt>1)]|length' 2>/dev/null)"
+    case "$_consumed" in (''|*[!0-9]*) _consumed="$max" ;; esac
+    printf '%s\n' "$_consumed"
```

(`visual_repair_screen`'s exit status was already ignored on this path — the old
code ran it then `printf`'d — so capturing its stdout changes no control flow.)

**C. Reconcile the default to the documented 3.**

```diff
- scripts/visual-review.sh:74   MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-6}"
+ scripts/visual-review.sh:74   MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}"

- scripts/night-shift.sh:1484   "${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-6}" \
+ scripts/night-shift.sh:1484   "${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" \
```

(Alternative: change the docs to 6. Reconciling code → 3 is preferred: it matches
the published contract and is the cheaper default.)

---

## Acceptance criteria

- [ ] AC1: A spec with a hyphenated/spaced frame name resolves the **correct**
  per-screen node id in `repair_agent` (no fallback, no eval error on stderr).
- [ ] AC2: No `eval` remains in the node-id pass-through; `shellcheck` clean.
- [ ] AC3: The global repair cap is charged the **actual** attempts each screen
  consumed; a screen that passes on attempt 1 bills 1 (or 0 if no repair ran), not
  `$max`.
- [ ] AC4: `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` unset yields **3** attempts in both
  entry points, matching `CLAUDE.md` / `COMMAND-PLAYBOOK.md`.

## Validation

- `shellcheck scripts/lib/visual-repair.sh scripts/visual-review.sh scripts/night-shift.sh`
  clean under `.shellcheckrc`.
- `scripts/night-shift.sh --fixture-test --dry-run` passes.
- Add a fixture: a screen named with a hyphen → assert the resolved node id equals
  `node_id_for` (not the fallback); and a screen that passes on attempt 1 → assert
  the global-cap counter increments by ≤1.

## Out of scope

- The aspect-ratio sanity check before `odiff` resize (LOW; separate item).
- Any change to the capture drive modes (file/launcharg/openurl/maestro).

## Related

- Audit recommendation #3 (HIGH).
