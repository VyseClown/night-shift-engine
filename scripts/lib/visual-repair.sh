#!/usr/bin/env bash
# shellcheck shell=bash
#
# visual-repair.sh — surface-agnostic bounded auto-repair loop for the
# design-fidelity pipeline. Sourced by scripts/visual-review.sh (standalone) and
# scripts/night-shift.sh (in-loop). The agent, capture, and validate steps are
# INJECTED as function names so each caller (and the fixtures) supplies its own.
# Expects a `log` function in scope (callers define it).

# Return 0 iff every changed path in <project>'s working tree begins with one of
# the allow-prefixes; else print offenders and return 1.
visual_repair_scope_check() {
  local project="$1"; shift
  local offenders="" line path p ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"            # strip the 2-char status + space
    ok=0
    for p in "$@"; do case "$path" in "$p"*) ok=1; break ;; esac; done
    [ "$ok" = "1" ] || offenders="$offenders$path"$'\n'
  done < <(git -C "$project" status --porcelain 2>/dev/null)
  if [ -n "$offenders" ]; then
    printf 'visual-repair: out-of-scope edits:\n%s' "$offenders" >&2
    return 1
  fi
  return 0
}

# Copy in-scope trees aside so a failed repair attempt can be reverted.
visual_repair_snapshot() {
  local project="$1" tmpdir="$2"; shift 2
  local p
  rm -rf "$tmpdir"; mkdir -p "$tmpdir"
  for p in "$@"; do
    [ -e "$project/$p" ] || continue
    mkdir -p "$tmpdir/$(dirname "$p")"
    cp -R "$project/$p" "$tmpdir/$p"
  done
}

# Restore the snapshotted trees over the working copy.
visual_repair_restore() {
  local project="$1" tmpdir="$2"; shift 2
  local p
  for p in "$@"; do
    [ -e "$tmpdir/$p" ] || continue
    rm -rf "${project:?}/$p"
    mkdir -p "$project/$(dirname "$p")"
    cp -R "$tmpdir/$p" "$project/$p"
  done
}

# Re-diff a screenshot against a reference; honors an injectable hook for tests.
visual_repair_diff() {
  local ref="$1" shot="$2" diff_out="$3"
  if [ -n "${NIGHT_SHIFT_VISUAL_DIFF_FN:-}" ]; then
    "$NIGHT_SHIFT_VISUAL_DIFF_FN" "$ref" "$shot" "$diff_out"
  else
    __visual_pixel_diff "$ref" "$shot" "$diff_out"
  fi
}

