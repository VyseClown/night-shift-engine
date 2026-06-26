# Repair Keep-Best + Audit Trail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `visual_repair_screen` converge as close to the design as possible — keep the best-scoring attempt, iterate to diminishing returns, and always end on the best (never worse than the pre-repair baseline) — and produce a visible audit trail (baseline + per-attempt images + a "what changed" line).

**Architecture:** Two sequential changes to the shared repair primitive `scripts/lib/visual-repair.sh` (Task 2 builds on Task 1's rewritten loop), plus a one-line cap-default bump in the two callers. No schema change; the report populates fields the `visual-diff` schema already defines.

**Tech Stack:** Bash (`set -uo pipefail`, shellcheck-clean at default severity), `jq`, `awk` for float compares. Tests = deterministic fixtures in `scripts/test/fixtures.sh` modeled on `fixture_visual_repair_loop`.

**Spec:** `docs/superpowers/specs/2026-06-25-repair-keep-best-design.md`.

## Global Constraints

- Work in the worktree `/Users/alessandrogentil/fidelity-wt` (branch `feat/repair-keep-best`, off `main`).
- Fixture suite: `NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run` — pass = `grep -c "not ok"` is `0`.
- Shellcheck **default severity**: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} +` must exit `0`.
- All diff_pct compares use `awk` (fractions like `0.0903`), never shell `[ ]` numeric.
- Knobs/defaults: `NIGHT_SHIFT_VISUAL_REPAIR_EPSILON` (0.005), `NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE` (2), hard-cap default `NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS` raised **3→6**.
- Never-worse: the loop must end on the best of {baseline, all attempts}; if nothing beats the baseline, restore the baseline (no change).
- Figma is read ONLY via the MCP (`mcp__figma__get_figma_data`); never a token/REST. The agent prompt keeps this.

## File Structure

- **Modify** `scripts/lib/visual-repair.sh` — rewrite `visual_repair_screen`'s loop (Task 1); add per-attempt/baseline images + `changed` analysis (Task 2); add `changed` to `repair_agent`'s prompt + result threading (Task 2).
- **Modify** `scripts/visual-review.sh:73` and `scripts/night-shift.sh:1415` — cap default `:-3` → `:-6` (Task 1).
- **Modify** `scripts/test/fixtures.sh` — update `fixture_visual_repair_loop` for the new iteration semantics + add new fixtures (Tasks 1-2).

---

### Task 1: Keep-best + converge-to-diminishing-returns

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`visual_repair_screen`)
- Modify: `scripts/visual-review.sh:73`, `scripts/night-shift.sh:1415`
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Produces: `visual_repair_screen` (same 15-arg signature) now seeds best from a baseline diff of the incoming `shot`, tracks the best-scoring attempt (improve = `cur <= best - EPSILON`), stops on tolerance / `PATIENCE` consecutive non-improving attempts / the `max` cap, restores the best code+images before returning, reports `diff_pct = best`, and returns success iff `best <= tol`.

- [ ] **Step 1: Write the failing tests.** In `scripts/test/fixtures.sh`, register after the existing `fixture_visual_repair_loop` line (`fixture_assert "visual repair loop: converge on pass" fixture_visual_repair_loop "$root"`):

```bash
  fixture_assert "visual repair: keeps the best attempt (not the last)" fixture_visual_repair_keepbest "$root"
  fixture_assert "visual repair: never worse than the pre-repair baseline" fixture_visual_repair_neverworse "$root"
  fixture_assert "visual repair: patience stop on diminishing returns" fixture_visual_repair_patience "$root"
