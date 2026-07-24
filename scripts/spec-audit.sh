#!/usr/bin/env bash
# shellcheck shell=bash
#
# spec-audit.sh — the pre-run spec-quality agent pass + report
# (docs/superpowers/specs/2026-07-24-spec-audit-design.md, "Agent layer"
# section). Mirrors scripts/test-audit.sh's agent-layer architecture: wraps
# the deterministic scanner (scripts/lib/spec-audit-static.js) with ONE
# bounded `claude -p` agent pass that (a) judges each static finding
# confirm/refute with a one-line reason, and (b) hunts judgment-tier smells
# the static scan cannot see (an acceptance criterion that is not actually
# testable, final-validation commands that would not exercise the change,
# an edge case the spec's own description implies but omits, scope
# under-specified for the stated goal, a Design Contract with no measurable
# target). The agent's reply is NEVER trusted for arithmetic — every count
# in the final report is recomputed by this script (jq) from the static
# findings + the agent's validated {rule,line} mapping, same discipline as
# test-audit.sh's own header describes for its layer.
#
# Usage:
#   scripts/spec-audit.sh --spec <file> [--project <dir>] [--model <name>]
#     [--offline] [--out <json>]
#
# Options:
#   --spec FILE    required; the spec markdown to audit. A relative path is
#                  resolved against --project when given, else against the
#                  current working directory (same convention as
#                  test-audit.sh's --tests/--src resolution, one level
#                  simpler — this script only ever sees one file).
#   --project DIR  optional; target repo. When given, the static scanner runs
#                  with $PROJECT as its cwd (so the static report's own
#                  `spec` field comes out project-relative) and it anchors
#                  --out's default location. Omitted -> --spec resolves
#                  against cwd and --out defaults under cwd.
#   --model NAME   model for the one paid `claude -p` call. Default: empty
#                  (inherit — no --model flag; the CLI's own startup model).
#                  Passed through verbatim: this script resolves nothing
#                  engine-specific, same posture as test-audit.sh.
#   --offline      skip the paid `claude -p` call entirely: the report is
#                  assembled from the static pass alone, every static finding
#                  left unjudged, `summary.final_total == static total`. Zero
#                  cost, fully deterministic.
#   --out PATH     report path. Default:
#                  <project-or-cwd>/.night-shift/spec-audit/report.json. A
#                  sibling `.md` (same stem) is always written alongside it.
#   -h|--help
#
# Report schema `night-shift-spec-audit/1`:
#   { schema, generated_at, spec, project, model,
#     static: <the full night-shift-spec-audit-static/1 report>,
#     judged: [ {line,rule,verdict:"confirm"|"refute",reason}, ... ],
#     additional: [ {smell,reason}, ... ],
#     agent_note: <string|null>,   // set when the agent pass was skipped,
#                                  // failed, or returned unparseable output —
#                                  // the ONE place that's visible; every
#                                  // static finding still stands, unjudged.
#     summary: { static_total, confirmed, refuted, additional, final_total } }
#
# `judged` contains ONLY validated entries (object shape; rule non-empty
# string; line a plain integer; verdict exactly "confirm" or "refute") whose
# (line,rule) matches a REAL static finding — deduped keep-first, so a sloppy
# or adversarial reply cannot move the summary. A static finding the agent
# never judged (or judged with a garbage verdict) contributes to `unjudged`,
# computed as static_total - confirmed - refuted; the finding itself is still
# visible in full under `.static.findings`. `additional` is the agent's own
# judgment-tier smells — a smell + one-line reason, not cross-checked against
# `.static.findings` (they are new findings the static scan has no entry
# for), deduped keep-first on the (smell,reason) pair.
#
# Exit status: 0 when summary.final_total == 0 (clean); 2 when
# summary.final_total > 0 (findings exist — confirmed and/or unjudged and/or
# additional); 3 on an infra/usage error (bad args, the static layer itself
# failing, an unwritable output dir) — nothing is written in that case. An
# agent-pass failure (missing claude, non-zero exit, unparseable reply after
# retry) is NEVER an exit-3 condition: it degrades to "every static finding
# stays unjudged" (fail-open on evidence, same posture as test-audit.sh),
# noted in `agent_note`, and the exit code still follows final_total.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[spec-audit] %s\n' "$*" >&2; }
# Exit 3 (not 2): this script's exit code is reserved for summary.final_total
# (0/2) — usage/infra errors that prevent producing ANY report get the third
# code instead (see header), same convention as test-audit.sh.
die() { log "ERROR: $*"; exit 3; }

