#!/usr/bin/env bash
set -u
set -o pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCHEMA_DIR="$WORKSPACE_ROOT/schemas"
PRIMARY=""
PROJECT=""
SPEC=""
EXPLICIT_SPEC=0
FIXTURE_TEST=0
DRY_RUN=0
FULL_PERSONA_LIVE_TEST=0
LIST_OPTIONAL_PERSONAS=0
PREFLIGHT=0
RESUME=0
MAX_STAGE_TURNS="${NIGHT_SHIFT_MAX_STAGE_TURNS:-12}"
MAX_STAGE_SECONDS="${NIGHT_SHIFT_MAX_STAGE_SECONDS:-3600}"
MAX_TASK_TURNS="${NIGHT_SHIFT_MAX_TASK_TURNS:-36}"
MAX_TASK_SECONDS="${NIGHT_SHIFT_MAX_TASK_SECONDS:-10800}"
# Cap on consecutive malformed or absent primary signals. A primary stuck
# emitting junk would otherwise burn up to MAX_TASK_TURNS paid turns before any
# stop; this fails fast. The counter resets on the first valid signal, so a
# healthy run (which produces a valid signal almost every turn) never trips it.
MAX_MALFORMED_SIGNALS="${NIGHT_SHIFT_MAX_MALFORMED_SIGNALS:-5}"
RATE_LIMIT_BUFFER_SECONDS="${NIGHT_SHIFT_RATE_LIMIT_BUFFER_SECONDS:-60}"
# Sanity ceiling on a rate-limit wait. A genuine session limit resets within a
# few hours; a wait longer than this almost certainly means the reset time was
# misparsed, so we block for manual resume instead of sleeping for ~a day.
RATE_LIMIT_MAX_WAIT_SECONDS="${NIGHT_SHIFT_RATE_LIMIT_MAX_WAIT_SECONDS:-21600}"
# Model for the persona review sub-agents. Personas verify mostly binary
# conditions against a primary-prepared bundle, which a cheaper reviewer model
# handles well (the fresh cheap observer already proves the pattern); the
# primary session's own model is never changed. Set to "inherit" to launch
# personas on the primary's model.
PERSONA_MODEL="${NIGHT_SHIFT_PERSONA_MODEL:-sonnet}"
# Primary session scope. A single pinned session for the whole run replays its
# entire (ever-growing) history on every turn — cache reads/writes scale ~quad-
# ratically with turn count, and the 5-minute cache TTL expires across slow gaps
# (validation suites, persona fan-outs), re-writing the full prefix at 1.25x
# instead of reading it at 0.1x. "stage" starts a fresh session at each stage
# scope boundary (plan -> implement -> observe -> complete, plus task boundaries
# and observer-BLOCK -> implement) and hands off through files on disk, the same
# fresh-and-cheap pattern the observer already uses. Set to "run" for the legacy
# single pinned session.
SESSION_SCOPE="${NIGHT_SHIFT_SESSION_SCOPE:-stage}"
# Per-role model tiering. Concentrate the strongest model on the two low-token,
# high-judgment steps and use a cheaper model for the expensive middle:
#   - PLAN_MODEL: planning is few turns but the highest-leverage step (a bad plan
#     poisons the whole implement loop), so it defaults to opus.
#   - IMPLEMENT_MODEL: the test-first implement grind is where most tokens live
#     and the most constrained step (plan fixed, failing tests written), so it
#     defaults to the cheaper sonnet. The observe-request and completion turns
#     run here too (they are not judgment).
#   - OBSERVER_MODEL: the independent final gate runs once on fresh context (~cheap
#     to upgrade) and is the last line of defense before a human sees the work, so
#     it defaults to opus regardless of what the primary ran. On an observer BLOCK
#     the task returns to a fresh IMPLEMENT_MODEL session to fix the findings.
# These switch model only at stage-scope boundaries, which already start a fresh
# session, so the model is constant within a scope (resumes pass the same flag).
# Set any to "inherit" to use the CLI's startup model instead (e.g. a Claude Pro
# plan without Opus access). Only opt out of OBSERVER_MODEL if you must — it is
# the strong backstop that makes a cheaper primary safe.
PLAN_MODEL="${NIGHT_SHIFT_PLAN_MODEL:-opus}"
IMPLEMENT_MODEL="${NIGHT_SHIFT_IMPLEMENT_MODEL:-sonnet}"
# Design-fidelity implements (a spec with a ## Design Contract) are judgment-heavy
# (decompose a Figma design, reuse/build components, reconcile with real state), so
# the IMPLEMENT scope bumps to this stronger model. inherit/sonnet to override.
DESIGN_IMPLEMENT_MODEL="${NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL:-opus}"
OBSERVER_MODEL="${NIGHT_SHIFT_OBSERVER_MODEL:-opus}"
# Design-fidelity visual capture. OFF by default: the visual_review stage is a
# clean no-op SKIP unless this is 1 AND the spec has a `## Design Contract` AND
# the simulator/diff tooling is present (see scripts/lib/visual-capture.sh).
VISUAL_CAPTURE="${NIGHT_SHIFT_VISUAL_CAPTURE:-0}"
# Opt-in in-loop visual auto-repair. OFF by default: when 1, the visual_review stage
# repairs over-tolerance screens (engine-invoked) and commits a fix(visual) commit
# before handing the repaired tip to the observer. Requires the project's dev
# build/Metro; cleanly skips (proceeds unrepaired) if unavailable.
VISUAL_REPAIR="${NIGHT_SHIFT_VISUAL_REPAIR:-0}"
# (NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS / per-screen auto-repair attempts removed with
# the agent-driven repair loop: visual_review is now engine-invoked single-pass
# measure+report; the observer drives any repair via a fresh implement cycle.)
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
# shellcheck source=scripts/lib/visual-repair.sh
. "$NIGHT_SHIFT_LIB/visual-repair.sh"
# Opt-in device registry for parallel visual_review (inert unless
# NIGHT_SHIFT_DEVICE_REGISTRY=1). See scripts/lib/device-registry.sh.
# shellcheck source=scripts/lib/device-registry.sh
. "$NIGHT_SHIFT_LIB/device-registry.sh"
# Concurrency run-lock primitives (lock_is_stale/atomic_lock_acquire/acquire_lock/
# release_lock). Shared so device-registry.sh can reuse the atomic-claim idiom.
# shellcheck source=scripts/lib/locking.sh
. "$NIGHT_SHIFT_LIB/locking.sh"
# Rate-limit + run-recovery predicates (rate-limit reset math, recoverable/resumable
# state). See scripts/lib/recovery.sh.
# shellcheck source=scripts/lib/recovery.sh
. "$NIGHT_SHIFT_LIB/recovery.sh"
# Spec validation, path canonicalization, preflight readiness, and validation-
# command execution. See scripts/lib/preflight.sh.
# shellcheck source=scripts/lib/preflight.sh
. "$NIGHT_SHIFT_LIB/preflight.sh"
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
  scripts/night-shift.sh --list-optional-personas   # JSON manifest, no run
  scripts/night-shift.sh --preflight --project PATH --spec PATH  # JSON readiness, no run
  scripts/night-shift.sh --project PATH [--spec PATH] --resume    # resume a preserved blocked run

Claude runs the entire flow: stage-scoped primary sessions implement (a fresh
session per stage scope — plan, implement, observe — handing off through files
on disk to keep cost down; set NIGHT_SHIFT_SESSION_SCOPE=run for one pinned
session), the spec's review personas (selected by its Track + Review Profile)
review, and a fresh independent Claude session observes each candidate. Models are
tiered by role: plan on NIGHT_SHIFT_PLAN_MODEL (default opus), implement/observe-
request/completion on NIGHT_SHIFT_IMPLEMENT_MODEL (default sonnet) — but the implement
scope of a ## Design Contract spec bumps to NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL (default
opus) for design-fidelity work — personas on
NIGHT_SHIFT_PERSONA_MODEL (default sonnet), and the observer on
NIGHT_SHIFT_OBSERVER_MODEL (default opus); any "inherit" uses the startup model.
Runs use
explicit session IDs, local candidate commits, per-profile persona approvals, and
observer approval. Live fixture tests make paid Claude calls;
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
    --spec) [ "$#" -ge 2 ] || die "--spec requires a value"; SPEC="$2"; EXPLICIT_SPEC=1; shift 2 ;;
    --fixture-test) FIXTURE_TEST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --full-persona-live-test) FULL_PERSONA_LIVE_TEST=1; shift ;;
    --list-optional-personas) LIST_OPTIONAL_PERSONAS=1; shift ;;
    --preflight) PREFLIGHT=1; shift ;;
    --resume) RESUME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required executable not found: $1"
}

