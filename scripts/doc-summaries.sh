#!/usr/bin/env bash
# shellcheck shell=bash
#
# doc-summaries.sh — greppable-summary convention checker (agentic-gaps
# tranche §B, closing the doc-freshness gate). Every top-level docs/*.md file
# in THIS engine repo is supposed to open with a `> Summary: <one-to-three
# lines>` line within its first 7 lines, so a router (a human or a fresh
# Claude instance following COMMAND-PLAYBOOK.md) can `grep -A7` a doc hit and
# know whether it's the right file without opening it. See AGENTS.md's
# "Doc summaries" section for the convention itself; this script only checks
# compliance, never writes summaries (that judgment stays with whoever adds
# or edits a doc).
#
# Scope: top-level docs/*.md ONLY (the glob does not descend, so
# docs/examples/, docs/proposals/, docs/superpowers/, and any other
# subdirectory are excluded automatically — the convention is not imposed on
# those, nor on any target project's own docs).
#
# Usage:
#   scripts/doc-summaries.sh --check
#
# --check is the only mode (YAGNI — nothing else consumes this today).
# Exit 0 when every top-level docs/*.md file has a `> Summary:` line in its
# first 7 lines; exit 1 and list the offending file(s) on stderr otherwise.
#
# Test seam: set DOC_SUMMARIES_DIR to point --check at a different directory
# of *.md files (e.g. a fixture dir with a conforming and a non-conforming
# doc) instead of this repo's own docs/ — used by the fixture suite to test
# both the pass and the fail path without touching real docs. Defaults to
# <repo-root>/docs (the directory this script's own parent's docs/ resolves
# to).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="${DOC_SUMMARIES_DIR:-$WORKSPACE_ROOT/docs}"

log() { printf '[doc-summaries] %s\n' "$*" >&2; }

usage() {
  sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

check() {
  local f offenders=0 had_any=0
  for f in "$DOCS_DIR"/*.md; do
    [ -e "$f" ] || continue
    had_any=1
    if ! head -n 7 "$f" | grep -q '^> Summary:'; then
      log "missing \`> Summary:\` opener within the first 7 lines: $f"
      offenders=$((offenders + 1))
    fi
  done
  if [ "$had_any" -eq 0 ]; then
    log "no *.md files found in $DOCS_DIR"
  fi
  if [ "$offenders" -gt 0 ]; then
    log "$offenders file(s) missing a \`> Summary:\` opener"
    return 1
  fi
  log "all top-level docs/*.md files have a Summary opener"
  return 0
}

case "${1:-}" in
  --check) check; exit $? ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
