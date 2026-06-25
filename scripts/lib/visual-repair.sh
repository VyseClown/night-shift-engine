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
