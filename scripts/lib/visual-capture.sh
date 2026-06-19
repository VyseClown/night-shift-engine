# shellcheck shell=bash
# Design-fidelity visual capture — CONTRACT SCAFFOLD (Phase 2).
#
# This defines the engine's half of visual validation: how it WOULD capture
# per-screen screenshots, pixel-diff them against design references, and emit
# `visual-diff-*.json` reports (schemas/visual-diff.json) that the night-shift
# viewer already renders. The actual capture + pixel-diff require a real
# simulator/emulator (Xcode / Android SDK) and an image-diff tool, which the CI
# environment lacks, so those two steps are STUBS (clearly marked __visual_*).
#
# Everything else is real and deterministic (contract parsing, report assembly,
# pass-consistency, schema shape) and is covered by the fixture suite. The
# orchestrator is INERT by default: run_visual_capture is a no-op SKIP unless
# capture is explicitly enabled AND the tooling is present, so it never affects a
# normal run. Integration point (not wired into the live loop yet): call
# run_visual_capture after candidate creation when the spec has a `## Design
# Contract` and the Design Fidelity Reviewer is active; write reports into
# `$RUN_ROOT/validated/`.

# Default per-screen tolerance (max diff_pct considered a pass) when a spec's
# Design Contract does not declare one.
VISUAL_DEFAULT_TOLERANCE="${NIGHT_SHIFT_VISUAL_TOLERANCE:-0.10}"

# Capability gate. Capture only runs when explicitly opted in AND the required
# tooling exists. Returns non-zero (skip) otherwise — which is always the case in
# an environment without a simulator and image-diff tool. The specific tools are
# intentionally pluggable: a real deployment sets NIGHT_SHIFT_VISUAL_CAPTURE=1 and
# provides `xcrun`/`adb` (capture) and a diff tool on PATH.
visual_capture_available() {
  [ "${NIGHT_SHIFT_VISUAL_CAPTURE:-0}" = "1" ] || return 1
  command -v "${NIGHT_SHIFT_VISUAL_CAPTURE_TOOL:-xcrun}" >/dev/null 2>&1 || return 1
  command -v "${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" >/dev/null 2>&1 || return 1
  return 0
}

# Reads the spec's `## Design Contract` and prints one `screen|state|device` line
# per (frame × required-state × device) triple — the screens a capture run must
# cover. Frames come from `- Frames:`, states from `- Required states:`, and
# devices from `- Devices:` (all comma-separated). Devices default to `iphone-15`
# when absent. Pure/deterministic; prints nothing when the section or fields are
# absent.
visual_capture_screens() {
  local file="$1" section frames states devices f s d old_ifs
  section="$(awk '
    /^## Design Contract([ \t]|$)/ { ind=1; next }
    /^## / { ind=0 }
    ind { print }
  ' "$file")"
  # Capture the value, dropping any trailing `<!-- ... -->` guidance comment.
  frames="$(printf '%s\n' "$section" | sed -nE 's/^- Frames: ?(.*)/\1/p' | head -n 1 | sed -E 's/[[:space:]]*<!--.*$//')"
  states="$(printf '%s\n' "$section" | sed -nE 's/^- Required states: ?(.*)/\1/p' | head -n 1 | sed -E 's/[[:space:]]*<!--.*$//')"
  devices="$(printf '%s\n' "$section" | sed -nE 's/^- Devices: ?(.*)/\1/p' | head -n 1 | sed -E 's/[[:space:]]*<!--.*$//')"
  [ -n "$devices" ] || devices="iphone-15"
  [ -n "$frames" ] && [ -n "$states" ] || return 0
  old_ifs="$IFS"; IFS=','
  for f in $frames; do
    f="$(printf '%s' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$f" ] || continue
    for s in $states; do
      s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      [ -n "$s" ] || continue
      for d in $devices; do
        d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$d" ] || continue
        printf '%s|%s|%s\n' "$f" "$s" "$d"
      done
    done
  done
  IFS="$old_ifs"
}

