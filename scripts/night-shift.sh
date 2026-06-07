#!/usr/bin/env bash
set -u
set -o pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCHEMA_DIR="$WORKSPACE_ROOT/schemas"
PRIMARY=""
PROJECT=""
SPEC=""
FIXTURE_TEST=0
DRY_RUN=0
FULL_PERSONA_LIVE_TEST=0
MAX_STAGE_TURNS="${NIGHT_SHIFT_MAX_STAGE_TURNS:-12}"
MAX_STAGE_SECONDS="${NIGHT_SHIFT_MAX_STAGE_SECONDS:-3600}"
MAX_TASK_TURNS="${NIGHT_SHIFT_MAX_TASK_TURNS:-36}"
MAX_TASK_SECONDS="${NIGHT_SHIFT_MAX_TASK_SECONDS:-10800}"
RATE_LIMIT_BUFFER_SECONDS="${NIGHT_SHIFT_RATE_LIMIT_BUFFER_SECONDS:-60}"
# Sanity ceiling on a rate-limit wait. A genuine session limit resets within a
# few hours; a wait longer than this almost certainly means the reset time was
# misparsed, so we block for manual resume instead of sleeping for ~a day.
RATE_LIMIT_MAX_WAIT_SECONDS="${NIGHT_SHIFT_RATE_LIMIT_MAX_WAIT_SECONDS:-21600}"
# Persona/profile resolution — the persona/track constants (PERSONAS_RN,
# PERSONAS_WEB, PERSONAS_OPTIONAL, PERSONAS, the floors, DEFAULT_TRACK) and the
# pure functions that map a spec to its active review set — live in
# lib/personas.sh, sourced here so the orchestrator file stays focused. These are
# globals/functions in the same shell, so the rest of the script uses them
# unchanged. (Most of the deterministic fixture suite exercises this module.)
NIGHT_SHIFT_LIB="$WORKSPACE_ROOT/scripts/lib"
# shellcheck source=scripts/lib/personas.sh
. "$NIGHT_SHIFT_LIB/personas.sh"
# Design-fidelity visual capture (Phase 2). A contract scaffold: inert by default
# (no-op SKIP without a simulator + image-diff tool); see the file header for the
# integration point. Sourced so its functions and the visual-diff schema check
# are available to the run and the fixtures.
# shellcheck source=scripts/lib/visual-capture.sh
. "$NIGHT_SHIFT_LIB/visual-capture.sh"
# Ignored, dependency directories the isolated validation worktree needs but git
# does not track. They are symlinked from the project so RN tooling works without
# reinstalling or triggering npx downloads. Override with NIGHT_SHIFT_DEPENDENCY_LINKS.
# Defaults cover both the rn layout (root node_modules + CocoaPods) and the web
# layout where node_modules live in sub-packages (e.g. the viewer's server/ and
# web/). link_worktree_dependencies skips any entry that does not exist, so listing
# all of them is safe — each project only links what it actually has. Override with
# NIGHT_SHIFT_DEPENDENCY_LINKS for a non-standard layout.
DEPENDENCY_LINKS="${NIGHT_SHIFT_DEPENDENCY_LINKS:-node_modules ios/Pods server/node_modules web/node_modules}"

usage() {
  cat <<'EOF'
Usage:
  scripts/night-shift.sh --project PATH [--spec PATH]
  scripts/night-shift.sh --fixture-test --dry-run
  scripts/night-shift.sh --fixture-test [--full-persona-live-test]

Claude runs the entire flow: the pinned primary session implements, the spec's
review personas (selected by its Track + Review Profile) review, and a fresh
independent Claude session observes each candidate. Runs use explicit session
IDs, local candidate commits, per-profile persona approvals, and observer
approval. Live fixture tests make paid Claude calls;
full six-persona live coverage requires --full-persona-live-test and
NIGHT_SHIFT_ACCEPT_COSTS=YES. (--primary is accepted only as claude.)
EOF
}

log() { printf '[night-shift] %s\n' "$*"; }
die() { printf '[night-shift] BLOCKED: %s\n' "$*" >&2; exit 1; }
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date '+%s'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --primary) [ "$#" -ge 2 ] || die "--primary requires a value"; PRIMARY="$2"; shift 2 ;;
    --project) [ "$#" -ge 2 ] || die "--project requires a value"; PROJECT="$2"; shift 2 ;;
    --spec) [ "$#" -ge 2 ] || die "--spec requires a value"; SPEC="$2"; shift 2 ;;
    --fixture-test) FIXTURE_TEST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --full-persona-live-test) FULL_PERSONA_LIVE_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required executable not found: $1"
}

json_schema_basic() {
  local kind="$1" file="$2"
  jq -e . "$file" >/dev/null 2>&1 || return 1
  case "$kind" in
    next-action)
      jq -e '
        type == "object" and
        ((keys | sort) == ["action","artifacts","reason","stage","task"]) and
        (.action | IN("RUN_PERSONAS","CREATE_CANDIDATE","REQUEST_OBSERVER","NEXT_TASK","BLOCKED","COMPLETE")) and
        (.task | type == "string" and length > 0) and
        (.stage | type == "string" and length > 0) and
        (.reason | type == "string" and length > 0) and
        (.artifacts | type == "array" and all(.[]; type == "string" and length > 0 and
          (startswith("/") | not) and (test("(^|/)\\.\\.(/|$)") | not))) and
        ((.artifacts | unique | length) == (.artifacts | length))
      ' "$file" >/dev/null 2>&1
      ;;
    persona-review)
      jq -e --arg personas "$PERSONAS" '
        ($personas | split("|")) as $p |
        type == "object" and
        ((keys | sort) == ["commit","documentation_changes","findings","persona","stage","status"]) and
        (.persona as $v | $p | index($v) != null) and
        (.stage | IN("plan","implementation")) and
        (.commit == null or (.commit | type == "string" and length > 0)) and
        (.status | IN("APPROVE","BLOCK")) and
        (.documentation_changes | type == "array" and all(.[]; type == "string" and length > 0)) and
        (.findings | type == "array" and all(.[];
          ((keys | sort) == ["evidence","id","required_change"]) and
          (.id | type == "string" and test("^[A-Z][A-Z0-9_-]*-[0-9]{3,}$")) and
          (.evidence | type == "string" and length > 0) and
          (.required_change | type == "string" and length > 0))) and
        (if .status == "APPROVE" then (.findings | length == 0) else (.findings | length > 0) end)
      ' "$file" >/dev/null 2>&1
      ;;
    observer-review)
      jq -e '
        type == "object" and
        ((keys | sort) == ["candidate_commit","documentation_changes","findings","observer","primary","status","task"]) and
        (.observer == "claude") and (.primary == "claude") and
        (.task | type == "string" and length > 0) and
        (.candidate_commit | type == "string" and test("^[0-9a-f]{7,64}$")) and
        (.status | IN("APPROVE","BLOCK")) and
        (.documentation_changes | type == "array" and all(.[]; type == "string" and length > 0)) and
        (.findings | type == "array" and all(.[];
          ((keys | sort) == ["evidence","id","required_change"]) and
          (.id | type == "string" and test("^OBS-[0-9]{3,}$")) and
          (.evidence | type == "string" and length > 0) and
          (.required_change | type == "string" and length > 0))) and
        (if .status == "APPROVE" then (.findings | length == 0) else (.findings | length > 0) end)
      ' "$file" >/dev/null 2>&1
      ;;
    execution-evidence)
      jq -e '
        type == "object" and
        ((keys | sort) == ["baseline","final_validation","task","test_first"]) and
        (.task | type == "string" and length > 0) and
        (.baseline | type == "array" and length > 0 and all(.[];
          ((keys | sort) == ["command","exit_status","output"]) and
          (.command | type == "string" and length > 0) and
          (.exit_status | type == "number" and floor == . and . >= 0) and
          (.output | type == "string"))) and
        (.final_validation | type == "array" and length > 0 and all(.[];
          ((keys | sort) == ["command","exit_status","output"]) and
          (.command | type == "string" and length > 0) and
          (.exit_status | type == "number" and floor == . and . >= 0) and
          (.output | type == "string"))) and
        (.test_first |
          ((keys | sort) == ["command","failing_exit_status","failing_output","passing_exit_status","passing_output"]) and
          (.command | type == "string" and length > 0) and
          (.failing_exit_status | type == "number" and floor == . and . > 0) and
          (.failing_output | type == "string" and length > 0) and
          (.passing_exit_status == 0) and
          (.passing_output | type == "string" and length > 0))
      ' "$file" >/dev/null 2>&1
      ;;
    visual-diff)
      # Design-fidelity report the engine's visual-capture scaffold emits and the
      # viewer renders. Mirrors schemas/visual-diff.json (kept byte-identical to
      # the viewer's vendored copy), including pass-consistency: pass is true iff
      # diff_pct <= tolerance.
      jq -e '
        type == "object" and
        ((keys | sort) == ["screens","task"]) and
        (.task | type == "string" and length > 0) and
        (.screens | type == "array" and length > 0 and all(.[];
          ((keys | sort) == ["diff_image","diff_pct","pass","reference","screen","screenshot","state","tolerance"]) and
          (.screen | type == "string" and length > 0) and
          (.state | type == "string" and length > 0) and
          (.reference | type == "string" and length > 0) and
          (.screenshot | type == "string" and length > 0) and
          (.diff_pct | type == "number" and . >= 0) and
          (.tolerance | type == "number" and . >= 0) and
          (.pass | type == "boolean") and
          (.diff_image == null or (.diff_image | type == "string" and length > 0)) and
          (.pass == (.diff_pct <= .tolerance))))
      ' "$file" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

write_json_atomic() {
  local target="$1" filter="$2"
  shift 2
  local tmp="${target}.tmp.$$"
  jq -n "$@" "$filter" >"$tmp" || return 1
  mv "$tmp" "$target"
}

# Recognizes Claude's structured session-limit response: HTTP 429 plus a result
# string carrying a 12-hour clock reset time and an IANA (slash) timezone, e.g.
# "...resets 5:40am (America/Sao_Paulo)". This is deliberately strict: anything
# we cannot parse with confidence (abbreviated timezones like "UTC"/"PST",
# 24-hour times, or weekly limits phrased as a weekday) returns false, so the
# caller falls through to block_run for safe manual resume rather than guessing.
# NOTE: the .api_error_status field name and message wording are the live CLI
# contract — verify against a real 429 capture if the CLI version changes.
is_rate_limit_response() {
  local raw="$1"
  jq -e '
    .api_error_status == 429 and
    (.result | type == "string" and
      test("resets [0-9]{1,2}:[0-9]{2}(am|pm) \\([A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+\\)"))
  ' "$raw" >/dev/null 2>&1
}

rate_limit_reset_fields() {
  local raw="$1"
  jq -r '.result // empty' "$raw" 2>/dev/null |
    sed -nE 's/.*resets ([0-9]{1,2}):([0-9]{2})(am|pm) \(([A-Za-z0-9._+-]+(\/[A-Za-z0-9._+-]+)+)\).*/\1|\2|\3|\4/p'
}

epoch_clock_fields() {
  local epoch="$1" timezone="$2"
  TZ="$timezone" date -r "$epoch" '+%H|%M|%S' 2>/dev/null ||
    TZ="$timezone" date -d "@$epoch" '+%H|%M|%S' 2>/dev/null
}