# Bounded per-screen repair. Prints the final screen object; returns 0 if it ends
# within tolerance, else 1.
visual_repair_screen() {
  local project="$1" tmpbase="$2" out_dir="$3" screen="$4" state="$5" device="$6" \
    ref="$7" shot="$8" diff_img="$9" tol="${10}" max="${11}" agent_fn="${12}" \
    capture_fn="${13}" validate_fn="${14}" allow_csv="${15}"
  local IFS_OLD="$IFS"; IFS=','; read -r -a allow <<<"$allow_csv"; IFS="$IFS_OLD"
  local attempts="[]" unmet="[]" cur="" n=0 snap="$tmpbase/snap" passed=0 agent_out
  local _pct_file="$tmpbase/_pct"
  local best_pct="" best_snap="$tmpbase/best" best_shot="$tmpbase/best.shot" best_diff="$tmpbase/best.diff" stall=0 best_changed=""
  local epsilon="${NIGHT_SHIFT_VISUAL_REPAIR_EPSILON:-0.005}" patience="${NIGHT_SHIFT_VISUAL_REPAIR_PATIENCE:-2}"
  mkdir -p "$tmpbase"
  # Seed "best" with the pre-repair baseline: if no attempt beats it, end on no change.
  if visual_repair_diff "$ref" "$shot" "$diff_img" >"$_pct_file" 2>/dev/null; then
    best_pct="$(cat "$_pct_file")"
    visual_repair_snapshot "$project" "$best_snap" "${allow[@]}"
    cp "$shot" "$best_shot" 2>/dev/null || true; cp "$diff_img" "$best_diff" 2>/dev/null || true
  fi
  # Baseline ("before") audit entry + image copies. Numbered attempt 1 (the schema
  # requires attempt>=1); agent repairs are numbered from 2 below.
  if [ -n "$best_pct" ]; then
    cp "$shot" "${shot%.png}.attempt-1.png" 2>/dev/null || true
    cp "$diff_img" "${diff_img%.png}.attempt-1.png" 2>/dev/null || true
    local _bpass; _bpass="$(LC_ALL=C awk -v p="$best_pct" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson p "$best_pct" --argjson ps "$_bpass" \
      --arg s "${shot%.png}.attempt-1.png" --arg d "${diff_img%.png}.attempt-1.png" \
      '. + [{attempt:1, diff_pct:$p, pass:$ps, analysis:"baseline (before repair)", screenshot:$s, diff_image:$d}]')"
  fi
  while [ "$n" -lt "$max" ]; do
    n=$((n+1))
    local dn=$((n+1))   # displayed/recorded attempt number (baseline is 1; repairs from 2)
    visual_repair_snapshot "$project" "$snap" "${allow[@]}"
    agent_out="$("$agent_fn" "$screen" "$state" "$ref" "$shot" "$diff_img" "$cur" "$tol" "$out_dir" 2>/dev/null || printf '{}')"
    unmet="$(printf '%s' "$agent_out" | jq -c '.unmet_brief // []' 2>/dev/null || printf '[]')"
    local changed; changed="$(printf '%s' "$agent_out" | jq -r '.changed // ""' 2>/dev/null || printf '')"
    if ! visual_repair_scope_check "$project" "${allow[@]}" || ! "$validate_fn" "$project"; then
      log "visual-repair: $screen attempt $n failed scope/validation; reverting"
      visual_repair_restore "$project" "$snap" "${allow[@]}"
      attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$dn" --arg s "$shot" --arg d "$diff_img" \
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
    cp "$shot" "${shot%.png}.attempt-$dn.png" 2>/dev/null || true
    cp "$diff_img" "${diff_img%.png}.attempt-$dn.png" 2>/dev/null || true
    local pass; pass="$(LC_ALL=C awk -v p="$cur" -v t="$tol" 'BEGIN{print (p<=t)?"true":"false"}')"
    attempts="$(printf '%s' "$attempts" | jq -c --argjson a "$dn" --argjson p "$cur" --argjson ps "$pass" \
      --arg an "$changed" --arg s "${shot%.png}.attempt-$dn.png" --arg d "${diff_img%.png}.attempt-$dn.png" \
      '. + [{attempt:$a, diff_pct:$p, pass:$ps, analysis:$an, screenshot:$s, diff_image:$d}]')"
    local improved; improved="$(LC_ALL=C awk -v c="$cur" -v b="$best_pct" -v e="$epsilon" 'BEGIN{ if (b=="") print "yes"; else print (c <= b - e)?"yes":"no" }')"
    if [ "$improved" = "yes" ]; then
      best_pct="$cur"; best_changed="$changed"; visual_repair_snapshot "$project" "$best_snap" "${allow[@]}"
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
  visual_assemble_screen "$screen" "$state" "$device" "$ref" "$shot" "$cur" "$tol" "$diff_img" "$best_changed" "$attempts" "$unmet"
  [ "$passed" = "1" ]
}

# Spec/Figma helpers (shared by both repair surfaces).
# label (iphone-16-pro-max) -> simctl device name (iPhone 16 Pro Max). Portable
# across BSD/GNU (awk toupper/tolower; GNU sed's \u is a no-op on macOS BSD sed).
device_label_to_name() {
  printf '%s' "$1" | sed -E 's/-/ /g' | awk '{
    for (i=1;i<=NF;i++) {
      w=tolower($i)
      if (w=="iphone") $i="iPhone"
      else if (w=="mini") $i="mini"
      else if (w=="pro") $i="Pro"
      else if (w=="max") $i="Max"
      else if (w ~ /^[0-9]+$/) { }
      else $i=toupper(substr($i,1,1)) substr($i,2)
    }
    print
  }'
}

# Per-spec capture device labels (e.g. iphone-16) from the Design Contract.
visual_repair_devices() { visual_capture_screens "$1" | awk -F'|' '{print $3}' | sort -u; }

