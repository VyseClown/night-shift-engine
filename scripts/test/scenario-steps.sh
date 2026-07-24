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
    "the spec declares a smoke command that fails only on the candidate")
      printf '\n## Smoke\n- Smoke: `test ! -f add.js`\n' >> "$SPEC" ;;
    "the claude stub in mode \""*"\"")
      write_stub "$(quoted "$phrase")" ;;
    "the engine runs with the spec")
      run_engine --spec "$SPEC" || true ;;   # verdict asserted by Then-steps
    "the engine runs with the spec, expected to fail")
      run_engine --spec "$SPEC" && fail "engine exited 0 unexpectedly" ;;
    "the engine runs again with the spec and --resume")
      run_engine --resume || fail "--resume run exited non-zero" ;;
    "the archived run status is \""*"\"")
      local want got; want="$(quoted "$phrase")"
      got="$(jq -r .status "$(archived summary.json)" 2>/dev/null)"
      [ "$got" = "$want" ] || fail "run status: want $want, got ${got:-none}" ;;
    "the live run status is \""*"\"")
      local want got; want="$(quoted "$phrase")"
      got="$(jq -r .status "$PROJECT/.night-shift/state.json" 2>/dev/null)"
      [ "$got" = "$want" ] || fail "live status: want $want, got ${got:-none}" ;;
    "the live state field \""*"\" contains \""*"\"")
      local path val; path="$(quoted "$phrase")"; val="$(second_quoted "$phrase")"
      jq -r "$path" "$PROJECT/.night-shift/state.json" 2>/dev/null | grep -q -- "$val" \
        || fail "live state $path missing '$val'" ;;
    "the run is not archived")
      local rid; rid="$(jq -r .run_id "$PROJECT/.night-shift/state.json" 2>/dev/null)"
      [ -n "$rid" ] || fail "no live run_id"
      [ ! -d "$PROJECT/.night-shift/archive/$rid" ] || fail "blocked run must not be archived" ;;
    "the archived journal is valid jsonl")
      jq -e . "$(archived events.jsonl)" >/dev/null || fail "journal unparseable" ;;
    "the archived journal contains event \""*"\" with status \""*"\"")
      local t s; t="$(quoted "$phrase")"; s="$(second_quoted "$phrase")"
      jq -e --arg t "$t" --arg s "$s" 'select(.type==$t) | select(.payload.status==$s)' "$(archived events.jsonl)" \
        | grep -q . || fail "archived journal missing $t with status $s" ;;
    "the archived journal contains event \""*"\" with \""*"\"")
      local t f; t="$(quoted "$phrase")"; f="$(second_quoted "$phrase")"
      jq -e --arg t "$t" 'select(.type==$t) | select('"$f"')' "$(archived events.jsonl)" \
        | grep -q . || fail "archived journal missing $t matching $f" ;;
    "the archived journal contains event \""*"\"")
      jq -e --arg t "$(quoted "$phrase")" 'select(.type==$t)' "$(archived events.jsonl)" \
        | grep -q . || fail "journal missing event $(quoted "$phrase")" ;;
    "the live journal contains event \""*"\" with \""*"\"")
      local t f; t="$(quoted "$phrase")"; f="$(second_quoted "$phrase")"
      jq -e --arg t "$t" 'select(.type==$t) | select('"$f"')' "$PROJECT/.night-shift/events.jsonl" \
        | grep -q . || fail "live journal missing $t matching $f" ;;
    "the live journal contains event \""*"\"")
      jq -e --arg t "$(quoted "$phrase")" 'select(.type==$t)' "$PROJECT/.night-shift/events.jsonl" \
        | grep -q . || fail "live journal missing event $(quoted "$phrase")" ;;
    "the project file \""*"\" exists")
      [ -f "$PROJECT/$(quoted "$phrase")" ] || fail "missing $(quoted "$phrase")" ;;
    "the project file \""*"\" contains \""*"\"")
      local f v; f="$(quoted "$phrase")"; v="$(second_quoted "$phrase")"
      grep -q -- "$v" "$PROJECT/$f" 2>/dev/null || fail "$f missing '$v'" ;;
    "the project test suite passes")
      (cd "$PROJECT" && node --test add.test.js) >/dev/null 2>&1 || fail "candidate tests red" ;;
    *)
      fail "unknown step: '$phrase'" ;;
  esac
}