rate_limit_reset_epoch() {
  local raw="$1" reference_epoch="$2" fields hour minute meridiem timezone
  local current_fields current_hour current_minute current_second target_minutes current_minutes delta
  local old_ifs
  fields="$(rate_limit_reset_fields "$raw")"
  [ -n "$fields" ] || return 1
  old_ifs="$IFS"; IFS='|'
  read -r hour minute meridiem timezone <<EOF
$fields
EOF
  IFS="$old_ifs"
  case "$hour:$minute:$meridiem" in
    [1-9]:[0-5][0-9]:am|[1-9]:[0-5][0-9]:pm|1[0-2]:[0-5][0-9]:am|1[0-2]:[0-5][0-9]:pm) ;;
    *) return 1 ;;
  esac
  hour=$((10#$hour))
  minute=$((10#$minute))
  [ "$meridiem" = "am" ] && [ "$hour" -eq 12 ] && hour=0
  [ "$meridiem" = "pm" ] && [ "$hour" -ne 12 ] && hour=$((hour + 12))
  current_fields="$(epoch_clock_fields "$reference_epoch" "$timezone")" || return 1
  old_ifs="$IFS"; IFS='|'
  read -r current_hour current_minute current_second <<EOF
$current_fields
EOF
  IFS="$old_ifs"
  current_hour=$((10#$current_hour))
  current_minute=$((10#$current_minute))
  current_second=$((10#$current_second))
  target_minutes=$((hour * 60 + minute))
  current_minutes=$((current_hour * 60 + current_minute))
  delta=$((target_minutes - current_minutes))
  [ "$delta" -ge 0 ] || delta=$((delta + 1440))
  printf '%s\n' $((reference_epoch - current_second + delta * 60))
}

file_mtime_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

recoverable_rate_limit_state() {
  local state="$1" raw="$2" status session emitted
  [ -f "$state" ] && [ -f "$raw" ] || return 1
  status="$(jq -r '.status' "$state")"
  case "$status" in blocked|waiting) ;; *) return 1 ;; esac
  is_rate_limit_response "$raw" || return 1
  session="$(jq -r '.session_id // empty' "$state")"
  emitted="$(jq -r '.session_id // empty' "$raw")"
  [ -n "$session" ] && [ "$emitted" = "$session" ] || return 1
  if [ "$status" = "blocked" ] && [ "$(jq -r '.rate_limit_reset_at // empty' "$state")" = "" ]; then
    case "$(jq -r '.block_reason // empty' "$state")" in
      "primary command failed with status "*) ;;
      *) return 1 ;;
    esac
  fi
}

wait_for_rate_limit_reset() {
  local raw="$1" reference reset_epoch deadline now wait_seconds stage_active task_active
  reference="$(file_mtime_epoch "$raw")" || reference="$(now_epoch)"
  reset_epoch="$(rate_limit_reset_epoch "$raw" "$reference")" ||
    block_run "Claude returned HTTP 429 but its reset time could not be parsed"
  deadline=$((reset_epoch + RATE_LIMIT_BUFFER_SECONDS))
  now="$(now_epoch)"
  wait_seconds=$((deadline - now))
  [ "$wait_seconds" -gt 0 ] || wait_seconds=0
  # Guard against a misparsed reset time producing a runaway sleep (e.g. a
  # day-rollover on bad input). Block for manual resume instead.
  [ "$wait_seconds" -le "$RATE_LIMIT_MAX_WAIT_SECONDS" ] ||
    block_run "computed rate-limit wait ${wait_seconds}s exceeds the ${RATE_LIMIT_MAX_WAIT_SECONDS}s cap; reset time likely misparsed — resume manually once the limit clears"
  # Capture the ACTIVE elapsed (now - started_at) before waiting. On resume we
  # rebase started_at to now-minus-this, so neither the wait nor any offline gap
  # (a killed-and-recovered process) is counted against the stage/task time caps.
  # Prefer values already recorded on a prior entry, since recovery re-enters here
  # with a stale started_at.
  stage_active="$(jq -r '.rate_limit_stage_elapsed // empty' "$STATE")"
  task_active="$(jq -r '.rate_limit_task_elapsed // empty' "$STATE")"
  if [ -z "$stage_active" ] || [ -z "$task_active" ]; then
    stage_active=$((now - $(jq -r '.stage_started_at' "$STATE")))
    task_active=$((now - $(jq -r '.task_started_at' "$STATE")))
    [ "$stage_active" -ge 0 ] || stage_active=0
    [ "$task_active" -ge 0 ] || task_active=0
  fi
  state_set '
    .status="waiting" |
    .rate_limit_reset_at=$reset |
    .rate_limit_stage_elapsed=$se |
    .rate_limit_task_elapsed=$te |
    .updated_at=$iso
  ' --argjson reset "$reset_epoch" --argjson se "$stage_active" \
    --argjson te "$task_active" --arg iso "$(now_iso)"
  if [ "$wait_seconds" -gt 0 ]; then
    log "Claude session limit reached; waiting ${wait_seconds}s until reset plus ${RATE_LIMIT_BUFFER_SECONDS}s buffer"
    sleep "$wait_seconds"
  else
    log "Claude session limit reset has passed; retrying the pinned session now"
  fi
  # Rebase budgets: only active time counts, regardless of wait/offline duration.
  now="$(now_epoch)"
  state_set '
    .status="running" |
    .stage_started_at=($now - $se) |
    .task_started_at=($now - $te) |
    .stage_started[.stage]=($now - $se) |
    del(.block_reason,.rate_limit_reset_at,.rate_limit_stage_elapsed,.rate_limit_task_elapsed,.rate_limit_budget_paused_until) |
    .updated_at=$iso
  ' --argjson now "$now" --argjson se "$stage_active" \
    --argjson te "$task_active" --arg iso "$(now_iso)"
}

fixture_assert() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
  fi
}

fixture_reject() {
  local description="$1"
  shift
  if "$@"; then
    printf 'not ok - %s\n' "$description" >&2
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
  else
    printf 'ok - %s\n' "$description"
  fi
}

run_dry_fixtures() {
  local root="$WORKSPACE_ROOT/.night-shift-fixture.$$"
  local good bad
  FIXTURE_FAILURES=0
  FIXTURE_ROOT="$root"
  mkdir -p "$root"
  trap 'rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM

  good="$root/action.json"
  bad="$root/bad.json"
  printf '%s\n' '{"action":"RUN_PERSONAS","task":"specs/a.md","stage":"plan_review","artifacts":["packet.json"],"reason":"plan ready"}' >"$good"
  fixture_assert "valid next-action signal" json_schema_basic next-action "$good"
  printf '%s\n' '{"action":"NOPE","task":"","stage":"plan","artifacts":["../escape"],"reason":""}' >"$bad"
  fixture_reject "malformed and escaping signal" json_schema_basic next-action "$bad"
  fixture_reject "missing signal" json_schema_basic next-action "$root/missing.json"

  good="$root/persona.json"
  printf '%s\n' '{"persona":"Performance Expert","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$good"
  fixture_assert "persona approval schema" json_schema_basic persona-review "$good"
  printf '%s\n' '{"persona":"Performance Expert","stage":"implementation","commit":"abc1234","status":"BLOCK","findings":[],"documentation_changes":[]}' >"$bad"
  fixture_reject "blocking persona requires findings" json_schema_basic persona-review "$bad"

  good="$root/observer.json"
  printf '%s\n' '{"observer":"claude","primary":"claude","task":"specs/a.md","candidate_commit":"abcdef1","status":"BLOCK","findings":[{"id":"OBS-001","evidence":"test output","required_change":"test passes"}],"documentation_changes":[]}' >"$good"
  fixture_assert "observer blocker schema" json_schema_basic observer-review "$good"
  jq '.observer = "codex"' "$good" >"$bad"
  fixture_reject "observer must be claude" json_schema_basic observer-review "$bad"

  good="$root/evidence.json"
  printf '%s\n' '{"task":"specs/a.md","baseline":[{"command":"check","exit_status":0,"output":"ok"}],"test_first":{"command":"test","failing_exit_status":1,"failing_output":"failed","passing_exit_status":0,"passing_output":"passed"},"final_validation":[{"command":"check","exit_status":0,"output":"ok"}]}' >"$good"
  fixture_assert "execution evidence schema" json_schema_basic execution-evidence "$good"
  jq '.test_first.failing_exit_status = 0' "$good" >"$bad"
  fixture_reject "test-first evidence requires an observed failure" json_schema_basic execution-evidence "$bad"

  fixture_assert "bug-first task ordering" fixture_task_order "$root"
  fixture_assert "stage limit boundary" fixture_limits
  fixture_assert "review retry preserves successful results" fixture_partial_retry "$root"
  fixture_assert "in-place persona artifact copy is a no-op (no BSD cp failure)" fixture_persona_inplace_copy "$root"
  fixture_assert "candidate commit mapping" fixture_commit_mapping "$root"
  fixture_assert "success cleanup and blocked recovery" fixture_cleanup_recovery "$root"
  fixture_assert "interruption state recovery" fixture_state_recovery "$root"
  fixture_assert "real transition gate sequence" fixture_transitions
  fixture_assert "malformed adapter retries once" fixture_adapter_retry "$root"
  fixture_assert "final-only validation commands pass by identity" fixture_validation_identity "$root"
  fixture_assert "candidate validation excludes working-tree dirt" fixture_candidate_isolation "$root"
  fixture_assert "candidate selection keeps insertion order (no unique-sort)" fixture_candidate_order "$root"
  fixture_assert "stage entry uses a fresh clock (no ancient restore)" fixture_stage_fresh_start "$root"
  fixture_assert "observer verdict extraction (json/fenced/embedded)" fixture_observer_extraction "$root"
  fixture_assert "observer verdict normalization (synonyms/ids/extra keys)" fixture_observer_normalization "$root"
  fixture_assert "missing tool detection (exit 127)" fixture_missing_tools "$root"
  fixture_assert "finding stall counter accumulates and resets" fixture_finding_stall "$root"
  fixture_assert "validation worktree gets linked dependencies" fixture_worktree_dependencies "$root"
  fixture_assert "validation worktree links nested (web-layout) dependencies" fixture_worktree_dependencies_nested "$root"
  fixture_assert "tmp base is canonical (worktree path matches cleanup prefix)" fixture_tmp_base_canonical "$root"
  fixture_assert "review fields are read only from the ## Review section" fixture_review_fields_scoped "$root"
  fixture_assert "visual-diff schema enforces shape + pass-consistency" fixture_visual_diff_schema "$root"
  fixture_assert "visual capture parses Design Contract frames x states" fixture_visual_capture_screens "$root"
  fixture_assert "visual screen assembly derives pass and null diff_image" fixture_visual_assemble_screen "$root"
  fixture_assert "visual capture is an inert no-op without tooling" fixture_visual_capture_skips "$root"
  fixture_assert "spec validation accepts slash fields" fixture_spec_validation "$root"
  fixture_assert "web spec validates without native permission lines" fixture_spec_validation_web "$root"
  fixture_assert "review profile resolves to floor + scoped personas" fixture_review_profile "$root"
  fixture_assert "web track resolves to web personas + floor" fixture_review_profile_web "$root"
  fixture_assert "persona gate enforces the active profile set" fixture_profile_gate "$root"
  fixture_assert "optional reviewer field unions into active set" fixture_optional_persona_field "$root"
  fixture_assert "comma-separated optional reviewers all union in" fixture_optional_persona_multi "$root"
  fixture_assert "contract section auto-activates optional reviewer" fixture_optional_persona_section "$root"
  fixture_assert "unknown optional reviewer is rejected" fixture_optional_persona_unknown "$root"
  fixture_assert "no optional opt-in leaves active set unchanged" fixture_optional_persona_none "$root"
  fixture_assert "schema accepts optional persona records" fixture_optional_persona_schema "$root"
  fixture_assert "added optional persona unions via field" fixture_optional_persona_added_field "$root"
  fixture_assert "added optional persona auto-activates via its section" fixture_optional_persona_added_section "$root"
  fixture_assert "explicit Personas list overrides the profile (floor kept)" fixture_explicit_personas_override "$root"
  fixture_assert "explicit Personas list may name an optional reviewer" fixture_explicit_personas_with_optional "$root"
  fixture_assert "explicit Personas list rejects an off-track name" fixture_explicit_personas_unknown "$root"
  fixture_assert "structured session limit is recognized" fixture_rate_limit_recognition "$root"
  fixture_assert "rate-limit reset epoch uses reported timezone" fixture_rate_limit_epoch "$root"
  fixture_assert "rate-limit resume rebases elapsed budgets" fixture_rate_limit_rebase "$root"
  fixture_assert "preserved rate-limit block is recoverable" fixture_rate_limit_recovery "$root"
  fixture_assert "runaway rate-limit wait hits the cap" fixture_rate_limit_cap "$root"

  if [ "$FIXTURE_FAILURES" -ne 0 ]; then
    die "$FIXTURE_FAILURES deterministic fixture(s) failed"
  fi
  rm -rf "$root"
  trap - EXIT HUP INT TERM
  log "all deterministic fixtures passed"
}

fixture_task_order() {
  local root="$1"
  cat >"$root/TODO.md" <<'EOF'
- [ ] feature: Later feature (`specs/feature.md`)
- [ ] bug: First bug (`specs/bug.md`)
EOF
  [ "$(select_task_from_todo "$root/TODO.md")" = "specs/bug.md" ]
}

fixture_limits() {
  limit_exceeded 11 100 35 100 && return 1
  limit_exceeded 12 100 35 100
}

fixture_partial_retry() {
  local root="$1" dir
  dir="$root/retries"
  mkdir -p "$dir"
  printf approved >"$dir/a.result"
  printf malformed >"$dir/b.raw"
  printf approved >"$dir/b.result"
  [ "$(find "$dir" -name '*.result' -type f | wc -l | tr -d ' ')" = "2" ] &&
    [ "$(cat "$dir/a.result")" = "approved" ]
}

# The primary may write a persona artifact directly into the round result dir, so
# the mirror copy becomes self-referential. BSD cp fails ("are identical") on a
# self-copy; the -ef guard must make it a no-op while a real copy still happens.
fixture_persona_inplace_copy() {
  local root="$1" dir="$root/inplace" out dst
  mkdir -p "$dir"
  printf '{}' >"$dir/web-architect.json"
  out="$dir/web-architect.json"
  dst="$dir/web-architect.json"
  { [ "$out" -ef "$dst" ] || cp "$out" "$dst"; } || return 1
  dst="$dir/mirror.json"
  { [ "$out" -ef "$dst" ] || cp "$out" "$dst"; } || return 1
  [ -f "$dir/mirror.json" ]
}

fixture_commit_mapping() {
  local root="$1" file
  file="$root/state-map.json"
  printf '%s\n' '{"base_commit":"aaaaaaa","candidate_commits":["bbbbbbb","ccccccc"]}' >"$file"
  jq -e '.base_commit == "aaaaaaa" and .candidate_commits[-1] == "ccccccc"' "$file" >/dev/null
}

fixture_cleanup_recovery() {
  local root="$1" run
  run="$root/run"
  mkdir -p "$run/raw" "$run/archive"
  printf state >"$run/state.json"
  printf raw >"$run/raw/output"
  compact_success "$run" "fixture" >/dev/null
  [ -f "$run/archive/fixture/state.json" ] && [ ! -e "$run/raw" ]
}

fixture_state_recovery() {
  local root="$1" file
  file="$root/recovery.json"
  printf '%s\n' '{"status":"running","primary":"claude","session_id":"fixed-id","stage":"implementation","primary_turns":4}' >"$file"
  jq -e '.status == "running" and .session_id == "fixed-id" and .primary_turns == 4' "$file" >/dev/null
}

fixture_transitions() {
  local stage=planning
  transition_allowed "$stage" RUN_PERSONAS || return 1
  stage=implementation
  transition_allowed "$stage" RUN_PERSONAS || return 1
  stage=implementation_ready
  transition_allowed "$stage" CREATE_CANDIDATE || return 1
  stage=observer_review
  transition_allowed "$stage" REQUEST_OBSERVER || return 1
  ! transition_allowed planning CREATE_CANDIDATE &&
    ! transition_allowed implementation REQUEST_OBSERVER &&
    ! transition_allowed completion RUN_PERSONAS
}

fixture_adapter_retry() {
  local root="$1" attempts="$root/attempts" output="$root/retry-output.json"
  printf '0\n' >"$attempts"
  validated_retry observer-review "$output" fixture_retry_adapter "$attempts" "$output"
  [ "$(cat "$attempts")" = "2" ] && json_schema_basic observer-review "$output"
}

fixture_validation_identity() {
  local root="$1" baseline="$root/baseline.json" final="$root/final.json"
  printf '%s\n' '[{"command":"typecheck","exit_status":1,"output":"old failure"},{"command":"lint","exit_status":0,"output":"ok"}]' >"$baseline"
  printf '%s\n' '[{"command":"typecheck","exit_status":1,"output":"same failure"},{"command":"tests","exit_status":0,"output":"ok"}]' >"$final"
  validation_not_regressed "$baseline" "$final"
}

fixture_candidate_isolation() {
  local root="$1" repo="$root/repo" worktree="$root/worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  printf 'dirty\n' >"$repo/dirty.txt"
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  [ -f "$worktree/tracked.txt" ] && [ ! -e "$worktree/dirty.txt" ]
}

fixture_worktree_dependencies() {
  local root="$1" repo="$root/deprepo" worktree="$root/depwt" ok saved_project saved_links
  mkdir -p "$repo/node_modules"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  printf 'dep\n' >"$repo/node_modules/marker.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  saved_project="$PROJECT"; saved_links="$DEPENDENCY_LINKS"
  PROJECT="$repo"; DEPENDENCY_LINKS="node_modules"
  link_worktree_dependencies "$worktree"
  PROJECT="$saved_project"; DEPENDENCY_LINKS="$saved_links"
  [ -L "$worktree/node_modules" ] && [ -f "$worktree/node_modules/marker.txt" ]
}

fixture_worktree_dependencies_nested() {
  # A nested dependency dir (web layout, e.g. server/node_modules) is linked into
  # the worktree — the parent dir is created first. Proves the expanded default
  # works for the viewer without a manual NIGHT_SHIFT_DEPENDENCY_LINKS override.
  local root="$1" repo="$root/ndeprepo" worktree="$root/ndepwt" saved_project saved_links
  mkdir -p "$repo/server/node_modules"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  printf 'dep\n' >"$repo/server/node_modules/marker.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  saved_project="$PROJECT"; saved_links="$DEPENDENCY_LINKS"
  PROJECT="$repo"; DEPENDENCY_LINKS="node_modules server/node_modules web/node_modules"
  link_worktree_dependencies "$worktree"
  PROJECT="$saved_project"; DEPENDENCY_LINKS="$saved_links"
  [ -L "$worktree/server/node_modules" ] && [ -f "$worktree/server/node_modules/marker.txt" ]
}

fixture_tmp_base_canonical() {
  local base p1 p2
  base="$(tmp_base)"
  case "$base" in */) return 1 ;; esac        # no trailing slash
  [ -d "$base" ] || return 1                  # resolves to a real dir
  # The cleanup prefix and a stored worktree path derive from the same base, so a
  # stored path always matches the prefix check (the /var vs /private/var bug).
  p1="$base/night-shift-RUN-"
  p2="$base/night-shift-RUN-abc123"
  case "$p2" in "$p1"*) return 0 ;; *) return 1 ;; esac
}

fixture_review_fields_scoped() {
  local root="$1" spec="$root/scoped.md" active
  # A "- Personas:" line OUTSIDE the ## Review section (here under Related) must
  # NOT be read as the explicit-personas field. Without scoping it would be parsed
  # as an off-track explicit override and abort resolution; with scoping the spec
  # resolves to its plain full rn profile.
  fixture_write_min_spec "$spec" '## Related
- Personas: Web Architect'
  active="$(resolve_active_personas "$spec")" || return 1
  [ "$(printf '%s' "$active" | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  printf '%s' "$active" | grep -q "Web Architect" && return 1
  printf '%s' "$active" | grep -q "Mobile UX Designer" || return 1
  return 0
}

fixture_visual_diff_schema() {
  local root="$1" good="$root/vd-good.json" bad="$root/vd-bad.json" badkey="$root/vd-key.json"
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","reference":"design/Home-default.png","screenshot":"shots/Home-default.png","diff_pct":0.05,"tolerance":0.1,"pass":true,"diff_image":null}]}' >"$good"
  json_schema_basic visual-diff "$good" || return 1
  # pass=true but diff_pct > tolerance → inconsistent → rejected.
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","reference":"r","screenshot":"s","diff_pct":0.5,"tolerance":0.1,"pass":true,"diff_image":null}]}' >"$bad"
  json_schema_basic visual-diff "$bad" && return 1
  # missing a per-screen key → rejected.
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","reference":"r","screenshot":"s","diff_pct":0,"tolerance":0.1,"pass":true}]}' >"$badkey"
  json_schema_basic visual-diff "$badkey" && return 1
  return 0
}

fixture_visual_capture_screens() {
  local root="$1" spec="$root/dc.md" out
  printf '%s\n' '## Design Contract' '- Frames: Home, Settings' '- Required states: default, empty' '## Edge Cases' >"$spec"
  out="$(visual_capture_screens "$spec")"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 4 ] || return 1
  printf '%s\n' "$out" | grep -qx 'Home|default' || return 1
  printf '%s\n' "$out" | grep -qx 'Settings|empty' || return 1
  # No Design Contract → no screens.
  printf 'no contract\n' >"$spec"
  [ -z "$(visual_capture_screens "$spec")" ] || return 1
  return 0
}

fixture_visual_assemble_screen() {
  local root="$1" obj
  # Within tolerance → pass derived true; diff_image preserved.
  obj="$(visual_assemble_screen Home default design/h.png shots/h.png 0.05 0.1 diffs/h.png)"
  printf '%s' "$obj" | jq -e '.pass == true and .diff_image == "diffs/h.png"' >/dev/null || return 1
  # Over tolerance → pass derived false; empty diff_image → null.
  obj="$(visual_assemble_screen Home empty r s 0.4 0.1 "")"
  printf '%s' "$obj" | jq -e '.pass == false and .diff_image == null' >/dev/null || return 1
  # The assembled object is a valid screen inside a report.
  printf '{"task":"t","screens":[%s]}\n' "$obj" >"$root/asm.json"
  json_schema_basic visual-diff "$root/asm.json" || return 1
  return 0
}

fixture_visual_capture_skips() {
  local root="$1" out="$root/capout"
  mkdir -p "$out"
  # Inert by default: unavailable → no-op, returns 0, writes no report, never blocks.
  visual_capture_available && return 1
  run_visual_capture "$root/spec.md" abc123 "$out" >/dev/null 2>&1 || return 1
  [ -z "$(find "$out" -name 'visual-diff-*.json' 2>/dev/null)" ] || return 1
  return 0
}

fixture_spec_validation() {
  local root="$1" spec="$root/spec.md"
  cat >"$spec" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
- Native `ios/` changes permitted: no - js only
- Native `android/` changes permitted: no - js only
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: none - n/a
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  # Field names contain '/', which must not break the sed value extraction.
  validate_spec "$spec" 2>/dev/null
}

fixture_spec_validation_web() {
  local root="$1" web="$root/web-spec.md" rn="$root/rn-no-native.md"
  # A web spec with NO native ios/android permission lines must validate.
  cat >"$web" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Track: web
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
## Documentation
- Documentation owned by each review persona:
  - Web UX & Accessibility Designer: ux
  - Web Architect: arch
  - Backend & Data Expert: data
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  validate_spec "$web" 2>/dev/null || return 1
  # An otherwise-complete rn spec that omits the native lines must still fail,
  # so removing them for web did not weaken the rn track.
  cat >"$rn" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Track: rn
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: dom
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  validate_spec "$rn" 2>/dev/null && return 1
  return 0
}

fixture_review_profile() {
  local root="$1" set spec
  # logic profile = floor + Performance Expert (4); no UX Designer.
  set="$(profile_personas logic)" || return 1
  [ "$(printf '%s' "$set" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  printf '%s' "$set" | grep -q "Performance Expert" || return 1
  printf '%s' "$set" | grep -q "Mobile UX Designer" && return 1
  # full keeps all six.
  [ "$(profile_personas full | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  # Unknown profile is rejected.
  profile_personas bogus && return 1
  # Missing field and unknown value both fail resolution.
  spec="$root/np.md"; printf '# no profile here\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  spec="$root/bp.md"; printf -- '- Review Profile: nonsense\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # A valid field resolves to its set.
  spec="$root/gp.md"; printf -- '- Review Profile: native\n' >"$spec"
  resolve_active_personas "$spec" >/dev/null 2>&1 || return 1
  return 0
}

fixture_review_profile_web() {
  local root="$1" set spec
  # web `data` profile = floor + Backend & Data Expert (4); web Architect floor.
  set="$(profile_personas data web)" || return 1
  [ "$(printf '%s' "$set" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  printf '%s' "$set" | grep -q "Backend & Data Expert" || return 1
  printf '%s' "$set" | grep -q "Web Architect" || return 1
  # web `full` keeps all six web personas, including the web designer.
  [ "$(profile_personas full web | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  profile_personas full web | grep -q "Web UX & Accessibility Designer" || return 1
  # Track-specific profiles do not cross tracks: native is rn-only, data web-only.
  profile_personas native web && return 1
  profile_personas data rn && return 1
  # A spec declaring Track: web resolves to the web set (4 for data).
  spec="$root/web.md"; printf -- '- Track: web\n- Review Profile: data\n' >"$spec"
  [ "$(resolve_active_personas "$spec" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  # An unknown track is rejected.
  spec="$root/badtrack.md"; printf -- '- Track: ios\n- Review Profile: full\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # A missing Track field defaults to rn, so the rn-only native profile resolves.
  spec="$root/notrack.md"; printf -- '- Review Profile: native\n' >"$spec"
  resolve_active_personas "$spec" >/dev/null 2>&1 || return 1
  return 0
}

fixture_profile_gate() {
  local root="$1" dir="$root/profile-gate" set persona i=0 old_ifs
  mkdir -p "$dir"
  set="$(profile_personas logic)" || return 1
  old_ifs="$IFS"; IFS='|'
  for persona in $set; do
    IFS="$old_ifs"; i=$((i + 1))
    printf '{"persona":"%s","stage":"implementation","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}\n' \
      "$persona" >"$dir/$i.json"
    IFS='|'
  done
  IFS="$old_ifs"
  # Exact active set passes the gate's coverage check.
  jq -s -e --arg personas "$set" \
    '($personas|split("|")|sort) as $e | (map(.persona)|sort)==$e' "$dir"/*.json >/dev/null || return 1
  # A result from a non-active persona breaks the coverage check.
  printf '{"persona":"Mobile UX Designer","stage":"implementation","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}\n' \
    >"$dir/extra.json"
  jq -s -e --arg personas "$set" \
    '($personas|split("|")|sort) as $e | (map(.persona)|sort)==$e' "$dir"/*.json >/dev/null && return 1
  return 0
}

# Writes a minimal valid rn `full` spec to $1, optionally appending extra body
# ($2). Mirrors fixture_spec_validation's shape so the optional-persona fixtures
# reuse the same proven baseline (Track defaults to rn, full = the six rn
# personas with doc-owner lines for the whole floor + set).
fixture_write_min_spec() {
  local spec="$1" extra="${2:-}"
  cat >"$spec" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Permissions
- New dependencies permitted: no - none
- Native `ios/` changes permitted: no - js only
- Native `android/` changes permitted: no - js only
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: dom
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
## Review
- Review Profile: full
SPEC
  # `## Review` is intentionally last so an appended extra (a field line like
  # `- Optional reviewers:` / `- Personas:` / `- Track:`) lands INSIDE the Review
  # section, where spec_field_scope reads it. An appended `## …` contract heading
  # ends the Review section and is found by the whole-file section scan.
  [ -z "$extra" ] || printf '%s\n' "$extra" >>"$spec"
}

fixture_optional_persona_field() {
  local root="$1" spec="$root/opt-field.md" active
  # Opting in via the field unions Product Reviewer into the active set; the full
  # floor (and the rest of the profile set) stays present.
  fixture_write_min_spec "$spec" '- Optional reviewers: Product Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Product Reviewer" || return 1
  case "|$active|" in *"|React Native Architect|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|TypeScript & Code Quality Expert|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Human Advocate|"*) ;; *) return 1 ;; esac
  # Design Fidelity is not opted in, so it must NOT appear.
  printf '%s' "$active" | grep -q "Design Fidelity Reviewer" && return 1
  return 0
}

fixture_optional_persona_multi() {
  local root="$1" spec="$root/opt-multi.md" active
  # A comma-separated list opts in MORE THAN ONE optional reviewer in one field;
  # every named reviewer must union in (single-value was the only prior coverage).
  fixture_write_min_spec "$spec" '- Optional reviewers: Security Reviewer, API Contract Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  printf '%s' "$active" | grep -q "API Contract Reviewer" || return 1
  return 0
}

fixture_optional_persona_section() {
  local root="$1" spec="$root/opt-section.md" active
  # A `## Design Contract` heading auto-activates Design Fidelity Reviewer even
  # with no Optional reviewers field.
  fixture_write_min_spec "$spec" '## Design Contract
- Figma file: example'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Design Fidelity Reviewer" || return 1
  printf '%s' "$active" | grep -q "Product Reviewer" && return 1
  return 0
}

fixture_optional_persona_unknown() {
  local root="$1" spec="$root/opt-unknown.md" out
  # An entry that is not a member of PERSONAS_OPTIONAL must fail resolution
  # AND validate_spec must surface the specific reason (not a generic hint).
  fixture_write_min_spec "$spec" '- Optional reviewers: Bogus Persona'
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # Capture to a var: piping validate_spec into grep would, under pipefail,
  # report validate_spec's non-zero exit instead of grep's match result.
  out="$(validate_spec "$spec" 2>&1)" || true
  case "$out" in
    *"unknown optional reviewer: Bogus Persona"*) return 0 ;;
    *) return 1 ;;
  esac
}

fixture_optional_persona_none() {
  local root="$1" spec="$root/opt-none.md" active plain
  # No field and no contract section: the active set must equal the plain profile
  # set exactly, proving optional personas add nothing by default.
  fixture_write_min_spec "$spec"
  active="$(resolve_active_personas "$spec")" || return 1
  plain="$(profile_personas full rn)" || return 1
  [ "$active" = "$plain" ] || return 1
  return 0
}

fixture_optional_persona_schema() {
  local root="$1" prod="$root/persona-prod.json" design="$root/persona-design.json"
  local sec="$root/persona-sec.json" api="$root/persona-api.json"
  # The persona-review membership check must ACCEPT every optional persona.
  printf '%s\n' '{"persona":"Product Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$prod"
  json_schema_basic persona-review "$prod" || return 1
  printf '%s\n' '{"persona":"Design Fidelity Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$design"
  json_schema_basic persona-review "$design" || return 1
  printf '%s\n' '{"persona":"Security Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$sec"
  json_schema_basic persona-review "$sec" || return 1
  printf '%s\n' '{"persona":"API Contract Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$api"
  json_schema_basic persona-review "$api" || return 1
  return 0
}

fixture_optional_persona_added_field() {
  local root="$1" spec="$root/opt-sec-field.md" active
  # A newly added optional persona (Security Reviewer) unions in via the field,
  # proving the optional roster is data-driven, not hardcoded to the first two.
  fixture_write_min_spec "$spec" '- Optional reviewers: Security Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  return 0
}

fixture_optional_persona_added_section() {
  local root="$1" spec="$root/opt-api-section.md" active
  # An `## API Contract` heading auto-activates the API Contract Reviewer with no
  # Optional reviewers field — section activation is driven by PERSONAS_OPTIONAL +
  # optional_contract_heading, so new personas work without touching the loop.
  fixture_write_min_spec "$spec" '## API Contract
- Endpoint: GET /thing'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "API Contract Reviewer" || return 1
  return 0
}

fixture_explicit_personas_override() {
  local root="$1" spec="$root/explicit.md" active count
  # An explicit `- Personas:` list overrides the profile: the active set is the
  # floor plus exactly the named specialists, and unnamed profile personas drop.
  fixture_write_min_spec "$spec" '- Personas: Performance Expert'
  active="$(resolve_active_personas "$spec")" || return 1
  # Floor is always present even though only Performance Expert was named.
  case "|$active|" in *"|React Native Architect|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|TypeScript & Code Quality Expert|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Human Advocate|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Performance Expert|"*) ;; *) return 1 ;; esac
  # Mobile UX Designer is in the `full` profile but was NOT named, so it drops.
  printf '%s' "$active" | grep -q "Mobile UX Designer" && return 1
  # floor (3) + Performance Expert = 4 active personas, no profile bloat.
  count="$(printf '%s' "$active" | tr '|' '\n' | grep -c .)"
  [ "$count" -eq 4 ] || return 1
  return 0
}

fixture_explicit_personas_with_optional() {
  local root="$1" spec="$root/explicit-opt.md" active
  # An explicit list may name an optional persona directly (no contract section
  # needed); it resolves like any other member of the universe.
  fixture_write_min_spec "$spec" '- Personas: Performance Expert, Security Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  printf '%s' "$active" | grep -q "Performance Expert" || return 1
  return 0
}

fixture_explicit_personas_unknown() {
  local root="$1" spec="$root/explicit-bad.md" out
  # A name outside the track set ∪ PERSONAS_OPTIONAL (here a web persona on the
  # default rn track) is rejected, and validate_spec surfaces the specific reason.
  fixture_write_min_spec "$spec" '- Personas: Web Architect'
  resolve_active_personas "$spec" 2>/dev/null && return 1
  out="$(validate_spec "$spec" 2>&1)" || true
  case "$out" in
    *"unknown persona in Personas field: Web Architect"*) return 0 ;;
    *) return 1 ;;
  esac
}

fixture_rate_limit_recognition() {
  local root="$1" good="$root/rate-good.json" bad="$root/rate-bad.json"
  printf '%s\n' '{"api_error_status":429,"result":"You have hit your session limit - resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$good"
  printf '%s\n' '{"api_error_status":500,"result":"resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$bad"
  is_rate_limit_response "$good" && ! is_rate_limit_response "$bad"
}

fixture_rate_limit_epoch() {
  local root="$1" raw="$root/rate-epoch.json"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  [ "$(rate_limit_reset_epoch "$raw" 0)" = "60" ]
}

fixture_rate_limit_rebase() {
  local root="$1" state="$root/rebase-state.json" raw="$root/rebase-raw.json" now
  local saved_state="${STATE:-}" saved_root="${RUN_ROOT:-}" saved_buffer="$RATE_LIMIT_BUFFER_SECONDS"
  # Simulate recovery long after a limit: stale started_at (epoch 1) plus the
  # active elapsed captured at pause time (30s stage, 45s task).
  printf '%s\n' '{"status":"waiting","stage":"planning","stage_started_at":1,"task_started_at":1,"stage_started":{"planning":1},"session_id":"fixed-id","rate_limit_stage_elapsed":30,"rate_limit_task_elapsed":45}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  # Negative buffer forces the reset deadline into the past so no real sleep runs.
  STATE="$state"; RUN_ROOT="$root"; RATE_LIMIT_BUFFER_SECONDS=-100000
  wait_for_rate_limit_reset "$raw" >/dev/null 2>&1
  STATE="$saved_state"; RUN_ROOT="$saved_root"; RATE_LIMIT_BUFFER_SECONDS="$saved_buffer"
  now="$(date +%s)"
  # started_at must be rebased to ~now-minus-active-elapsed (downtime excluded).
  jq -e --argjson now "$now" '
    (($now - .stage_started_at) as $se | $se >= 28 and $se <= 45) and
    (($now - .task_started_at) as $te | $te >= 43 and $te <= 60) and
    .status == "running" and (has("rate_limit_stage_elapsed") | not)
  ' "$state" >/dev/null
}

fixture_rate_limit_recovery() {
  local root="$1" state="$root/rate-recovery-state.json" raw="$root/rate-recovery-raw.json"
  printf '%s\n' '{"status":"blocked","session_id":"fixed-id","block_reason":"primary command failed with status 1"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$raw"
  recoverable_rate_limit_state "$state" "$raw"
}

fixture_rate_limit_cap() {
  local root="$1" state="$root/cap-state.json" raw="$root/cap-raw.json" rc=0
  local saved_state="${STATE:-}" saved_root="${RUN_ROOT:-}" saved_cap="$RATE_LIMIT_MAX_WAIT_SECONDS"
  printf '%s\n' '{"status":"running","stage":"planning","stage_started_at":0,"task_started_at":0,"stage_started":{"planning":0},"session_id":"fixed-id"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  # Force the cap below any possible wait so the guard must trigger block_run.
  STATE="$state"; RUN_ROOT="$root"; RATE_LIMIT_MAX_WAIT_SECONDS=-1
  (wait_for_rate_limit_reset "$raw") >/dev/null 2>&1 || rc=$?
  STATE="$saved_state"; RUN_ROOT="$saved_root"; RATE_LIMIT_MAX_WAIT_SECONDS="$saved_cap"
  [ "$rc" -ne 0 ]
}

fixture_candidate_order() {
  local root="$1" f="$root/cand.json"
  # Latest candidate sorts lexicographically BEFORE the previous one.
  printf '%s\n' '{"candidate_commits":["ffff111"],"candidate":"ffff111"}' >"$f"
  jq '.candidate_commits = ((.candidate_commits + ["0000aaa"])
        | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) | .candidate="0000aaa"' \
    "$f" > "$f.t" && mv "$f.t" "$f"
  # .candidate is the real latest, and [-1] keeps insertion order (not sorted).
  [ "$(jq -r '.candidate' "$f")" = "0000aaa" ] &&
    [ "$(jq -r '.candidate_commits[-1]' "$f")" = "0000aaa" ] &&
    [ "$(jq -r '.candidate_commits[0]' "$f")" = "ffff111" ]
}

fixture_stage_fresh_start() {
  local root="$1" state="$root/stage.json" saved="${STATE:-}" now
  # An ancient recorded start for the stage we are about to (re-)enter.
  printf '%s\n' '{"stage":"implementation","stage_turns":5,"stage_started_at":100,"stage_counters":{"implementation":5},"stage_started":{"implementation":100,"implementation_ready":200},"updated_at":"x"}' >"$state"
  STATE="$state"
  set_stage implementation_ready
  STATE="$saved"
  now="$(date +%s)"
  # Must use NOW, not the ancient 200, and carry over the stage's turn count.
  jq -e --argjson now "$now" '
    .stage == "implementation_ready" and
    (($now - .stage_started_at) >= 0 and ($now - .stage_started_at) < 30) and
    .stage_started_at > 1000
  ' "$state" >/dev/null
}

fixture_observer_normalization() {
  local root="$1" in="$root/obs-norm.json" ok=1
  # The exact non-conforming shape that wedged the real run.
  printf '%s\n' '{"status":"REQUEST_CHANGES","base_commit":"x","summary":"missing changelog","observer":"claude","primary":"claude","task":"t","candidate_commit":"c","findings":[{"id":"OBS-1","severity":"high","location":"CHANGELOG.md","required_change":"add changelog","evidence":"spec line 105"}],"documentation_changes":[]}' >"$in"
  normalize_observer_output "$in" "specs/toggle-todo.md" "ba0b987bc2d559df865cac09562044fd337c17c9"
  json_schema_basic observer-review "$in" &&
    [ "$(jq -r '.status' "$in")" = "BLOCK" ] &&
    [ "$(jq -r '.findings[0].id' "$in")" = "OBS-001" ] &&
    [ "$(jq -r '.task' "$in")" = "specs/toggle-todo.md" ] &&
    [ "$(jq -r '.candidate_commit' "$in")" = "ba0b987bc2d559df865cac09562044fd337c17c9" ] || ok=0
  # APPROVE synonym drops findings and validates.
  printf '%s\n' '{"status":"APPROVED","findings":[{"id":"OBS-2","evidence":"e","required_change":"r"}]}' >"$in"
  normalize_observer_output "$in" "specs/x.md" "abcdef1234567"
  json_schema_basic observer-review "$in" &&
    [ "$(jq -r '.status' "$in")" = "APPROVE" ] &&
    [ "$(jq -r '.findings|length' "$in")" = "0" ] || ok=0
  [ "$ok" -eq 1 ]
}

fixture_observer_extraction() {
  local root="$1" raw="$root/ex-raw.json" out="$root/ex-out.json" ok=1
  # (1) whole result is JSON
  jq -n '{result:"{\"status\":\"APPROVE\",\"findings\":[]}"}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.status' "$out")" = "APPROVE" ] || ok=0
  # (2) prose then a fenced ```json verdict block
  printf '%s' 'Here is my review. Looks fine overall.

```json
{"status":"BLOCK","findings":[{"id":"OBS-001"}]}
```' | jq -Rs '{result:.}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.findings[0].id' "$out")" = "OBS-001" ] || ok=0
  # (3) JSON object embedded in prose, no fence
  printf '%s' 'Verdict: {"status":"APPROVE","findings":[]} done.' | jq -Rs '{result:.}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.status' "$out")" = "APPROVE" ] || ok=0
  [ "$ok" -eq 1 ]
}

fixture_missing_tools() {
  local root="$1" ok="$root/tools-ok.json" bad="$root/tools-bad.json"
  printf '%s\n' '[{"command":"npx tsc","exit_status":0,"output":"ok"}]' >"$ok"
  printf '%s\n' '[{"command":"npx tsc","exit_status":127,"output":"not found"}]' >"$bad"
  tools_available "$ok" && ! tools_available "$bad"
}

fixture_finding_stall() {
  local root="$1" h="$root/stall.json"
  rm -f "$h"
  [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"a"}]')" = "1" ] &&
    [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"a"}]')" = "2" ] &&
    [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"b"}]')" = "1" ]
}

fixture_retry_adapter() {
  local attempts="$1" output="$2" count
  count="$(cat "$attempts")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$attempts"
  if [ "$count" -eq 1 ]; then
    printf '%s\n' '{"bad":true}' >"$output"
  else
    printf '%s\n' '{"observer":"claude","primary":"claude","task":"specs/a.md","candidate_commit":"abcdef1","status":"APPROVE","findings":[],"documentation_changes":[]}' >"$output"
  fi
}

validated_retry() {
  local kind="$1" output="$2" callback="$3"
  shift 3
  local attempt=0
  while [ "$attempt" -lt 2 ]; do
    "$callback" "$@" || true
    json_schema_basic "$kind" "$output" && return 0
    attempt=$((attempt + 1))
  done
  return 1
}

select_task_from_todo() {
  local todo="$1" result
  [ -f "$todo" ] || return 1
  result="$(sed -nE 's/^- \[ \] bug:.*\(`([^`]+)`\).*/\1/p' "$todo" | head -n 1)"
  if [ -z "$result" ]; then
    result="$(sed -nE 's/^- \[ \] feature:.*\(`([^`]+)`\).*/\1/p' "$todo" | head -n 1)"
  fi
  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

limit_exceeded() {
  local stage_turns="$1" stage_elapsed="$2" task_turns="$3" task_elapsed="$4"
  [ "$stage_turns" -ge "$MAX_STAGE_TURNS" ] ||
    [ "$stage_elapsed" -ge "$MAX_STAGE_SECONDS" ] ||
    [ "$task_turns" -ge "$MAX_TASK_TURNS" ] ||
    [ "$task_elapsed" -ge "$MAX_TASK_SECONDS" ]
}

# A command that exits 127 was not found; missing tooling must never look like a
# passing or merely-unchanged validation. bash -lc may not inherit the nvm PATH
# from the interactive zsh profile during a headless overnight launch.
tools_available() {
  jq -e 'all(.[]; .exit_status != 127)' "$1" >/dev/null 2>&1
}

# A fingerprint of the work under review (full diff vs base). When real code or
# tests change, this changes and resets the stall counter, so legitimate
# resolution attempts are not falsely blocked as "unchanged". Empty during the
# plan stage, where no code exists yet.
material_token() {
  git -C "$PROJECT" diff "$BASE_COMMIT" 2>/dev/null | cksum | awk '{print $1 ":" $2}'
}

# The isolated validation worktree has none of the ignored dependency dirs.
# Symlink them from the project so type-check/lint/test run without reinstalling.
link_worktree_dependencies() {
  local worktree="$1" rel src dst
  for rel in $DEPENDENCY_LINKS; do
    src="$PROJECT/$rel"
    dst="$worktree/$rel"
    [ -e "$src" ] || continue
    [ -e "$dst" ] && continue
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst" ||
      block_run "could not link dependency $rel into validation worktree"
  done
}

assert_tools_available() {
  tools_available "$1" ||
    block_run "$2 validation could not find a required tool (exit 127); fix PATH/toolchain before running"
}

# Tracks how many consecutive rounds a finding ID recurs with the same
# fingerprint. Cosmetic-only rounds keep the same fingerprint and accumulate;
# a materially changed fingerprint resets the count to 1. Echoes the max count.
bump_finding_history() {
  local history="$1" findings="$2" tmp
  [ -f "$history" ] || printf '{}\n' >"$history"
  tmp="$history.tmp.$$"
  jq --argjson findings "$findings" '
    reduce $findings[] as $f (.;
      .[$f.id] = (if .[$f.id].fingerprint == $f.fp
        then {fingerprint:$f.fp, count:(.[$f.id].count + 1)}
        else {fingerprint:$f.fp, count:1} end))
  ' "$history" >"$tmp" && mv "$tmp" "$history" || die "failed to update finding history"
  jq -r '[to_entries[].value.count] | max // 0' "$history"
}

compact_success() {
  local run_dir="$1" run_id="$2" archive
  archive="$run_dir/archive/$run_id"
  mkdir -p "$archive"
  [ -f "$run_dir/state.json" ] && cp "$run_dir/state.json" "$archive/state.json"
  [ -d "$run_dir/validated" ] && cp -R "$run_dir/validated" "$archive/validated"
  [ -f "$run_dir/summary.json" ] && cp "$run_dir/summary.json" "$archive/summary.json"
  for entry in "$run_dir"/* "$run_dir"/.[!.]* "$run_dir"/..?*; do
    [ -e "$entry" ] || continue
    [ "$entry" = "$run_dir/archive" ] || rm -rf "$entry"
  done
}

run_live_fixtures() {
  [ "${NIGHT_SHIFT_ACCEPT_COSTS:-}" = "YES" ] ||
    die "live fixture tests make paid model calls; set NIGHT_SHIFT_ACCEPT_COSTS=YES"
  require_command claude
  log "running minimal paid Claude startup, session-ID, resume, unattended-tool, and observer checks"
  log "(each live check is silent on success and only prints on failure)"
  log "1/3 startup + session-id + resume..."
  live_adapter_check claude
  log "2/3 unattended tool use (bypassPermissions)..."
  live_primary_tool_check
  log "3/3 observer (neutral cwd, no tools, schema)..."
  live_observer_check
  if [ "$FULL_PERSONA_LIVE_TEST" -eq 1 ]; then
    log "cost warning accepted: running six live persona calls"
    live_persona_checks
  fi
  log "all live checks passed — the workflow can run unattended"
}

# Proves the primary can actually edit files / run tools UNATTENDED with the same
# permission posture the run uses. Without this the overnight primary would be
# unable to act and the run would stall — the gap a session-only smoke test hides.
live_primary_tool_check() {
  local root marker
  root="$WORKSPACE_ROOT/.night-shift-live-primary.$$"
  marker="$root/proof.txt"
  mkdir -p "$root"
  (cd "$root" && claude -p --permission-mode bypassPermissions --output-format json \
    'Create a file named proof.txt in the current directory containing exactly the word OK. Use your tools. Then reply done.') \
    >"$root/out.json" 2>&1 ||
    die "primary unattended tool call failed; state preserved at $root"
  [ -f "$marker" ] && grep -q OK "$marker" ||
    die "primary could not write a file unattended (permission posture is wrong); state preserved at $root"
  rm -rf "$root"
}

# Exercises the real observer invocation: neutral CWD, JSON result-text
# extraction, and schema validation the run depends on. This is the part most
# likely to differ across Claude CLI versions, so prove it before a run.
live_observer_check() {
  local root neutral raw out
  root="$WORKSPACE_ROOT/.night-shift-live-observer.$$"
  neutral="$root/cwd"
  mkdir -p "$neutral"
  raw="$root/observer.raw"
  out="$root/observer.json"
  (cd "$neutral" && claude -p --output-format json \
    'End your reply with exactly one fenced code block tagged json and nothing after it, containing: {"observer":"claude","primary":"claude","task":"specs/smoke.md","candidate_commit":"abcdef1","status":"APPROVE","findings":[],"documentation_changes":[]}') >"$raw" 2>"${raw}.err" ||
    die "observer call failed; state preserved at $root"
  extract_claude_structured "$raw" "$out" ||
    die "could not parse observer JSON from .result; state preserved at $root"
  json_schema_basic observer-review "$out" ||
    die "observer output did not match observer-review.json; state preserved at $root"
  rm -rf "$root"
}

live_adapter_check() {
  local adapter="$1" root output session
  root="$WORKSPACE_ROOT/.night-shift-live-$adapter.$$"
  mkdir -p "$root"
  output="$root/start.raw"
  claude -p --output-format json \
    'Return exactly the word READY. Do not use tools.' >"$output" ||
    die "Claude live startup failed; state preserved at $root"
  session="$(jq -r '.session_id // empty' "$output")"
  [ -n "$session" ] || die "Claude emitted no session ID; state preserved at $root"
  claude -p --resume "$session" --output-format json \
    'Return exactly the word RESUMED. Do not use tools.' >"$root/resume.raw" ||
    die "Claude explicit resume failed; state preserved at $root"
  [ "$(jq -r '.session_id // empty' "$root/resume.raw")" = "$session" ] ||
    die "Claude session ID changed on resume; state preserved at $root"
  rm -rf "$root"
}

live_persona_checks() {
  local persona slug
  old_ifs="$IFS"; IFS='|'
  for persona in $PERSONAS; do
    IFS="$old_ifs"
    slug="$(printf '%s' "$persona" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
    log "live persona smoke check: $slug"
    claude -p --output-format json "As $persona, return APPROVE and no findings for an empty diff." >/dev/null
    IFS='|'
  done
  IFS="$old_ifs"
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

canonical_file() {
  local dir base
  dir="$(dirname "$1")"; base="$(basename "$1")"
  [ -f "$1" ] || return 1
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

# Canonical temp base directory. On macOS $TMPDIR is /var/folders/.../T/ (a
# symlink with a trailing slash), but `git worktree list` reports the resolved
# /private/var/... form, so a stored path built from raw $TMPDIR never
# string-matches git's. Resolve it once (pwd -P strips the symlink, trailing and
# double slashes) so stored worktree paths and the cleanup prefix match git.
tmp_base() {
  (cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || printf '%s' "${TMPDIR:-/tmp}"
}

validate_spec() {
  local file="$1" missing="" field value persona active track reason
  track="$(spec_track "$file")"
  for field in \
    "## Repository" \
    "Project path:" \
    "Base branch:" \
    "Feature branch:" \
    "## Permissions" \
    "New dependencies permitted:" \
    "## Documentation" \
    "Documentation owned by each review persona:" \
    "## Test Plan" \
    "First failing test or executable check:" \
    "Baseline validation commands" \
    "Final validation commands"; do
    grep -Fq "$field" "$file" || missing="${missing}\n- $field"
  done
  for field in "Project path" "Base branch" "Feature branch" \
    "New dependencies permitted" "First failing test or executable check"; do
    value="$(sed -nE "s#^- ${field}: ?(.*)#\\1#p" "$file" | head -n 1)"
    case "$value" in ""|*"[project-name]"*|*"[name]"*|*"..."*) missing="${missing}\n- invalid value for $field" ;; esac
  done
  # "New dependencies permitted" carries yes/no + details on every track.
  value="$(sed -nE 's#^- New dependencies permitted: ?(.*)#\1#p' "$file" | head -n 1)"
  printf '%s\n' "$value" | grep -Eq '^(yes|no) - .+' ||
    missing="${missing}\n- New dependencies permitted requires yes/no plus details"
  # Native ios/android permissions are required only on the rn track. Web specs
  # have no native directories, so those lines are neither required nor checked.
  if [ "$track" = "rn" ]; then
    for field in 'Native `ios/` changes permitted' 'Native `android/` changes permitted'; do
      grep -Fq "$field:" "$file" || { missing="${missing}\n- $field:"; continue; }
      value="$(sed -nE "s#^- ${field}: ?(.*)#\\1#p" "$file" | head -n 1)"
      case "$value" in ""|*"[project-name]"*|*"[name]"*|*"..."*) missing="${missing}\n- invalid value for $field"; continue ;; esac
      printf '%s\n' "$value" | grep -Eq '^(yes|no) - .+' ||
        missing="${missing}\n- $field requires yes/no plus details"
    done
  fi
  # Documentation ownership is required only for personas active in the spec's
  # review profile; others may be omitted or marked "none — not in profile".
  active="$(resolve_active_personas "$file" 2>/dev/null)"
  if [ -z "$active" ]; then
    # Recompute capturing stderr so the specific reason surfaces in the
    # migration block (e.g. an unknown optional reviewer), not just a generic
    # profile/track hint.
    reason="$(resolve_active_personas "$file" 2>&1 >/dev/null)"
    case "$reason" in
      *"unknown optional reviewer:"*|*"unknown persona in Personas field:"*)
        missing="${missing}\n- ${reason}" ;;
      *)
        track="$(spec_track "$file")"
        if persona_set "$track" >/dev/null 2>&1; then
          missing="${missing}\n- valid Review Profile for track ${track} (one of: $(valid_profiles_for_track "$track"))"
        else
          missing="${missing}\n- valid Track (one of: rn, web)"
        fi ;;
    esac
  else
    old_ifs="$IFS"; IFS='|'
    for persona in $active; do
      IFS="$old_ifs"
      grep -Eq "^[[:space:]]+- ${persona}: .+" "$file" ||
        missing="${missing}\n- documentation owner: $persona"
      IFS='|'
    done
    IFS="$old_ifs"
  fi
  if [ -n "$missing" ]; then
    printf 'Selected spec is incomplete. Missing required fields:%b\n' "$missing" >&2
    printf 'Migration: copy these sections from %s/specs/_template.md and provide explicit values.\n' "$WORKSPACE_ROOT" >&2
    return 1
  fi
}

check_branch_and_worktree() {
  local spec="$1" feature base current conflicts
  base="$(sed -nE 's/^- Base branch: `([^`]+)`.*/\1/p' "$spec" | head -n 1)"
  feature="$(sed -nE 's/^- Feature branch: `([^`]+)`.*/\1/p' "$spec" | head -n 1)"
  current="$(git -C "$PROJECT" branch --show-current)"
  [ -n "$current" ] || return 1
  [ "$current" != "$base" ] || return 1
  [ "$current" = "$feature" ] || return 1
  conflicts="$(git -C "$PROJECT" worktree list --porcelain | awk -v project="$PROJECT" -v branch="refs/heads/$feature" '
    /^worktree / { path=substr($0,10) }
    /^branch / { if (substr($0,8) == branch && path != project) print path }
  ')"
  [ -z "$conflicts" ]
}

extract_validation_commands() {
  local file="$1" heading="$2"
  awk -v heading="$heading" '
    index($0, heading) { active=1; next }
    active && /^- [A-Z]/ { exit }
    active && /^## / { exit }
    active && $0 ~ /^[[:space:]]+[0-9]+\. `/ && match($0, /`[^`]+`/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
    }
  ' "$file"
}

run_test_command() {
  local phase="$1" command="$2" target="$3" run_dir="${4:-$PROJECT}" output rc=0
  output="$RUN_ROOT/raw/test-first-$phase.log"
  (cd "$run_dir" && bash -lc "$command") >"$output" 2>&1 || rc=$?
  jq -n --arg command "$command" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$output")" \
    '{command:$command,exit_status:$exit_status,output:$output}' >"$target"
}

run_validation_commands() {
  local kind="$1" target="$2" commands="$3" run_dir="${4:-$PROJECT}" command output rc first=1 tmp
  tmp="$target.tmp.$$"
  printf '[\n' >"$tmp"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    output="$RUN_ROOT/raw/validation-$kind-$(printf '%s' "$command" | cksum | awk '{print $1}').log"
    rc=0
    (cd "$run_dir" && bash -lc "$command") >"$output" 2>&1 || rc=$?
    [ "$first" -eq 1 ] || printf ',\n' >>"$tmp"
    jq -n --arg command "$command" --argjson exit_status "$rc" \
      --arg output "$(tail -c 20000 "$output")" \
      '{command:$command,exit_status:$exit_status,output:$output}' >>"$tmp"
    first=0
  done <<EOF
$commands
EOF
  printf '\n]\n' >>"$tmp"
  [ "$first" -eq 0 ] || return 1
  mv "$tmp" "$target"
}

validation_not_regressed() {
  local baseline="$1" final="$2"
  jq -e --slurpfile baseline "$baseline" '
    all(.[];
      . as $final |
      ($baseline[0] | map(select(.command == $final.command)) | first) as $base |
      if $base == null then $final.exit_status == 0
      else ($final.exit_status == 0 or
        ($base.exit_status > 0 and $final.exit_status == $base.exit_status))
      end)
  ' "$final" >/dev/null
}

validate_spec_project() {
  local file="$1" declared
  declared="$(sed -nE 's/^- Project path: `([^`]+)`.*/\1/p' "$file" | head -n 1)"
  case "$declared" in
    "~/"*) declared="$HOME/${declared#\~/}" ;;
    /*) ;;
    *) declared="$WORKSPACE_ROOT/$declared" ;;
  esac
  declared="$(canonical_dir "$declared")" || return 1
  [ "$declared" = "$PROJECT" ]
}

resolve_artifact() {
  local rel="$1" resolved
  case "$rel" in /*|*"../"*|../*|*/..) return 1 ;; esac
  [ -f "$PROJECT/$rel" ] || return 1
  resolved="$(canonical_file "$PROJECT/$rel")" || return 1
  case "$resolved" in "$PROJECT"/*) printf '%s\n' "$resolved" ;; *) return 1 ;; esac
}

state_set() {
  local filter="$1"
  shift
  local tmp="$STATE.tmp.$$"
  jq "$@" "$filter" "$STATE" >"$tmp" && mv "$tmp" "$STATE" ||
    die "failed to update run state; preserved at ${RUN_ROOT:-unknown}"
}

initialize_run() {
  RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  RUN_ROOT="$PROJECT/.night-shift"
  STATE="$RUN_ROOT/state.json"
  mkdir -p "$RUN_ROOT/control" "$RUN_ROOT/raw" "$RUN_ROOT/prompts" \
    "$RUN_ROOT/validated" "$RUN_ROOT/archive"
  BASE_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
  BASE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
  BASE_STATUS="$RUN_ROOT/baseline-status.txt"
  git -C "$PROJECT" status --porcelain=v1 >"$BASE_STATUS"
  git -C "$PROJECT" worktree list --porcelain >"$RUN_ROOT/worktrees.txt"
  write_json_atomic "$STATE" '{
      run_id:$run_id,status:"running",primary:$primary,observer:$observer,
      session_id:null,task:$task,stage:"planning",stage_turns:0,
      primary_turns:0,task_turns:0,stage_started_at:$epoch,
      task_started_at:$epoch,started_at:$iso,updated_at:$iso,
      review_round:0,finding_ids:[],candidate_commits:[],
      base_commit:$base,base_branch:$branch,baseline_status:$baseline_status,
      plan_approved:false,implementation_approved:false,
      candidate_verified:false,baseline_complete:false,
      stage_counters:{planning:0},stage_started:{planning:$epoch}
    }' \
    --arg run_id "$RUN_ID" --arg primary "$PRIMARY" --arg observer "$OBSERVER" \
    --arg task "$SPEC" --argjson epoch "$(now_epoch)" --arg iso "$(now_iso)" \
    --arg base "$BASE_COMMIT" --arg branch "$BASE_BRANCH" \
    --arg baseline_status "$BASE_STATUS" ||
    die "could not initialize run state"
  baseline_commands="$(extract_validation_commands "$SPEC" "Baseline validation commands")"
  run_validation_commands baseline "$RUN_ROOT/validated/baseline.json" "$baseline_commands" ||
    block_run "baseline validation commands are missing or could not run"
  assert_tools_available "$RUN_ROOT/validated/baseline.json" "baseline"
  test_command="$(sed -nE 's/^- First failing test or executable check: `([^`]+)`.*/\1/p' "$SPEC" | head -n 1)"
  [ -n "$test_command" ] || block_run "test-first command is missing"
  run_test_command failing "$test_command" "$RUN_ROOT/validated/test-first-failing.json"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")" -ne 127 ] ||
    block_run "test-first command was not found (exit 127); fix the toolchain before running"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")" -ne 0 ] ||
    block_run "test-first command did not fail before implementation"
  state_set '.baseline_complete=true'
}

recover_run() {
  local status recovery_raw
  RUN_ROOT="$PROJECT/.night-shift"
  STATE="$RUN_ROOT/state.json"
  [ -f "$STATE" ] || return 1
  status="$(jq -r '.status' "$STATE")"
  recovery_raw="$RUN_ROOT/raw/primary-$(( $(jq -r '.primary_turns' "$STATE") + 1 )).json"
  if [ "$status" != "running" ]; then
    recoverable_rate_limit_state "$STATE" "$recovery_raw" || return 1
  fi
  [ "$(jq -r '.primary' "$STATE")" = "$PRIMARY" ] ||
    die "existing run belongs to primary $(jq -r '.primary' "$STATE")"
  RUN_ID="$(jq -r '.run_id' "$STATE")"
  SPEC="$(jq -r '.task' "$STATE")"
  OBSERVER="$(jq -r '.observer' "$STATE")"
  BASE_COMMIT="$(jq -r '.base_commit' "$STATE")"
  BASE_BRANCH="$(jq -r '.base_branch' "$STATE")"
  BASE_STATUS="$(jq -r '.baseline_status // empty' "$STATE")"
  [ -f "$BASE_STATUS" ] || die "recorded baseline status is missing: $BASE_STATUS"
  cleanup_validation_worktree ||
    die "could not clean the interrupted candidate validation worktree"
  log "recovering run $RUN_ID at stage $(jq -r '.stage' "$STATE") with explicit session $(jq -r '.session_id' "$STATE")"
  if [ "$status" != "running" ]; then
    wait_for_rate_limit_reset "$recovery_raw"
  else
    # Normal resume: the gap since the run was interrupted must not count against
    # the stage/task time budgets, so rebase both to now.
    state_set '.stage_started_at=$now | .task_started_at=$now | .stage_started[.stage]=$now | .updated_at=$iso' \
      --argjson now "$(now_epoch)" --arg iso "$(now_iso)"
  fi
}

archive_old_signal() {
  local signal="$RUN_ROOT/control/next-action.json"
  if [ -f "$signal" ]; then
    mkdir -p "$RUN_ROOT/control/previous"
    mv "$signal" "$RUN_ROOT/control/previous/$(date -u '+%Y%m%dT%H%M%SZ').json"
  fi
}

primary_prompt() {
  local prompt="$1" stage turns remaining persona_list persona_count active
  stage="$(jq -r '.stage' "$STATE")"
  turns="$(jq -r '.stage_turns' "$STATE")"
  remaining=$((MAX_STAGE_TURNS - turns))
  active="$(resolve_active_personas "$SPEC")" || block_run "cannot resolve review profile for $SPEC"
  persona_list="$(printf '%s' "$active" | tr '|' '\n' | sed 's/^/  - /')"
  persona_count="$(printf '%s' "$active" | tr '|' '\n' | grep -c .)"
  cat >"$prompt" <<EOF
You are the fixed $PRIMARY primary for night-shift run $RUN_ID.
Project: $PROJECT
Task spec: $SPEC
Current stage: $stage
Base commit: $BASE_COMMIT

Read $WORKSPACE_ROOT/AGENTS.md and $WORKSPACE_ROOT/AGENT_LOOP.md, then continue
the task in this same session. Preserve baseline dirty work. You own planning,
implementation, reviewer coordination, finding resolution, validation,
candidate commits, documentation, and task completion.

The active review personas for this run (review profile selects them — $persona_count total) are:
$persona_list

Before ending this turn, write a fresh JSON signal to:
  .night-shift/control/next-action.json
It must validate against $SCHEMA_DIR/next-action.json. "task" must equal
$SPEC. "artifacts" lists only project-relative files (no absolute paths, no
"..") the wrapper must consume for the chosen action:

- RUN_PERSONAS: run each active persona listed above as a separate sub-agent,
  each scoped to its own domain. Write exactly $persona_count result files, one
  per active persona, each validating against $SCHEMA_DIR/persona-review.json,
  with the persona's exact name and "stage" set to "plan" during plan_review or
  "implementation" during implementation_review. List all of those file paths in
  artifacts. Do not run personas outside the active set. Every finding is a
  blocker; APPROVE carries no findings.
- CREATE_CANDIDATE: create ONE local commit on the feature branch containing
  only files this run changed (never baseline dirty paths). Then write an
  execution-evidence file validating against $SCHEMA_DIR/execution-evidence.json
  whose baseline, test_first, and final_validation match the spec's commands.
  List that evidence file in artifacts.
- REQUEST_OBSERVER: list the candidate evidence, relevant tests, and docs the
  fresh observer needs. The wrapper runs the observer; do not run it yourself.
- NEXT_TASK: only after observer APPROVE. First check off the completed entry in
  $WORKSPACE_ROOT/TODO.md, then signal NEXT_TASK.
- COMPLETE: only after observer APPROVE with no remaining TODO entries.
- BLOCKED: stop with a clear reason when you cannot proceed safely.

Remaining primary turns in this stage before blocking: $remaining.
Do not switch roles, push, merge, clean, reset, or use implicit session selectors.

This is an UNATTENDED overnight run. No human is available. Never ask a
question, request confirmation, or wait for input. If you cannot proceed safely,
write a next-action.json with action "BLOCKED" and put the question or decision
in "reason" for the human to resolve in the morning. Make reasonable decisions
autonomously for anything else.
EOF
}

invoke_primary() {
  local prompt="$RUN_ROOT/prompts/primary-$(jq -r '.primary_turns + 1' "$STATE").txt"
  local raw="$RUN_ROOT/raw/primary-$(jq -r '.primary_turns + 1' "$STATE").json"
  local session emitted rc
  enforce_limits
  archive_old_signal
  primary_prompt "$prompt"
  session="$(jq -r '.session_id // empty' "$STATE")"
  log "primary turn $(jq -r '.primary_turns + 1' "$STATE") · stage $(jq -r '.stage' "$STATE") · stage turn $(jq -r '.stage_turns + 1' "$STATE")/$MAX_STAGE_TURNS · task turn $(jq -r '.task_turns + 1' "$STATE")/$MAX_TASK_TURNS"
  while :; do
    rc=0
    # The primary must edit files and run commands unattended, so it runs in a
    # non-interactive permission mode. Safe because the run is confined to a
    # feature branch and the wrapper forbids push/merge/destructive Git ops and
    # excludes pre-existing dirt from candidate commits.
    if [ -z "$session" ]; then
      (cd "$PROJECT" && claude -p --permission-mode bypassPermissions \
        --output-format json "$(cat "$prompt")") >"$raw" || rc=$?
    else
      (cd "$PROJECT" && claude -p --resume "$session" --permission-mode bypassPermissions \
        --output-format json "$(cat "$prompt")") >"$raw" || rc=$?
    fi
    emitted="$(jq -r '.session_id // empty' "$raw" 2>/dev/null)"
    [ "$rc" -ne 0 ] || break
    if is_rate_limit_response "$raw" &&
      [ -n "$emitted" ] &&
      { [ -z "$session" ] || [ "$emitted" = "$session" ]; }; then
      session="$emitted"
      state_set '.session_id=$session | .updated_at=$now' \
        --arg session "$session" --arg now "$(now_iso)"
      wait_for_rate_limit_reset "$raw"
      continue
    fi
    block_run "primary command failed with status $rc"
  done
  [ -n "$emitted" ] || block_run "primary emitted no resumable session ID"
  if [ -n "$session" ] && [ "$emitted" != "$session" ]; then
    block_run "primary session ID changed from $session to $emitted"
  fi
  state_set '
    .session_id=$session |
    .primary_turns += 1 | .task_turns += 1 | .stage_turns += 1 |
    .updated_at=$now
  ' --arg session "$emitted" --arg now "$(now_iso)"
  enforce_elapsed_limits
}

enforce_limits() {
  local now stage_elapsed task_elapsed stage_turns task_turns
  now="$(now_epoch)"
  stage_elapsed=$((now - $(jq -r '.stage_started_at' "$STATE")))
  task_elapsed=$((now - $(jq -r '.task_started_at' "$STATE")))
  stage_turns="$(jq -r '.stage_turns' "$STATE")"
  task_turns="$(jq -r '.task_turns' "$STATE")"
  if limit_exceeded "$stage_turns" "$stage_elapsed" "$task_turns" "$task_elapsed"; then
    block_run "turn/time limit reached (stage ${stage_turns}/${MAX_STAGE_TURNS}, task ${task_turns}/${MAX_TASK_TURNS})"
  fi
}

enforce_elapsed_limits() {
  local now stage_elapsed task_elapsed
  now="$(now_epoch)"
  stage_elapsed=$((now - $(jq -r '.stage_started_at' "$STATE")))
  task_elapsed=$((now - $(jq -r '.task_started_at' "$STATE")))
  if [ "$stage_elapsed" -ge "$MAX_STAGE_SECONDS" ] ||
    [ "$task_elapsed" -ge "$MAX_TASK_SECONDS" ]; then
    block_run "time limit reached after the completed primary turn"
  fi
}

set_stage() {
  # Each stage ENTRY gets a fresh wall-clock start, so the per-stage time budget
  # measures time in this entry — not stale time from an earlier visit (stages
  # are re-entered on review blocks, and a long run/resume gap would otherwise
  # restore an ancient start and trip the elapsed limit immediately). Turn counts
  # still accumulate per stage via stage_counters.
  state_set '
    .stage_counters[.stage]=.stage_turns |
    .stage=$stage |
    .stage_turns=(.stage_counters[$stage] // 0) |
    .stage_started_at=$epoch |
    .stage_started[$stage]=$epoch |
    .updated_at=$now
  ' \
    --arg stage "$1" --argjson epoch "$(now_epoch)" --arg now "$(now_iso)"
}

transition_allowed() {
  case "$1:$2" in
    planning:RUN_PERSONAS|plan_review:RUN_PERSONAS|implementation:RUN_PERSONAS|implementation_review:RUN_PERSONAS|implementation_ready:CREATE_CANDIDATE|observer_review:REQUEST_OBSERVER|completion:NEXT_TASK|completion:COMPLETE|*:BLOCKED) return 0 ;;
    *) return 1 ;;
  esac
}

block_run() {
  local reason="$1"
  cleanup_validation_worktree >/dev/null 2>&1 || reason="$reason; validation worktree cleanup also failed"
  [ -f "${STATE:-}" ] && state_set '.status="blocked" | .block_reason=$reason | .updated_at=$now' \
    --arg reason "$reason" --arg now "$(now_iso)"
  die "$reason; complete state preserved at ${RUN_ROOT:-unknown}"
}

cleanup_validation_worktree() {
  local path expected_prefix
  [ -n "${STATE:-}" ] && [ -f "$STATE" ] || return 0
  path="$(jq -r '.validation_worktree // empty' "$STATE")"
  [ -n "$path" ] || return 0
  expected_prefix="$(tmp_base)/night-shift-$RUN_ID-"
  case "$path" in "$expected_prefix"*) ;; *) return 1 ;; esac
  if git -C "$PROJECT" worktree list --porcelain | grep -Fqx "worktree $path"; then
    git -C "$PROJECT" worktree remove --force "$path" >/dev/null || return 1
  elif [ -e "$path" ]; then
    return 1
  fi
  state_set 'del(.validation_worktree)'
}

