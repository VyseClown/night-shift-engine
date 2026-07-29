#!/usr/bin/env bash
# shellcheck shell=bash
# visual-compare.sh — standalone visual-comparison report generator.
#
# Takes a manifest of image PAIRS (design/web reference vs captured candidate),
# pixel-diffs each pair with the sanctioned tool (odiff, via visual-capture.sh's
# __visual_pixel_diff — same parsing, same resize dance, same edge cases), and
# emits a `visual-diff-<name>.json` report + copied assets into a run's
# `validated/` dir. Because the report speaks the EXISTING visual-diff contract
# (schemas/visual-diff.json), the night-shift viewer renders it side-by-side
# (reference | candidate | diff overlay, diff % vs tolerance, pass badge) with
# zero viewer changes.
#
# Unlike visual-review.sh this does NO capturing: both images already exist.
# Use it to publish ad-hoc design reviews (e.g. responsive-web screenshots vs
# native sim captures) into a run the viewer can show.
#
# Usage:
#   scripts/visual-compare.sh --manifest <pairs.json> --run-dir <runDir> [--name <report-name>]
#
# Manifest (JSON):
#   {
#     "task": "detail-sheet parity: responsive web vs native",  # required
#     "tolerance": 0.35,                                   # optional, 0-1 fraction; default VISUAL_DEFAULT_TOLERANCE
#     "device": "iOS sim vs responsive web 402px",         # optional default per-pair device label
#     "pairs": [                                           # required, non-empty
#       {
#         "screen": "activity-sheet-top",                  # required
#         "state": "at-rest",                              # optional, default "default"
#         "reference": "/abs/path/web-ref.jpg",            # required (any sips-readable format)
#         "candidate": "/abs/path/native-capture.png",     # required
#         "device": "iPhone 16 Pro sim",                   # optional, overrides manifest device
#         "tolerance": 0.25,                               # optional, overrides manifest tolerance
#         "analysis": "known cosmetic delta: title wraps"  # optional, shown under the pair
#       }
#     ]
#   }
#
# Output (all inside <runDir>/validated/):
#   visual-compare/<screen>-<state>-{reference,candidate,diff}.png
#   visual-diff-<name>.json   (viewer picks it up by the visual-diff-* glob)
#
# diff_pct is a 0-1 FRACTION (visual-diff contract; pass == diff_pct <= tolerance).
# Exit: 0 = report written; 2 = precondition failure (tooling/manifest); 1 = a pair failed to diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/visual-capture.sh
source "$SCRIPT_DIR/lib/visual-capture.sh"

