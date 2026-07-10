# shellcheck shell=bash
# scripts/lib/port-audit-normalize.sh
#
# Reply extraction + deterministic assembly for the port-audit agent pass
# (port-fidelity Task 8). Mirrors the fail-closed discipline of
# scripts/lib/normalize.sh's extract_claude_structured/normalize_*_result: pull
# the model's JSON out of whatever shape it came back in (a raw
# `claude -p --output-format json` envelope, OR — for --offline fixtures — the
# agent's reply object handed over directly), never silently accept a shape
# that fails validation, and never let agent-supplied arithmetic leak into the
# report. Sourced by scripts/port-audit.sh.
#
# THE key discipline (binding, from the Task 8 brief): the agent's reply
# supplies ONLY the element-to-code MAPPING — {elementId, property, evidence:
# "file:line"} triples, nothing else. Any expected/actual/status/delta fields
# a model stuffs into a reply entry are read by nobody below — port_audit_assemble
# recomputes expected (from the manifest, looked up by elementId+property) and
# actual (from the material, looked up by the evidence file:line) itself, then
# derives status/delta from THOSE, so a model that free-associates a wrong
# "status":"match" over numbers that actually differ gets silently corrected.
# A manifest element/property the agent never mentions is not an omission the
# agent must justify — port_audit_assemble notices the silence itself and
# emits a "missing" entry, so coverage is complete regardless of what the
# model chose to report.

# ---------------------------------------------------------------------------
# Reply extraction
# ---------------------------------------------------------------------------

