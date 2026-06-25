#!/usr/bin/env bash
# shellcheck shell=bash
#
# visual-review.sh — one-command design-fidelity pass for an rn project.
#
# Builds the app, installs it on the Design-Contract device matrix, stages the
# Figma reference images, drives each screen via the app's preview deep link,
# pixel-diffs the screenshot against the reference with odiff, and writes one
# validated/visual-diff-<spec>.json per reviewed spec (the night-shift viewer
# renders these). It reuses the engine's scripts/lib/visual-capture.sh — this is
# the standalone "review the finished app" companion to the per-spec visual_review
# stage inside the night-shift loop. Run it AFTER a chain completes.
#
# Usage:
#   scripts/visual-review.sh --project <dir> [options]
#
# Options:
#   --project DIR     rn project to review (required; must hold the built app)
#   --spec FILE       review just this spec; default = every spec in
#                     $WORKSPACE_ROOT/specs that targets --project AND has a
#                     `## Design Contract` (repeatable)
#   --scheme NAME     URL scheme the preview route answers (default: app.json scheme)
#   --drive MODE      how capture pushes each screen into the app:
#                       openurl (default) — custom-scheme deep link; iOS 16+ may
#                         show an "Open in app?" prompt that blocks capture.
#                       file — write "<screen>:<state>" into the app's document dir
#                         and cold-launch (prompt-free; app reads it on boot). Needs
#                         the project's file-driven preview boot.
#   --preview-file N  target filename for --drive file (default nightshift-preview.txt)
#   --no-build        skip the build/install stage (reuse the installed app)
#   --no-refs         skip Figma export (reuse already-staged references)
#   --out DIR         where to write screenshots/diffs/reports
#                     (default: <project>/.night-shift/visual-review)
#   --repair[=N]      after the report, auto-repair over-tolerance screens (N
#                     attempts/screen, default 3). Implies --drive file; edits are
#                     left UNCOMMITTED for review. Off by default.
#   --repair-shared   allow repair edits to src/ui (shared) as well as src/features
#   -h, --help
#
# Prerequisites:
#   - Xcode + an iOS simulator, and `odiff` on PATH.
#   - An app preview route the engine can drive:
#       <scheme>://preview?screen=<Screen>&state=<state>
#     rendering each screen deterministically (seeded fixtures). Build this via the
#     `visual-review-validation` night-shift spec; without it, capture SKIPs.
#   - For reference export (unless --no-refs): FIGMA_TOKEN (a Figma personal access
#     token). Without it, pre-stage references yourself under <out>/design/.
#
# Exit status: 0 if every captured screen passed its tolerance (or all SKIPped
# cleanly), 1 if any screen exceeded tolerance, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '[visual-review] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

# The engine's capture/diff/report primitives (visual_capture_screens,
# run_visual_capture, __visual_*). It expects a `log` in scope — defined above.
# shellcheck source=scripts/lib/visual-capture.sh
. "$SCRIPT_DIR/lib/visual-capture.sh"
# shellcheck source=scripts/lib/visual-repair.sh
. "$SCRIPT_DIR/lib/visual-repair.sh"

# ---- args -------------------------------------------------------------------
PROJECT="" SCHEME="" OUT="" NO_BUILD=0 NO_REFS=0 DRIVE="openurl" PREVIEW_FILE=""
REPAIR=0 MAX_ATTEMPTS="${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" REPAIR_SHARED=0
SPECS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --spec)    SPECS+=("${2:-}"); shift 2 ;;
    --scheme)  SCHEME="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --drive)   DRIVE="${2:-}"; shift 2 ;;
    --preview-file) PREVIEW_FILE="${2:-}"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --no-refs)  NO_REFS=1; shift ;;
    --repair=*)      REPAIR=1; MAX_ATTEMPTS="${1#--repair=}"; shift ;;
    --repair)        REPAIR=1; case "${2:-}" in ''|--*) : ;; *) MAX_ATTEMPTS="$2"; shift ;; esac; shift ;;
    --repair-shared) REPAIR_SHARED=1; shift ;;
    -h|--help) sed -n '4,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$DRIVE" in openurl|file) : ;; *) die "unknown --drive '$DRIVE' (expected: openurl | file)" ;; esac
[ -n "$PROJECT" ] || die "--project is required"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
[ -f "$PROJECT/app.json" ] || die "no app.json under $PROJECT (is this an Expo app?)"
command -v "${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" >/dev/null 2>&1 || die "diff tool '${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}' not on PATH"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found (need Xcode + a simulator)"

# Scheme + bundle id come from app.json when not overridden.
[ -n "$SCHEME" ] || SCHEME="$(jq -r '.expo.scheme // empty' "$PROJECT/app.json")"
[ -n "$SCHEME" ] || die "no URL scheme (set one in app.json or pass --scheme)"
BUNDLE_ID="$(jq -r '.expo.ios.bundleIdentifier // empty' "$PROJECT/app.json")"
[ -n "$BUNDLE_ID" ] || die "app.json has no ios.bundleIdentifier"
OUT="${OUT:-$PROJECT/.night-shift/visual-review}"
mkdir -p "$OUT/design"