# Read-only manifest of the optional review personas and their auto-activating
# contract headings. The single source of truth is PERSONAS_OPTIONAL +
# optional_contract_heading (scripts/lib/personas.sh, sourced above), so adding a
# persona there flows through here with no extra edit. Consumed by the viewer to
# render its optional-persona toggles. `contractHeading` has no `##` prefix; the
# heading as it appears in a spec is `## <contractHeading>`.
emit_optional_personas_manifest() {
  local first=1 name heading old_ifs
  printf '{\n  "optional_personas": [\n'
  old_ifs="$IFS"; IFS='|'
  for name in $PERSONAS_OPTIONAL; do
    IFS="$old_ifs"
    heading="$(optional_contract_heading "$name")" || { IFS='|'; continue; }
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    {"name": %s, "contractHeading": %s}' \
      "$(printf '%s' "$name" | jq -R .)" "$(printf '%s' "$heading" | jq -R .)"
    IFS='|'
  done
  IFS="$old_ifs"
  printf '\n  ]\n}\n'
}

if [ "$LIST_OPTIONAL_PERSONAS" -eq 1 ]; then
  require_command jq
  emit_optional_personas_manifest
  exit 0
fi

json_schema_basic() {
  local kind="$1" file="$2"
  jq -e . "$file" >/dev/null 2>&1 || return 1
  case "$kind" in
    next-action)
      jq -e '
        type == "object" and
        ((keys | sort) == ["action","artifacts","reason","stage","task"]) and
        (.action | IN("RUN_PERSONAS","CREATE_CANDIDATE","REQUEST_OBSERVER","RUN_VISUAL","NEXT_TASK","BLOCKED","COMPLETE")) and
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
          ((keys | sort) == ["analysis","attempts","device","diff_image","diff_pct","pass","reference","screen","screenshot","state","tolerance","unmet_brief"]) and
          (.screen | type == "string" and length > 0) and
          (.state | type == "string" and length > 0) and
          (.device | type == "string" and length > 0) and
          (.reference | type == "string" and length > 0) and
          (.screenshot | type == "string" and length > 0) and
          (.diff_pct | type == "number" and . >= 0) and
          (.tolerance | type == "number" and . >= 0) and
          (.pass | type == "boolean") and
          (.analysis | type == "string") and
          (.attempts | type == "array" and all(.[];
            ((keys | sort) == ["analysis","attempt","diff_image","diff_pct","pass","screenshot"]) and
            (.attempt | type == "number" and floor == . and . >= 1) and
            (.diff_pct | type == "number" and . >= 0) and
            (.pass | type == "boolean") and
            (.analysis | type == "string") and
            (.screenshot | type == "string" and length > 0) and
            (.diff_image == null or (.diff_image | type == "string" and length > 0)))) and
          (.diff_image == null or (.diff_image | type == "string" and length > 0)) and
          (.unmet_brief | type == "array" and all(.[]; type == "string")) and
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

# Rate-limit detection/reset-timing + recovery-state predicates (is_rate_limit_response,
# rate_limit_reset_epoch, recoverable_rate_limit_state, resumable_blocked_state,
# wait_for_rate_limit_reset, …) now live in scripts/lib/recovery.sh (sourced above).

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

# All unchecked TODO specs in selection order — bugs first, then features — one
# per line. start_next_task walks these and picks the first one for THIS run's
# project, so a queued spec for another project is skipped (not a block).
list_unchecked_specs() {
  local todo="$1"
  [ -f "$todo" ] || return 0
  sed -nE 's/^- \[ \] bug:.*\(`([^`]+)`\).*/\1/p' "$todo"
  sed -nE 's/^- \[ \] feature:.*\(`([^`]+)`\).*/\1/p' "$todo"
}

limit_exceeded() {
  local stage_turns="$1" stage_elapsed="$2" task_turns="$3" task_elapsed="$4"
  [ "$stage_turns" -ge "$MAX_STAGE_TURNS" ] ||
    [ "$stage_elapsed" -ge "$MAX_STAGE_SECONDS" ] ||
    [ "$task_turns" -ge "$MAX_TASK_TURNS" ] ||
    [ "$task_elapsed" -ge "$MAX_TASK_SECONDS" ]
}

