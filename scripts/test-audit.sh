#!/usr/bin/env bash
# shellcheck shell=bash
#
# test-audit.sh — the false-confidence test-audit agent pass + report
# (agentic-gaps tranche Task 9, closing Phase C: docs/superpowers/specs/
# 2026-07-11-agentic-gaps-tranche-design.md §C). Mirrors scripts/port-audit.sh's
# agent-layer architecture: wraps Task 8's deterministic scanner
# (scripts/lib/test-audit-static.js) with ONE bounded `claude -p` agent pass
# that (a) judges each static finding confirm/refute with a one-line reason,
# and (b) hunts judgment-tier smells the static scan cannot see (a mock
# asserted against itself, a tautological round-trip, a guard visible in the
# source with no negative-case test, a stale `.skip`). The agent's reply is
# NEVER trusted for arithmetic — every count in the final report is
# recomputed by this script (jq) from the static findings + the agent's
# validated {file,line,rule} mapping, same discipline as
# scripts/lib/port-audit-normalize.sh's header describes for its own layer.
#
# Usage:
#   scripts/test-audit.sh --project <dir> --tests <path...> [--src <dir>]
#     [--model <name>] [--offline] [--out <json>]
#
# Options:
#   --project DIR  required; target repo (test/source paths below resolve
#                  relative to it, same convention as --scope in
#                  port-audit.sh; an absolute path is used as-is).
#   --tests PATH   required, one or more; a test file, a directory (walked
#                  for *.test.*/*.spec.* files), or a glob, passed through to
#                  scripts/lib/test-audit-static.js's own resolver. Consumes
#                  every following argument up to the next `--flag` (same
#                  convention as that CLI's own --tests).
#   --src DIR      optional; source dir for the static layer's
#                  assert-on-unknown-property rule AND the agent pass's
#                  "source under test" context. Omitted -> that rule is
#                  skipped (still 0 in counts) and the agent sees test files
#                  only.
#   --model NAME   model for the one paid `claude -p` call. Default: empty
#                  (inherit — no --model flag; the CLI's own startup model).
#                  Passed through verbatim: this script resolves nothing
#                  engine-specific (no model-fallback lookup) — a caller that
#                  wants that (night-shift.sh's test_audit_candidate) resolves
#                  it BEFORE calling here.
#   --offline      skip the paid `claude -p` call entirely: the report is
#                  assembled from the static pass alone, every static finding
#                  left unjudged. Zero cost, fully deterministic — what the
#                  fixture suite's static-only case exercises.
#   --out PATH     report path. Default:
#                  <project>/.night-shift/test-audit/report.json. A sibling
#                  `.md` (same stem) is always written alongside it.
#   -h|--help
#
# Report schema `night-shift-test-audit/1`:
#   { schema, generated_at, project, model,
#     static: <the full night-shift-test-audit-static/1 report>,
#     judged: [ {file,line,rule,verdict:"confirm"|"refute",reason}, ... ],
#     additional: [ {file,line,rule,summary}, ... ],
#     agent_note: <string|null>,   // set when the agent pass was skipped,
#                                  // failed, or returned unparseable output —
#                                  // the ONE place that's visible; every
#                                  // static finding still stands, unjudged.
#     summary: { static_total, confirmed, refuted, additional, final_total } }
#
# `judged` contains ONLY validated entries (object shape; file/rule non-empty
# strings; line a plain integer; verdict exactly "confirm" or "refute") whose
# (file,line,rule) matches a REAL static finding — deduped keep-first, so a
# sloppy or adversarial reply cannot move the summary. A static finding the
# agent never judged (or judged with a garbage verdict) contributes to
# `unjudged`, computed as static_total - confirmed - refuted; the finding
# itself is still visible in full under `.static.findings`. `additional` is
# the same validation + dedupe applied to the agent's own new-finding array;
# these are NEW findings the static scan has no entry for, so they are not
# cross-checked against `.static.findings`.
#
# Exit status: 0 when summary.final_total == 0 (clean); 2 when
# summary.final_total > 0 (findings exist — confirmed and/or unjudged and/or
# additional); 3 on an infra/usage error (bad args, the static layer itself
# failing, an unwritable output dir) — nothing is written in that case. An
# agent-pass failure (missing claude, non-zero exit, unparseable reply after
# retry) is NEVER an exit-3 condition: it degrades to "every static finding
# stays unjudged" (fail-open on evidence, the port-audit posture — a
# deterministic wrapper never lets an agent's absence erase evidence it
# already has), noted in `agent_note`, and the exit code still follows
# final_total.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[test-audit] %s\n' "$*" >&2; }
# Exit 3 (not 2): unlike port-audit.sh, this script's exit code is reserved
# for summary.final_total (0/2) — usage/infra errors that prevent producing
# ANY report get the third code instead (see header).
die() { log "ERROR: $*"; exit 3; }