# Capture must be enabled + tooling present, or run_visual_capture no-ops.
export NIGHT_SHIFT_VISUAL_CAPTURE=1
export NIGHT_SHIFT_PREVIEW_SCHEME="$SCHEME"

# Drive mode (how capture pushes each screen into the app):
#   openurl (default) — custom-scheme deep link; iOS 16+ may show an "Open in app?"
#     confirmation that blocks unattended capture.
#   file              — write "<screen>:<state>" into the app's document dir and
#     cold-launch (prompt-free; the app reads it on boot). Needs the app's
#     file-driven preview boot (built with EXPO_PUBLIC_PREVIEW=1 for this project).
case "$DRIVE" in
  openurl) : ;;
  file)
    export NIGHT_SHIFT_PREVIEW_BUNDLE_ID="$BUNDLE_ID"
    export NIGHT_SHIFT_PREVIEW_FILE="${PREVIEW_FILE:-nightshift-preview.txt}"
    log "drive=file (prompt-free): writes $NIGHT_SHIFT_PREVIEW_FILE into $BUNDLE_ID's docs, then simctl launch"
    ;;
  *) die "unknown --drive '$DRIVE' (expected: openurl | file)" ;;
esac

if [ "$REPAIR" -eq 1 ]; then
  [ "$DRIVE" = "file" ] || { DRIVE=file; export NIGHT_SHIFT_PREVIEW_BUNDLE_ID="$BUNDLE_ID" NIGHT_SHIFT_PREVIEW_FILE="${PREVIEW_FILE:-nightshift-preview.txt}"; }
  log "REPAIR ON (≤${MAX_ATTEMPTS}/screen): spawns PAID claude sessions and EDITS screen code (left uncommitted)."
fi

# ---- which specs ------------------------------------------------------------
# Default: every spec that targets THIS project and declares a Design Contract.
if [ "${#SPECS[@]}" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Eq '^## Design Contract([ \t]|$)' "$f" || continue
    decl="$(sed -nE 's/^- Project path: `([^`]+)`.*/\1/p' "$f" | head -n1)"
    # The spec literally contains "~/…"; match that text and expand it manually.
    # shellcheck disable=SC2088
    case "$decl" in "~/"*) decl="$HOME/${decl#\~/}" ;; esac
    [ "$(cd "$decl" 2>/dev/null && pwd)" = "$PROJECT" ] || continue
    SPECS+=("$f")
  done < <(find "$WORKSPACE_ROOT/specs" -maxdepth 1 -name '*.md' ! -name '_template*' 2>/dev/null | sort)
fi
[ "${#SPECS[@]}" -gt 0 ] || die "no specs with a ## Design Contract target $PROJECT"
log "reviewing ${#SPECS[@]} spec(s) against $PROJECT (scheme=$SCHEME)"

# ---- stage 1: build + install on the device matrix --------------------------
# Devices the matrix needs = the union of every reviewed spec's `- Devices:`.
matrix_devices() {
  local f
  for f in "${SPECS[@]}"; do visual_capture_screens "$f" | awk -F'|' '{print $3}'; done | sort -u
}
device_label_to_name() { printf '%s' "$1" | sed -E 's/-/ /g' | sed -E 's/\b(.)/\u\1/g'; }

build_and_install() {
  log "stage 1/4: build + install"
  ( cd "$PROJECT" && npx expo prebuild --platform ios --no-install >/dev/null 2>&1 ) ||
    log "  expo prebuild reported issues (continuing; may already be prebuilt)"
  local first; first="$(matrix_devices | head -n1)"
  log "  building dev client (npx expo run:ios) on '$(device_label_to_name "$first")' — this is slow…"
  ( cd "$PROJECT" && npx expo run:ios --device "$(device_label_to_name "$first")" >/dev/null 2>&1 ) ||
    die "expo run:ios failed — build the app manually, then re-run with --no-build"
  local app; app="$(find "$PROJECT/ios/build" -name '*.app' -type d 2>/dev/null | head -n1)"
  [ -n "$app" ] || { log "  built .app not found; assuming run:ios installed it"; return 0; }
  local d name
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(device_label_to_name "$d")"
    xcrun simctl boot "$name" >/dev/null 2>&1 || true
    xcrun simctl install "$name" "$app" >/dev/null 2>&1 &&
      log "  installed on $name" || log "  WARN: could not install on $name"
  done < <(matrix_devices)
}