# Resolve a screen's Figma node id from the spec's `- Figma node IDs:` line, else
# the spec's single declared node.
node_id_for() {
  local spec="$1" screen="$2" line id
  line="$(grep -E '^- Figma node IDs:' "$spec" | head -n1)"
  id="$(printf '%s' "$line" | grep -oE "${screen}[[:space:]]*=[[:space:]]*\`[0-9I][0-9:I;-]*\`" | grep -oE '`[^`]+`' | tr -d '`' | head -n1)"
  [ -n "$id" ] || id="$(printf '%s' "$line" | grep -oE '`[0-9I][0-9:I;-]*`' | head -n1 | tr -d '`')"
  printf '%s' "$id"
}

figma_key_for() { sed -nE 's/.*fileKey `([A-Za-z0-9]+)`.*/\1/p' "$1" | head -n1; }

# Print the spec's design-intent sections (## Design Contract + ## Design source)
# verbatim — the human-editable source the repair agent honors.
spec_design_sections() {
  awk '/^## /{ p = ($0 ~ /^## (Design Contract|Design source)/) ? 1 : 0 } p' "$1"
}

# Fetch node $node's Figma design data (Dev Mode specs + annotations) via the MCP and
# write concise design notes to $cache, ONCE — the repair agent then Reads $cache each
# attempt instead of calling get_figma_data live (cuts Figma API volume; avoids 429).
# Caches (skips if $cache exists). Degrades cleanly (non-zero) if claude/MCP unavailable.
visual_stage_figma_data() {
  local key="$1" node="$2" cache="$3" prompt
  [ -s "$cache" ] && return 0
  [ -n "$key" ] && [ -n "$node" ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$cache")" || return 1
  prompt="Call mcp__figma__get_figma_data for node ${node} in file ${key}. Then use the Write tool to write its COMPLETE result to the file ${cache} as JSON, VERBATIM — every node, its type, all fills and gradient stops, bounds, text styles, and child/stacking order. Do NOT summarize, omit, or paraphrase (layered/overlapping shapes are SEPARATE child nodes — keep them all). Figma is accessed ONLY through the MCP; never a token or REST. Reply 'done' once the file exists."
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "Write,mcp__figma__get_figma_data" >/dev/null 2>&1 ) || true
  [ -s "$cache" ]
}

# Stage every Design-Contract screen's Figma reference into $out_dir/design/ via the
# MCP (visual_stage_ref). Used by both visual-review.sh and the in-loop run_visual.
visual_stage_refs_for_spec() {
  local spec="$1" out_dir="$2" key screen state device ref
  key="$(figma_key_for "$spec")"
  [ -n "$key" ] || { log "  no fileKey in $spec Design Contract; skipping refs"; return 0; }
  while IFS='|' read -r screen state device; do
    [ -n "$screen" ] || continue
    ref="$out_dir/design/${screen}-${state}-${device}.png"
    [ -s "$ref" ] && continue
    visual_stage_ref "$key" "$(node_id_for "$spec" "$screen")" "$ref" || true
  done < <(visual_capture_screens "$spec")
}

# ---- Metro fast-reload harness (for repair) ---------------------------------
_REPAIR_METRO_PID=""
_REPAIR_METRO_STARTED=0

# True when a Metro bundler already answers on the dev port.
metro_is_up() {
  curl -s -o /dev/null "http://localhost:${NIGHT_SHIFT_METRO_PORT:-8081}/status" 2>/dev/null
}

# shellcheck disable=SC2153  # PROJECT/NO_BUILD are caller-set globals (documented interface)
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
repair_metro_stop() {
  [ "${_REPAIR_METRO_STARTED:-0}" = "1" ] || return 0
  [ -n "${_REPAIR_METRO_PID:-}" ] && kill "$_REPAIR_METRO_PID" 2>/dev/null || true
  [ -n "${_REPAIR_METRO_PID:-}" ] && wait "$_REPAIR_METRO_PID" 2>/dev/null || true
  _REPAIR_METRO_PID=""; _REPAIR_METRO_STARTED=0
}

# ---- repair agent + validate ------------------------------------------------
# shellcheck disable=SC2329  # invoked indirectly as an injected function name
repair_validate() {
  ( cd "$1" && npx tsc --noEmit >/dev/null 2>&1 && npx eslint . --max-warnings 0 >/dev/null 2>&1 )
}

# shellcheck disable=SC2329  # invoked indirectly as an injected function name
repair_agent() {
  local screen="$1" state="$2" ref="$3" shot="$4" diff_img="$5" pct="$6" tol="$7" out_dir="$8"
  local key node allow prompt result cache spec_notes
  key="$REPAIR_FILEKEY"; node="$REPAIR_NODE_${screen}"; node="${!node:-$REPAIR_FALLBACK_NODE}"
  allow="src/features/"; [ "$REPAIR_SHARED" -eq 1 ] && allow="src/features/ and src/ui/"
  cache="$out_dir/design/$screen-figma.json"
  spec_notes="$(spec_design_sections "${REPAIR_SPEC:-}" 2>/dev/null)"
  prompt="You are repairing the '$screen' screen ($state) of this Expo RN app to match its Figma frame.
FIRST use the Read tool to OPEN AND VIEW the images so you can see the pixels: reference=$ref  current screenshot=$shot  diff overlay (red = differences)=$diff_img.  current diff=$pct, target tolerance=$tol.
Read the raw Figma node tree (JSON) at $cache — it is your source of truth for EXACT per-element styles: every node's fills, gradient stops, bounds, text styles, and child/stacking order. Layered or overlapping shapes are SEPARATE child nodes — match each. If that file is absent, work from the images. ALSO treat the following design intent from the spec as requirements:
---
$spec_notes
---
Figma is accessed ONLY through the MCP; never use a Figma token or REST API.
Edit ONLY files under $allow to bring the screen to the design. Do NOT touch tests, src/data, src/domain, app/, or native config. Keep 'npx tsc --noEmit' and 'npx eslint . --max-warnings 0' clean. Do NOT run git, commit, push, or build native.
When done, print ONLY a JSON object: {\"changed\":\"<one concise line describing the visual change you made>\", \"unmet_brief\":[\"<specs/comments you could not satisfy>\"]}."
  # The prompt MUST go via stdin: the variadic --allowed-tools otherwise swallows a
  # positional prompt ("Input must be provided…") and the agent silently no-ops.
  # Tools are comma-separated — a single space-joined string is parsed as ONE
  # (invalid) tool name, leaving the agent with no tools. (Proven by the smoke.)
  result="$(cd "$PROJECT" && printf '%s' "$prompt" | claude -p --output-format json \
    --model "${NIGHT_SHIFT_VISUAL_REPAIR_MODEL:-claude-opus-4-8}" \
    --allowed-tools "Read,Edit,Write,Bash(npx tsc*),Bash(npx eslint*)" 2>/dev/null)"
  printf '%s' "$result" | jq -r '.result // "{}"' 2>/dev/null | grep -o '{.*}' | tail -n1
  [ -n "$result" ]
}

# Per-spec repair orchestration shared by both surfaces. candidate_label is the only
# path difference between them (standalone: "review"; in-loop: the candidate SHA).
# Assumes Metro/the dev build is already up (the caller manages repair_metro_*).
visual_repair_for_spec() {
  local spec="$1" project="$2" out_dir="$3" candidate_label="$4" report="$5" \
        max="$6" allow_csv="$7"
  REPAIR_FILEKEY="$(figma_key_for "$spec")"
  REPAIR_FALLBACK_NODE="$(node_id_for "$spec" "")"
  REPAIR_SPEC="$spec"
  case "$allow_csv" in *src/ui*) REPAIR_SHARED=1 ;; *) REPAIR_SHARED=0 ;; esac
  local fail="$out_dir/_fail.tsv"
  jq -r '.screens[]|select(.pass|not)|[.diff_pct,.screen,.state,.device]|@tsv' "$report" >"$fail"
  # shellcheck disable=SC2329  # invoked indirectly via visual_repair_run
  _repair_one() {
    local sc="$1" st="$2" dv="$3"
    eval "REPAIR_NODE_$sc=\"$(node_id_for "$spec" "$sc")\""
    visual_stage_figma_data "$REPAIR_FILEKEY" "$(node_id_for "$spec" "$sc")" \
      "$out_dir/design/$sc-figma.json" || true
    visual_repair_screen "$project" "$out_dir/_rsnap" "$out_dir" "$sc" "$st" "$dv" \
      "$out_dir/design/$sc-$st-$dv.png" "$out_dir/screenshots/$candidate_label/$sc-$st-$dv.png" \
      "$out_dir/diffs/$candidate_label/$sc-$st-$dv.png" "$(visual_capture_tolerance "$spec")" \
      "$max" repair_agent visual_recapture_screen repair_validate "$allow_csv" >/dev/null
    printf '%s\n' "$max"
  }
  visual_repair_run "$fail" "${NIGHT_SHIFT_VISUAL_REPAIR_GLOBAL_CAP:-30}" _repair_one
  unset -f _repair_one
}

# Process failing screens worst-diff first, stopping at the global attempt cap.
# repair_one_fn returns the number of attempts it consumed on its stdout's last
# line (an integer); if it prints nothing numeric, 1 is assumed.
visual_repair_run() {
  local tsv="$1" cap="$2" repair_one_fn="$3" used=0 screen state device out
  while IFS=$'\t' read -r _ screen state device; do
    [ -n "$screen" ] || continue
    [ "$used" -lt "$cap" ] || { log "visual-repair: global cap $cap reached; stopping"; break; }
    out="$("$repair_one_fn" "$screen" "$state" "$device" 2>/dev/null | tail -n1)"
    case "$out" in (''|*[!0-9]*) out=1 ;; esac
    used=$((used + out))
  done < <(sort -t"$(printf '\t')" -k1,1 -rn "$tsv")
}