```

Add the three fixtures (each: a temp git project; the agent writes the attempt number into the screen file so the restored-to-best code is checkable; a diff sequence via `NIGHT_SHIFT_VISUAL_DIFF_FN`; note **call 1 is the baseline diff**):

```bash
fixture_visual_repair_keepbest() {
  local root="$1" proj="$root/kbp" out="$root/kbout"
  mkdir -p "$proj/src/features/home" "$out/design"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"; : >"$out/shot.png"; : >"$out/diff.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _an=0; _agent(){ _an=$((_an+1)); printf '%s' "$_an" >"$proj/src/features/home/HomeScreen.tsx"; printf '{}'; }
    _cap(){ :; }; _ok(){ return 0; }
    # call1=baseline 0.40, a1=0.30, a2=0.09 (best), a3=0.12
    _seq=(0.40 0.30 0.09 0.12); _i=0
    _diffseq(){ printf '%s' "${_seq[$_i]}"; _i=$((_i+1)); return 0; }
    export NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE=9
    NIGHT_SHIFT_VISUAL_DIFF_FN=_diffseq
    obj="$(visual_repair_screen "$proj" "$root/kt" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.01 3 _agent _cap _ok "src/features/")"
    # best is attempt 2 (0.09): report shows 0.09 and the code is restored to attempt-2's marker.
    printf '%s' "$obj" | jq -e '.diff_pct==0.09 and (.attempts|length)==3' >/dev/null || exit 1
    [ "$(cat "$proj/src/features/home/HomeScreen.tsx")" = "2" ] || exit 1
    exit 0
  ) || return 1
  return 0
}

fixture_visual_repair_neverworse() {
  local root="$1" proj="$root/nwp" out="$root/nwout"
  mkdir -p "$proj/src/features/home" "$out/design"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"; : >"$out/shot.png"; : >"$out/diff.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _agent(){ printf 'WORSE' >"$proj/src/features/home/HomeScreen.tsx"; printf '{}'; }
    _cap(){ :; }; _ok(){ return 0; }
    # baseline 0.10; every attempt is worse (0.30).
    _seq=(0.10 0.30 0.30 0.30); _i=0
    _diffseq(){ printf '%s' "${_seq[$_i]}"; _i=$((_i+1)); return 0; }
    export NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE=2
    NIGHT_SHIFT_VISUAL_DIFF_FN=_diffseq
    obj="$(visual_repair_screen "$proj" "$root/nt" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.05 6 _agent _cap _ok "src/features/")"
    # best is the baseline 0.10; the worse edits were discarded (file back to empty baseline).
    printf '%s' "$obj" | jq -e '.diff_pct==0.10' >/dev/null || exit 1
    [ ! -s "$proj/src/features/home/HomeScreen.tsx" ] || exit 1
    exit 0
  ) || return 1
  return 0
}

