#!/usr/bin/env bash
# shellcheck shell=bash
#
# design-extract.sh — one-command design-manifest extraction (port-fidelity
# Task 4). Thin CLI wrapper over the Task 2/3 extractors: validates args,
# resolves the default --out location under the target project, and dispatches
# to whichever extractor the mode needs. Neither extractor is modified or
# reimplemented here — this script only adds the ergonomics (shared flag
# surface, a project-relative default --out, printing the written paths) so a
# night-shift spec's `- Design manifest:` field has a one-line command to
# (re)generate what it points at.
#
#   --mode web    -> node scripts/lib/cdp-extract.js   (drives real Chrome over CDP)
#   --mode figma  -> node scripts/lib/figma-manifest.js (parses a committed node-dump)
#
# Both write a night-shift-design-manifest/1 JSON at <out>/<screen>.json;
# web mode additionally writes <out>/<screen>-<W>x<H>.png.
#
# Usage:
#   scripts/design-extract.sh --mode web --screen <name> --project <dir> --url <u>
#     [--out <dir>] [--viewport WxH] [--cookie k=v]... [--header 'K: V']...
#   scripts/design-extract.sh --mode figma --screen <name> --project <dir> --nodes <file>
#     [--globals <file>] [--out <dir>]
#
# Options:
#   --mode web|figma   required; selects the extractor
#   --screen NAME      required; screen name (manifest filename stem)
#   --project DIR      required; target app repo. Default --out is
#                      <project>/design/manifest/
#   --url URL          required for --mode web (page to drive over CDP)
#   --nodes FILE       required for --mode figma (node-dump text file)
#   --globals FILE     figma mode only; defaults to
#                      <dirname of --nodes>/_global-vars.txt
#   --out DIR          where the manifest (+ PNG for web) is written
#                      (default: <project>/design/manifest/)
#   --viewport WxH     web mode only; default 430x932 (passed through)
#   --cookie k=v       web mode only; repeatable (passed through)
#   --header 'K: V'    web mode only; repeatable (passed through)
#   -h|--help
#
# Exit status: 0 on success, 2 on a usage/argument error, or whatever the
# dispatched extractor exits with (1 = extraction failure, one-line stderr).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[design-extract] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

# ---- args -------------------------------------------------------------------
MODE="" SCREEN="" PROJECT="" URL="" OUT="" VIEWPORT="" NODES="" GLOBALS=""
COOKIES=() HEADERS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)     MODE="${2:-}"; shift 2 ;;
    --screen)   SCREEN="${2:-}"; shift 2 ;;
    --project)  PROJECT="${2:-}"; shift 2 ;;
    --url)      URL="${2:-}"; shift 2 ;;
    --nodes)    NODES="${2:-}"; shift 2 ;;
    --globals)  GLOBALS="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --viewport) VIEWPORT="${2:-}"; shift 2 ;;
    --cookie)   COOKIES+=("${2:-}"); shift 2 ;;
    --header)   HEADERS+=("${2:-}"); shift 2 ;;
    -h|--help)  sed -n '3,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  web|figma) ;;
  *) die "--mode must be 'web' or 'figma' (got '${MODE:-<empty>}')" ;;
esac
[ -n "$SCREEN" ] || die "--screen is required"
[ -n "$PROJECT" ] || die "--project is required"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
OUT="${OUT:-$PROJECT/design/manifest}"

case "$MODE" in
  web)
    [ -n "$URL" ] || die "--mode web requires --url"
    [ -z "$NODES" ] || die "--nodes is only valid with --mode figma"
    [ -z "$GLOBALS" ] || die "--globals is only valid with --mode figma"
    ;;
  figma)
    [ -n "$NODES" ] || die "--mode figma requires --nodes"
    [ -z "$URL" ] || die "--url is only valid with --mode web"
    [ -z "$VIEWPORT" ] || die "--viewport is only valid with --mode web"
    [ -n "$GLOBALS" ] || GLOBALS="$(dirname "$NODES")/_global-vars.txt"
    ;;
esac

mkdir -p "$OUT" || die "cannot create --out dir: $OUT"

case "$MODE" in
  web)
    ARGS=(--url "$URL" --screen "$SCREEN" --out "$OUT")
    [ -z "$VIEWPORT" ] || ARGS+=(--viewport "$VIEWPORT")
    for c in ${COOKIES[@]+"${COOKIES[@]}"}; do ARGS+=(--cookie "$c"); done
    for h in ${HEADERS[@]+"${HEADERS[@]}"}; do ARGS+=(--header "$h"); done
    node "$SCRIPT_DIR/lib/cdp-extract.js" "${ARGS[@]}"
    ;;
  figma)
    node "$SCRIPT_DIR/lib/figma-manifest.js" \
      --nodes "$NODES" --globals "$GLOBALS" --screen "$SCREEN" --out "$OUT"
    ;;
esac
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# Print whatever the extractor actually wrote (manifest JSON always; web mode
# also a screenshot PNG). Globbing without nullglob is deliberate: an
# unmatched "$OUT/$SCREEN"-*.png stays a literal, non-existent path, so the
# `[ -e ]` guard below silently skips it in figma mode instead of printing a
# bogus entry.
# set -uo pipefail (no -e) means the script's own exit status would otherwise be
# whatever the last loop iteration returned (false when the PNG glob doesn't
# match, e.g. figma mode) — explicit `exit 0` is required so a clean dispatch
# always reports success regardless of which paths existed to print.
for f in "$OUT/$SCREEN.json" "$OUT/$SCREEN"-*.png; do
  [ -e "$f" ] && printf '%s\n' "$f"
done
exit 0