validate_signal() {
  local signal="$RUN_ROOT/control/next-action.json"
  [ -f "$signal" ] || return 2
  json_schema_basic next-action "$signal" || return 1
  [ "$(jq -r '.task' "$signal")" = "$SPEC" ] || return 1
}

# Extracts the observer's JSON verdict from a `claude -p --output-format json`
# envelope, trying the most reliable shapes in order.
extract_claude_structured() {
  local raw="$1" out="$2" result
  # (0) An explicit structured_output field, if a future flag ever populates it.
  if jq -e 'has("structured_output") and .structured_output != null' "$raw" >/dev/null 2>&1; then
    jq '.structured_output' "$raw" >"$out" 2>/dev/null && return 0
  fi
  result="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  [ -n "$result" ] || return 1
  # (1) The whole result is already a JSON object.
  printf '%s' "$result" | jq '.' >"$out" 2>/dev/null && return 0
  # (2) The LAST fenced code block (``` or ```json) — the model's verdict block.
  printf '%s\n' "$result" | awk '
    /^[ \t]*```/ { if (infence) { infence=0; last=buf } else { infence=1; buf="" } next }
    infence { buf = buf $0 "\n" }
    END { printf "%s", last }
  ' | jq '.' >"$out" 2>/dev/null && [ -s "$out" ] && return 0
  # (3) The outermost {...} object embedded anywhere in prose.
  printf '%s' "$result" | tr '\n' ' ' \
    | sed -E 's/^[^{]*//; s/[^}]*$//' \
    | jq '.' >"$out" 2>/dev/null && [ -s "$out" ] && return 0
  return 1
}

run_personas() {
  local signal="$1" review_stage persona_stage result_dir out artifact
  review_stage="$(jq -r '.stage' "$STATE")"
  case "$review_stage" in
    planning|plan_review) persona_stage="plan"; set_stage plan_review ;;
    implementation|implementation_review) persona_stage="implementation"; set_stage implementation_review ;;
    *) block_run "RUN_PERSONAS is invalid from stage $review_stage" ;;
  esac
  result_dir="$RUN_ROOT/validated/personas/$(basename "$SPEC" .md)/$persona_stage/round-$(( $(jq -r '.review_round' "$STATE") + 1 ))"
  mkdir -p "$result_dir"
  state_set '.review_round += 1'

  # Claude primary runs the active personas as native sub-agents and lists their
  # result files as artifacts. Each must validate against persona-review.json.
  jq -r '.artifacts[]' "$signal" | while IFS= read -r artifact; do
    out="$(resolve_artifact "$artifact")" || exit 20
    json_schema_basic persona-review "$out" || exit 21
    dst="$result_dir/$(basename "$out")"
    # The primary may have written the artifact directly into $result_dir; in that
    # case the copy is a no-op (and BSD cp would fail with "are identical").
    [ "$out" -ef "$dst" ] || cp "$out" "$dst" || exit 22
  done || block_run "persona result artifacts are missing, unsafe, or malformed"

  local expected_set expected_count
  expected_set="$(resolve_active_personas "$SPEC")" ||
    block_run "cannot resolve the active persona set for $SPEC"
  expected_count="$(printf '%s' "$expected_set" | tr '|' '\n' | grep -c .)"
  [ "$(find "$result_dir" -type f -name '*.json' | wc -l | tr -d ' ')" -eq "$expected_count" ] ||
    block_run "persona gate requires exactly $expected_count validated results for this spec's active personas"
  jq -s -e --arg stage "$persona_stage" --arg personas "$expected_set" '
    ($personas | split("|") | sort) as $expected |
    (map(.persona) | sort) == $expected and
    all(.[]; .stage == $stage)
  ' "$result_dir"/*.json >/dev/null ||
    block_run "persona gate requires one result from each active persona for the current stage"
  if find "$result_dir" -type f -name '*.json' -exec jq -e '.status == "APPROVE"' {} \; |
    grep -q false; then
    local blocked
    blocked="$(find "$result_dir" -type f -name '*.json' -exec jq -r 'select(.status=="BLOCK").persona' {} \; | paste -sd ', ' -)"
    log "personas ($persona_stage): BLOCK by $blocked — primary must resolve"
    detect_stalled_personas "$result_dir" "$persona_stage"
    set_stage "$([ "$persona_stage" = plan ] && printf planning || printf implementation)"
  else
    log "personas ($persona_stage): $expected_count/$expected_count APPROVE"
    if [ "$persona_stage" = plan ]; then
      state_set '.plan_approved=true'
      set_stage implementation
    else
      state_set '.implementation_approved=true'
      set_stage implementation_ready
    fi
  fi
  record_findings "$result_dir"
}

record_findings() {
  local dir="$1" ids tmp
  # Only review files carry .findings; baseline/final/evidence JSON do not (some
  # are arrays). Guard the type so those produce nothing instead of jq errors.
  ids="$(find "$dir" -type f -name '*.json' -exec jq -r 'if (type=="object" and (.findings|type=="array")) then (.findings[].id // empty) else empty end' {} \; | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  tmp="$STATE.tmp.$$"
  jq --argjson ids "$ids" '.finding_ids = ((.finding_ids + $ids) | unique)' "$STATE" >"$tmp" && mv "$tmp" "$STATE" ||
    die "failed to record findings; state preserved at ${RUN_ROOT:-unknown}"
}

verify_candidate() {
  local candidate changed baseline_paths committed_path baseline_path previous evidence artifact validation_worktree
  [ "$(jq -r '.baseline_complete and .plan_approved and .implementation_approved' "$STATE")" = "true" ] ||
    block_run "candidate requires baseline, plan, and implementation gates"
  candidate="$(git -C "$PROJECT" rev-parse HEAD)"
  [ "$candidate" != "$BASE_COMMIT" ] || block_run "CREATE_CANDIDATE did not create a commit"
  git -C "$PROJECT" merge-base --is-ancestor "$BASE_COMMIT" "$candidate" ||
    block_run "candidate is not descended from the recorded base commit"
  changed="$(git -C "$PROJECT" diff --name-only "$BASE_COMMIT..$candidate")"
  [ -n "$changed" ] || block_run "candidate commit is empty"
  baseline_paths="$RUN_ROOT/baseline-paths.txt"
  sed -E 's/^.. //' "$BASE_STATUS" | sed -E 's/.* -> //' | sort -u >"$baseline_paths"
  while IFS= read -r committed_path; do
    [ -n "$committed_path" ] || continue
    while IFS= read -r baseline_path; do
      [ -n "$baseline_path" ] || continue
      case "$committed_path" in
        "${baseline_path%/}"|"${baseline_path%/}"/*)
          block_run "candidate includes pre-existing dirty path: $committed_path"
          ;;
      esac
    done <"$baseline_paths"
  done <<EOF
$changed
EOF
  previous="$(jq -r '.candidate // empty' "$STATE")"
  [ "$candidate" != "$previous" ] ||
    block_run "CREATE_CANDIDATE did not produce a new candidate commit"
  validation_worktree="$(tmp_base)/night-shift-$RUN_ID-$candidate"
  [ ! -e "$validation_worktree" ] ||
    block_run "candidate validation worktree already exists: $validation_worktree"
  git -C "$PROJECT" worktree add --detach "$validation_worktree" "$candidate" >/dev/null ||
    block_run "could not create isolated candidate validation worktree"
  state_set '.validation_worktree=$path' --arg path "$validation_worktree"
  link_worktree_dependencies "$validation_worktree"

  evidence=""
  while IFS= read -r artifact; do
    resolved="$(resolve_artifact "$artifact")" || block_run "candidate evidence artifact is unsafe or missing"
    if json_schema_basic execution-evidence "$resolved"; then
      [ -z "$evidence" ] || block_run "candidate action supplied duplicate execution evidence"
      evidence="$resolved"
    fi
  done <<EOF
$(jq -r '.artifacts[]' "$RUN_ROOT/control/next-action.json")
EOF
  [ -n "$evidence" ] || block_run "candidate requires schema-valid execution evidence"
  [ "$(jq -r '.task' "$evidence")" = "$SPEC" ] ||
    block_run "execution evidence task does not match current spec"
  test_command="$(jq -r '.test_first.command' "$evidence")"
  [ "$test_command" = "$(jq -r '.command' "$RUN_ROOT/validated/test-first-failing.json")" ] ||
    block_run "test-first command differs from wrapper-owned failing command"
  run_test_command passing "$test_command" "$RUN_ROOT/validated/test-first-passing.json" "$validation_worktree"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-passing.json")" -eq 0 ] ||
    block_run "test-first command still fails after implementation"
  jq -e --slurpfile failing "$RUN_ROOT/validated/test-first-failing.json" \
    --slurpfile passing "$RUN_ROOT/validated/test-first-passing.json" '
      .test_first.command == $failing[0].command and
      .test_first.failing_exit_status == $failing[0].exit_status and
      .test_first.passing_exit_status == $passing[0].exit_status
    ' "$evidence" >/dev/null ||
    block_run "primary test-first evidence does not match wrapper-owned executions"
  jq -e --slurpfile baseline "$RUN_ROOT/validated/baseline.json" '
    [.baseline[] | {command,exit_status}] ==
    [$baseline[0][] | {command,exit_status}]
  ' "$evidence" >/dev/null ||
    block_run "primary baseline evidence does not match wrapper-owned baseline"
  final_commands="$(extract_validation_commands "$SPEC" "Final validation commands")"
  run_validation_commands final "$RUN_ROOT/validated/final.json" "$final_commands" "$validation_worktree" ||
    block_run "final validation commands are missing or could not run"
  assert_tools_available "$RUN_ROOT/validated/final.json" "final"
  validation_not_regressed "$RUN_ROOT/validated/baseline.json" "$RUN_ROOT/validated/final.json" ||
    block_run "final validation introduced a new or worsened failure"
  jq -e --slurpfile final "$RUN_ROOT/validated/final.json" '
    [.final_validation[] | {command,exit_status}] ==
    [$final[0][] | {command,exit_status}]
  ' "$evidence" >/dev/null ||
    block_run "primary final evidence does not match wrapper-owned validation"
  git -C "$PROJECT" worktree remove --force "$validation_worktree" >/dev/null ||
    block_run "candidate passed but validation worktree cleanup failed"
  state_set 'del(.validation_worktree)'
  # Append preserving INSERTION order (jq `unique` sorts, which would make
  # candidate_commits[-1] the lexicographically-largest hash, not the latest).
  # Also record the latest explicitly in .candidate for unambiguous selection.
  state_set '
    .candidate_commits = ((.candidate_commits + [$candidate])
      | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) |
    .candidate=$candidate | .updated_at=$now
  ' --arg candidate "$candidate" --arg now "$(now_iso)"
  cp "$evidence" "$RUN_ROOT/validated/execution-$candidate.json"
  state_set '.candidate_verified=true'
  log "candidate $candidate validated; handing to observer"
  set_stage observer_review
}

observer_prompt() {
  local context="$1" candidate="$2"
  cat <<EOF
You are an independent Claude observer reviewing another Claude session's work.
You share no context with the implementer; judge only the supplied evidence.

Reason briefly if you must, then END YOUR REPLY with exactly one fenced code
block tagged json containing your verdict and nothing after it:

\`\`\`json
{"observer":"claude","primary":"claude","task":"$SPEC","candidate_commit":"$candidate","status":"APPROVE","findings":[],"documentation_changes":[]}
\`\`\`

Rules for that JSON object:
- "observer" and "primary" are both "claude"; "task" and "candidate_commit" are
  exactly the values above.
- "status" is EXACTLY "APPROVE" or "BLOCK" — there is no other value. To request
  changes, use "BLOCK" (not "REQUEST_CHANGES"). Use ONLY the seven keys shown
  above; do not add keys like "severity", "location", "summary", or "base_commit".
- "status" is "APPROVE" with an empty "findings" array, or "BLOCK" with one or
  more findings.
- Each finding has a stable "id" matching ^OBS-[0-9]{3,}$, concrete "evidence",
  and a binary "required_change". "documentation_changes" is an array of strings.

Task: $SPEC
Base commit: $BASE_COMMIT
Candidate commit: $candidate

CONTEXT:
$(cat "$context")
EOF
}

invoke_observer_once() {
  local context="$1" candidate="$2" out="$3" raw="$4" neutral
  # Context-isolated observer: a fresh Claude session (no --resume) launched from
  # a neutral empty directory. It runs in the default (non-bypass) permission
  # mode, so tool use is not auto-approved and, combined with the neutral cwd, it
  # cannot inspect the repository — it reviews only the supplied evidence.
  # NOTE: do NOT pass --allowedTools here; it is variadic and swallows the prompt
  # argument. stdout (the JSON result) goes to $raw; stderr (warnings) is kept
  # separately so it never corrupts JSON parsing. Output is schema-validated and
  # retried by the caller.
  neutral="${TMPDIR:-/tmp}/night-shift-observer-$RUN_ID"
  mkdir -p "$neutral"
  # Plain print mode. We do NOT use --json-schema: in this CLI it waits on stdin
  # and hangs, producing nothing. Instead the prompt asks the observer to end its
  # reply with a fenced ```json verdict block, which extract_claude_structured
  # pulls out; json_schema_basic then enforces the strict contract.
  (cd "$neutral" && claude -p --output-format json \
    "$(observer_prompt "$context" "$candidate")") >"$raw" 2>"${raw}.err" || return 1
  extract_claude_structured "$raw" "$out"
}