fixture_visual_repair_patience() {
  local root="$1" proj="$root/ptp" out="$root/ptout"
  mkdir -p "$proj/src/features/home" "$out/design"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"; : >"$out/shot.png"; : >"$out/diff.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _an=0; _agent(){ _an=$((_an+1)); printf '%s' "$_an" >"$proj/src/features/home/HomeScreen.tsx"; printf '{}'; }
    _cap(){ :; }; _ok(){ return 0; }
    # baseline 0.40; a1 0.30, a2 0.20 (best); a3 0.205, a4 0.207 -> 2 non-improving -> stop at 4 (< max 6).
    _seq=(0.40 0.30 0.20 0.205 0.207 0.20 0.20); _i=0
    _diffseq(){ printf '%s' "${_seq[$_i]}"; _i=$((_i+1)); return 0; }
    export NIGHT_SHIFT_VISUAL_REPAIR_EPSILON=0.005 NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE=2
    NIGHT_SHIFT_VISUAL_DIFF_FN=_diffseq
    obj="$(visual_repair_screen "$proj" "$root/pt" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.01 6 _agent _cap _ok "src/features/")"
    printf '%s' "$obj" | jq -e '.diff_pct==0.20 and (.attempts|length)==4' >/dev/null || exit 1
    exit 0
  ) || return 1
  return 0
}
```

Then **update `fixture_visual_repair_loop`** for the new semantics (the baseline diff consumes the first `_diffseq` call, and patience would otherwise cut the never-converge case short):
- In its first subshell, change `_diffseq` from `[ "$_N" -ge 2 ]` to `[ "$_N" -ge 3 ]` (baseline=call1=0.30, a1=call2=0.30, a2=call3=0.05 → still 2 attempts, pass). The `.attempts|length)==2 and (.unmet_brief==["spacing"])` assertion stays.
- In its second subshell (the `_hi` never-converge + `_bad` revert cases), add `export NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE=99` at the top of the subshell so the always-0.30 case still runs the full 3 attempts (`(.attempts|length)==3 and .pass==false` stays valid; `_hi` now also serves the baseline call — fine, it's constant).

- [ ] **Step 2: Run tests to verify they fail.**

Run: `cd /Users/alessandrogentil/fidelity-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -E "keeps the best|never worse|patience stop"`
Expected: three `not ok …` (the current loop keeps the last attempt, has no baseline seed, and no patience stop).

- [ ] **Step 3: Rewrite the loop.** Replace the entire body of `visual_repair_screen` in `scripts/lib/visual-repair.sh` (from `local IFS_OLD=...` through the final `[ "$passed" = "1" ]`, keeping the function signature line) with:

```bash
  local IFS_OLD="$IFS"; IFS=','; read -r -a allow <<<"$allow_csv"; IFS="$IFS_OLD"
  local attempts="[]" unmet="[]" cur="" n=0 snap="$tmpbase/snap" passed=0 agent_out
  local _pct_file="$tmpbase/_pct"
  local best_pct="" best_snap="$tmpbase/best" best_shot="$tmpbase/best.shot" best_diff="$tmpbase/best.diff" stall=0
  local epsilon="${NIGHT_SHIFT_VISUAL_REPAIR_EPSILON:-0.005}" patience="${NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE:-2}"
  mkdir -p "$tmpbase"
  # Seed "best" with the pre-repair baseline: if no attempt beats it, end on no change.
  if visual_repair_diff "$ref" "$shot" "$diff_img" >"$_pct_file" 2>/dev/null; then
    best_pct="$(cat "$_pct_file")"
    visual_repair_snapshot "$project" "$best_snap" "${allow[@]}"
    cp "$shot" "$best_shot" 2>/dev/null || true; cp "$diff_img" "$best_diff" 2>/dev/null || true
  fi
  while [ "$n" -lt "$max" ]; do
    n=$((n+1))
    visual_repair_snapshot "$project" "$snap" "${allow[@]}"
    agent_out="$("$agent_fn" "$screen" "$state" "$ref" "$shot" "$diff_img" "$cur" "$tol" "$out_dir" 2>/dev/null || printf '{}')"
    unmet="$(printf '%s' "$agent_out" | jq -c '.unmet_brief // []' 2>/dev/null || printf '[]')"
    if ! visual_repair_scope_check "$project" "${allow[@]}" || ! "$validate_fn" "$project"; then
      log "visual-repair: $screen attempt $n failed scope/validation; reverting"
      visual_repair_restore "$project" "$snap" "${allow[@]}"
      attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --arg s "$shot" --arg d "$diff_img" \
        '. + [{attempt:$a, diff_pct:0, pass:false, analysis:"reverted: scope/validation failed", screenshot:$s, diff_image:$d}]')"
      break
    fi
    local _try=0 _dok=0
    while [ "$_try" -lt 2 ]; do
      _try=$((_try+1))
      "$capture_fn" "$screen" "$state" "$device" "$shot"
      if visual_repair_diff "$ref" "$shot" "$diff_img" >"$_pct_file" 2>/dev/null; then _dok=1; break; fi
      [ "$_try" -lt 2 ] && { log "visual-repair: $screen re-capture diff failed; retrying after settle"; sleep "${NIGHT_SHIFT_VISUAL_RECAPTURE_SETTLE:-5}"; }
    done
    [ "$_dok" = "1" ] || printf '1' >"$_pct_file"
    cur="$(cat "$_pct_file")"
    local pass; pass="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --argjson p "$cur" --argjson ps "$pass" \
      --arg s "$shot" --arg d "$diff_img" \
      '. + [{attempt:$a, diff_pct:$p, pass:$ps, analysis:"", screenshot:$s, diff_image:$d}]')"
    local improved; improved="$(LC_ALL=C awk -v c="$cur" -v b="$best_pct" -v e="$epsilon" 'BEGIN{ if (b=="") print "yes"; else print (c <= b - e)?"yes":"no" }')"
    if [ "$improved" = "yes" ]; then
      best_pct="$cur"; visual_repair_snapshot "$project" "$best_snap" "${allow[@]}"
      cp "$shot" "$best_shot" 2>/dev/null || true; cp "$diff_img" "$best_diff" 2>/dev/null || true
      stall=0
    else
      stall=$((stall+1))
    fi
    if [ "$pass" = "true" ]; then break; fi
    [ "$stall" -ge "$patience" ] && { log "visual-repair: $screen improvement stalled; stopping"; break; }
  done
  # End on the best: restore the best code + images.
  if [ -d "$best_snap" ]; then
    visual_repair_restore "$project" "$best_snap" "${allow[@]}"
    cp "$best_shot" "$shot" 2>/dev/null || true; cp "$best_diff" "$diff_img" 2>/dev/null || true
    cur="$best_pct"
  fi
  [ -n "$cur" ] || cur="1"
  passed="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?1:0}')"
  visual_assemble_screen "$screen" "$state" "$device" "$ref" "$shot" "$cur" "$tol" "$diff_img" "" "$attempts" "$unmet"
  [ "$passed" = "1" ]
