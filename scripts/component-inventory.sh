#!/usr/bin/env bash
# shellcheck shell=bash
#
# component-inventory.sh — one-command component-inventory extraction
# (port-fidelity Task 5, opening Phase C's component-reuse gate). Thin CLI
# wrapper over scripts/lib/component-inventory.js: validates args, resolves
# the default --out location under the target project, mkdir -p's its parent,
# dispatches to the extractor, and jq-validates the JSON it wrote. Mirrors
# scripts/design-extract.sh's wrapper style (Task 4) — it does not
# reimplement or modify the extractor, only adds CLI ergonomics.
#
# Writes a night-shift-component-inventory/1 JSON (schema in
# scripts/lib/component-inventory.js's header) consumed by Task 6, which
# will add two more flags this wrapper does not yet wire:
#   --single-file <file>   emit just the exported component names of one
#                           file, one per line
#   --closest <name>       print the inventory component name with the
#                           smallest case-insensitive Levenshtein distance
#                           to <name>
#
# Usage:
#   scripts/component-inventory.sh --project <repo>
#     [--dirs 'glob1,glob2'] [--out <file>]
#
# Options:
#   --project DIR   required; target app repo
#   --dirs LIST     comma-separated glob patterns (relative to --project),
#                    e.g. 'src/ui/components,src/features/*/components'.
#                    Precedence: --dirs > $NIGHT_SHIFT_COMPONENT_DIRS
#                    (same comma-separated form) > built-in defaults
#                    (src/ui/components, src/components,
#                    src/features/*/components).
#   --out FILE      where the inventory JSON is written (default:
#                    <project>/.night-shift/component-inventory.json)
#   -h|--help
#
# Exit status: 0 on success, 2 on a usage/argument error, or whatever
# scripts/lib/component-inventory.js exits with (1 = extraction failure,
# one-line stderr reason).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[component-inventory] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

# ---- args -------------------------------------------------------------------
PROJECT="" DIRS="" OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --dirs)    DIRS="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
OUT="${OUT:-$PROJECT/.night-shift/component-inventory.json}"

mkdir -p "$(dirname "$OUT")" || die "cannot create --out dir: $(dirname "$OUT")"

ARGS=(--project "$PROJECT" --out "$OUT")
[ -z "$DIRS" ] || ARGS+=(--dirs "$DIRS")

node "$SCRIPT_DIR/lib/component-inventory.js" "${ARGS[@]}"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if command -v jq >/dev/null 2>&1; then
  jq empty "$OUT" >/dev/null 2>&1 || die "extractor wrote invalid JSON: $OUT"
fi

printf '%s\n' "$OUT"
exit 0
