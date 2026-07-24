#!/usr/bin/env bash
# scenario-run.sh — executes scripts/test/scenarios/*.feature. Each scenario
# runs in its own subshell (integration-lib's EXIT-trap cleanup fires per
# scenario). Unknown steps and parse errors are hard failures.
set -u
DIR="$(cd "$(dirname "$0")" && pwd -P)"
FAILS=0
run_scenario_file() {
  local file="$1" name="" lineno=0 rc
  # shellcheck disable=SC2094  # $file is only ever read: redirected as this
  # loop's stdin below and passed through to finish_scenario for messages —
  # nothing here writes to it, but shellcheck can't tell the two apart.
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    local line="${raw#"${raw%%[![:space:]]*}"}"      # ltrim
    case "$line" in
      ''|'#'*) continue ;;
      'Scenario: '*)
        [ -z "$name" ] || finish_scenario "$file"
        name="${line#Scenario: }"; STEPS=() ;;
      Given\ *|When\ *|And\ *|Then\ *|But\ *)
        [ -n "$name" ] || { echo "not ok - $file:$lineno step before Scenario:" >&2; exit 1; }
        STEPS+=("${line#* }") ;;
      *) echo "not ok - $file:$lineno unparseable line: $line" >&2; exit 1 ;;
    esac
  done <"$file"
  [ -z "$name" ] || finish_scenario "$file"
}
# finish_scenario reads `name`/`STEPS` from run_scenario_file's locals via
# bash's dynamic scoping, not as arguments (same idiom scripts/test/fixtures.sh
# already leans on — see its SC2318 file-header note).
# shellcheck disable=SC2154
finish_scenario() {
  local file="$1" rc=0
  ( # FAIL_PREFIX is read by integration-lib.sh's fail() once sourced below,
    # not in this file — a cross-file consumer the next line's directive
    # accounts for since static analysis can't see it.
    # shellcheck disable=SC2034
    FAIL_PREFIX="scenario"
    # shellcheck source=scripts/test/scenario-steps.sh
    . "$DIR/scenario-steps.sh"
    for s in "${STEPS[@]}"; do run_step "$s"; done
  ) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'ok - scenario: %s\n' "$name"
  else printf 'not ok - scenario: %s (%s)\n' "$name" "$file" >&2; FAILS=$((FAILS + 1)); fi
  name=""
}
if [ "${1:-}" = "--all" ]; then set -- "$DIR"/scenarios/*.feature; fi
[ "$#" -ge 1 ] || { echo "usage: scenario-run.sh --all | <file...>" >&2; exit 2; }
for f in "$@"; do run_scenario_file "$f"; done
exit "$((FAILS > 0 ? 1 : 0))"