```

- [ ] **Step 4: Raise the cap default.** In `scripts/visual-review.sh:73` change `MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}"` to `:-6`. In `scripts/night-shift.sh:1415` change `"${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}"` to `:-6`.

- [ ] **Step 5: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/fidelity-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0` (new fixtures pass AND the updated `fixture_visual_repair_loop` passes)
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 6: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/visual-review.sh scripts/night-shift.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): keep-best + converge-to-diminishing-returns (never worse than baseline)"
```

---

### Task 2: Audit trail — per-attempt/baseline images + "what changed"

**Files:**
- Modify: `scripts/lib/visual-repair.sh` (`visual_repair_screen` — building on Task 1; `repair_agent` prompt)
- Test: `scripts/test/fixtures.sh`

**Interfaces:**
- Consumes: Task 1's rewritten loop (the baseline-seed block, the per-attempt record line, the best-tracking block, the final `visual_assemble_screen` call).
- Produces: `attempts[]` gains an `attempt: 0` baseline entry and each attempt records a **distinct** `<shot>.attempt-N.png` / `<diff>.attempt-N.png` plus an `analysis` from the agent's `changed`; the screen-level `analysis` is the best attempt's `changed`. `repair_agent` returns `{"changed":"…","unmet_brief":[…]}`.

- [ ] **Step 1: Write the failing test.** Register after the Task-1 fixtures:

```bash
  fixture_assert "visual repair: records baseline + per-attempt images and what-changed" fixture_visual_repair_audit "$root"
```

Add the fixture (capture stub writes a **distinct** byte per call so the per-attempt files differ; agent returns `changed`):