# Pure: "--model NAME" or nothing for "inherit"/empty — same idiom as
# port-audit.sh's port_audit_model_flag, standalone (no shared lib to source
# for one line).
test_audit_model_flag() {
  case "$1" in
    inherit|"") ;;
    *) printf -- '--model %s' "$1" ;;
  esac
}

# Resolves a --tests/--src entry against $PROJECT: absolute paths pass
# through; a relative path containing a literal `..` segment is rejected
# (lexical only, no symlink-chase — same tradeoff port-audit.sh documents for
# its own --manifest). Prints the resolved path on success.
resolve_project_path() {
  local raw="$1"
  case "$raw" in
    /*) printf '%s' "$raw"; return 0 ;;
  esac
  case "/$raw/" in *"/../"*) return 1 ;; esac
  printf '%s/%s' "$PROJECT" "$raw"
}

# ---- args -------------------------------------------------------------------
PROJECT="" SRC="" MODEL="" OUT="" OFFLINE=0
TESTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --tests)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in --*) break ;; esac
        TESTS+=("$1"); shift
      done
      ;;
    --src)     SRC="${2:-}"; shift 2 ;;
    --model)   MODEL="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '3,64p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required"
[ "${#TESTS[@]}" -gt 0 ] || die "--tests is required (at least one path)"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"

RESOLVED_TESTS=()
t=""
for t in "${TESTS[@]}"; do
  rt="$(resolve_project_path "$t")" || die "--tests path escapes the project: $t"
  RESOLVED_TESTS+=("$rt")
done

SRC_ARGS=()
if [ -n "$SRC" ]; then
  SRC="$(resolve_project_path "$SRC")" || die "--src path escapes the project: ${SRC}"
  SRC_ARGS=(--src "$SRC")
fi

[ -n "$OUT" ] || OUT="$PROJECT/.night-shift/test-audit/report.json"
mkdir -p "$(dirname "$OUT")" || die "cannot create output dir: $(dirname "$OUT")"
case "$OUT" in
  *.json) MD_OUT="${OUT%.json}.md" ;;
  *) MD_OUT="$OUT.md" ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-audit.XXXXXX")" || die "cannot create scratch dir"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- static pass (Task 8, always real/deterministic — --offline only skips
# the agent pass below, never this) -------------------------------------------
# Run from inside $PROJECT so the static layer's own path.relative(cwd, ...)
# yields project-relative file paths in the report (RESOLVED_TESTS/SRC are
# already absolute, so the cd changes nothing about what gets scanned).
STATIC="$TMP_DIR/static.json"
if ! ( cd "$PROJECT" && node "$SCRIPT_DIR/lib/test-audit-static.js" --tests "${RESOLVED_TESTS[@]}" \
    "${SRC_ARGS[@]}" --out "$STATIC" ) >"$STATIC.log" 2>&1; then
  die "test-audit-static.js failed: $(cat "$STATIC.log" 2>/dev/null)"
fi
[ -s "$STATIC" ] || die "test-audit-static.js produced no report"

# Best-effort concrete file list for the agent prompt (directories walked
# shallowly for test-shaped names; a bare shell glob is expanded natively;
# anything neither a file nor a directory, e.g. a `**` glob, is left to
# test-audit-static.js's own resolver above and simply omitted from the
# prompt dump below — the static findings it produced still name real
# file:line pairs regardless).
resolve_test_files_for_prompt() {
  local entry
  for entry in "$@"; do
    if [ -d "$entry" ]; then
      find "$entry" -type f \( \
        -iname '*.test.js' -o -iname '*.test.ts' -o -iname '*.test.jsx' -o -iname '*.test.tsx' \
        -o -iname '*.spec.js' -o -iname '*.spec.ts' -o -iname '*.spec.jsx' -o -iname '*.spec.tsx' \
        \) 2>/dev/null
    elif [ -f "$entry" ]; then
      printf '%s\n' "$entry"
    else
      # shellcheck disable=SC2086 # deliberate: let the shell glob $entry
      for g in $entry; do [ -f "$g" ] && printf '%s\n' "$g"; done
    fi
  done | sort -u
}

# ---- reply extraction + validation (mirrors port-audit-normalize.sh's
# cascade, adapted to this script's {judged,additional} shape) ---------------

# Extracts the agent's {"judged":[...], "additional":[...]} object from $1
# into $2. Tries, in order: (0) $1 IS already the reply object (the
# --offline/fail-open synthetic reply below); (1) the whole `.result` of a
# `claude -p --output-format json` envelope, parsed as JSON; (2) the LAST
# fenced code block inside `.result`; (3) the outermost {...} embedded in
# `.result` prose. Returns 1 (fail closed) if no shape yields an object with
# a `judged` or `additional` key.
test_audit_extract_reply() {
  local raw="$1" out="$2" candidate fenced braced

  if jq -e 'type == "object" and (has("judged") or has("additional"))' "$raw" >/dev/null 2>&1; then
    jq '.' "$raw" >"$out" 2>/dev/null && return 0
    return 1
  fi

  candidate="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  [ -n "$candidate" ] || return 1

  if printf '%s' "$candidate" | jq -e 'type == "object" and (has("judged") or has("additional"))' >/dev/null 2>&1; then
    printf '%s' "$candidate" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  fenced="$(printf '%s\n' "$candidate" | awk '
    /^[ \t]*```/ { if (infence) { infence=0; last=buf } else { infence=1; buf="" } next }
    infence { buf = buf $0 "\n" }
    END { printf "%s", last }
  ')"
  if [ -n "$fenced" ] && printf '%s' "$fenced" | jq -e 'type == "object" and (has("judged") or has("additional"))' >/dev/null 2>&1; then
    printf '%s' "$fenced" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  braced="$(printf '%s' "$candidate" | tr '\n' ' ' | sed -E 's/^[^{]*//; s/[^}]*$//')"
  if [ -n "$braced" ] && printf '%s' "$braced" | jq -e 'type == "object" and (has("judged") or has("additional"))' >/dev/null 2>&1; then
    printf '%s' "$braced" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  return 1
}