# The per-screen tolerance for a spec (a `- Tolerance:` line in the Design
# Contract, else the default). Pure.
visual_capture_tolerance() {
  local file="$1" t
  t="$(awk '
    /^## Design Contract([ \t]|$)/ { ind=1; next }
    /^## / { ind=0 }
    ind { print }
  ' "$file" | sed -nE 's/^- Tolerance: ?([0-9.]+).*/\1/p' | head -n 1)"
  [ -n "$t" ] || t="$VISUAL_DEFAULT_TOLERANCE"
  printf '%s' "$t"
}

# Pure: emit one screen object for the report. pass is derived, never trusted from
# input: pass == (diff_pct <= tolerance). `attempts` is a JSON array string.
visual_assemble_screen() {
  local screen="$1" state="$2" device="$3" reference="$4" screenshot="$5" \
    diff_pct="$6" tolerance="$7" diff_image="$8" analysis="${9:-}" attempts="${10:-[]}"
  jq -nc \
    --arg screen "$screen" --arg state "$state" --arg device "$device" \
    --arg reference "$reference" --arg screenshot "$screenshot" \
    --argjson diff_pct "$diff_pct" --argjson tolerance "$tolerance" \
    --arg diff_image "$diff_image" --arg analysis "$analysis" \
    --argjson attempts "$attempts" '
    {
      screen: $screen, state: $state, device: $device, reference: $reference,
      screenshot: $screenshot, diff_pct: $diff_pct, tolerance: $tolerance,
      pass: ($diff_pct <= $tolerance), analysis: $analysis,
      diff_image: (if $diff_image == "" then null else $diff_image end),
      attempts: $attempts
    }'
}

# ── STUBS: the only simulator/tool-dependent steps. A real deployment replaces
# these; both return non-zero here so run_visual_capture cleanly degrades. ──

# Would boot a simulator/emulator, navigate to <screen>/<state>, and write a PNG
# to $3. Returns 2 = "not implemented in this environment".
__visual_capture_screenshot() {
  return 2  # requires xcrun simctl / adb screencap on a real machine
}

# Would pixel-diff $1 (reference) vs $2 (screenshot), write a diff image to $3,
# and print the difference percentage. Returns 2 = "not implemented".
__visual_pixel_diff() {
  return 2  # requires an image-diff tool (e.g. odiff / pixelmatch)
}

# Orchestrator. No-op SKIP unless capture is available; otherwise drives the
# scaffolded capture→diff→assemble→emit pipeline and writes one
# visual-diff-<spec>.json into $out_dir. Never blocks a run — an unavailable or
# not-yet-implemented capture degrades to "design fidelity stays static-only".
run_visual_capture() {
  local spec="$1" candidate="$2" out_dir="$3"
  if ! visual_capture_available; then
    log "visual-capture: SKIP — no simulator/diff tooling or NIGHT_SHIFT_VISUAL_CAPTURE!=1; design fidelity stays static-only (the viewer renders reports if/when emitted)"
    return 0
  fi
  local screens tol screen state device ref shot diff_img pct objs="" line
  screens="$(visual_capture_screens "$spec")"
  [ -n "$screens" ] || { log "visual-capture: no Design Contract frames/states; nothing to capture"; return 0; }
  tol="$(visual_capture_tolerance "$spec")"
  while IFS='|' read -r screen state device; do
    [ -n "$screen" ] || continue
    ref="design/${screen}-${state}.png"
    shot="screenshots/${candidate}/${screen}-${state}.png"
    diff_img="diffs/${candidate}/${screen}-${state}.png"
    if ! __visual_capture_screenshot "$screen" "$state" "$out_dir/$shot"; then
      log "visual-capture: capture step not implemented; skipping (scaffold only)"
      return 0
    fi
    pct="$(__visual_pixel_diff "$out_dir/$ref" "$out_dir/$shot" "$out_dir/$diff_img")" || {
      log "visual-capture: diff step not implemented; skipping (scaffold only)"
      return 0
    }
    objs="$objs$(visual_assemble_screen "$screen" "$state" "$device" "$ref" "$shot" "$pct" "$tol" "$diff_img" "" "[]"),"
  done <<EOF
$screens
EOF
  [ -n "$objs" ] || return 0
  jq -n --arg task "$spec" --argjson screens "[${objs%,}]" \
    '{task: $task, screens: $screens}' >"$out_dir/visual-diff-$(basename "$spec" .md).json"
}
