# shellcheck shell=bash
# scripts/lib/normalize.sh
# Verdict extraction + live-model output normalization: pull the JSON verdict
# out of a `claude -p --output-format json` envelope, then coerce sloppily-
# shaped persona/observer verdicts into the strict review schemas (fail-closed
# on BLOCK, never fabricate an APPROVE). Sourced by night-shift.sh.

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

# Coerce a substantively-valid but sloppily-shaped persona-review verdict into the
# strict persona-review schema — the SAME robustness the observer already gets from
# normalize_observer_output. A live model (esp. a cheaper persona tier) reliably
# returns the right STATUS but often the wrong FINDING keys (e.g. file/line/summary/
# details instead of id/evidence/required_change), which would fail json_schema_basic
# and, after the retry, block the whole run on a format nit. So: map status synonyms
# (verdict/APPROVED/PASS/… → APPROVE/BLOCK), keep a schema-valid finding id but
# synthesize REV-NNN for a missing/malformed one, pull evidence/required_change from
# common synonyms, drop unknown keys, and keep APPROVE↔findings consistent.
#
# Bias (deliberate, mirrors the observer): fail-closed on BLOCK — a blocking verdict
# with no usable finding still HALTS the run via a placeholder, and an APPROVE is
# never fabricated. Pure: reads $1, prints normalized JSON; the wrapper stamps
# .persona/.stage before calling this, so those pass through untouched. A non-record
# (review bundle, plan doc) yields junk that still fails json_schema_basic, as before.
# jq prelude shared by BOTH verdict normalizers. The status-synonym map and
# nonempty's non-string skipping are contract-critical and must never diverge
# between the persona and observer parsers — a synonym added to one side makes
# the two review tiers read the same sloppy verdict differently. The findings
# COERCION bodies below stay separate BY DESIGN: persona keeps schema-valid
# finding ids while the observer forces OBS-, and the evidence/required_change
# candidate orders were tuned per tier — that divergence is intentional.
JQ_VERDICT_PRELUDE='
    def norm_status: (. // "BLOCK") | tostring | ascii_upcase
      | if (. == "APPROVE" or . == "APPROVED" or . == "PASS" or . == "OK" or . == "LGTM")
        then "APPROVE" else "BLOCK" end;
    def nonempty($v): ($v | if (type == "string" and length > 0) then . else empty end);
'

normalize_persona_result() {
  jq "${JQ_VERDICT_PRELUDE}"'
    {
      persona: .persona,
      stage: .stage,
      commit: (if (.commit == null or (.commit | type == "string" and length > 0)) then .commit else null end),
      status: ((.status // .verdict) | norm_status),
      findings: ((.findings // []) | to_entries | map(
        (.key + 1) as $k |
        # Coerce a non-object findings element (a live model sometimes emits a bare
        # string, or a mixed array) into an object so the $f.id/$f.evidence lookups
        # below never index a string and abort jq — which would empty the output,
        # force the retry, and spuriously block the run this normalizer exists to save.
        (.value | if type == "object" then . else {evidence: (if type == "string" then . else tostring end)} end) as $f |
        (($f.id // "") | tostring) as $idstr |
        (if ($idstr | test("^[A-Z][A-Z0-9_-]*-[0-9]{3,}$")) then $idstr
         else ("REV-" + ((if ($idstr | test("[0-9]")) then ($idstr | capture("(?<n>[0-9]+)").n) else ($k | tostring) end)
           | if (length < 3) then (("000" + .)[-3:]) else . end)) end) as $id |
        {
          id: $id,
          # Prefer the first NON-EMPTY STRING among the candidates. `//` alone is
          # wrong here: a live model often sets required_change to a BOOLEAN true
          # (treating it as a flag), and `true // x` keeps true -> "true", losing the
          # real change. nonempty() skips non-strings so we fall through to real text.
          evidence: ([nonempty($f.evidence), nonempty($f.summary), nonempty($f.details), nonempty($f.message), nonempty($f.location)] | (.[0] // "see persona notes")),
          required_change: ([nonempty($f.required_change), nonempty($f.recommendation), nonempty($f.fix), nonempty($f.summary), nonempty($f.evidence)] | (.[0] // "address the persona finding"))
        })),
      documentation_changes: ((.documentation_changes // []) | map(select(type == "string" and length > 0)))
    }
    | if .status == "APPROVE" then .findings = []
      elif (.findings | length) == 0 then
        .findings = [{id: "REV-001", evidence: "persona requested changes without a structured finding", required_change: "address the persona feedback"}]
      else . end
  ' "$1"
}


# Coerces a substantively-valid but sloppily-formatted observer verdict into the
# strict observer-review shape: forces the identity fields the wrapper already
# knows (observer/primary/task/candidate_commit), maps status synonyms like
# REQUEST_CHANGES to BLOCK, pads finding ids to OBS-NNN, drops unknown keys, and
# keeps APPROVE<->findings consistent. This stops a well-meaning verdict from
# wedging the run on a format nit.
#
# $4 (primary), optional, defaults to "claude": the ACTUAL implement vendor for
# this task (the caller passes stage_engine's answer). Defaulting to "claude"
# keeps every pre-existing 3-arg call site (fixtures included) byte-for-byte —
# this field is forced regardless of what the model wrote, so a codex-implement
# task's observer output must be normalized to "codex" here, not left at
# whatever normalize_observer_output would otherwise hardcode.
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
  local file="$1" task="$2" candidate="$3" primary="${4:-claude}" tmp="$1.norm.$$"
  jq --arg task "$task" --arg candidate "$candidate" --arg primary "$primary" "${JQ_VERDICT_PRELUDE}"'
    # Prefer the first NON-EMPTY STRING among candidates: a live model (observer
    # included — verified) often sets required_change to a BOOLEAN true, and a plain
    # `//` keeps it -> "true". nonempty() skips non-strings so we fall through to real
    # text (required_change falls back to the finding evidence when no change text).
    {
      observer: "claude",
      primary: $primary,
      task: $task,
      candidate_commit: $candidate,
      status: (.status | norm_status),
      findings: ((.findings // []) | to_entries | map(
        (.key + 1) as $k |
        # Coerce a non-object findings element (a live model sometimes emits a bare
        # string, or a mixed array) into an object so the $f.id/$f.evidence lookups
        # below never index a string and abort jq — which would empty the output,
        # force the retry, and spuriously block the run this normalizer exists to save.
        (.value | if type == "object" then . else {evidence: (if type == "string" then . else tostring end)} end) as $f |
        (($f.id // "") | tostring) as $idstr |
        (if ($idstr | test("[0-9]")) then ($idstr | capture("(?<n>[0-9]+)").n) else ($k | tostring) end) as $num |
        {
          id: ("OBS-" + (if ($num | length) < 3 then (("000" + $num)[-3:]) else $num end)),
          evidence: ([nonempty($f.evidence), nonempty($f.location), nonempty($f.summary), nonempty($f.details), nonempty($f.message)] | (.[0] // "see observer notes")),
          required_change: ([nonempty($f.required_change), nonempty($f.summary), nonempty($f.recommendation), nonempty($f.fix), nonempty($f.evidence)] | (.[0] // "address the observer finding"))
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