# Extracts the agent's {"entries": [...]} object from $1 into $2. Tries, in
# order: (0) $1 IS ALREADY the reply object (what --offline hands over — no
# claude envelope to unwrap); (1) the whole `.result` of a
# `claude -p --output-format json` envelope, parsed as JSON; (2) the LAST
# fenced code block inside `.result`; (3) the outermost {...} embedded in
# `.result` prose. Same shape-cascade discipline as normalize.sh's
# extract_claude_structured. Returns 1 (fail closed) if no shape yields an
# object with an `entries` key — the caller retries once, then gives up.
port_audit_extract_reply() {
  local raw="$1" out="$2" candidate fenced braced

  if jq -e 'type == "object" and has("entries")' "$raw" >/dev/null 2>&1; then
    jq '.' "$raw" >"$out" 2>/dev/null && return 0
    return 1
  fi

  candidate="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
  [ -n "$candidate" ] || return 1

  if printf '%s' "$candidate" | jq -e 'type == "object" and has("entries")' >/dev/null 2>&1; then
    printf '%s' "$candidate" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  fenced="$(printf '%s\n' "$candidate" | awk '
    /^[ \t]*```/ { if (infence) { infence=0; last=buf } else { infence=1; buf="" } next }
    infence { buf = buf $0 "\n" }
    END { printf "%s", last }
  ')"
  if [ -n "$fenced" ] && printf '%s' "$fenced" | jq -e 'type == "object" and has("entries")' >/dev/null 2>&1; then
    printf '%s' "$fenced" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  braced="$(printf '%s' "$candidate" | tr '\n' ' ' | sed -E 's/^[^{]*//; s/[^}]*$//')"
  if [ -n "$braced" ] && printf '%s' "$braced" | jq -e 'type == "object" and has("entries")' >/dev/null 2>&1; then
    printf '%s' "$braced" | jq '.' >"$out" 2>/dev/null && return 0
  fi

  return 1
}

# Shape validation beyond "has an entries key": entries must be an array (of
# anything — non-object elements are silently dropped by port_audit_assemble,
# same tolerance normalize.sh's persona/observer coercers give a stray string
# array element). A reply where `entries` is present but e.g. a string or an
# object is garbage and must fail so the retry/failure path engages.
port_audit_valid_entries() {
  local file="$1"
  jq -e '(.entries? ) | type == "array"' "$file" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Deterministic assembly (manifest + material + agent mapping -> report)
# ---------------------------------------------------------------------------

# The property-mapping table (documented here since there is no separate
# schema doc for it): typography fields map 1:1 to element.typography.*;
# color/backgroundColor map to element.color/.background; borderRadius maps to
# element.radius; iconSize/width/height map to element.iconSize/bounds.w/.h.
# element.spacing carries only THREE fields (marginTop, paddingH, gapToPrev —
# see Task 2/3), not one per CSS/RN directional property, so every margin*/
# padding* usage property collapses onto marginTop/paddingH; "gap" maps to
# gapToPrev. Figma-mode manifests have marginTop/paddingH structurally 0 (no
# CSS box model in the node-dump grammar — Task 3's note), so on a figma-source
# manifest margin*/padding* prefer gapToPrev instead, per the brief.
#
# port_audit_assemble MANIFEST_FILE MATERIAL_FILE AGENT_ENTRIES_FILE SCREEN \
#   MANIFEST_DISPLAY_PATH MODEL OUT_FILE
# Writes the night-shift-port-audit/1 report to OUT_FILE. Pure/deterministic
# given its five inputs; the caller decides what to do on jq failure (this
# function has no partial-success path — either OUT_FILE gets a complete
# report or nothing changes).
port_audit_assemble() {
  local manifest_file="$1" material_file="$2" agent_file="$3" screen="$4" \
    manifest_path="$5" model="$6" out_file="$7"
  jq -n \
    --slurpfile _m "$manifest_file" \
    --slurpfile _mat "$material_file" \
    --slurpfile _ae "$agent_file" \
    --arg screen "$screen" --arg manifestPath "$manifest_path" --arg model "$model" '
    ($_m[0]) as $m | ($_mat[0]) as $mat |
    (($_ae[0].entries // []) | map(select(type == "object"))) as $ae |

    def find_el($id): ([$m.elements[]? | select(.id == $id)] | first) // null;
    def find_usage($file; $line): ([$mat.usages[]? | select(.file == $file and .line == $line)] | first) // null;

    # expected_value: the ONLY source of "expected" — never trust an agent-
    # supplied expected/actual/status, only elementId+property+evidence.
    def expected_value($id; $property):
      (find_el($id)) as $el |
      if $el == null then null
      elif $property == "fontSize" then ($el.typography.fontSize // null)
      elif $property == "fontWeight" then ($el.typography.fontWeight // null)
      elif $property == "fontFamily" then ($el.typography.fontFamily // null)
      elif $property == "lineHeight" then ($el.typography.lineHeight // null)
      elif $property == "letterSpacing" then ($el.typography.letterSpacing // null)
      elif $property == "color" then ($el.color // null)
      elif $property == "backgroundColor" then ($el.background // null)
      elif $property == "borderRadius" then ($el.radius // null)
      elif $property == "iconSize" then ($el.iconSize // null)
      elif $property == "width" then ($el.bounds.w // null)
      elif $property == "height" then ($el.bounds.h // null)
      elif ($property == "gap") then ($el.spacing.gapToPrev // null)
      elif ($property | test("^margin")) then
        (if ($m.source.kind // "") == "figma" then ($el.spacing.gapToPrev // null) else ($el.spacing.marginTop // null) end)
      elif ($property | test("^padding")) then
        (if ($m.source.kind // "") == "figma" then ($el.spacing.gapToPrev // null) else ($el.spacing.paddingH // null) end)
      else null
      end;

    def tonum: if type == "number" then . elif (type == "string" and test("^-?[0-9]+(\\.[0-9]+)?$")) then tonumber else null end;
    # Case-fold + strip a leftover quote pair before comparing strings — the
    # brief: manifest hex is always lowercase, material `resolved` may carry
    # any case (a token literal keeps its source casing).
    def foldstr: if . == null then null elif (type == "string") then (gsub("^[\"'\'']|[\"'\'']$"; "") | ascii_downcase) else (tostring | ascii_downcase) end;

    # The ONE place status/delta are decided. Numeric tolerance |delta|<=1 is
    # a match (the brief); otherwise exact case-folded string equality.
    def compare($expected; $actual):
      ($expected | tonum) as $en | ($actual | tonum) as $an |
      if ($en != null and $an != null) then
        ($an - $en) as $d | ((if $d < 0 then -$d else $d end) <= 1) as $close |
        (if $close then {status: "match", delta: $d} else {status: "off", delta: $d} end)
      else
        ($expected | foldstr) as $es | ($actual | foldstr) as $as |
        if $es == $as then {status: "match", delta: 0}
        else {status: "off", delta: null} end
      end;

    # Resolve one agent-reported {elementId, property, evidence} triple into a
    # full report entry. evidence missing/unparseable -> unknown (the agent
    # named a pair but gave nothing usable); evidence present but does not
    # resolve to a real material usage -> unknown (agent pointed at a bogus
    # file:line); expected absent (no such manifest element/property) ->
    # extra (a real code style with no manifest counterpart); otherwise a
    # normal expected-vs-actual compare.
    def resolve_reported($e):
      ($e.elementId // null) as $id | ($e.property // "") as $prop | ($e.evidence // "") as $ev |
      (($ev | capture("^(?<file>.+):(?<line>[0-9]+)$"))? // null) as $loc |
      if $loc == null then
        { elementId: $id, property: $prop, expected: null, actual: null, status: "unknown", delta: null,
          evidence: (if $ev == "" then null else $ev end) }
      else
        (find_usage($loc.file; ($loc.line | tonumber))) as $u |
        (if $id == null then null else expected_value($id; $prop) end) as $exp |
        if $u == null then
          { elementId: $id, property: $prop, expected: $exp, actual: null, status: "unknown", delta: null, evidence: $ev }
        elif $exp == null then
          { elementId: $id, property: $prop, expected: null, actual: $u.resolved, status: "extra", delta: null, evidence: $ev }
        elif (($m.source.kind // "") == "figma"
              and ($prop | test("^(gap$|margin|padding)"))
              and (($exp | tonum) != null) and (($exp | tonum) < 0)) then
          # A NEGATIVE figma spacing expectation (the gapToPrev of an
          # absolute-positioned/overlapping node, e.g. -625 on the live
          # gate login screen) is an overlap ARTIFACT of the y-sorted gap
          # chain, not design truth: never let it decide off OR match.
          # Status "unknown" keeps the pair visible (expected/actual/evidence
          # intact) without poisoning pct in either direction. Web manifests
          # are unaffected — their spacing comes from the real CSS box model.
          { elementId: $id, property: $prop, expected: $exp, actual: $u.resolved, status: "unknown", delta: null, evidence: $ev }
        else
          (compare($exp; $u.resolved)) as $c |
          { elementId: $id, property: $prop, expected: $exp, actual: $u.resolved, status: $c.status, delta: $c.delta, evidence: $ev }
        end
      end;

    # Dedupe on (elementId, property), KEEP-FIRST in reply order: a sloppy or
    # adversarial agent reporting the same pair twice must not inflate the
    # summary counts/pct (the one axis where reply CONTENT could otherwise
    # move the summary), and the entries array itself must carry no
    # duplicates. reduce (not unique_by) so "first reported wins" is explicit
    # rather than an artifact of sort stability. null elementIds dedupe too —
    # "extra" is informational, one entry per property is enough.
    ([$ae[]? | resolve_reported(.)]
      | reduce .[] as $e ([];
          if any(.[]; .elementId == $e.elementId and .property == $e.property)
          then . else . + [$e] end)) as $reported |

    # Deterministic "missing" checklist: manifest elements x a SMALL set of
    # always-checkable, cleanly-null-or-not properties (typography/color/
    # background/radius/iconSize — NOT spacing/bounds, whose manifest-side
    # values are never null and would make every element "checkable" for
    # properties no source line plausibly sets). Silence on a checklist item
    # means "not implemented" — the wrapper infers this itself; the agent
    # never has to affirmatively claim an absence. Any (elementId, property)
    # pair the agent DID report, in or out of this checklist, is excluded here
    # (already covered by $reported above, whatever its resolved status).
    ([$reported[] | select(.elementId != null) | [.elementId, .property]]) as $covered |
    ([
      $m.elements[]? as $el |
      (
        (if $el.typography != null then ["fontSize", "fontWeight"] else [] end)
        + (if $el.color != null then ["color"] else [] end)
        + (if $el.background != null then ["backgroundColor"] else [] end)
        + (if ($el.radius // 0) > 0 then ["borderRadius"] else [] end)
        + (if $el.iconSize != null then ["iconSize"] else [] end)
      )[] as $prop |
      select(($covered | any(.[0] == $el.id and .[1] == $prop)) | not) |
      { elementId: $el.id, property: $prop, expected: expected_value($el.id; $prop), actual: null,
        status: "missing", delta: null, evidence: null }
    ]) as $missing |

    ($reported + $missing) as $entries |
    ($entries | length) as $total |
    ($entries | map(select(.status == "match")) | length) as $nmatch |
    ($entries | map(select(.status == "off")) | length) as $noff |
    ($entries | map(select(.status == "missing")) | length) as $nmissing |
    ($entries | map(select(.status == "extra")) | length) as $nextra |
    ($entries | map(select(.status == "unknown")) | length) as $nunknown |

    {
      schema: "night-shift-port-audit/1",
      screen: $screen,
      manifest: $manifestPath,
      model: $model,
      entries: $entries,
      summary: {
        match: $nmatch, off: $noff, missing: $nmissing, extra: $nextra, unknown: $nunknown,
        pct: (if $total > 0 then (($nmatch * 100 / $total) | round) else 0 end)
      }
    }
  ' >"$out_file"
}

# Writes the fail-closed empty report: entries:[] + summary.error, used after
# the agent pass exhausts its retry budget (2 failed attempts). Never blocks
# the caller — port-audit.sh still exits 3 (a real signal that fidelity
# auditing didn't happen this run), but the report file always exists.
port_audit_error_report() {
  local screen="$1" manifest_path="$2" model="$3" reason="$4" out_file="$5"
  jq -n --arg screen "$screen" --arg manifestPath "$manifest_path" --arg model "$model" --arg reason "$reason" '
    { schema: "night-shift-port-audit/1", screen: $screen, manifest: $manifestPath, model: $model,
      entries: [], summary: { error: $reason } }
  ' >"$out_file"
}
