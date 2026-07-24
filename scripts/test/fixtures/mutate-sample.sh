# shellcheck shell=bash
# Frozen mutation-harness self-test target. Content is load-bearing for
# fixture_mutate_* — each rule below must keep its exact occurrence count.
sample_gate() {
  local n="${1:-0}" m="${2:-1}"
  [ "$n" -eq 0 ] || return 1
  [ "$m" -eq 1 ] || exit 1
  [ "$n" -ne 5 ] || return 1
  [ "$n" -lt 3 ] || true
  [ "$n" -gt 9 ] || true
  [ -z "$3" ] && [ -n "$4" ] && return 0
  return 0
}