```bash
fixture_visual_repair_audit() {
  local root="$1" proj="$root/aup" out="$root/auout"
  mkdir -p "$proj/src/features/home" "$out/design"
  git -C "$proj" init -q && git -C "$proj" config user.email t@t && git -C "$proj" config user.name t
  : >"$proj/src/features/home/HomeScreen.tsx"; git -C "$proj" add -A; git -C "$proj" commit -qm base
  : >"$out/design/Home-default-iphone-15.png"
  (
    . "$WORKSPACE_ROOT/scripts/lib/visual-capture.sh"; . "$WORKSPACE_ROOT/scripts/lib/visual-repair.sh"; log(){ :; }
    _an=0; _agent(){ _an=$((_an+1)); printf '%s' "$_an" >"$proj/src/features/home/HomeScreen.tsx"; printf '{"changed":"grew ring","unmet_brief":[]}'; }
    _cn=0; _cap(){ _cn=$((_cn+1)); printf 'shot%s' "$_cn" >"$4"; }   # capture_fn args: screen state device SHOT($4); distinct bytes/attempt
    _ok(){ return 0; }
    printf 'base' >"$out/shot.png"; printf 'base' >"$out/diff.png"
    _seq=(0.40 0.30 0.09 0.12); _i=0; _diffseq(){ printf '%s' "${_seq[$_i]}"; _i=$((_i+1)); return 0; }
    export NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE=9
    NIGHT_SHIFT_VISUAL_DIFF_FN=_diffseq
    obj="$(visual_repair_screen "$proj" "$root/at" "$out" Home default iphone-15 \
        "$out/design/Home-default-iphone-15.png" "$out/shot.png" "$out/diff.png" 0.01 3 _agent _cap _ok "src/features/")"
    # baseline attempt-0 + 3 attempts, each a distinct screenshot path that exists; analysis carried.
    printf '%s' "$obj" | jq -e '(.attempts|length)==4 and (.attempts[0].attempt==0) and (.attempts[0].analysis|test("baseline")) and (.attempts[2].analysis=="grew ring") and .analysis=="grew ring"' >/dev/null || exit 1
    [ -s "$out/shot.attempt-0.png" ] && [ -s "$out/shot.attempt-1.png" ] && [ -s "$out/shot.attempt-2.png" ] || exit 1
    [ "$(printf '%s' "$obj" | jq -r '.attempts[2].screenshot')" = "$out/shot.attempt-2.png" ] || exit 1
    exit 0
  ) || return 1
  return 0
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `cd /Users/alessandrogentil/fidelity-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep "per-attempt images"`
Expected: `not ok …` (no baseline entry, attempts share one path, analysis is `""`).

- [ ] **Step 3: Implement the audit trail.** Make these edits to `visual_repair_screen` (post-Task-1):

(a) **Track the best's "what changed".** Add `best_changed=""` to the best-state `local` line. In the baseline-seed block, after the snapshot, write the baseline images + a baseline entry, replacing the `attempts="[]"` initializer — change `local attempts="[]" …` to `local attempts="…"` is awkward; instead, after the baseline-seed `if` block, add:

```bash
  # Baseline ("before") audit entry + image copies (attempt 0).
  if [ -n "$best_pct" ]; then
    cp "$shot" "${shot%.png}.attempt-0.png" 2>/dev/null || true
    cp "$diff_img" "${diff_img%.png}.attempt-0.png" 2>/dev/null || true
    local _bpass; _bpass="$(LC_ALL=C awk -v p="$best_pct" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson p "$best_pct" --argjson ps "$_bpass" \
      --arg s "${shot%.png}.attempt-0.png" --arg d "${diff_img%.png}.attempt-0.png" \
      '. + [{attempt:0, diff_pct:$p, pass:$ps, analysis:"baseline (before repair)", screenshot:$s, diff_image:$d}]')"
  fi
```

(b) **Per-attempt `changed` + distinct images.** In the loop, after `unmet="$(…)"`, add:
```bash
    local changed; changed="$(printf '%s' "$agent_out" | jq -r '.changed // ""' 2>/dev/null || printf '')"
```
Then replace the success-path attempt-record block:
```bash
    cur="$(cat "$_pct_file")"
    local pass; pass="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --argjson p "$cur" --argjson ps "$pass" \
      --arg s "$shot" --arg d "$diff_img" \
      '. + [{attempt:$a, diff_pct:$p, pass:$ps, analysis:"", screenshot:$s, diff_image:$d}]')"