# Pure predicate: true when the consecutive malformed/absent-signal count has
# reached the cap and the run should block. Extracted (like limit_exceeded) so
# the loop's abort decision is unit-testable without the live model loop.
malformed_cap_reached() {
  [ "$1" -ge "$MAX_MALFORMED_SIGNALS" ]
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

# Append a finished turn's cost to the run's incremental ledger. The raw claude
# JSON is the only source of total_cost_usd/usage, so record it the instant the
# turn completes rather than re-reading raw files at archive time — a costly turn
# (notably the opus observer) is then never lost to a raw file that has since been
# rewritten, retried, or cleaned. A raw without total_cost_usd (rate-limit partial,
# non-JSON) contributes nothing and is not fatal.
record_cost() {
  local raw="$1" source="$2"
  [ -f "$raw" ] || return 0
  jq -c --arg source "$source" \
    'select(type == "object" and has("total_cost_usd")) |
     {source: $source, total_cost_usd, num_turns: (.num_turns // null), usage: (.usage // null)}' \
    "$raw" >>"$RUN_ROOT/cost-ledger.jsonl" 2>/dev/null || true
}

compact_success() {
  local run_dir="$1" run_id="$2" archive ledger
  archive="$run_dir/archive/$run_id"
  mkdir -p "$archive"
  [ -f "$run_dir/state.json" ] && cp "$run_dir/state.json" "$archive/state.json"
  [ -d "$run_dir/validated" ] && cp -R "$run_dir/validated" "$archive/validated"
  [ -f "$run_dir/summary.json" ] && cp "$run_dir/summary.json" "$archive/summary.json"
  # Preserve per-turn cost telemetry built incrementally by record_cost (every
  # primary turn + the observer). It is independent of the raw files, so it
  # survives even when a raw is gone by archive time; copy it and add a TOTAL row.
  ledger="$archive/costs.jsonl"
  [ -f "$run_dir/cost-ledger.jsonl" ] && cp "$run_dir/cost-ledger.jsonl" "$ledger"
  if [ -s "$ledger" ]; then
    # Compute the TOTAL row into a temp first, then append: reading and appending
    # the same file in one pipeline (jq ... "$ledger" >>"$ledger") has undefined
    # ordering and could silently drop the row. The append is best-effort.
    local total_tmp="$ledger.total.$$"
    if jq -sc '{source: "TOTAL", total_cost_usd: (map(.total_cost_usd) | add), records: length}' \
      "$ledger" >"$total_tmp" 2>/dev/null; then
      cat "$total_tmp" >>"$ledger"
    fi
    rm -f "$total_tmp"
  fi
  for entry in "$run_dir"/* "$run_dir"/.[!.]* "$run_dir"/..?*; do
    [ -e "$entry" ] || continue
    [ "$entry" = "$run_dir/archive" ] || rm -rf "$entry"
  done
}

# Spec validation + path canonicalization + launch-readiness preflight + validation-
# command execution/evidence (canonical_dir, validate_spec, emit_preflight,
# validate_spec_project, run_validation_commands, …) now live in scripts/lib/preflight.sh.

# Concurrency run-lock (F1) — lock_is_stale / atomic_lock_acquire / acquire_lock /
# release_lock now live in scripts/lib/locking.sh (sourced above), shared with
# device-registry.sh which reuses the atomic-claim idiom.

state_set() {
  local filter="$1"
  shift
  local tmp="$STATE.tmp.$$"
  jq "$@" "$filter" "$STATE" >"$tmp" && mv "$tmp" "$STATE" ||
    die "failed to update run state; preserved at ${RUN_ROOT:-unknown}"
}

# Pure predicate: return 0 if $1 is a non-negative integer string, 1 otherwise.
# Used by state_int to validate jq output before feeding it into $((...)).
is_valid_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Read a numeric field from $STATE by jq path, validate it is a non-negative
# integer, and echo the value.  Returns 0 on success, 1 on null/non-numeric.
# IMPORTANT: this function is always called inside a command substitution
# $(...), so calling block_run / exit here would only kill the subshell — the
# parent would continue with an empty value and the limit check would be
# silently bypassed.  Instead, the CALLER must check the return code and block:
#
#   local x; x="$(state_int '.field')" || block_run "..."
#
# A plain-assignment's exit status IS the command-substitution's exit status,
# so this form correctly triggers block_run in the parent shell.
# Usage: state_int '.field_name'
state_int() {
  local path="$1" val
  val="$(jq -r "${path} // empty" "$STATE" 2>/dev/null)"
  if ! is_valid_int "$val"; then
    printf '' # emit nothing so the caller gets an empty string
    return 1
  fi
  printf '%s' "$val"
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
  # -z: NUL-delimited, paths are literal/unquoted (no C-escape quoting for
  # spaces or unicode). Porcelain -z format: each record is <XY><SP><path><NUL>
  # and for renames the OLD path follows as a second NUL-terminated field.
  git -C "$PROJECT" status --porcelain=v1 -z >"$BASE_STATUS"
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
      stage_counters:{planning:0},stage_started:{planning:$epoch},
      malformed_signal_consecutive:0
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
  test_first_exit="$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")"
  [ "$test_first_exit" -ne 127 ] ||
    block_run "test-first command was not found (exit 127); fix the toolchain before running"
  if [ "$test_first_exit" -eq 0 ]; then
    # Green at baseline: the spec modifies an already-tested module, so the named test
    # cannot be red before any change exists. Defer the red proof to a red-against-base
    # overlay after implementation (verify_candidate): the candidate's updated test
    # files must fail against BASE production code. This keeps the red→green guarantee
    # wrapper-owned while supporting modify-existing-tested-code features.
    state_set '.test_first_baseline_green=true'
    log "test-first passes at baseline; modify-mode — red is verified against base after implementation"
  else
    state_set '.test_first_baseline_green=false'
  fi
  state_set '.baseline_complete=true'
}

recover_run() {
  local status recovery_raw pt resume_block=0
  RUN_ROOT="$PROJECT/.night-shift"
  STATE="$RUN_ROOT/state.json"
  [ -f "$STATE" ] || return 1
  status="$(jq -r '.status' "$STATE")"
  # Validate .primary_turns into a local first so the || fires in THIS shell
  # (state_int returns non-zero on bad input; a plain assignment's exit status
  # IS the $(...) exit status, which block_run needs to see in the parent).
  pt="$(state_int '.primary_turns')" ||
    block_run "state field .primary_turns is not a valid integer; state may be corrupt"
  recovery_raw="$RUN_ROOT/raw/primary-$(( pt + 1 )).json"
  if [ "$status" != "running" ]; then
    if recoverable_rate_limit_state "$STATE" "$recovery_raw"; then
      :
    elif [ "$RESUME" -eq 1 ] && resumable_blocked_state "$STATE"; then
      resume_block=1
    else
      return 1
    fi
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
  if [ "$resume_block" -eq 1 ]; then
    # Operator-initiated --resume of a logic-blocked run: clear the block and rebase
    # the clocks. plan/implementation approvals and the recorded stage are kept, so
    # the primary re-enters that stage and retries only the step that blocked.
    log "resuming blocked run $RUN_ID at stage $(jq -r '.stage' "$STATE") (--resume); clearing block_reason"
    state_set '.status="running" | del(.block_reason) |
      .stage_started_at=$now | .task_started_at=$now | .stage_started[.stage]=$now | .updated_at=$iso' \
      --argjson now "$(now_epoch)" --arg iso "$(now_iso)"
  elif [ "$status" != "running" ]; then
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

# Pure: which personas must produce results for the next review round. On the
# first round of a stage (no pending blockers, or blockers recorded for a
# different stage) it is the full active set; after a BLOCK round only the
# blockers re-run. Approvals already earned do not expire — each open finding
# is verified resolved by the persona that raised it, so re-running approvers
# is pure waste.
review_round_set() {
  local full="$1" pending="$2" pending_stage="$3" stage="$4"
  if [ -n "$pending" ] && [ -n "$pending_stage" ] && [ "$pending_stage" = "$stage" ]; then
    printf '%s' "$pending"
  else
    printf '%s' "$full"
  fi
}

# Pure: the session scope a stage belongs to. Stages within one scope share a
# primary session; crossing scopes starts a fresh one. An unrecognized stage maps
# to itself, so any new stage is its own scope (a safe default that errs toward a
# reset rather than silently extending a session).
stage_session_scope() {
  case "$1" in
    planning|plan_review) printf 'plan' ;;
    implementation|implementation_review|implementation_ready) printf 'implement' ;;
    visual_review) printf 'visual' ;;
    observer_review) printf 'observe' ;;
    completion) printf 'complete' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Pure: exit 0 if moving OLD_STAGE -> NEW_STAGE must clear the pinned session.
# In "run" mode the session is never cleared (legacy single pinned session). In
# "stage" mode the session is cleared whenever the stage scope changes.
session_boundary() {
  local old_stage="$1" new_stage="$2" mode="$3"
  [ "$mode" = "stage" ] || return 1
  [ "$(stage_session_scope "$old_stage")" != "$(stage_session_scope "$new_stage")" ]
}

# Pure: print the "--model NAME" CLI argument for a model, or nothing for
# "inherit"/empty (use the CLI's startup model). Printed unquoted at the call
# site so it word-splits into argv — safe under bash 3.2 + set -u, where an empty
# array expansion would trip "unbound variable" (model names never contain spaces).
model_flag() {
  case "$1" in
    inherit|"") ;;
    *) printf -- '--model %s' "$1" ;;
  esac
}

# True when the spec declares a ## Design Contract (the marker that also activates the
# Design Fidelity Reviewer + visual_review). Drives the build-from-Figma procedure and
# the opus implement bump. Independent of VISUAL_CAPTURE (the build is design-directed
# even when capture tooling is absent). Empty/missing path -> false.
spec_has_design_contract() {
  [ -n "${1:-}" ] && grep -Eq '^## Design Contract([ \t]|$)' "$1" 2>/dev/null
}

# Pure: the model the primary should run on in a given session scope. Planning is
# low-token, high-leverage judgment (a bad plan poisons the whole implement loop),
# so it gets PLAN_MODEL; everything after the plan — the implement grind, the
# observe-request turn, and completion — is constrained execution on the cheaper
# IMPLEMENT_MODEL, EXCEPT the implement scope of a ## Design Contract spec, which is
# judgment-heavy design-fidelity work and bumps to DESIGN_IMPLEMENT_MODEL (opus). The
# strong independent judgment in the observe scope is the separate observer
# (OBSERVER_MODEL), not this primary turn. Unknown scope ->
# "inherit" (force no model; safe default).
stage_model() {
  case "$1" in
    plan) printf '%s' "$PLAN_MODEL" ;;
    implement)
      if spec_has_design_contract "${SPEC:-}"; then printf '%s' "$DESIGN_IMPLEMENT_MODEL"
      else printf '%s' "$IMPLEMENT_MODEL"; fi ;;
    visual|observe|complete) printf '%s' "$IMPLEMENT_MODEL" ;;
    *) printf 'inherit' ;;
  esac
}

primary_prompt() {
  local prompt="$1" stage turns remaining persona_list persona_count active
  local review_stage_name pending pending_stage review_set reround_note
  local session primary_turns handoff_note design_build_note spec_base expected
  stage="$(jq -r '.stage' "$STATE")"
  expected="$(expected_action "$stage")"
  turns="$(jq -r '.stage_turns' "$STATE")"
  remaining=$((MAX_STAGE_TURNS - turns))
  active="$(resolve_active_personas "$SPEC")" || block_run "cannot resolve review profile for $SPEC"
  case "$stage" in
    planning|plan_review) review_stage_name="plan" ;;
    implementation|implementation_review) review_stage_name="implementation" ;;
    *) review_stage_name="" ;;
  esac
  pending="$(jq -r '.pending_personas // empty' "$STATE")"
  pending_stage="$(jq -r '.pending_stage // empty' "$STATE")"
  review_set="$(review_round_set "$active" "$pending" "$pending_stage" "$review_stage_name")"
  persona_list="$(printf '%s' "$review_set" | tr '|' '\n' | sed 's/^/  - /')"
  persona_count="$(printf '%s' "$review_set" | tr '|' '\n' | grep -c .)"
  reround_note=""
  if [ "$review_set" != "$active" ]; then
    reround_note="
Re-review round: the personas listed above are the only ones with open findings
from the previous round. Re-run ONLY them — each verifies its own findings are
resolved. Approvals from the other active personas carry forward; do not re-run
approved personas."
  fi
  # A fresh stage session (empty session after at least one prior turn) carries no
  # in-memory context. Point it at the files that hold the run state so it picks up
  # where the previous stage left off instead of re-planning or redoing resolved
  # work. The persona round dirs use the same layout run_observer reads.
  session="$(jq -r '.session_id // empty' "$STATE")"
  primary_turns="$(jq -r '.primary_turns' "$STATE")"
  spec_base="$(basename "$SPEC" .md)"
  handoff_note=""
  if [ -z "$session" ] && [ "$primary_turns" -gt 0 ]; then
    handoff_note="
This is a FRESH stage session — you have no memory of earlier stages. All prior
context lives ONLY in files; trust them over any assumption, and do NOT re-plan
approved work or redo findings already resolved. Read what you need:
  - the spec ($SPEC) — the requirements;
  - the approved plan at .night-shift/control/plan.md — your own plan from the
    planning stage;
  - the latest persona reviews under
    .night-shift/validated/personas/$spec_base/<stage>/round-N/ (highest N);
  - the latest observer verdict at .night-shift/validated/observer-*.json, if any;
  - the in-progress implementation IS the working tree — diff it against the base
    commit $BASE_COMMIT to see exactly what has been done so far.
"
  fi
  design_build_note=""
  case "$stage" in
    implementation|implementation_review)
      if spec_has_design_contract "$SPEC"; then
        design_build_note="
Design-fidelity build (this spec has a \`## Design Contract\`). You are building this
screen to match its Figma design. Before/while implementing:
1. Pull the design via the Figma MCP (never a token): mcp__figma__get_figma_data for the
   node's structure (layout, text, sizes, colors, typography, tokens) AND its Dev Mode
   annotations / notes / comments, and mcp__figma__download_figma_images for the frame
   image — open and VIEW it. Treat the annotations and comments as requirements (states,
   spacing rationale, behavior), not just the pixels.
2. Decompose the design into a component breakdown.
3. Reuse what exists: Grep/Glob src/ui/components and src/features/* for components that
   already satisfy each piece and REUSE them; build only what is genuinely missing.
4. Build the missing components to the design (the project's tokens/sizes/spacing from
   src/ui), following the layer boundaries.
5. Assemble them on the screen, wired to real app state (per this spec) — do NOT hardcode
   the Figma's sample values.
6. Keep tsc/eslint/tests green. The engine's visual_review then pixel-diffs your screen
   against the Figma image and auto-repairs the residual — get the structure + tokens
   right here; it tightens the pixels.
"
      fi ;;
  esac
  cat >"$prompt" <<EOF
You are the fixed $PRIMARY primary for night-shift run $RUN_ID.
Project: $PROJECT
Task spec: $SPEC
Current stage: $stage
Base commit: $BASE_COMMIT
$design_build_note
Read $WORKSPACE_ROOT/AGENTS.md and $WORKSPACE_ROOT/AGENT_LOOP.md, then continue
the task in this session from the state on disk. Preserve baseline dirty work.
You own planning, implementation, resolving review findings, validation,
candidate commits, documentation, and task completion. The ENGINE runs the
review personas itself; you do not coordinate or run reviewers.

Maintain the authoritative plan at .night-shift/control/plan.md: write it during
planning (acceptance criteria, approach, file-level steps) and keep it current as
work proceeds. It is the handoff record across stage sessions and the "current
plan" section of the RUN_PERSONAS review bundle.
$handoff_note
On the next RUN_PERSONAS action the ENGINE runs these $persona_count independent
review personas itself (you do NOT run them or write their results):
$persona_list
$reround_note
Stage gate — you are at stage "$stage". The wrapper advances stages ONE step at a
time, so the only valid signal from this stage is: $expected (or BLOCKED if you
truly cannot proceed). Do NOT skip ahead to a later action. In the implementation
stage this means: implement the code, run the implementation personas, then emit
RUN_PERSONAS — the wrapper moves you to the candidate (CREATE_CANDIDATE) and the
independent observer (REQUEST_OBSERVER) on later turns. Do not create the
candidate commit or request the observer yourself from an earlier stage; any
out-of-stage signal is rejected and wastes a turn.

Before ending this turn, write a fresh JSON signal to:
  .night-shift/control/next-action.json
It must validate against $SCHEMA_DIR/next-action.json. "task" must equal
$SPEC. "artifacts" lists only project-relative files (no absolute paths, no
"..") the wrapper must consume for the chosen action:

- RUN_PERSONAS: ensure the authoritative plan at .night-shift/control/plan.md is
  current (it is the plan the reviewers judge), then signal RUN_PERSONAS with an
  EMPTY "artifacts" array. The ENGINE assembles the review bundle (spec, plan, the
  diff against the base commit, validation output) and runs each of the
  $persona_count active personas as an independent, context-isolated sub-agent
  itself — you do NOT run personas, write persona result files, or list them. On a
  re-review round, resolve every finding the engine reported last round before you
  signal RUN_PERSONAS again.
- CREATE_CANDIDATE: create ONE local commit on the feature branch containing
  only files this run changed (never baseline dirty paths). Then write an
  execution-evidence file validating against $SCHEMA_DIR/execution-evidence.json
  whose baseline, test_first, and final_validation match the spec's commands.
  List that evidence file in artifacts.
- REQUEST_OBSERVER: list the candidate evidence, relevant tests, and docs the
  fresh observer needs. The wrapper runs the observer; do not run it yourself.
- RUN_VISUAL: only from the visual_review stage. The ENGINE itself runs the
  design-fidelity capture (Figma reference -> iOS-simulator screenshot -> pixel
  diff) and produces + validates $RUN_ROOT/validated/visual-diff-<NAME>.json, then
  hands the candidate and report to the observer. You do NOT run capture, edit
  screens, or write the report yourself — simply signal RUN_VISUAL with an empty
  "artifacts" array to let the engine perform the capture step. (If the capture
  tooling is unavailable the engine cleanly skips and proceeds; per-screen
  pass/fail is the observer's concern.)
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
  # Declare then assign separately so a jq failure on $STATE is not masked by
  # local's own (always-zero) exit status — the discipline used in enforce_limits
  # and state_int.
  local turn prompt raw
  turn="$(jq -r '.primary_turns + 1' "$STATE")" ||
    block_run "could not read .primary_turns from state; state may be corrupt"
  prompt="$RUN_ROOT/prompts/primary-$turn.txt"
  raw="$RUN_ROOT/raw/primary-$turn.json"
  local session emitted rc model
  # Consecutive 429-without-success counter. Persisted in state so recovery
  # after a crash picks up the count; reset to 0 on the first clean turn.
  # Cap: 5 consecutive rate-limit resets with no successful primary turn → block
  # for manual resume to prevent an infinite sleep-and-retry spiral.
  local rate_limit_cap=5 consecutive_429
  consecutive_429="$(jq -r '.rate_limit_consecutive // 0' "$STATE" 2>/dev/null)"
  is_valid_int "$consecutive_429" || consecutive_429=0
  enforce_limits
  archive_old_signal
  primary_prompt "$prompt"
  session="$(jq -r '.session_id // empty' "$STATE")"
  # Model for this stage's scope, pinned only on a FRESH start. A session is born
  # inside one scope and the model is constant within a scope (a scope boundary
  # already nulls .session_id and starts a fresh session), so a --resume — whether
  # a turn-to-turn continue, a rate-limit retry, or recovery of a blocked run —
  # already carries its creation model and must NOT re-pass --model. This keeps
  # resume robust regardless of whether the CLI accepts --model alongside --resume.
  model="$(stage_model "$(stage_session_scope "$(jq -r '.stage' "$STATE")")")"
  log "primary turn $(jq -r '.primary_turns + 1' "$STATE") · stage $(jq -r '.stage' "$STATE") · stage turn $(jq -r '.stage_turns + 1' "$STATE")/$MAX_STAGE_TURNS · task turn $(jq -r '.task_turns + 1' "$STATE")/$MAX_TASK_TURNS"
  while :; do
    rc=0
    # The primary must edit files and run commands unattended, so it runs in a
    # non-interactive permission mode. Safe because the run is confined to a
    # feature branch and the wrapper forbids push/merge/destructive Git ops and
    # excludes pre-existing dirt from candidate commits.
    if [ -z "$session" ]; then
      # model_flag must word-split into `--model X` (or vanish when empty).
      # shellcheck disable=SC2046
      (cd "$PROJECT" && claude -p $(model_flag "$model") --permission-mode bypassPermissions \
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
      consecutive_429=$((consecutive_429 + 1))
      # Guard against an infinite sleep spiral: if the rate limit is not
      # clearing after $rate_limit_cap consecutive resets with no successful
      # turn in between, block for manual resume. This catches a misbehaving
      # session that keeps hitting the limit after each wait completes.
      [ "$consecutive_429" -lt "$rate_limit_cap" ] ||
        block_run "rate limit not clearing after $consecutive_429 consecutive resets; resume manually once the limit clears"
      session="$emitted"
      state_set '.session_id=$session | .rate_limit_consecutive=$n | .updated_at=$now' \
        --arg session "$session" --argjson n "$consecutive_429" --arg now "$(now_iso)"
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
    .rate_limit_consecutive=0 |
    .updated_at=$now
  ' --arg session "$emitted" --arg now "$(now_iso)"
  record_cost "$raw" "$(basename "$raw")"
  enforce_elapsed_limits
}

enforce_limits() {
  local now stage_elapsed task_elapsed stage_turns task_turns
  local stage_started task_started
  now="$(now_epoch)"
  # Validate each field into a local before doing arithmetic or comparisons.
  # state_int returns non-zero on null/corrupt input; a plain assignment's exit
  # status IS the $(...) exit status, so || fires in THIS shell — block_run is
  # reached in the parent, not swallowed by a subshell.  Declare locals
  # separately from the guarded assignments so `local x="$(...)"` does not
  # mask the exit status (local always returns 0 in bash/dash/sh).
  stage_started="$(state_int '.stage_started_at')" ||
    block_run "state field .stage_started_at is not a valid integer; state may be corrupt"
  task_started="$(state_int '.task_started_at')" ||
    block_run "state field .task_started_at is not a valid integer; state may be corrupt"
  stage_turns="$(state_int '.stage_turns')" ||
    block_run "state field .stage_turns is not a valid integer; state may be corrupt"
  task_turns="$(state_int '.task_turns')" ||
    block_run "state field .task_turns is not a valid integer; state may be corrupt"
  stage_elapsed=$((now - stage_started))
  task_elapsed=$((now - task_started))
  if limit_exceeded "$stage_turns" "$stage_elapsed" "$task_turns" "$task_elapsed"; then
    block_run "turn/time limit reached (stage ${stage_turns}/${MAX_STAGE_TURNS}, task ${task_turns}/${MAX_TASK_TURNS})"
  fi
}

enforce_elapsed_limits() {
  local now stage_elapsed task_elapsed
  local stage_started task_started
  now="$(now_epoch)"
  # Same pattern as enforce_limits: validate into locals first, then do
  # arithmetic on the validated values in the parent shell.
  stage_started="$(state_int '.stage_started_at')" ||
    block_run "state field .stage_started_at is not a valid integer; state may be corrupt"
  task_started="$(state_int '.task_started_at')" ||
    block_run "state field .task_started_at is not a valid integer; state may be corrupt"
  stage_elapsed=$((now - stage_started))
  task_elapsed=$((now - task_started))
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
  local old_stage session_clear='' scope_reset=''
  old_stage="$(jq -r '.stage' "$STATE")"
  # Crossing a session-scope boundary clears the pinned session so the next
  # primary turn starts fresh and hands off through files (see SESSION_SCOPE).
  if session_boundary "$old_stage" "$1" "$SESSION_SCOPE"; then
    session_clear=' | .session_id=null'
    log "stage $old_stage → $1: starting a fresh stage session"
  fi
  # Persona review rounds are numbered PER stage scope: run_personas writes/reads
  # round-$((review_round+1)) and the primary writes the latest round of the
  # current stage. review_round must therefore reset to 0 when the stage SCOPE
  # changes — otherwise a plan re-review round leaves the counter ahead, so the
  # implementation gate reads an empty round-N dir the primary never wrote to (its
  # results are in round-1) and blocks; --resume only bumps the counter further.
  # Scope-based (via stage_session_scope), not session-based, so it also holds in
  # SESSION_SCOPE=run. Carried re-review pending belongs to the old scope, so drop
  # it too. (GH #18)
  if [ "$(stage_session_scope "$old_stage")" != "$(stage_session_scope "$1")" ]; then
    scope_reset=' | .review_round=0 | del(.pending_personas, .pending_stage)'
  fi
  state_set "
    .stage_counters[.stage]=.stage_turns |
    .stage=\$stage |
    .stage_turns=(.stage_counters[\$stage] // 0) |
    .stage_started_at=\$epoch |
    .stage_started[\$stage]=\$epoch |
    .updated_at=\$now${session_clear}${scope_reset}
  " \
    --arg stage "$1" --argjson epoch "$(now_epoch)" --arg now "$(now_iso)"
}

transition_allowed() {
  case "$1:$2" in
    planning:RUN_PERSONAS|plan_review:RUN_PERSONAS|implementation:RUN_PERSONAS|implementation_review:RUN_PERSONAS|implementation_ready:CREATE_CANDIDATE|visual_review:RUN_VISUAL|observer_review:REQUEST_OBSERVER|completion:NEXT_TASK|completion:COMPLETE|*:BLOCKED) return 0 ;;
    *) return 1 ;;
  esac
}

# Pure: the single forward action a stage may emit (BLOCKED is always also valid).
# Mirrors transition_allowed so the prompt can tell the primary exactly which
# signal to write — the wrapper advances stages one step at a time, so a primary
# that skips ahead (e.g. REQUEST_OBSERVER straight from implementation) is blocked.
# Keep in sync with transition_allowed above.
expected_action() {
  case "$1" in
    planning|plan_review|implementation|implementation_review) printf 'RUN_PERSONAS' ;;
    implementation_ready) printf 'CREATE_CANDIDATE' ;;
    visual_review) printf 'RUN_VISUAL' ;;
    observer_review) printf 'REQUEST_OBSERVER' ;;
    completion) printf 'NEXT_TASK or COMPLETE' ;;
    *) printf 'BLOCKED' ;;
  esac
}

block_run() {
  local reason="$1"
  cleanup_validation_worktree >/dev/null 2>&1 || reason="$reason; validation worktree cleanup also failed"
  cleanup_observer_tmp
  # Record the blocked status best-effort: if state.json is corrupt, state_set
  # itself calls die — which would exit BEFORE this block_run's die with the
  # real reason. Guard the state write so its failure is tolerated and the
  # original reason always surfaces in the final die below.
  if [ -f "${STATE:-}" ]; then
    ( state_set '.status="blocked" | .block_reason=$reason | .updated_at=$now' \
        --arg reason "$reason" --arg now "$(now_iso)" ) 2>/dev/null || true
  fi
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

# Remove the neutral cwd the observer ran from (see invoke_observer_once). It is
# per-RUN_ID and reused across observer attempts, so it is only cleaned at the
# run's terminal paths (block_run / complete_run). Best-effort and idempotent.
cleanup_observer_tmp() {
  [ -n "${RUN_ID:-}" ] || return 0
  rm -rf "${TMPDIR:-/tmp}/night-shift-observer-$RUN_ID" 2>/dev/null || true
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

# Normalize a near-miss persona-review record to the canonical schema shape so the
# round gate (which reads .status) accepts a genuine APPROVE/BLOCK result instead
# of rejecting it with a confusing downstream message ("BLOCK by <empty>"). The
# primary occasionally writes `verdict` for the schema's `status`, and omits the
# always-empty `commit`/`documentation_changes` on a clean APPROVE. Pure: reads $1,
# prints normalized JSON; a non-record (review bundle, plan doc) passes through and
# then fails json_schema_basic, exactly as before. (GH #20)
normalize_persona_result() {
  jq '
    (if (has("verdict") and (has("status") | not)) then (.status = .verdict | del(.verdict)) else . end)
    | (if has("commit") then . else .commit = null end)
    | (if has("documentation_changes") then . else .documentation_changes = [] end)
  ' "$1"
}

# --- engine-spawned persona review (provenance: the WRAPPER runs each persona) --
# Personas are run by the engine itself, not the primary, so a primary cannot
# fabricate review approvals: it only signals RUN_PERSONAS (empty artifacts) and
# the wrapper assembles the bundle, spawns each persona as an independent,
# context-isolated sub-agent (mirroring the observer), stamps the result's
# identity, validates it, and writes it into the round dir.

persona_doc() {
  case "$1" in
    web) printf '%s' "$WORKSPACE_ROOT/docs/review-personas-web.md" ;;
    *)   printf '%s' "$WORKSPACE_ROOT/docs/review-personas.md" ;;
  esac
}

# Slug a persona name to a filesystem-safe, collision-free token. "TypeScript &
# Code Quality Expert" -> "typescript-code-quality-expert".
persona_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' |
    sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# Extract a persona's review-lens prose from the track's persona doc (falling back
# to the other doc, since the node track reuses backend personas documented under
# web). Matches a markdown heading whose text — after stripping #s and an optional
# "N. " ordinal — equals the persona name, and prints the section body up to the
# next heading. Empty output is acceptable: persona_prompt falls back to a generic
# instruction so a missing doc never blocks a run.
persona_lens() {
  local persona="$1" track="$2" doc body
  for doc in "$(persona_doc "$track")" \
             "$WORKSPACE_ROOT/docs/review-personas.md" \
             "$WORKSPACE_ROOT/docs/review-personas-web.md"; do
    [ -f "$doc" ] || continue
    body="$(awk -v name="$persona" '
      /^#{1,6}[ \t]/ {
        h=$0; sub(/^#{1,6}[ \t]+/, "", h); sub(/^[0-9]+\.[ \t]+/, "", h);
        sub(/[ \t]+$/, "", h);
        if (insec) exit;
        if (h == name) { insec=1; next }
        next
      }
      insec { print }
    ' "$doc")"
    if [ -n "$body" ]; then printf '%s' "$body"; return 0; fi
  done
  return 0
}

# Assemble the review bundle the engine hands every persona: the spec, the
# approved plan, and (for implementation) the diff against the base commit plus
# the latest validation output. Wrapper-computed, so the evidence the reviewers
# judge is independent of anything the primary chooses to surface.
assemble_review_bundle() {
  local stage="$1" out="$2"
  {
    printf '# Review bundle (engine-assembled) — stage: %s\n\n' "$stage"
    printf '## Task spec\n\n'
    cat "$SPEC"
    if [ -s "$RUN_ROOT/control/plan.md" ]; then
      printf '\n\n## Approved plan\n\n'
      cat "$RUN_ROOT/control/plan.md"
    fi
    if [ "$stage" = "implementation" ]; then
      printf '\n\n## Implementation diff against base commit %s\n\n```diff\n' "$BASE_COMMIT"
      git -C "$PROJECT" diff "$BASE_COMMIT" -- . 2>/dev/null
      printf '```\n'
      if [ -s "$RUN_ROOT/validated/baseline.json" ]; then
        printf '\n## Baseline validation output\n\n```json\n'
        cat "$RUN_ROOT/validated/baseline.json"
        printf '\n```\n'
      fi
    fi
  } >"$out"
}

# The prompt for one engine-spawned persona. Mirrors observer_prompt: judge only
# the supplied bundle, end with a single fenced json verdict block.
persona_prompt() {
  local persona="$1" stage="$2" bundle="$3" lens="$4"
  [ -n "$lens" ] || lens="Review strictly within the concerns of \"$persona\"; raise only issues a \"$persona\" would own."
  cat <<EOF
You are the "$persona" review persona for night-shift run $RUN_ID, independently
reviewing another Claude session's $stage work. You share no context with the
implementer and cannot see the repository — judge ONLY the review bundle below,
strictly through your persona's lens. This is unattended; never ask questions.

Your review lens:
$lens

Reason briefly if you must, then END YOUR REPLY with exactly one fenced code
block tagged json containing your verdict and NOTHING after it:

\`\`\`json
{"persona":"$persona","stage":"$stage","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}
\`\`\`

Rules for that JSON object:
- Use ONLY these six keys. "status" is EXACTLY "APPROVE" or "BLOCK" — APPROVE with
  an empty "findings" array, or BLOCK with one or more findings. Every concern you
  have is a blocker; an APPROVE carries no findings.
- Each finding has a stable "id" matching ^[A-Z][A-Z0-9_-]*-[0-9]{3,}$ (e.g.
  UX-001), concrete "evidence", and a binary "required_change".
  "documentation_changes" is an array of strings.

REVIEW BUNDLE:
$(cat "$bundle")
EOF
}

# One persona sub-agent, context-isolated like the observer: a fresh Claude
# session launched from a neutral empty dir (no repo access), its JSON verdict
# extracted from stdout. A discrete seam the fixtures override to test the spawn
# loop deterministically without a live model.
invoke_persona_once() {
  local persona="$1" stage="$2" bundle="$3" out="$4" raw="$5" neutral lens
  neutral="${TMPDIR:-/tmp}/night-shift-persona-$RUN_ID"
  mkdir -p "$neutral"
  lens="$(persona_lens "$persona" "$(spec_track "$SPEC")")"
  # model_flag word-splits into `--model X` (or nothing). No --allowedTools: it is
  # variadic and would swallow the prompt argument (see invoke_observer_once).
  # shellcheck disable=SC2046
  (cd "$neutral" && claude -p $(model_flag "$PERSONA_MODEL") --output-format json \
    "$(persona_prompt "$persona" "$stage" "$bundle" "$lens")") >"$raw" 2>"${raw}.err" || return 1
  extract_claude_structured "$raw" "$out"
}

# Spawn every persona in $expected_set, writing one validated result per persona
# into $result_dir. The wrapper STAMPS .persona/.stage authoritatively (identity =
# who the engine asked, not a spoofable field) then normalizes + schema-validates;
# a persona that cannot return a valid review after a retry blocks the run.
spawn_personas() {
  local result_dir="$1" persona_stage="$2" expected_set="$3"
  local bundle persona slug out raw tmp idd norm tries old_ifs
  bundle="$RUN_ROOT/control/review-bundle.md"
  assemble_review_bundle "$persona_stage" "$bundle"
  old_ifs="$IFS"; IFS='|'
  for persona in $expected_set; do
    IFS="$old_ifs"
    slug="$(persona_slug "$persona")"
    out="$result_dir/$slug.json"
    raw="$RUN_ROOT/raw/persona-$persona_stage-$slug.json"
    tmp="$result_dir/.spawn-$slug.$$"; idd="$tmp.id"; norm="$tmp.norm"
    tries=0
    while :; do
      tries=$((tries + 1))
      if invoke_persona_once "$persona" "$persona_stage" "$bundle" "$tmp" "$raw" &&
        jq --arg p "$persona" --arg s "$persona_stage" '.persona=$p | .stage=$s' "$tmp" >"$idd" 2>/dev/null &&
        normalize_persona_result "$idd" >"$norm" 2>/dev/null &&
        json_schema_basic persona-review "$norm"; then
        mv "$norm" "$out"
        rm -f "$tmp" "$idd"
        record_cost "$raw" "$(basename "$raw")"
        log "persona ($persona_stage): $persona → $(jq -r '.status' "$out")"
        break
      fi
      rm -f "$tmp" "$idd" "$norm"
      [ "$tries" -lt 2 ] ||
        block_run "engine-spawned persona '$persona' did not return a valid $persona_stage review after $tries attempts"
    done
    IFS='|'
  done
  IFS="$old_ifs"
}

run_personas() {
  local review_stage persona_stage result_dir
  review_stage="$(jq -r '.stage' "$STATE")"
  case "$review_stage" in
    planning|plan_review) persona_stage="plan"; set_stage plan_review ;;
    implementation|implementation_review) persona_stage="implementation"; set_stage implementation_review ;;
    *) block_run "RUN_PERSONAS is invalid from stage $review_stage" ;;
  esac
  result_dir="$RUN_ROOT/validated/personas/$(basename "$SPEC" .md)/$persona_stage/round-$(( $(jq -r '.review_round' "$STATE") + 1 ))"
  mkdir -p "$result_dir"
  state_set '.review_round += 1'

  local full_set expected_set expected_count pending pending_stage
  full_set="$(resolve_active_personas "$SPEC")" ||
    block_run "cannot resolve the active persona set for $SPEC"
  # Re-review rounds only require results from the personas that blocked the
  # previous round (recorded in state as pending); earlier approvals carry
  # forward. The first round of each stage always requires the full active set.
  pending="$(jq -r '.pending_personas // empty' "$STATE")"
  pending_stage="$(jq -r '.pending_stage // empty' "$STATE")"
  expected_set="$(review_round_set "$full_set" "$pending" "$pending_stage" "$persona_stage")"
  expected_count="$(printf '%s' "$expected_set" | tr '|' '\n' | grep -c .)"

  # The ENGINE — not the primary — spawns each active persona as an independent,
  # context-isolated sub-agent and writes the validated result into the round dir.
  # This is the provenance guarantee that closes the self-report hole: the gate
  # below judges results the wrapper produced (the primary only signals
  # RUN_PERSONAS with no artifacts), so a cost-cutting primary cannot fabricate
  # persona approvals. Mirrors the independent-observer spawn.
  spawn_personas "$result_dir" "$persona_stage" "$expected_set"

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
    blocked="$(find "$result_dir" -type f -name '*.json' -exec jq -r 'select(.status=="BLOCK").persona' {} \; | paste -sd '|' -)"
    log "personas ($persona_stage): BLOCK by $(printf '%s' "$blocked" | sed 's/|/, /g') — primary must resolve"
    # Only the blockers re-run next round; the personas that approved this
    # round (or an earlier one) keep their approval.
    state_set '.pending_personas=$p | .pending_stage=$s' \
      --arg p "$blocked" --arg s "$persona_stage"
    detect_stalled_personas "$result_dir" "$persona_stage"
    set_stage "$([ "$persona_stage" = plan ] && printf planning || printf implementation)"
  else
    if [ "$expected_set" = "$full_set" ]; then
      log "personas ($persona_stage): $expected_count/$expected_count APPROVE"
    else
      log "personas ($persona_stage): $expected_count/$expected_count re-reviewed blockers APPROVE (earlier approvals carried)"
    fi
    state_set 'del(.pending_personas, .pending_stage)'
    if [ "$persona_stage" = plan ]; then
      # The plan doc is the cross-session handoff record; the implementation stage
      # may run in a fresh session that has nothing but the files on disk.
      [ -s "$RUN_ROOT/control/plan.md" ] ||
        block_run "plan approved but .night-shift/control/plan.md is missing or empty"
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

# path_in_baseline FILE PATH
# Returns 0 if PATH exactly matches or is under any path recorded in the NUL-
# delimited -z status FILE, 1 otherwise.
#
# The -z porcelain format per record: "XY PATH\0" (or "XY NEW\0OLD\0" for
# renames).  We strip the 3-byte "XY " prefix and take only the first field of
# each record so we always get the CURRENT/new path — the one that would appear
# in a commit.  We compare literal bytes so spaces and unicode are safe.
#
# KNOWN LIMITATION: if a pre-existing dirty file is renamed by the run itself,
# the committed name (the new name) will not equal the old dirty name stored in
# the baseline, so rename-of-pre-existing-dirt is not tracked.  Don't try to
# solve this; just flag it for the reviewer.
path_in_baseline() {
  local baseline_file="$1" path="$2" record stripped
  # The -z output is a single blob with NUL separators. We read field-by-field
  # splitting on NUL.  Each record begins with "XY " (3 bytes); we skip the
  # second NUL field of rename records (the old path) by checking for a status
  # prefix — real record starts always begin with two non-space chars then a
  # space; an old-path field starts with the path directly.
  while IFS= read -r -d '' record; do
    # Skip blank fields that can appear at record boundaries.
    [ -n "$record" ] || continue
    # A real record starts with "XY " (status prefix — X, Y, space = 3 chars).
    # The old-path tail of a rename record starts with the path itself; it will
    # not match "??\ *" because the path char at position 3 is not a space.
    case "$record" in
      ??\ *) ;;      # starts with status prefix — process it
      *)     continue ;;  # old-path tail of a rename — skip
    esac
    # Strip the 3-char "XY " prefix to get the literal path.
    stripped="${record#???}"
    case "$path" in
      "${stripped%/}"|"${stripped%/}"/*)
        return 0 ;;
    esac
  done <"$baseline_file"
  return 1
}

verify_candidate() {
  local candidate committed_path previous evidence artifact validation_worktree
  [ "$(jq -r '.baseline_complete and .plan_approved and .implementation_approved' "$STATE")" = "true" ] ||
    block_run "candidate requires baseline, plan, and implementation gates"
  candidate="$(git -C "$PROJECT" rev-parse HEAD)"
  [ "$candidate" != "$BASE_COMMIT" ] || block_run "CREATE_CANDIDATE did not create a commit"
  git -C "$PROJECT" merge-base --is-ancestor "$BASE_COMMIT" "$candidate" ||
    block_run "candidate is not descended from the recorded base commit"
  # Use -z so both sides are NUL-delimited and paths are literal/unquoted —
  # git diff --name-only (without -z) quotes paths with spaces just like status
  # (without -z) does, making the match unreliable.
  [ -n "$(git -C "$PROJECT" diff -z --name-only "$BASE_COMMIT..$candidate")" ] ||
    block_run "candidate commit is empty"
  # For each path committed by the run, check whether it was pre-existing dirt.
  # Both sides are now unquoted bytes so spaces and unicode compare correctly.
  while IFS= read -r -d '' committed_path; do
    [ -n "$committed_path" ] || continue
    if path_in_baseline "$BASE_STATUS" "$committed_path"; then
      block_run "candidate includes pre-existing dirty path: $committed_path"
    fi
  done < <(git -C "$PROJECT" diff -z --name-only "$BASE_COMMIT..$candidate")
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
  # Modify-mode (the first-failing-test passed at baseline): establish the genuine red
  # proof now by overlaying the candidate's updated test files onto BASE production and
  # requiring RED there. This overwrites test-first-failing.json with a real failing
  # reference, so the green/cross-checks below behave exactly as in the net-new path.
  if [ "$(jq -r '.test_first_baseline_green // false' "$STATE")" = "true" ]; then
    local named_test_command
    named_test_command="$(jq -r '.command' "$RUN_ROOT/validated/test-first-failing.json")"
    verify_red_against_base "$PROJECT" "$BASE_COMMIT" "$candidate" "$named_test_command" \
      "$RUN_ROOT/validated/test-first-failing.json" ||
      block_run "could not run the test-first red-against-base overlay"
    [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")" -ne 0 ] ||
      block_run "test-first: candidate tests still pass against base production code (no genuine red→green)"
  fi
  # Run the passing check with the WRAPPER's own failing command (not the primary's
  # echoed string), so a primary-supplied command never drives control flow.
  test_command="$(jq -r '.command' "$RUN_ROOT/validated/test-first-failing.json")"
  run_test_command passing "$test_command" "$RUN_ROOT/validated/test-first-passing.json" "$validation_worktree"
  [ "$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-passing.json")" -eq 0 ] ||
    block_run "test-first command still fails after implementation"
  # Verify by exit status only — command strings are wrapper-owned, so an
  # LLM-transcribed command (e.g. `\;`→`;`) must not block a correct run.
  jq -e --slurpfile failing "$RUN_ROOT/validated/test-first-failing.json" \
    --slurpfile passing "$RUN_ROOT/validated/test-first-passing.json" '
      .test_first.failing_exit_status == $failing[0].exit_status and
      .test_first.passing_exit_status == $passing[0].exit_status
    ' "$evidence" >/dev/null ||
    block_run "primary test-first evidence does not match wrapper-owned executions (exit statuses)"
  evidence_exit_status_matches "$evidence" baseline "$RUN_ROOT/validated/baseline.json" ||
    block_run "primary baseline evidence does not match wrapper-owned baseline (exit statuses)"
  final_commands="$(extract_validation_commands "$SPEC" "Final validation commands")"
  run_validation_commands final "$RUN_ROOT/validated/final.json" "$final_commands" "$validation_worktree" ||
    block_run "final validation commands are missing or could not run"
  assert_tools_available "$RUN_ROOT/validated/final.json" "final"
  validation_not_regressed "$RUN_ROOT/validated/baseline.json" "$RUN_ROOT/validated/final.json" ||
    block_run "final validation introduced a new or worsened failure"
  evidence_exit_status_matches "$evidence" final_validation "$RUN_ROOT/validated/final.json" ||
    block_run "primary final evidence does not match wrapper-owned validation (exit statuses)"
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
  if visual_stage_enabled "$SPEC"; then
    set_stage visual_review
  else
    set_stage observer_review
  fi
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
  # model_flag intentionally word-splits into `--model X` (or nothing).
  # shellcheck disable=SC2046
  (cd "$neutral" && claude -p $(model_flag "$OBSERVER_MODEL") --output-format json \
    "$(observer_prompt "$context" "$candidate")") >"$raw" 2>"${raw}.err" || return 1
  extract_claude_structured "$raw" "$out"
}

# Pure: should the visual_review stage do work for this spec? True iff capture is
# globally enabled AND the spec declares a `## Design Contract`. Tooling presence
# is checked later in the capture helper (which SKIPs cleanly if absent), so this
# decision is deterministic and fixture-testable without a simulator.
visual_stage_enabled() {
  [ "$VISUAL_CAPTURE" = "1" ] || return 1
  grep -Eq '^## Design Contract([ \t]|$)' "$1" 2>/dev/null
}

# The visual_review stage handler. Engine-invoked: the engine itself stages the Figma
# references via the MCP (scripts/lib/visual-repair.sh visual_stage_refs_for_spec) then
# runs the design-fidelity capture (Figma reference -> iOS-simulator screenshot -> pixel
# diff) via scripts/lib/visual-capture.sh, producing validated/visual-diff-<spec>.json,
# then advances to the observer (which reviews the candidate + the report; per-screen
# pass/fail is the observer's concern, a failing report still flows as evidence).
# run_visual_capture cleanly SKIPs — writing no report, returning 0 — when the
# simulator/diff tooling or Design-Contract frames are absent; we then proceed
# without blocking. Only a present-but-malformed report is a hard error. In
# registry mode the capture claims and releases a dedicated simulator within this
# (engine) process, so its RETURN trap frees the device even on an early exit here.
run_visual() {
  local report candidate
  [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && device_registry_prune
  candidate="$(jq -r '.candidate // .candidate_commits[-1] // empty' "$STATE")"
  [ -n "$candidate" ] || block_run "visual_review reached without a candidate commit"
  visual_stage_refs_for_spec "$SPEC" "$RUN_ROOT/validated"
  run_visual_capture "$SPEC" "$candidate" "$RUN_ROOT/validated" || true
  report="$RUN_ROOT/validated/visual-diff-$(basename "$SPEC" .md).json"
  case "$(visual_report_status "$report")" in
    valid)
      log "visual_review: report accepted ($(jq -r '[.screens[]|select(.pass)]|length' "$report")/$(jq -r '.screens|length' "$report") screens pass)"
      run_visual_inloop_repair "$report" "$candidate" ;;
    absent)
      log "visual_review: no visual-diff report produced (capture skipped or tooling unavailable); proceeding to observer" ;;
    malformed)
      block_run "visual_review produced a malformed visual-diff report" ;;
  esac
  set_stage observer_review
}

# Engine-invoked in-loop repair. No-op unless NIGHT_SHIFT_VISUAL_REPAIR=1, capture
# tooling is available, and the report has over-tolerance screens. On any harness
# failure it logs and returns (the run proceeds to the observer unrepaired).
run_visual_inloop_repair() {
  local report="$1" candidate="$2"
  [ "$VISUAL_REPAIR" = "1" ] && visual_capture_available || return 0
  local over; over="$(jq -r '[.screens[]|select(.pass|not)]|length' "$report")"
  [ "$over" -gt 0 ] || { log "visual_review: all screens within tolerance; no repair needed"; return 0; }
  local branch; branch="$(git -C "$PROJECT" branch --show-current)"
  case "$branch" in main|master|'') log "visual_review: refusing to auto-repair on '$branch'; skipping repair"; return 0 ;; esac
  local iter_dev; iter_dev="$(visual_repair_devices "$SPEC" | head -n1)"
  NO_BUILD="${NIGHT_SHIFT_VISUAL_REPAIR_NO_BUILD:-0}"
  repair_metro_start "$(device_label_to_name "$iter_dev")" || { log "visual_review: repair harness unavailable; proceeding unrepaired"; return 0; }
  visual_repair_for_spec "$SPEC" "$PROJECT" "$RUN_ROOT/validated" "$candidate" "$report" \
    "${NIGHT_SHIFT_VISUAL_MAX_ATTEMPTS:-3}" \
    "$([ "${NIGHT_SHIFT_VISUAL_REPAIR_SHARED:-0}" = "1" ] && echo 'src/features/,src/ui/' || echo 'src/features/')" \
    "$iter_dev"
  repair_metro_stop
  if git -C "$PROJECT" diff --quiet && git -C "$PROJECT" diff --cached --quiet; then
    log "visual_review: repair made no edits; proceeding unrepaired"; return 0
  fi
  local screens; screens="$(jq -r '[.screens[]|select(.pass|not)|.screen]|unique|join(", ")' "$report")"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -q -m "fix(visual): auto-repair $screens" || { log "visual_review: repair commit failed; proceeding"; return 0; }
  local newsha; newsha="$(git -C "$PROJECT" rev-parse HEAD)"
  state_set '
    .candidate_commits = ((.candidate_commits + [$c])
      | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) |
    .candidate=$c | .updated_at=$now
  ' --arg c "$newsha" --arg now "$(now_iso)"
  run_visual_capture "$SPEC" "$newsha" "$RUN_ROOT/validated"
  log "visual_review: auto-repaired ($screens); committed $newsha; refreshed report for observer"
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
    # Record the cost of THIS attempt immediately after the call returns,
    # regardless of whether the verdict validates. This ensures the cost is
    # never lost when both attempts fail and we fall through to block_run. On
    # the success path we return 0 below WITHOUT a second record_cost call,
    # so there is no double-counting.
    record_cost "$raw.$attempt" "$(basename "$raw")"
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
  cleanup_observer_tmp
  log "run $RUN_ID complete; compact archive: $RUN_ROOT/archive/$RUN_ID"
  exit 0
}

start_next_task() {
  local next_spec="" epoch cand canon
  # Walk the unchecked queue and pick the first spec that belongs to THIS run's
  # project. Specs for other projects are skipped (a run is pinned to one
  # --project and cannot switch). If none remain for this project, the run is
  # done — complete and archive rather than block on someone else's spec.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    case "$cand" in /*) canon="$cand" ;; *) canon="$WORKSPACE_ROOT/$cand" ;; esac
    canon="$(canonical_file "$canon")" || continue
    validate_spec_project "$canon" || continue
    [ "$canon" != "$SPEC" ] ||
      block_run "NEXT_TASK requires the completed TODO entry to be checked off"
    next_spec="$canon"; break
  done <<EOF
$(list_unchecked_specs "$WORKSPACE_ROOT/TODO.md")
EOF
  # complete_run exits; the trailing `return` is defensive only.
  # shellcheck disable=SC2317
  [ -n "$next_spec" ] || { complete_run; return; }
  validate_spec "$next_spec" || block_run "next TODO spec is incomplete"
  SPEC="$next_spec"
  BASE_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
  BASE_BRANCH="$(git -C "$PROJECT" branch --show-current)"
  BASE_STATUS="$RUN_ROOT/baseline-status-$(basename "$SPEC" .md).txt"
  # -z: NUL-delimited literal paths; matches the format used in verify_candidate.
  git -C "$PROJECT" status --porcelain=v1 -z >"$BASE_STATUS"
  epoch="$(now_epoch)"
  state_set '
    .task=$task | .stage="planning" | .stage_turns=0 | .task_turns=0 |
    .session_id=null |
    .stage_started_at=$epoch | .task_started_at=$epoch |
    .base_commit=$base | .base_branch=$branch | .review_round=0 |
    .baseline_status=$baseline_status | .finding_ids=[] | .candidate_commits=[] |
    .plan_approved=false | .implementation_approved=false |
    .candidate_verified=false | .baseline_complete=false |
    .test_first_baseline_green=false |
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
  test_first_exit="$(jq -r '.exit_status' "$RUN_ROOT/validated/test-first-failing.json")"
  [ "$test_first_exit" -ne 127 ] ||
    block_run "next task test-first command was not found (exit 127); fix the toolchain"
  if [ "$test_first_exit" -eq 0 ]; then
    # Same modify-mode handling as the initial baseline gate: a spec that modifies an
    # already-tested module cannot be red at baseline; the red proof is verified
    # against base after implementation (see verify_candidate).
    state_set '.test_first_baseline_green=true'
    log "next task test-first passes at baseline; modify-mode — red verified against base after implementation"
  else
    state_set '.test_first_baseline_green=false'
  fi
  state_set '.baseline_complete=true'
}

handle_signal() {
  local signal="$RUN_ROOT/control/next-action.json" action
  action="$(jq -r '.action' "$signal")"
  log "signal: $action — $(jq -r '.reason' "$signal")"
  transition_allowed "$(jq -r '.stage' "$STATE")" "$action" ||
    block_run "action $action is invalid from stage $(jq -r '.stage' "$STATE")"
  case "$action" in
    RUN_PERSONAS) run_personas ;;
    CREATE_CANDIDATE) verify_candidate ;;
    REQUEST_OBSERVER) run_observer "$signal" ;;
    RUN_VISUAL) run_visual ;;
    NEXT_TASK)
      [ "$(jq -r '.stage' "$STATE")" = "completion" ] ||
        block_run "NEXT_TASK requires observer approval"
      # An explicit `--spec` run is a single task — the caller (e.g. a wrapper that
      # owns cross-spec sequencing + per-spec branch routing) advances to the next
      # spec itself. Treat NEXT_TASK as COMPLETE so the run exits 0 cleanly instead
      # of trying to chain to another TODO entry whose branch isn't checked out.
      if [ "${EXPLICIT_SPEC:-0}" = "1" ]; then
        log "explicit --spec run: task complete; not chaining to the next TODO entry"
        complete_run
      else
        start_next_task
      fi
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

  # Acquire a per-project lock BEFORE touching state.json; two concurrent runs
  # on the same --project would otherwise corrupt the shared state. The lock
  # is held until the EXIT trap fires (success, block_run, or signal).
  acquire_lock
  # Release the lock on normal exit AND on any signal.  The HUP/INT/TERM trap
  # is set below (after initialize_run) so it can call block_run; that trap
  # does NOT replace this EXIT trap — both fire on exit.
  trap 'release_lock' EXIT

  if recover_run; then
    :
  else
    # --resume must never silently fall through to a fresh run: if recovery found
    # nothing resumable, that is an operator error, not a cue to start over.
    [ "$RESUME" -eq 0 ] ||
      die "--resume: no resumable blocked run for this project (state missing, not blocked, rate-limited, or session/primary mismatch)"
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

  local malformed_n rc
  while :; do
    invoke_primary
    if validate_signal; then
      # Valid signal: clear the consecutive-malformed counter (only write when
      # nonzero to avoid a needless state churn on the common path), then act.
      malformed_n="$(state_int '.malformed_signal_consecutive // 0')" || malformed_n=0
      [ "$malformed_n" -eq 0 ] ||
        state_set '.malformed_signal_consecutive=0 | .updated_at=$now' --arg now "$(now_iso)"
      handle_signal
    else
      rc=$?
      # Malformed (rc=1) or absent (rc=2) signal: count it and abort once a
      # primary has produced MAX_MALFORMED_SIGNALS in a row with no valid signal
      # between, instead of grinding the whole turn budget on junk.
      malformed_n="$(state_int '.malformed_signal_consecutive // 0')" || malformed_n=0
      malformed_n=$((malformed_n + 1))
      state_set '.malformed_signal_consecutive=$n | .updated_at=$now' \
        --argjson n "$malformed_n" --arg now "$(now_iso)"
      ! malformed_cap_reached "$malformed_n" ||
        block_run "primary produced $malformed_n consecutive malformed/absent signals (cap $MAX_MALFORMED_SIGNALS); aborting to avoid burning the turn budget"
      if [ "$rc" -eq 1 ]; then
        log "primary signal malformed ($malformed_n/$MAX_MALFORMED_SIGNALS consecutive); continuing same explicit session for correction"
      else
        log "primary produced no signal ($malformed_n/$MAX_MALFORMED_SIGNALS consecutive); continuing same explicit session"
      fi
    fi
  done
}

require_command jq
if [ "$PREFLIGHT" -eq 1 ]; then
  require_command git
  [ -n "$PROJECT" ] || die "--preflight requires --project"
  [ -n "$SPEC" ] || die "--preflight requires --spec"
  [ -e "$SPEC" ] || die "spec not found: $SPEC"
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "project is not a Git repository: $PROJECT"
  emit_preflight "$PROJECT" "$SPEC"
  exit 0
fi
if [ "$FIXTURE_TEST" -eq 1 ]; then
  # shellcheck source=scripts/test/fixtures.sh
  . "$(dirname "$0")/test/fixtures.sh"
  run_dry_fixtures
  if [ "$DRY_RUN" -eq 0 ]; then run_live_fixtures; fi
  exit 0
fi
[ "$DRY_RUN" -eq 0 ] || die "--dry-run is valid only with --fixture-test"
main_run
