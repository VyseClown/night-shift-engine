#!/usr/bin/env bash
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

# Export a Figma node's PNG to $out via the Figma MCP (no token, no REST). Spawns a
# cheap `claude -p` whose only tool is mcp__figma__download_figma_images. Caches when
# $out already exists. Returns non-zero (degrade cleanly) when claude/MCP/download is
# unavailable, so callers SKIP rather than fail.
visual_stage_ref() {
  local key="$1" node="$2" out="$3" dir base prompt
  [ -s "$out" ] && return 0
  [ -n "$key" ] && [ -n "$node" ] || return 1
  command -v claude >/dev/null 2>&1 || { log "  no claude CLI — cannot MCP-export Figma $node"; return 1; }
  dir="$(dirname "$out")"; base="$(basename "$out")"; mkdir -p "$dir" || return 1
  prompt="Use the mcp__figma__download_figma_images tool to download fileKey ${key} node ${node} as a PNG (pngScale 2) to localPath \"${dir}\" with fileName \"${base}\" — i.e. exactly the file ${out}. Use ONLY that tool; never a Figma token or REST. Reply 'done' once the file exists."
  ( printf '%s' "$prompt" | claude -p --model "${NIGHT_SHIFT_VISUAL_REF_MODEL:-claude-haiku-4-5}" \
      --permission-mode bypassPermissions \
      --output-format json --allowed-tools "mcp__figma__download_figma_images" >/dev/null 2>&1 ) || true
  [ -s "$out" ]
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
# input: pass == (diff_pct <= tolerance). `attempts` and `unmet_brief` are JSON array strings.
visual_assemble_screen() {
  local screen="$1" state="$2" device="$3" reference="$4" screenshot="$5" \
    diff_pct="$6" tolerance="$7" diff_image="$8" analysis="${9:-}" attempts="${10:-[]}" \
    unmet_brief="${11:-[]}"
  jq -nc \
    --arg screen "$screen" --arg state "$state" --arg device "$device" \
    --arg reference "$reference" --arg screenshot "$screenshot" \
    --argjson diff_pct "$diff_pct" --argjson tolerance "$tolerance" \
    --arg diff_image "$diff_image" --arg analysis "$analysis" \
    --argjson attempts "$attempts" --argjson unmet_brief "$unmet_brief" '
    {
      screen: $screen, state: $state, device: $device, reference: $reference,
      screenshot: $screenshot, diff_pct: $diff_pct, tolerance: $tolerance,
      pass: ($diff_pct <= $tolerance), analysis: $analysis,
      diff_image: (if $diff_image == "" then null else $diff_image end),
      attempts: $attempts, unmet_brief: $unmet_brief
    }'
}

# ── Gated implementations: return 2 when tooling is absent so run_visual_capture
# degrades cleanly (CI / fixtures are unaffected). ──

# Pure: given simctl `list devices -j` JSON on stdin and a device label ($1),
# print the chosen device UDID. Selection priority: exact label match that is
# Booted, then any exact label match, then any Booted device, then any device.
# Label = the simctl device name lowercased with spaces -> hyphens
# (e.g. "iPhone 15 Pro Max" -> "iphone-15-pro-max"). Prints empty if none.
__visual_pick_udid() {
  jq -r --arg d "$1" '
    [.devices[][]? | {name, udid, state, label: (.name | ascii_downcase | gsub(" "; "-"))}]
    | ( (map(select(.label==$d and .state=="Booted")))
        + (map(select(.label==$d)))
        + (map(select(.state=="Booted")))
        + . )
    | .[0].udid // empty
  '
}

# Resolve a device label to a simulator UDID via simctl. Returns empty on failure.
__visual_resolve_udid() {
  local device="$1" js
  js="$(xcrun simctl list devices available -j 2>/dev/null)" || return 1
  printf '%s' "$js" | __visual_pick_udid "$device"
}

# Run a command under a timeout without GNU `timeout` (absent on macOS): background
# the command, start a watchdog that TERM-then-KILLs it after $1 seconds, and return
# the command's exit status (a watchdog kill surfaces as non-zero).
__visual_run_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 3; kill -KILL "$cmd_pid" 2>/dev/null ) &
  local wd_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  kill "$wd_pid" 2>/dev/null
  wait "$wd_pid" 2>/dev/null
  return "$rc"
}