# Shape validation beyond "has a judged/additional key": both, when present,
# must be arrays (of anything — element-level validation happens in
# test_audit_assemble's own jq).
test_audit_valid_reply() {
  jq -e '((.judged? // []) | type == "array") and ((.additional? // []) | type == "array")' "$1" >/dev/null 2>&1
}

# ---- deterministic assembly (static + validated agent reply -> report) -----
#
# test_audit_assemble STATIC_FILE REPLY_FILE PROJECT MODEL NOTE OUT_FILE
# Pure/deterministic given its inputs: either OUT_FILE gets a complete report
# or nothing changes. NOTE is the agent_note string ("" -> null).
test_audit_assemble() {
  local static_file="$1" reply_file="$2" project="$3" model="$4" note="$5" out_file="$6"
  jq -n \
    --slurpfile _s "$static_file" \
    --slurpfile _r "$reply_file" \
    --arg project "$project" --arg model "$model" --arg note "$note" \
    --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    ($_s[0]) as $static | ($_r[0]) as $reply |
    ($static.findings // []) as $findings |

    def keyed($e): [$e.file, ($e.line | tostring), $e.rule];
    def is_int_like($v): ($v // "") | tostring | test("^[0-9]+$");

    # Validated + deduped (keep-first) judged entries, restricted to
    # (file,line,rule) triples that name a REAL static finding — a reply that
    # references a nonexistent finding is noise, silently dropped, never
    # surfaced or counted.
    ([$findings[] | keyed(.)]) as $real_keys |
    ([($reply.judged // [])[]? | select(type == "object")
        | select((.file? // "") != "" and (.rule? // "") != "")
        | select(is_int_like(.line))
        | select((.verdict? // "") == "confirm" or (.verdict? // "") == "refute")
        | {file: .file, line: (.line | tonumber), rule: .rule, verdict: .verdict, reason: (.reason // "")}
      ] | map(. as $e | select($real_keys | any(. == keyed($e))))
        | reduce .[] as $j ([]; if any(.[]; keyed(.) == keyed($j)) then . else . + [$j] end)
    ) as $judged |

    # Validated + deduped (keep-first) additional entries — new findings, not
    # cross-checked against the static list (they are not IN it by design).
    ([($reply.additional // [])[]? | select(type == "object")
        | select((.file? // "") != "" and (.rule? // "") != "")
        | select(is_int_like(.line))
        | {file: .file, line: (.line | tonumber), rule: .rule, summary: (.summary // "")}
      ] | reduce .[] as $a ([]; if any(.[]; keyed(.) == keyed($a)) then . else . + [$a] end)
    ) as $additional |

    ($findings | length) as $static_total |
    ($judged | map(select(.verdict == "confirm")) | length) as $confirmed |
    ($judged | map(select(.verdict == "refute")) | length) as $refuted |
    ($static_total - $confirmed - $refuted) as $unjudged |
    ($additional | length) as $additional_count |

    {
      schema: "night-shift-test-audit/1",
      generated_at: $generated,
      project: $project,
      model: $model,
      static: $static,
      judged: $judged,
      additional: $additional,
      agent_note: (if $note == "" then null else $note end),
      summary: {
        static_total: $static_total,
        confirmed: $confirmed,
        refuted: $refuted,
        additional: $additional_count,
        final_total: ($confirmed + $unjudged + $additional_count)
      }
    }
  ' >"$out_file"
}

# Human-readable sibling report, deterministic from the same JSON.
test_audit_write_md() {
  local json="$1" md="$2" note
  {
    printf '# Test audit report\n\n'
    printf -- '- Project: `%s`\n' "$(jq -r '.project' "$json")"
    printf -- '- Model: `%s`\n' "$(jq -r 'if .model == "" then "inherit" else .model end' "$json")"
    printf -- '- Generated: %s\n\n' "$(jq -r '.generated_at' "$json")"
    printf '## Summary\n\n'
    printf -- '- Static findings: %s\n' "$(jq -r '.summary.static_total' "$json")"
    printf -- '- Confirmed: %s\n' "$(jq -r '.summary.confirmed' "$json")"
    printf -- '- Refuted (false positive): %s\n' "$(jq -r '.summary.refuted' "$json")"
    printf -- '- Additional (judgment-tier): %s\n' "$(jq -r '.summary.additional' "$json")"
    printf -- '- **Final total: %s**\n\n' "$(jq -r '.summary.final_total' "$json")"
    note="$(jq -r '.agent_note // empty' "$json")"
    [ -z "$note" ] || printf '> %s\n\n' "$note"
    printf '## Confirmed findings\n\n'
    jq -r '.judged[]? | select(.verdict=="confirm") | "- `\(.file):\(.line)` (\(.rule)) — \(.reason)"' "$json"
    printf '\n## Refuted findings (false positive)\n\n'
    jq -r '.judged[]? | select(.verdict=="refute") | "- `\(.file):\(.line)` (\(.rule)) — \(.reason)"' "$json"
    printf '\n## Unjudged static findings\n\n'
    jq -r '
      (.static.findings // []) as $all | (.judged // []) as $j |
      [ $all[] | . as $f
        | select(([$j[] | select(.file==$f.file and .line==$f.line and .rule==$f.rule)] | length) == 0) ]
      | .[] | "- `\(.file):\(.line)` (\(.rule)) — \(.snippet)"
    ' "$json" 2>/dev/null
    printf '\n## Additional (judgment-tier) findings\n\n'
    jq -r '.additional[]? | "- `\(.file):\(.line)` (\(.rule)) — \(.summary)"' "$json"
  } >"$md"
}

# ---- agent pass (skippable via --offline) -----------------------------------
REPLY="$TMP_DIR/reply.json"
NOTE=""
if [ "$OFFLINE" -eq 1 ]; then
  printf '{"judged":[],"additional":[]}\n' >"$REPLY"
  NOTE="--offline: agent pass skipped; every static finding kept unjudged"
else
  PROMPT_FILE="$TMP_DIR/prompt.txt"
  {
    printf 'You are auditing test files for FALSE CONFIDENCE: tests that PASS while\nasserting nothing meaningful. Evidence this matters: a real bug shipped\nbecause `expect(result.installmentGroupId).not.toBe("group-a")` passed\nvacuously — the property does not exist on `result`, so the comparison was\ntrivially true; only a sibling positive assertion elsewhere exposed it.\n\n'
    printf '## Deterministic static findings (night-shift-test-audit-static/1) — a\nmechanical line-scan, NOT a parser; treat every finding as a candidate to\nverify, not a verdict\n```json\n'
    cat "$STATIC"
    printf '\n```\n\n'
    printf '## Test files\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '\n### %s\n```\n' "$f"
      cat "$f" 2>/dev/null
      printf '\n```\n'
    done < <(resolve_test_files_for_prompt "${RESOLVED_TESTS[@]}")
    if [ -n "$SRC" ]; then
      printf '\n## Source under test (--src %s)\n' "$SRC"
      find "$SRC" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' \) 2>/dev/null | sort |
        while IFS= read -r sf; do
          printf '\n### %s\n```\n' "$sf"
          cat "$sf" 2>/dev/null
          printf '\n```\n'
        done
    fi
    printf '\nYour job has two parts.\n\n(a) For EACH static finding above (identified by file:line:rule), judge\nwhether it is a genuine false-confidence problem ("confirm") or a false\npositive from the mechanical scan ("refute"), with a one-line reason.\n\n(b) Separately, hunt for judgment-tier smells the static scan cannot see:\na mock asserted against itself rather than the real behavior; a\ntautological round-trip (encode then decode the same value, asserting only\nthat they match, with no independent expectation); a guard/branch clearly\npresent in the source under test with no negative-case test covering it; a\n`.skip`/`xit` test that reads as stale rather than deliberately deferred.\nOnly report something you have real evidence for at a specific file:line —\ndo not guess, and do not repeat a static finding as an "additional" one.\n\n'
    printf 'Reply with ONLY a single fenced json code block containing exactly one\nJSON object: {"judged":[{"file":"<path>","line":<n>,"rule":"<static rule\nname>","verdict":"confirm"|"refute","reason":"<one line>"}, ...],\n"additional":[{"file":"<path>","line":<n>,"rule":"<short-kebab-case\nname>","summary":"<one line>"}, ...]}. Omit judged/additional entries you\nhave nothing to report — do not pad either array.\n'
  } >"$PROMPT_FILE"

  RAW="$TMP_DIR/raw.json"
  LAST_REASON=""
  SUCCESS=0
  attempt=1
  while [ "$attempt" -le 2 ]; do
    RETRY_NOTE=""
    [ "$attempt" -eq 1 ] || RETRY_NOTE="Your previous reply could not be parsed ($LAST_REASON). Reply with ONLY the fenced json code block, no other prose.\n\n"
    # word-split is deliberate: test_audit_model_flag emits `--model X` or
    # nothing at all (empty/inherit) — same reasoning as port-audit.sh's own
    # call site.
    # shellcheck disable=SC2046
    ( cd "$PROJECT" && { [ -z "$RETRY_NOTE" ] || printf '%b' "$RETRY_NOTE"; cat "$PROMPT_FILE"; } | \
      claude -p $(test_audit_model_flag "$MODEL") --output-format json ) >"$RAW" 2>"$RAW.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      LAST_REASON="claude -p exited $rc: $(head -c 200 "$RAW.err" 2>/dev/null | tr '\n' ' ')"
      attempt=$((attempt + 1))
      continue
    fi
    if test_audit_extract_reply "$RAW" "$REPLY" && test_audit_valid_reply "$REPLY"; then
      SUCCESS=1
      break
    fi
    LAST_REASON="could not extract a valid {judged, additional} reply"
    attempt=$((attempt + 1))
  done

  if [ "$SUCCESS" -ne 1 ]; then
    printf '{"judged":[],"additional":[]}\n' >"$REPLY"
    NOTE="agent pass failed after 2 attempts ($LAST_REASON); every static finding kept unjudged"
    log "WARN: $NOTE"
  fi
fi

# ---- assemble + write --------------------------------------------------------
test_audit_assemble "$STATIC" "$REPLY" "$PROJECT" "$MODEL" "$NOTE" "$OUT"
[ -s "$OUT" ] || die "assembly produced no report"
test_audit_write_md "$OUT" "$MD_OUT"

FINAL_TOTAL="$(jq -r '.summary.final_total // 0' "$OUT" 2>/dev/null)"
case "$FINAL_TOTAL" in ''|*[!0-9]*) FINAL_TOTAL=0 ;; esac
log "wrote $OUT (final_total=$FINAL_TOTAL)"
if [ "$FINAL_TOTAL" -gt 0 ]; then
  exit 2
else
  exit 0
fi