run_observer() {
  local signal="$1" candidate context="$RUN_ROOT/prompts/observer-context.txt"
  local out raw attempt=0 artifact
  candidate="$(jq -r '.candidate // .candidate_commits[-1] // empty' "$STATE")"
  [ -n "$candidate" ] || block_run "observer requested without a candidate commit"
  plan_results="$(find "$RUN_ROOT/validated/personas/$(basename "$SPEC" .md)/plan" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sort -V | tail -n 1)"
  implementation_results="$(find "$RUN_ROOT/validated/personas/$(basename "$SPEC" .md)/implementation" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | sort -V | tail -n 1)"
  {
    printf '%s\n' '--- CURRENT SPEC ---'
    cat "$SPEC"
    printf '%s\n' '--- VALIDATED PERSONA SUMMARY ---'
    for review_dir in "$plan_results" "$implementation_results"; do
      [ -d "$review_dir" ] || continue
      find "$review_dir" -type f -name '*.json' -exec jq -c \
        '{persona,stage,commit,status,findings,documentation_changes}' {} \;
    done
  } >"$context"
  jq -r '.artifacts[]' "$signal" | while IFS= read -r artifact; do
    resolved="$(resolve_artifact "$artifact")" || exit 30
    printf '\n--- %s ---\n' "$artifact"
    cat "$resolved"
  done >>"$context" || block_run "observer context contains missing or unsafe artifacts"
  out="$RUN_ROOT/validated/observer-$candidate.json"
  raw="$RUN_ROOT/raw/observer-$candidate.jsonl"
  validated_observer_retry "$context" "$candidate" "$out" "$raw" ||
    block_run "observer output remained invalid after one retry"
  append_observer_review "$out"
  record_findings "$(dirname "$out")"
  if [ "$(jq -r '.status' "$out")" = "APPROVE" ]; then
    log "observer: APPROVE — task complete, ready to commit/next"
    set_stage completion
  else
    log "observer: BLOCK ($(jq -r '.findings | length' "$out") finding(s)) — back to implementation"
    detect_stalled_findings "$out"
    state_set '.implementation_approved=false | .candidate_verified=false'
    set_stage implementation
  fi
}