# Capture <screen> <state> <device> -> PNG at $4. Requires xcrun. Returns 2 when
# unavailable so run_visual_capture degrades cleanly.
__visual_capture_screenshot() {
  local screen="$1" state="$2" device="$3" out="$4" udid="${5:-}"
  command -v xcrun >/dev/null 2>&1 || return 2
  [ -n "$udid" ] || udid="$(__visual_resolve_udid "$device")"
  [ -n "$udid" ] || return 2
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  # --time must be a plain HH:MM clock string: iOS 26's simctl rejects an ISO
  # datetime ("non-ISO date/time string", exit 22), which the `|| true` would
  # swallow — silently leaving the real wall-clock time and making captures
  # non-deterministic. HH:MM is accepted across simctl versions.
  xcrun simctl status_bar "$udid" override \
    --time "09:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$out")"
  # Drive the app into the target scenario. Four modes (maestro, then preview file/launcharg/openurl):
  #   (0) maestro — NIGHT_SHIFT_MAESTRO_DIR: run a per-screen-state Maestro flow
  #       (<dir>/<Screen>-<state>.yaml) to navigate the REAL app; no preview harness.
  #   (1) file   — NIGHT_SHIFT_PREVIEW_FILE + _BUNDLE_ID: write "<screen>:<state>"
  #       into the app's document dir, then cold-launch. The app reads it on boot.
  #       Prompt-free AND needs no native launch-arg support — works with a JS-only
  #       preview harness. The robust default on newer iOS (see below).
  #   (2) launcharg — _BUNDLE_ID only: cold-launch with a --nightshift-preview arg
  #       the (natively-instrumented) app reads. Prompt-free but needs native code.
  #   (3) openurl — neither set: a custom-scheme deep link. Simplest, but iOS 16+
  #       shows an "Open in app?" confirmation that blocks unattended capture.
  local mdir="${NIGHT_SHIFT_MAESTRO_DIR:-}"
  local bid="${NIGHT_SHIFT_PREVIEW_BUNDLE_ID:-}"
  local pfile="${NIGHT_SHIFT_PREVIEW_FILE:-}"
  if [ -n "$mdir" ]; then
    # (0) maestro — drive the REAL app to the scenario via a per-screen-state flow,
    # then the shared status-bar override + screenshot below capture it. The flow is
    # self-contained (launchApp + navigation, no screenshot). Missing maestro or a
    # missing flow returns 2 (clean SKIP). Takes precedence over the preview modes.
    command -v maestro >/dev/null 2>&1 || return 2
    local flow="$mdir/${screen}-${state}.yaml"
    [ -f "$flow" ] || return 2
    # Bound the UI-test run: a hung xcodebuild driver must SKIP, not freeze the loop.
    __visual_run_timeout "${NIGHT_SHIFT_MAESTRO_TIMEOUT:-180}" \
      maestro --device "$udid" test "$flow" >/dev/null 2>&1 || return 2
  elif [ -n "$bid" ] && [ -n "$pfile" ]; then
    # (1) file-driven cold launch.
    local data
    data="$(xcrun simctl get_app_container "$udid" "$bid" data 2>/dev/null)" || return 2
    [ -n "$data" ] || return 2
    mkdir -p "$data/Documents" || return 2
    printf '%s:%s' "$screen" "$state" >"$data/Documents/$pfile" || return 2
    xcrun simctl terminate "$udid" "$bid" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bid" >/dev/null 2>&1 || return 2
  elif [ -n "$bid" ]; then
    # (2) launch-arg cold launch: terminate any running instance, then launch with
    # the preview arg (portable — avoids the --terminate-existing flag, which some
    # simctl versions reject).
    xcrun simctl terminate "$udid" "$bid" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bid" \
      --nightshift-preview "${screen}:${state}" >/dev/null 2>&1 || return 2
  else
    # (3) custom-scheme deep link.
    xcrun simctl openurl "$udid" \
      "${NIGHT_SHIFT_PREVIEW_SCHEME:-nightshift}://preview?screen=${screen}&state=${state}&device=${device}" >/dev/null 2>&1 || return 2
  fi
  # Let the app cold-start and the JS bundle render before capturing.
  sleep "${NIGHT_SHIFT_VISUAL_SETTLE_SECONDS:-6}"
  xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1 || return 2
  [ -s "$out" ]
}