# ---- Metro fast-reload harness (for repair) ---------------------------------
_REPAIR_METRO_PID=""
repair_metro_start() {
  local device="$1"
  if [ "$NO_BUILD" -ne 1 ]; then
    log "repair: building dev client on '$device' (slow, once)…"
    ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo run:ios --device "$device" >/dev/null 2>&1 ) \
      || die "repair: dev build failed; build manually then re-run with --no-build"
  fi
  log "repair: starting Metro (EXPO_PUBLIC_PREVIEW=1)…"
  ( cd "$PROJECT" && EXPO_PUBLIC_PREVIEW=1 npx expo start >/tmp/visual-repair-metro.log 2>&1 ) &
  _REPAIR_METRO_PID=$!
  # wait for the bundler port
  local i=0; until curl -s http://localhost:8081/status >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -ge 30 ] && { log "WARN: Metro did not come up after 60s"; break; }; sleep 2; done
}
repair_metro_stop() {
  [ -n "$_REPAIR_METRO_PID" ] || return 0
  kill "$_REPAIR_METRO_PID" 2>/dev/null || true
  pkill -f "expo start" 2>/dev/null || true
  _REPAIR_METRO_PID=""
}

# ---- stage 2: stage Figma reference images ----------------------------------
# Resolve a screen's Figma node id from the spec's
#   `- Figma node IDs: Home = `1:1548`, Foo = `1:2`` line. Falls back to the spec's
# single declared node if the screen isn't individually listed.
node_id_for() {
  local spec="$1" screen="$2" line id
  line="$(grep -E '^- Figma node IDs:' "$spec" | head -n1)"
  id="$(printf '%s' "$line" | grep -oE "${screen}[[:space:]]*=[[:space:]]*\`[0-9I][0-9:I;-]*\`" | grep -oE '`[^`]+`' | tr -d '`' | head -n1)"
  [ -n "$id" ] || id="$(printf '%s' "$line" | grep -oE '`[0-9I][0-9:I;-]*`' | head -n1 | tr -d '`')"
  printf '%s' "$id"
}
figma_key_for() {
  sed -nE 's/.*fileKey `([A-Za-z0-9]+)`.*/\1/p' "$1" | head -n1
}

# Export one Figma node to a PNG via the Figma REST API, with 429 backoff.
stage_ref() {
  local key="$1" node="$2" out="$3" attempt=0 wait=4 url
  [ -s "$out" ] && return 0          # already staged
  [ -n "${FIGMA_TOKEN:-}" ] || { log "  no FIGMA_TOKEN — cannot export $node (pre-stage $out yourself)"; return 1; }
  while [ "$attempt" -lt 5 ]; do
    url="$(curl -s -H "X-Figma-Token: $FIGMA_TOKEN" \
      "https://api.figma.com/v1/images/${key}?ids=${node}&format=png&scale=2" \
      | jq -r --arg n "$node" '.images[$n] // empty')"
    if [ -n "$url" ] && [ "$url" != "null" ]; then
      curl -s "$url" -o "$out" && [ -s "$out" ] && return 0
    fi
    attempt=$((attempt + 1)); log "  figma export retry $attempt for $node (waiting ${wait}s)"; sleep "$wait"; wait=$((wait * 2))
  done
  log "  WARN: could not export Figma node $node after retries"; return 1
}

stage_refs_for_spec() {
  local spec="$1" out_dir="$2" key screen state device ref
  key="$(figma_key_for "$spec")"
  [ -n "$key" ] || { log "  no fileKey in $spec Design Contract; skipping refs"; return 0; }
  while IFS='|' read -r screen state device; do
    [ -n "$screen" ] || continue
    ref="$out_dir/design/${screen}-${state}-${device}.png"
    [ -s "$ref" ] && continue
    stage_ref "$key" "$(node_id_for "$spec" "$screen")" "$ref" || true
  done < <(visual_capture_screens "$spec")
}

# ---- stage 3+4: capture, diff, report ---------------------------------------
review_spec() {
  local spec="$1" base out_dir report
  base="$(basename "$spec" .md)"
  out_dir="$OUT/$base"; mkdir -p "$out_dir/design"
  # Share the staged design refs across specs via the common design/ pool.
  cp -n "$OUT"/design/*.png "$out_dir/design/" 2>/dev/null || true
  [ "$NO_REFS" -eq 1 ] || stage_refs_for_spec "$spec" "$out_dir"
  log "stage 3/4: capture + diff — $base"
  run_visual_capture "$spec" "review" "$out_dir" || true
  report="$out_dir/visual-diff-$base.json"
  case "$(visual_report_status "$report")" in
    valid)
      local pass total
      pass="$(jq '[.screens[]|select(.pass)]|length' "$report")"
      total="$(jq '.screens|length' "$report")"
      log "  $base: $pass/$total screens within tolerance → $report"
      [ "$pass" -eq "$total" ] || return 1 ;;
    absent)  log "  $base: no report (capture SKIPped — app/preview route or refs missing)"; return 0 ;;
    malformed) log "  $base: malformed report"; return 1 ;;
  esac
}

# ---- run --------------------------------------------------------------------
[ "$NO_BUILD" -eq 1 ] || build_and_install
rc=0
for s in "${SPECS[@]}"; do review_spec "$s" || rc=1; done
log "done. reports under $OUT/<spec>/visual-diff-*.json (open in the night-shift viewer)."
exit "$rc"