```
with:
```bash
    cur="$(cat "$_pct_file")"
    cp "$shot" "${shot%.png}.attempt-$n.png" 2>/dev/null || true
    cp "$diff_img" "${diff_img%.png}.attempt-$n.png" 2>/dev/null || true
    local pass; pass="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$n" --argjson p "$cur" --argjson ps "$pass" \
      --arg an "$changed" --arg s "${shot%.png}.attempt-$n.png" --arg d "${diff_img%.png}.attempt-$n.png" \
      '. + [{attempt:$a, diff_pct:$p, pass:$ps, analysis:$an, screenshot:$s, diff_image:$d}]')"
```

(c) **Best carries its `changed`.** In the `if [ "$improved" = "yes" ]; then` block, add `best_changed="$changed"` after `best_pct="$cur"`.

(d) **Screen-level analysis = best's changed.** In the final `visual_assemble_screen` call, change the empty analysis arg `""` to `"$best_changed"`:
```bash
  visual_assemble_screen "$screen" "$state" "$device" "$ref" "$shot" "$cur" "$tol" "$diff_img" "$best_changed" "$attempts" "$unmet"
```

- [ ] **Step 4: Add `changed` to the repair agent.** In `repair_agent` (`scripts/lib/visual-repair.sh`), change the final prompt line from:
```bash
When done, print ONLY a JSON object: {\"unmet_brief\":[\"<specs/comments you could not satisfy>\"]}."
```
to:
```bash
When done, print ONLY a JSON object: {\"changed\":\"<one concise line describing the visual change you made>\", \"unmet_brief\":[\"<specs/comments you could not satisfy>\"]}."
```

- [ ] **Step 5: Run tests + shellcheck.**

Run: `cd /Users/alessandrogentil/fidelity-wt && NIGHT_SHIFT_ACCEPT_COSTS=YES scripts/night-shift.sh --fixture-test --dry-run 2>&1 | grep -c "not ok"` → Expected `0` (Task-1 fixtures still pass; their agents return `{}` so `changed` is `""`, and they assert `attempts|length` counting the baseline — **update the Task-1 fixtures' length assertions by +1** for the baseline entry: keepbest `==4`, patience `==5`; neverworse is unaffected (asserts only `diff_pct`). `fixture_visual_repair_loop` agents return `{}`/`{"unmet_brief":…}` so analysis stays `""` and its length assertions gain the baseline `+1` → update `==2`→`==3` and `==3`→`==4`.)
Run: `find scripts -name '*.sh' -type f -exec shellcheck -s bash {} + ; echo $?` → Expected `0`

- [ ] **Step 6: Commit.**

```bash
git add scripts/lib/visual-repair.sh scripts/test/fixtures.sh
git commit -m "feat(visual-repair): per-attempt + baseline images and what-changed analysis in the report"
```

---

## Self-Review

**Spec coverage:** §3 keep-best/patience/never-worse/end-on-best → Task 1; §4 knobs + cap 3→6 → Task 1 Steps 3-4; §3.1 per-attempt+baseline images → Task 2 Steps 3a-3b; §3.2 "what changed" → Task 2 Steps 3b-3d, 4; §6 fixtures → Tasks 1-2 Step 1 (+ the `fixture_visual_repair_loop` updates).

**Placeholder scan:** every code step shows full code. One deliberate in-step correction is called out (the `_cap` `$4` note) — the implementer must apply it; not a placeholder, an explicit instruction.

**Cross-task count consistency:** Task 2 adds the baseline `attempt: 0` entry, which shifts EVERY `attempts|length` assertion by +1. Task 2 Step 5 enumerates the required updates (keepbest 3→4, patience 4→5, loop 2→3 and 3→4). Task 1's fixtures are authored at their pre-baseline counts and bumped in Task 2 — an implementer running tasks in order sees Task 1 green, then Task 2 green after the bump.

**Type/name consistency:** `best_pct`/`best_snap`/`best_shot`/`best_diff`/`best_changed`/`stall`/`epsilon`/`patience`/`changed`, the `${shot%.png}.attempt-$n.png` path form, and the 15-arg `visual_repair_screen` signature are consistent across both tasks. The `visual_assemble_screen` analysis arg goes `""` → `"$best_changed"`.