# Re-capture a single screen via the existing file-drive path. Used by the repair
# loop after an edit hot-reloads. Returns non-zero if capture fails.
visual_recapture_screen() {
  local screen="$1" state="$2" device="$3" out="$4" udid
  udid="$(__visual_resolve_udid "$device")" || return 2
  [ -n "$udid" ] || return 2
  __visual_capture_screenshot "$screen" "$state" "$device" "$out" "$udid"
}

# Diff <reference> <screenshot> <diff_out>; prints diff_pct (0-100). Requires
# odiff. Returns 2 when unavailable.
__visual_pixel_diff() {
  local reference="$1" screenshot="$2" diff_out="$3"
  command -v "${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" >/dev/null 2>&1 || return 2
  mkdir -p "$(dirname "$diff_out")"
  # odiff requires identical dimensions. Resize a COPY of the reference to the
  # screenshot's exact pixel size so the diff is always valid. The original
  # reference file (referenced by the report) is left untouched. Falls back to the
  # original reference if sips is unavailable or sizing fails.
  local ref_use="$reference"
  if command -v sips >/dev/null 2>&1; then
    local dims w h
    dims="$(sips -g pixelWidth -g pixelHeight "$screenshot" 2>/dev/null)"
    w="$(printf '%s\n' "$dims" | awk '/pixelWidth/{print $2}')"
    h="$(printf '%s\n' "$dims" | awk '/pixelHeight/{print $2}')"
    if [ -n "$w" ] && [ -n "$h" ]; then
      ref_use="$(dirname "$diff_out")/.ref-resized-$$.png"
      cp "$reference" "$ref_use" 2>/dev/null && sips -z "$h" "$w" "$ref_use" >/dev/null 2>&1 || ref_use="$reference"
    fi
  fi
  local outp pct rc
  outp="$("${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" --parsable-stdout "$ref_use" "$screenshot" "$diff_out" 2>/dev/null)"
  rc=$?
  # A match → diff_pct 0 (a pass), NOT an unparseable SKIP. `odiff --parsable-stdout`
  # exits 0 IFF the images match (within threshold); depending on the odiff version it
  # then prints either NOTHING or a bare "0". The old check required rc==0 AND empty
  # output, so a perfectly-converged capture (odiff prints "0") fell through to the
  # ";"-format parser, produced no match, and returned 2 (unparseable failure) — which
  # the repair loop read as a FAILED attempt and reverted, making convergence impossible
  # to ever recognize. rc==0 alone is the correct "0% diff" signal.
  if [ "$rc" -eq 0 ]; then
    printf '0'
    return 0
  fi
  # Otherwise `odiff --parsable-stdout` prints "<diffPixelCount>;<diffPercentage>" —
  # e.g. "3142353;99.37" (exit 22) — where the percentage is 0–100 (confirmed
  # against odiff on a real run; see GH #16). The report's diff_pct is a 0–1
  # FRACTION (schema + `pass == diff_pct <= tolerance`, default tolerance 0.10), so
  # take the percentage field and divide by 100. Do NOT fall back to the first bare
  # number: that grabbed the pixel COUNT (3142353), a nonsensical diff_pct + broken
  # pass decision. A "NN%" literal (other diff tools) is the only fallback, also
  # normalized to 0–1. `LC_ALL=C` forces a '.' decimal point so the value stays
  # valid JSON for `jq --argjson` in any locale (a comma-decimal locale otherwise
  # yields "0,99" → invalid JSON).
  pct="$(printf '%s' "$outp" | LC_ALL=C awk -F';' 'NF>1 && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { printf "%.6f", $2/100; exit }')"
  if [ -z "$pct" ]; then
    local lit
    lit="$(printf '%s' "$outp" | grep -oE '[0-9]+(\.[0-9]+)?%' | head -n1 | tr -d '%')"
    [ -z "$lit" ] || pct="$(LC_ALL=C awk -v p="$lit" 'BEGIN{ printf "%.6f", p/100 }')"
  fi
  # Fail closed: an unparseable result must NOT silently become 0% (a false PASS).
  # Returning non-zero makes run_visual_capture log + skip this screen instead.
  [ -n "$pct" ] || return 2
  printf '%s' "$pct"
}

# In registry mode, return a claimed UDID for <label> (cached for the run via
# $_ns_cache_dir files — survives $() subshell boundaries), or empty on
# acquisition timeout (caller SKIPs). In default mode (_ns_reg != 1) returns
# empty so __visual_capture_screenshot resolves internally — unchanged behavior.
__visual_udid_for_label() {
  local label="$1" run_id="${RUN_ID:-$$}" cache_file u
  [ "${_ns_reg:-0}" = "1" ] || { printf ''; return 0; }
  # Use a file-based cache so claims survive $() subshell boundaries.
  cache_file="${_ns_cache_dir}/label/${label}"
  if [ -f "$cache_file" ]; then
    # Cache hit: reuse the previously claimed UDID.
    cat "$cache_file"; return 0
  fi
  u="$(device_claim "$label" "$run_id")"
  if [ -n "$u" ]; then
    mkdir -p "${_ns_cache_dir}/label"
    printf '%s' "$u" >"$cache_file"
    printf '%s\n' "$u" >>"${_ns_cache_dir}/claimed"
  fi
  printf '%s\n' "$u"
}

# Classify a visual-diff report at $1, for the engine-invoked visual_review:
#   absent    — no/empty file: capture cleanly SKIPped (tooling or frames absent);
#               the stage proceeds without blocking.
#   malformed — present but fails the schema shape: a real error → block.
#   valid     — a well-formed report with at least one screen.
# Pure (reads only $1); the fixture exercises all three branches.
visual_report_status() {
  local report="$1"
  [ -s "$report" ] || { printf 'absent\n'; return 0; }
  if jq -e '.task and (.screens | type=="array" and length>0)' "$report" >/dev/null 2>&1; then
    printf 'valid\n'
  else
    printf 'malformed\n'
  fi
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
  # Registry mode: claim devices per distinct label, release all on return.
  local _ns_reg=0 _ns_cache_dir=""
  [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && _ns_reg=1
  if [ "$_ns_reg" = "1" ]; then
    _ns_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/ns-vcr-XXXXXX")"
  fi
  # shellcheck disable=SC2329  # invoked indirectly via the RETURN trap below
  _ns_release_all() {
    # Defensive default: under `set -u` the RETURN trap can fire after the local
    # has left scope (non-registry runs), where _ns_cache_dir is empty anyway.
    [ -n "${_ns_cache_dir:-}" ] || return 0
    local u
    [ -f "$_ns_cache_dir/claimed" ] && while IFS= read -r u; do [ -n "$u" ] && device_release "$u"; done <"$_ns_cache_dir/claimed"
    rm -rf "$_ns_cache_dir"
  }
  trap '_ns_release_all' RETURN
  local screens tol screen state device ref shot diff_img pct objs=""
  screens="$(visual_capture_screens "$spec")"
  [ -n "$screens" ] || { log "visual-capture: no Design Contract frames/states; nothing to capture"; return 0; }
  tol="$(visual_capture_tolerance "$spec")"
  while IFS='|' read -r screen state device; do
    [ -n "$screen" ] || continue
    ref="design/${screen}-${state}-${device}.png"
    shot="screenshots/${candidate}/${screen}-${state}-${device}.png"
    diff_img="diffs/${candidate}/${screen}-${state}-${device}.png"
    local _udid; _udid="$(__visual_udid_for_label "$device")"
    if [ "$_ns_reg" = "1" ] && [ -z "$_udid" ]; then
      log "visual-capture: no simulator available for '$device' within timeout; SKIP"
      return 0
    fi
    if ! __visual_capture_screenshot "$screen" "$state" "$device" "$out_dir/$shot" "$_udid"; then
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

# Combine per-screen JSON objects (one compact object per line in $2) into a full
# visual-diff report for task $1. Prints the report JSON. Pure.
assemble_report() {
  local task="$1" screens_file="$2"
  jq -s --arg task "$task" '{task: $task, screens: .}' "$screens_file"
}

# When executed directly (not sourced), expose capture/diff as subcommands for the
# agent's repair loop. Sourcing (the orchestrator's use) skips this block.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    capture)        __visual_capture_screenshot "$@"; exit $? ;;
    diff)           __visual_pixel_diff "$@"; exit $? ;;
    screens)        visual_capture_screens "$@"; exit $? ;;
    assemble-screen) visual_assemble_screen "$@"; exit $? ;;
    report)          assemble_report "$@"; exit $? ;;
    *) printf 'usage: visual-capture.sh {capture screen state device out|diff ref shot diffout|screens spec|assemble-screen ...|report task screens.jsonl}\n' >&2; exit 64 ;;
  esac
fi