# Coerces a substantively-valid but sloppily-formatted observer verdict into the
# strict observer-review shape: forces the identity fields the wrapper already
# knows (observer/primary/task/candidate_commit), maps status synonyms like
# REQUEST_CHANGES to BLOCK, pads finding ids to OBS-NNN, drops unknown keys, and
# keeps APPROVE<->findings consistent. This stops a well-meaning verdict from
# wedging the run on a format nit.
#
# TRADEOFF (deliberate): when a finding omits `evidence`/`required_change`, or a
# BLOCK arrives with no structured finding at all, this fills generic placeholders
# ("see observer notes", "observer requested changes without a structured
# finding") so a malformed-but-blocking verdict still HALTS the run rather than
# being discarded. The cost is that an evidence string is therefore not guaranteed
# to be observer-authored, concrete evidence — only that a blocking verdict is
# never silently dropped. This is preferred over the alternative (rejecting the
# verdict, which fails-open toward "no findings"). We cannot instead use the CLI's
# --json-schema to force a clean shape: in this CLI it waits on stdin and hangs
# (see run_observer). Bias: fail-closed on BLOCK, never fabricate an APPROVE.
normalize_observer_output() {
  local file="$1" task="$2" candidate="$3" tmp="$1.norm.$$"
  jq --arg task "$task" --arg candidate "$candidate" '
    {
      observer: "claude",
      primary: "claude",
      task: $task,
      candidate_commit: $candidate,
      status: ((.status // "BLOCK") | tostring | ascii_upcase
        | if (. == "APPROVE" or . == "APPROVED" or . == "PASS" or . == "OK" or . == "LGTM")
          then "APPROVE" else "BLOCK" end),
      findings: ((.findings // []) | to_entries | map(
        (.key + 1) as $k | .value as $f |
        (($f.id // "") | tostring) as $idstr |
        (if ($idstr | test("[0-9]")) then ($idstr | capture("(?<n>[0-9]+)").n) else ($k | tostring) end) as $num |
        {
          id: ("OBS-" + (if ($num | length) < 3 then (("000" + $num)[-3:]) else $num end)),
          evidence: (($f.evidence // $f.location // $f.summary // "see observer notes") | tostring),
          required_change: (($f.required_change // $f.summary // $f.recommendation // "address the observer finding") | tostring)
        }
      )),
      documentation_changes: ((.documentation_changes // []) | map(select(type == "string" and length > 0)))
    }
    | if .status == "APPROVE" then .findings = []
      elif (.findings | length) == 0 then
        .findings = [{id: "OBS-001", evidence: "observer requested changes without a structured finding", required_change: "address the observer feedback"}]
      else . end
  ' "$file" >"$tmp" 2>/dev/null && mv "$tmp" "$file"
}

validated_observer_retry() {
  local context="$1" candidate="$2" out="$3" raw="$4" attempt=0
  while [ "$attempt" -lt 2 ]; do
    enforce_limits
    invoke_observer_once "$context" "$candidate" "$out" "$raw.$attempt" || true
    normalize_observer_output "$out" "$SPEC" "$candidate"
    enforce_elapsed_limits
    if json_schema_basic observer-review "$out" &&
      [ "$(jq -r '.observer' "$out")" = "$OBSERVER" ] &&
      [ "$(jq -r '.primary' "$out")" = "$PRIMARY" ] &&
      { [ "$(jq -r '.task' "$out")" = "$SPEC" ] ||
        [ "$(basename "$(jq -r '.task' "$out")")" = "$(basename "$SPEC")" ]; } &&
      [ "$(jq -r '.candidate_commit' "$out")" = "$candidate" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

append_observer_review() {
  local out="$1" ledger="$WORKSPACE_ROOT/NIGHT_SHIFT_REVIEW.md"
  {
    printf '\n## Run %s - %s\n\n' "$RUN_ID" "$(now_iso)"
    printf -- '- Task: `%s`\n- Base: `%s`\n- Candidate: `%s`\n\n' \
      "$SPEC" "$BASE_COMMIT" "$(jq -r '.candidate_commit' "$out")"
    printf '```json\n'
    jq . "$out"
    printf '```\n'
  } >>"$ledger"
}

# A finding counts as "unchanged" only when its required_change AND the work
# under review are the same as the prior round. The fingerprint therefore folds
# in the material token (full diff vs base) and, for the observer, the test-first
# evidence — so changed code, tests, or evidence reset the counter and only
# genuinely stalled rounds accumulate toward the three-round block.
detect_stalled_findings() {
  local out="$1" history candidate evidence_hash token findings maxc
  history="$RUN_ROOT/observer-history-$(basename "$SPEC" .md).json"
  candidate="$(jq -r '.candidate_commit' "$out")"
  evidence_hash="$(jq -c '{test_first}' \
    "$RUN_ROOT/validated/execution-$candidate.json" 2>/dev/null | cksum | awk '{print $1 ":" $2}')"
  token="$(material_token)"
  findings="$(jq -c --arg e "$evidence_hash" --arg t "$token" \
    '[.findings[] | {id, fp:(.required_change + "|" + $e + "|" + $t)}]' "$out")"
  [ "$findings" = "[]" ] && return 0
  maxc="$(bump_finding_history "$history" "$findings")"
  [ "$maxc" -lt 3 ] ||
    block_run "an observer finding remained materially unchanged for three rounds"
}

detect_stalled_personas() {
  local result_dir="$1" stage="$2" history token findings maxc
  history="$RUN_ROOT/persona-history-$(basename "$SPEC" .md)-$stage.json"
  token="$(material_token)"
  findings="$(find "$result_dir" -type f -name '*.json' \
    -exec jq -c --arg t "$token" '.findings[] | {id, fp:(.required_change + "|" + $t)}' {} \; | jq -sc '.')"
  [ "$findings" = "[]" ] && return 0
  maxc="$(bump_finding_history "$history" "$findings")"
  [ "$maxc" -lt 3 ] ||
    block_run "a persona finding stayed materially unchanged for three $stage rounds"
}

complete_run() {
  local summary="$RUN_ROOT/summary.json"
  state_set '.status="complete" | .completed_at=$now | .updated_at=$now' --arg now "$(now_iso)"
  jq '{run_id,status,primary,observer,task,base_commit,candidate_commits,
    primary_turns,review_round,finding_ids,started_at,completed_at}' "$STATE" >"$summary"
  compact_success "$RUN_ROOT" "$RUN_ID"
  log "run $RUN_ID complete; compact archive: $RUN_ROOT/archive/$RUN_ID"
  exit 0
}

start_next_task() {
  local next_spec epoch
  next_spec="$(select_task_from_todo "$WORKSPACE_ROOT/TODO.md")" || {
    complete_run
    return
  }
  case "$next_spec" in /*) ;; *) next_spec="$WORKSPACE_ROOT/$next_spec" ;; esac
  next_spec="$(canonical_file "$next_spec")" || block_run "next TODO spec does not exist"
  [ "$next_spec" != "$SPEC" ] ||
    block_run "NEXT_TASK requires the completed TODO entry to be checked off"
  validate_spec "$next_spec" || block_run "next TODO spec is incomplete"
  validate_spec_project "$next_spec" ||
    block_run "next TODO spec routes to a different or invalid project"
  SPEC="$next_spec"
  BASE_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
  BASE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
  BASE_STATUS="$RUN_ROOT/baseline-status-$(basename "$SPEC" .md).txt"
  git -C "$PROJECT" status --porcelain=v1 >"$BASE_STATUS"
  epoch="$(now_epoch)"
  state_set '
    .task=$task | .stage="planning" | .stage_turns=0 | .task_turns=0 |
    .stage_started_at=$epoch | .task_started_at=$epoch |
    .base_commit=$base | .base_branch=$branch | .review_round=0 |
    .baseline_status=$baseline_status | .finding_ids=[] | .candidate_commits=[] |
    .plan_approved=false | .implementation_approved=false |
    .candidate_verified=false | .baseline_complete=false |
    .stage_counters={planning:0} | .stage_started={planning:$epoch} |
    .updated_at=$now
  ' --arg task "$SPEC" --argjson epoch "$epoch" --arg base "$BASE_COMMIT" \
    --arg branch "$BASE_BRANCH" --arg baseline_status "$BASE_STATUS" \
    --arg now "$(now_iso)"
  log "starting next bug-first task: $SPEC"
  check_branch_and_worktree "$SPEC" ||
    block_run "next task branch or worktree routing is unsafe"
  baseline_commands="$(extract_validation_commands "$SPEC" "Baseline validation commands")"
  run_validation_commands baseline "$RUN_ROOT/validated/baseline-$(basename "$SPEC" .md).json" "$baseline_commands" ||
    block_run "next task baseline validation could not run"
  cp "$RUN_ROOT/validated/baseline-$(basename "$SPEC" .md).json" "$RUN_ROOT/validated/baseline.json"
  assert_tools_available "$RUN_ROOT/validated/baseline.json" "next task baseline"
  test_command="$(sed -nE 's/^- First failing test or executable check: `([^`]+)`.*/\1/p' "$SPEC" | head -n 1)"
  run_test_command failing "$test_command" "$RUN_ROOT/validated/test-first-failing.json"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")" -ne 127 ] ||
    block_run "next task test-first command was not found (exit 127); fix the toolchain"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")" -ne 0 ] ||
    block_run "next task test-first command did not fail before implementation"
  state_set '.baseline_complete=true'
}

handle_signal() {
  local signal="$RUN_ROOT/control/next-action.json" action
  action="$(jq -r '.action' "$signal")"
  log "signal: $action — $(jq -r '.reason' "$signal")"
  transition_allowed "$(jq -r '.stage' "$STATE")" "$action" ||
    block_run "action $action is invalid from stage $(jq -r '.stage' "$STATE")"
  case "$action" in
    RUN_PERSONAS) run_personas "$signal" ;;
    CREATE_CANDIDATE) verify_candidate ;;
    REQUEST_OBSERVER) run_observer "$signal" ;;
    NEXT_TASK)
      [ "$(jq -r '.stage' "$STATE")" = "completion" ] ||
        block_run "NEXT_TASK requires observer approval"
      start_next_task
      ;;
    BLOCKED) block_run "primary reported: $(jq -r '.reason' "$signal")" ;;
    COMPLETE)
      [ "$(jq -r '.stage' "$STATE")" = "completion" ] ||
        block_run "COMPLETE requires observer approval"
      complete_run
      ;;
    *) block_run "unsupported action $action" ;;
  esac
}

main_run() {
  require_command jq
  require_command git
  case "${PRIMARY:-claude}" in
    claude|"") PRIMARY="claude" ;;
    *) die "this workflow runs Claude only; --primary $PRIMARY is not supported" ;;
  esac
  [ -n "$PROJECT" ] || die "--project is required"
  PROJECT="$(canonical_dir "$PROJECT")" || die "project directory does not exist"
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "project is not a Git repository: $PROJECT"
  git -C "$PROJECT" check-ignore -q .night-shift/ ||
    die "project must ignore .night-shift/ in its .gitignore before a run"
  # The observer is a fresh, independent Claude session (no shared context with
  # the pinned primary session), not a second model.
  OBSERVER="claude"
  require_command claude
  case "$RATE_LIMIT_BUFFER_SECONDS" in
    ''|*[!0-9]*) die "NIGHT_SHIFT_RATE_LIMIT_BUFFER_SECONDS must be a non-negative integer" ;;
  esac

  if recover_run; then
    :
  else
    if [ -z "$SPEC" ]; then
      SPEC="$(select_task_from_todo "$WORKSPACE_ROOT/TODO.md")" ||
        die "no unfinished bug or feature entry in TODO.md and no --spec supplied"
    fi
    case "$SPEC" in /*) ;; *) SPEC="$WORKSPACE_ROOT/$SPEC" ;; esac
    SPEC="$(canonical_file "$SPEC")" || die "spec does not exist: $SPEC"
    validate_spec "$SPEC" || exit 1
    validate_spec_project "$SPEC" ||
      die "spec Project path does not match --project"
    check_branch_and_worktree "$SPEC" ||
      die "current branch or worktree does not safely match the spec"
    initialize_run
  fi
  trap 'block_run "run interrupted by signal"' HUP INT TERM

  while :; do
    invoke_primary
    if validate_signal; then
      handle_signal
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then
        log "primary signal malformed; continuing same explicit session for correction"
      else
        log "primary produced no signal; continuing same explicit session"
      fi
    fi
  done
}

require_command jq
if [ "$FIXTURE_TEST" -eq 1 ]; then
  run_dry_fixtures
  if [ "$DRY_RUN" -eq 0 ]; then run_live_fixtures; fi
  exit 0
fi
[ "$DRY_RUN" -eq 0 ] || die "--dry-run is valid only with --fixture-test"
main_run
