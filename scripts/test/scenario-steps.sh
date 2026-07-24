# shellcheck shell=bash
# scenario-steps.sh — Given/When/Then phrase → function dispatch for
# scenario-run.sh. Wraps integration-lib.sh; add new arms here, keep phrases
# literal (quoted values are extracted by the two helpers below).
# shellcheck source=scripts/test/integration-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/integration-lib.sh"

quoted() { local s="${1#*\"}"; printf '%s' "${s%%\"*}"; }   # first "..." value
second_quoted() { local s="${1#*\"}"; s="${s#*\"}"; s="${s#*\"}"; printf '%s' "${s%%\"*}"; }

archived() { find "$PROJECT/.night-shift/archive" -name "$1" 2>/dev/null | head -1; }

run_step() {
  local phrase="$1"
  case "$phrase" in
    "a throwaway node project with a red test")
      integration_setup ;;
    "the claude stub in mode \""*"\"")
      write_stub "$(quoted "$phrase")" ;;
    "the engine runs with the spec")
      run_engine --spec "$SPEC" || true ;;   # verdict asserted by Then-steps
    "the archived run status is \""*"\"")
      local want got; want="$(quoted "$phrase")"
      got="$(jq -r .status "$(archived summary.json)" 2>/dev/null)"
      [ "$got" = "$want" ] || fail "run status: want $want, got ${got:-none}" ;;
    "the archived journal is valid jsonl")
      jq -e . "$(archived events.jsonl)" >/dev/null || fail "journal unparseable" ;;
    "the archived journal contains event \""*"\"")
      jq -e --arg t "$(quoted "$phrase")" 'select(.type==$t)' "$(archived events.jsonl)" \
        | grep -q . || fail "journal missing event $(quoted "$phrase")" ;;
    "the project file \""*"\" exists")
      [ -f "$PROJECT/$(quoted "$phrase")" ] || fail "missing $(quoted "$phrase")" ;;
    "the project test suite passes")
      (cd "$PROJECT" && node --test add.test.js) >/dev/null 2>&1 || fail "candidate tests red" ;;
    *)
      fail "unknown step: '$phrase'" ;;
  esac
}