# Pure: "--model NAME" or nothing for "inherit"/empty — same idiom as
# test-audit.sh's test_audit_model_flag / port-audit.sh's
# port_audit_model_flag, standalone (no shared lib to source for one line).
spec_audit_model_flag() {
  case "$1" in
    inherit|"") ;;
    *) printf -- '--model %s' "$1" ;;
  esac
}

# Resolves --spec against $PROJECT when set, else against the caller's cwd:
# absolute paths pass through; a relative path containing a literal `..`
# segment is rejected when $PROJECT is set (lexical only, no symlink-chase —
# same tradeoff test-audit.sh's resolve_project_path documents).
resolve_spec_path() {
  local raw="$1"
  case "$raw" in
    /*) printf '%s' "$raw"; return 0 ;;
  esac
  if [ -n "$PROJECT" ]; then
    case "/$raw/" in *"/../"*) return 1 ;; esac
    printf '%s/%s' "$PROJECT" "$raw"
  else
    printf '%s/%s' "$(pwd)" "$raw"
  fi
}

# ---- args -------------------------------------------------------------------
SPEC="" PROJECT="" MODEL="" OUT="" OFFLINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec)    SPEC="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --model)   MODEL="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '3,76p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$SPEC" ] || die "--spec is required"
if [ -n "$PROJECT" ]; then
  PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
fi

SPEC_RESOLVED="$(resolve_spec_path "$SPEC")" || die "--spec path escapes the project: $SPEC"
[ -f "$SPEC_RESOLVED" ] || die "--spec not found or not a file: $SPEC_RESOLVED"

OUT_BASE="${PROJECT:-$(pwd)}"
[ -n "$OUT" ] || OUT="$OUT_BASE/.night-shift/spec-audit/report.json"
mkdir -p "$(dirname "$OUT")" || die "cannot create output dir: $(dirname "$OUT")"
case "$OUT" in
  *.json) MD_OUT="${OUT%.json}.md" ;;
  *) MD_OUT="$OUT.md" ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spec-audit.XXXXXX")" || die "cannot create scratch dir"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- static pass (always real/deterministic — --offline only skips the
# agent pass below, never this) -----------------------------------------------
# Run from inside $PROJECT (when given) so the static layer's own
# path.relative(cwd, ...) yields a project-relative `spec` field in the
# report — same reasoning as test-audit.sh's own cd before its static call.
STATIC="$TMP_DIR/static.json"
if ! ( cd "${PROJECT:-.}" && node "$SCRIPT_DIR/lib/spec-audit-static.js" \
    --spec "$SPEC_RESOLVED" --out "$STATIC" ) >"$STATIC.log" 2>&1; then
  die "spec-audit-static.js failed: $(cat "$STATIC.log" 2>/dev/null)"
fi
[ -s "$STATIC" ] || die "spec-audit-static.js produced no report"

# ---- reply extraction + validation (mirrors test-audit.sh's cascade,
# adapted to this script's {judged,additional} shape) ------------------------

# Extracts the agent's {"judged":[...], "additional":[...]} object from $1
# into $2. Tries, in order: (0) $1 IS already the reply object (the
# --offline/fail-open synthetic reply below); (1) the whole `.result` of a
# `claude -p --output-format json` envelope, parsed as JSON; (2) the LAST
# fenced code block inside `.result`; (3) the outermost {...} embedded in
# `.result` prose. Returns 1 (fail closed) if no shape yields an object with
# a `judged` or `additional` key.
spec_audit_extract_reply() {
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
# spec_audit_assemble's own jq).
spec_audit_valid_reply() {
  jq -e '((.judged? // []) | type == "array") and ((.additional? // []) | type == "array")' "$1" >/dev/null 2>&1
}

# ---- deterministic assembly (static + validated agent reply -> report) -----
#
# spec_audit_assemble STATIC_FILE REPLY_FILE PROJECT MODEL NOTE OUT_FILE
# Pure/deterministic given its inputs: either OUT_FILE gets a complete report
# or nothing changes. NOTE is the agent_note string ("" -> null).
spec_audit_assemble() {
  local static_file="$1" reply_file="$2" project="$3" model="$4" note="$5" out_file="$6"
  jq -n \
    --slurpfile _s "$static_file" \
    --slurpfile _r "$reply_file" \
    --arg project "$project" --arg model "$model" --arg note "$note" \
    --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    ($_s[0]) as $static | ($_r[0]) as $reply |
    ($static.findings // []) as $findings |

    def keyed($e): [($e.line | tostring), $e.rule];
    def is_int_like($v): ($v // "") | tostring | test("^[0-9]+$");

    # Validated + deduped (keep-first) judged entries, restricted to
    # (line,rule) pairs that name a REAL static finding — a reply that
    # references a nonexistent finding is noise, silently dropped, never
    # surfaced or counted.
    ([$findings[] | keyed(.)]) as $real_keys |
    ([($reply.judged // [])[]? | select(type == "object")
        | select((.rule? // "") != "")
        | select(is_int_like(.line))
        | select((.verdict? // "") == "confirm" or (.verdict? // "") == "refute")
        | {line: (.line | tonumber), rule: .rule, verdict: .verdict, reason: (.reason // "")}
      ] | map(. as $e | select($real_keys | any(. == keyed($e))))
        | reduce .[] as $j ([]; if any(.[]; keyed(.) == keyed($j)) then . else . + [$j] end)
    ) as $judged |

    # Validated + deduped (keep-first) additional entries — new judgment-tier
    # smells, not cross-checked against the static list (they are not IN it
    # by design).
    ([($reply.additional // [])[]? | select(type == "object")
        | select((.smell? // "") != "")
        | {smell: .smell, reason: (.reason // "")}
      ] | reduce .[] as $a ([]; if any(.[]; . == $a) then . else . + [$a] end)
    ) as $additional |

    # Known boundary (same property test-audit.sh documents for its own
    # recompute): this arithmetic is trustworthy regardless of what the
    # agent CLAIMS about totals, but it still trusts the per-finding
    # JUDGMENT CALL the agent makes (confirm vs. refute) — a parseable,
    # well-formed reply that refutes every real static finding legitimately
    # drives final_total to 0 by design. The recompute guards against
    # hostile or sloppy ARITHMETIC from the agent (e.g. a bogus top-level
    # "summary" block, or a miscounted array); it is not a check on whether
    # the individual verdicts the agent reached were correct.
    ($findings | length) as $static_total |
    ($judged | map(select(.verdict == "confirm")) | length) as $confirmed |
    ($judged | map(select(.verdict == "refute")) | length) as $refuted |
    ($static_total - $confirmed - $refuted) as $unjudged |
    ($additional | length) as $additional_count |

    {
      schema: "night-shift-spec-audit/1",
      generated_at: $generated,
      spec: $static.spec,
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
spec_audit_write_md() {
  local json="$1" md="$2" note
  {
    printf '# Spec audit report\n\n'
    printf -- '- Spec: `%s`\n' "$(jq -r '.spec' "$json")"
    printf -- '- Project: `%s`\n' "$(jq -r 'if .project == "" then "(cwd)" else .project end' "$json")"
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
    jq -r '.judged[]? | select(.verdict=="confirm") | "- line \(.line) (\(.rule)) — \(.reason)"' "$json"
    printf '\n## Refuted findings (false positive)\n\n'
    jq -r '.judged[]? | select(.verdict=="refute") | "- line \(.line) (\(.rule)) — \(.reason)"' "$json"
    printf '\n## Unjudged static findings\n\n'
    jq -r '
      (.static.findings // []) as $all | (.judged // []) as $j |
      [ $all[] | . as $f
        | select(([$j[] | select(.line==$f.line and .rule==$f.rule)] | length) == 0) ]
      | .[] | "- line \(.line) (\(.rule)) — \(.excerpt)"
    ' "$json" 2>/dev/null
    printf '\n## Additional (judgment-tier) findings\n\n'
    jq -r '.additional[]? | "- \(.smell) — \(.reason)"' "$json"
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
    printf 'You are auditing a spec markdown file BEFORE it is handed to an autonomous\ncoding agent for an unattended overnight run. A bad spec is expensive: an\nagent that burns hours implementing against an untestable acceptance\ncriterion, or validating with a command that never touches the change it\ndescribes, only surfaces the problem after the run — not before it.\n\n'
    printf '## Deterministic static findings (night-shift-spec-audit-static/1) — a\nmechanical line-scan, NOT a parser; treat every finding as a candidate to\nverify, not a verdict\n```json\n'
    cat "$STATIC"
    printf '\n```\n\n'
    printf '## Spec under audit (%s)\n```\n' "$SPEC_RESOLVED"
    cat "$SPEC_RESOLVED" 2>/dev/null
    printf '\n```\n\n'
    printf 'Your job has two parts.\n\n(a) For EACH static finding above (identified by line:rule), judge whether\nit is a genuine spec-quality problem ("confirm") or a false positive from\nthe mechanical scan ("refute"), with a one-line reason. Your `judged` array\nMUST contain exactly one entry for EVERY static finding above — one confirm\nor refute each, none omitted. Copy each finding'"'"'s line and rule VERBATIM\nfrom the static-findings JSON.\n\n'
    printf '(b) Separately, hunt for judgment-tier smells the static scan cannot see:\nan acceptance criterion that is not actually TESTABLE (no way to verify\npass/fail from the words on the page); a final-validation command that\nwould not EXERCISE the change the spec describes (e.g. a lint-only command\nfor a behavioral change); an edge case the spec'"'"'s own description implies\nbut never states (a stated range, format, or error path with no\ncorresponding acceptance criterion); scope left under-specified for the\nstated goal; a Design Contract referenced with no measurable target (no\nconcrete tolerance, size, or reference to check against). Only report\nsomething you have real evidence for — do not guess, and do not repeat a\nstatic finding as an "additional" one.\n\n'
    printf 'Reply with ONLY a single fenced json code block containing exactly one\nJSON object: {"judged":[{"line":<n>,"rule":"<static rule\nname>","verdict":"confirm"|"refute","reason":"<one line>"}, ...],\n"additional":[{"smell":"<short-kebab-case name>","reason":"<one line>"},\n...]}. Omit additional entries you have nothing to report for — do not pad\nthat array. `judged` is never empty when static findings exist above: it\nmirrors them one-for-one.\n'
  } >"$PROMPT_FILE"

  RAW="$TMP_DIR/raw.json"
  LAST_REASON=""
  SUCCESS=0
  attempt=1
  while [ "$attempt" -le 2 ]; do
    RETRY_NOTE=""
    [ "$attempt" -eq 1 ] || RETRY_NOTE="Your previous reply could not be parsed ($LAST_REASON). Reply with ONLY the fenced json code block, no other prose.\n\n"
    # word-split is deliberate: spec_audit_model_flag emits `--model X` or
    # nothing at all (empty/inherit) — same reasoning as test-audit.sh's own
    # call site.
    # shellcheck disable=SC2046
    ( { [ -z "$RETRY_NOTE" ] || printf '%b' "$RETRY_NOTE"; cat "$PROMPT_FILE"; } | \
      claude -p $(spec_audit_model_flag "$MODEL") --output-format json ) >"$RAW" 2>"$RAW.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      LAST_REASON="claude -p exited $rc: $(head -c 200 "$RAW.err" 2>/dev/null | tr '\n' ' ')"
      attempt=$((attempt + 1))
      continue
    fi
    if spec_audit_extract_reply "$RAW" "$REPLY" && spec_audit_valid_reply "$REPLY"; then
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
spec_audit_assemble "$STATIC" "$REPLY" "$PROJECT" "$MODEL" "$NOTE" "$OUT"
[ -s "$OUT" ] || die "assembly produced no report"
spec_audit_write_md "$OUT" "$MD_OUT"

FINAL_TOTAL="$(jq -r '.summary.final_total // 0' "$OUT" 2>/dev/null)"
case "$FINAL_TOTAL" in ''|*[!0-9]*) FINAL_TOTAL=0 ;; esac
log "wrote $OUT (final_total=$FINAL_TOTAL)"
if [ "$FINAL_TOTAL" -gt 0 ]; then
  exit 2
else
  exit 0
fi