MANIFEST="" RUN_DIR="" NAME="compare"

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | cut -c3-; exit 0 ;;
    *) echo "visual-compare: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "visual-compare: --manifest <pairs.json> required" >&2; exit 2; }
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { echo "visual-compare: --run-dir <runDir> required (existing dir)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "visual-compare: jq required" >&2; exit 2; }
command -v "${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff}" >/dev/null 2>&1 || {
  echo "visual-compare: ${NIGHT_SHIFT_VISUAL_DIFF_TOOL:-odiff} not found (brew install odiff)" >&2; exit 2; }
jq -e '.task and (.pairs | type == "array" and length > 0)' "$MANIFEST" >/dev/null 2>&1 || {
  echo "visual-compare: manifest needs .task and a non-empty .pairs array" >&2; exit 2; }

VALIDATED_DIR="$RUN_DIR/validated"
ASSET_DIR="$VALIDATED_DIR/visual-compare"
mkdir -p "$ASSET_DIR"

# Slugify a screen/state into a safe filename fragment.
__vc_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//'; }

# Copy + normalize an input image to PNG inside the asset dir (odiff wants
# raster formats it knows; the viewer's asset route wants an allowlisted
# extension; the report wants paths INSIDE the run dir). sips ships with macOS.
__vc_import_png() {
  local src="$1" dst="$2"
  cp "$src" "$dst.import" || return 1
  if sips -s format png "$dst.import" --out "$dst" >/dev/null 2>&1; then
    rm -f "$dst.import"
  else
    mv "$dst.import" "$dst"
  fi
  [ -s "$dst" ]
}

default_tolerance="$(jq -r '.tolerance // empty' "$MANIFEST")"
[ -n "$default_tolerance" ] || default_tolerance="$VISUAL_DEFAULT_TOLERANCE"
default_device="$(jq -r '.device // "comparison"' "$MANIFEST")"
task="$(jq -r '.task' "$MANIFEST")"

screens_json="[]"
failures=0
pair_count="$(jq '.pairs | length' "$MANIFEST")"

for i in $(seq 0 $((pair_count - 1))); do
  pair="$(jq -c ".pairs[$i]" "$MANIFEST")"
  screen="$(jq -r '.screen // empty' <<<"$pair")"
  state="$(jq -r '.state // "default"' <<<"$pair")"
  reference_src="$(jq -r '.reference // empty' <<<"$pair")"
  candidate_src="$(jq -r '.candidate // empty' <<<"$pair")"
  device="$(jq -r ".device // \"$default_device\"" <<<"$pair")"
  tolerance="$(jq -r ".tolerance // \"$default_tolerance\"" <<<"$pair")"
  analysis="$(jq -r '.analysis // ""' <<<"$pair")"

  if [ -z "$screen" ] || [ ! -f "$reference_src" ] || [ ! -f "$candidate_src" ]; then
    echo "visual-compare: pairs[$i] invalid (screen/reference/candidate)" >&2
    failures=$((failures + 1))
    continue
  fi

  slug="$(__vc_slug "$screen")-$(__vc_slug "$state")"
  ref_png="$ASSET_DIR/$slug-reference.png"
  cand_png="$ASSET_DIR/$slug-candidate.png"
  diff_png="$ASSET_DIR/$slug-diff.png"

  __vc_import_png "$reference_src" "$ref_png" || { echo "visual-compare: import failed: $reference_src" >&2; failures=$((failures + 1)); continue; }
  __vc_import_png "$candidate_src" "$cand_png" || { echo "visual-compare: import failed: $candidate_src" >&2; failures=$((failures + 1)); continue; }

  if ! diff_pct="$(__visual_pixel_diff "$ref_png" "$cand_png" "$diff_png")"; then
    echo "visual-compare: diff failed for $screen ($state)" >&2
    failures=$((failures + 1))
    continue
  fi

  pass="$(LC_ALL=C awk -v d="$diff_pct" -v t="$tolerance" 'BEGIN{ print (d <= t) ? "true" : "false" }')"
  diff_rel="visual-compare/$slug-diff.png"
  [ -s "$diff_png" ] || diff_rel=""

  screens_json="$(jq -c \
    --arg screen "$screen" --arg state "$state" --arg device "$device" \
    --arg reference "visual-compare/$slug-reference.png" \
    --arg screenshot "visual-compare/$slug-candidate.png" \
    --arg diff_image "$diff_rel" --arg analysis "$analysis" \
    --argjson diff_pct "$diff_pct" --argjson tolerance "$tolerance" --argjson pass "$pass" \
    '. + [{
      screen: $screen, state: $state, device: $device,
      reference: $reference, screenshot: $screenshot,
      diff_pct: $diff_pct, tolerance: $tolerance, pass: $pass,
      analysis: $analysis, attempts: [],
      diff_image: (if $diff_image == "" then null else $diff_image end),
      unmet_brief: []
    }]' <<<"$screens_json")"
done

emitted="$(jq 'length' <<<"$screens_json")"
if [ "$emitted" -eq 0 ]; then
  echo "visual-compare: no pair produced a diff — no report written" >&2
  exit 1
fi

report="$VALIDATED_DIR/visual-diff-$(__vc_slug "$NAME").json"
jq -n --arg task "$task" --argjson screens "$screens_json" '{task: $task, screens: $screens}' > "$report"
echo "visual-compare: wrote $report ($emitted screens, $failures failed pairs)"
[ "$failures" -eq 0 ] || exit 1
