#!/usr/bin/env bash
# shellcheck shell=bash
#
# port-audit.sh — the port-fidelity agent pass + report (Task 8, closing
# Phase B). Wraps Task 7's deterministic material extractor
# (scripts/lib/port-audit-static.js) and a Task 2/3 design manifest with ONE
# bounded `claude -p` agent pass, then hands the agent's reply to
# scripts/lib/port-audit-normalize.sh for deterministic assembly: the agent's
# ONLY job is to map manifest elements to the source lines that implement
# them (an {elementId, property, evidence:"file:line"} triple per finding) —
# every expected/actual/status/delta value in the final report is computed by
# the wrapper from the manifest + material data itself, never trusted from
# the agent's own arithmetic (see port-audit-normalize.sh's header).
#
# Usage:
#   scripts/port-audit.sh --project <rn-app> --screen <name> --manifest <path>
#     [--scope src/features/<dir>] [--tokens <path>] [--model <name>]
#     [--live] [--device <label>] [--state <name>] [--reference <png>]
#     [--offline <canned-reply.json>]
#
# Options:
#   --project DIR    required; target RN app repo.
#   --screen NAME    required; screen name (report filename stem).
#   --manifest PATH  required; a night-shift-design-manifest/1 JSON, either
#                    absolute or relative to --project (matching Task 4's
#                    `- Design manifest:` convention). Rejected if absolute-
#                    looking-but-outside or containing `..` — same escape
#                    discipline as manifest_path_resolve in night-shift.sh,
#                    minus its symlink-chase (this CLI reads the file once,
#                    it is not fed unattended into a long-lived prompt tree).
#   --scope DIR      passed through to port-audit-static.js (project-relative
#                    source dir to scan). Default: src/features/<screen>.
#   --tokens PATH    passed through to port-audit-static.js. Default:
#                    src/ui/tokens.ts (its own default).
#   --model NAME     model for the one paid `claude -p` call. Default: empty
#                    (inherit — the CLI's own startup model; no --model flag
#                    is passed to claude at all). `inherit` is a synonym.
#   --live           after the report, attempt one capture+odiff for this
#                    screen (reuses scripts/lib/visual-capture.sh's guard +
#                    capture functions — never reimplemented here). Adds
#                    summary.pixelDiffPct (0-100) on success, or
#                    summary.pixelDiffPct:null + summary.liveSkipped:<reason>
#                    when the prerequisites/tooling/reference aren't there.
#                    Never blocks: --live degrades to a skip, same spirit as
#                    run_visual_capture.
#   --device LABEL   --live only; simulator device label. Default: iphone-15.
#   --state NAME     --live only; screen state. Default: default.
#   --reference PNG  --live only; reference image to diff against. Default:
#                    <dirname of --manifest>/<screen>.png, falling back to
#                    <dirname of --manifest>/<screen>-*.png (cdp-extract's web
#                    naming) if present.
#   --offline FILE   skip the paid `claude -p` call entirely; feed FILE (the
#                    agent's reply, or a full `claude -p --output-format
#                    json` envelope containing one) through the SAME
#                    normalize+assemble path a live run uses. This is what
#                    the fixture suite exercises — zero cost, fully
#                    deterministic.
#   -h|--help
#
# Produces: <project>/.night-shift/port-audit/<screen>.json (schema
# night-shift-port-audit/1 — see scripts/lib/port-audit-normalize.sh).
#
# Exit status: 0 on success (report written, agent pass succeeded); 2 on a
# usage/argument/precondition error (nothing written, or the failure is not
# about the agent's reply); 3 when the agent pass fails twice in a row (ONE
# retry budget) — the report is still written with entries:[] +
# summary.error, so a caller can always read *a* report, but this exit code
# is the signal that fidelity auditing did not actually happen this run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/port-audit-normalize.sh
source "$SCRIPT_DIR/lib/port-audit-normalize.sh"

log() { printf '[port-audit] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

# model_flag equivalent (binding: reuse the pattern, but this CLI is
# standalone — night-shift.sh's own model_flag is not sourced here). Word-
# splits into `--model X`, or vanishes (empty) when the model is unset/
# "inherit" so `claude -p` falls back to the CLI's own startup model.
port_audit_model_flag() {
  case "$1" in
    inherit|"") ;;
    *) printf -- '--model %s' "$1" ;;
  esac
}

# Reviewer isolation — a copy of night-shift.sh's reviewer_isolation_args
# rule (scripts/lib/memory.sh), re-derived from the same two env knobs since
# this CLI is standalone: NIGHT_SHIFT_REVIEWER_ISOLATION=1, or unset while
# NIGHT_SHIFT_MEMORY=ai-memory, runs the one `claude -p` with hooks off and no
# MCP servers (`--settings {"disableAllHooks":true} --strict-mcp-config`,
# word-split at the call site). This report feeds the observer's evidence, so
# a user-level SessionStart hook (ai-memory injects the project's open handoff
# into every session) must not shape it. `=0` forces it off. Keep in lockstep
# with memory.sh.
port_audit_isolation_args() {
  case "${NIGHT_SHIFT_REVIEWER_ISOLATION:-}" in
    1) ;;
    0) return 0 ;;
    *) [ "${NIGHT_SHIFT_MEMORY:-off}" = "ai-memory" ] || return 0 ;;
  esac
  printf -- '--settings {"disableAllHooks":true} --strict-mcp-config'
}

# ---- args -------------------------------------------------------------------
PROJECT="" SCREEN="" MANIFEST_ARG="" SCOPE="" TOKENS="" MODEL="" OFFLINE=""
LIVE=0 DEVICE="iphone-15" STATE="default" REFERENCE=""
SCOPE_EXPLICIT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="${2:-}"; shift 2 ;;
    --screen)    SCREEN="${2:-}"; shift 2 ;;
    --manifest)  MANIFEST_ARG="${2:-}"; shift 2 ;;
    --scope)     SCOPE="${2:-}"; SCOPE_EXPLICIT=1; shift 2 ;;
    --tokens)    TOKENS="${2:-}"; shift 2 ;;
    --model)     MODEL="${2:-}"; shift 2 ;;
    --offline)   OFFLINE="${2:-}"; shift 2 ;;
    --live)      LIVE=1; shift ;;
    --device)    DEVICE="${2:-}"; shift 2 ;;
    --state)     STATE="${2:-}"; shift 2 ;;
    --reference) REFERENCE="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '3,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required"
[ -n "$SCREEN" ] || die "--screen is required"
[ -n "$MANIFEST_ARG" ] || die "--manifest is required"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
[ -n "$OFFLINE" ] && { [ -f "$OFFLINE" ] || die "--offline file not found: $OFFLINE"; }

# ---- resolve --manifest (project-contained; same escape rules as
# manifest_path_resolve in night-shift.sh, without the symlink chase) --------
case "$MANIFEST_ARG" in
  /*) MANIFEST="$MANIFEST_ARG" ;;
  *)
    case "/$MANIFEST_ARG/" in *"/../"*) die "--manifest must not contain ..: $MANIFEST_ARG" ;; esac
    MANIFEST="$PROJECT/$MANIFEST_ARG"
    ;;
esac
[ -f "$MANIFEST" ] || die "--manifest not found: $MANIFEST_ARG"
jq -e 'type == "object" and (.elements | type == "array")' "$MANIFEST" >/dev/null 2>&1 \
  || die "--manifest is not a valid night-shift-design-manifest/1 JSON: $MANIFEST_ARG"

SCOPE="${SCOPE:-src/features/$SCREEN}"
# A DEFAULT-derived scope (no explicit --scope) silently killed the whole
# audit (die -> exit 2, no report at all) whenever a screen name didn't
# match an existing src/features/<screen> dir — e.g. a screen ported to a
# differently-named or shared feature dir. Fall back to the whole-src
# scope in that case and say so; an EXPLICIT --scope that doesn't exist is
# still an operator error and dies below (in port-audit-static.js).
if [ "$SCOPE_EXPLICIT" -eq 0 ] && [ ! -d "$PROJECT/$SCOPE" ]; then
  log "default scope not found ($SCOPE) under --project; falling back to src (whole-src scope)"
  SCOPE="src"
fi
OUT_DIR="$PROJECT/.night-shift/port-audit"
OUT_FILE="$OUT_DIR/$SCREEN.json"
mkdir -p "$OUT_DIR" || die "cannot create output dir: $OUT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/port-audit.XXXXXX")" || die "cannot create scratch dir"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- material (Task 7, always real/deterministic — --offline only skips the
# agent pass, never the static extraction) ------------------------------------
MATERIAL="$TMP_DIR/material.json"
TOKENS_ARGS=()
[ -z "$TOKENS" ] || TOKENS_ARGS=(--tokens "$TOKENS")
if ! node "$SCRIPT_DIR/lib/port-audit-static.js" --project "$PROJECT" --scope "$SCOPE" \
    "${TOKENS_ARGS[@]}" >"$MATERIAL" 2>"$MATERIAL.err"; then
  die "port-audit-static.js failed: $(cat "$MATERIAL.err" 2>/dev/null)"
fi
[ -s "$MATERIAL" ] || die "port-audit-static.js produced no material"

# ---- build the agent prompt --------------------------------------------------
PROMPT_FILE="$TMP_DIR/prompt.txt"
{
  printf 'You are auditing how faithfully an RN screen port implements its design manifest.\n\n'
  printf '## Design manifest (night-shift-design-manifest/1) — the ground truth\n```json\n'
  cat "$MANIFEST"
  printf '\n```\n\n'
  printf '## Source material (night-shift-port-audit-material/1) — flattened tokens + resolved style-property usages found in the scoped source\n```json\n'
  cat "$MATERIAL"
  printf '\n```\n\n'
  printf 'Your ONLY job: for as many (manifest element, property) pairs as you can, find the ONE source usage that implements it and report {elementId, property, evidence:"file:line"}. Do NOT compute expected/actual/status/delta yourself — omit them entirely; a deterministic wrapper recomputes all of that from the manifest and material data directly, so anything you compute is ignored. Only report a pair you have real evidence for (a usages[] entry, or your own reading of the source, at a specific file:line); do not report pairs you could not find — silence is read as "not implemented", you do not need to say so explicitly. You may also report a usages[] entry that has no manifest counterpart at all (leave elementId null) — informational only.\n\n'
  printf 'Reply with ONLY a single fenced json code block containing exactly one JSON object: {"entries":[{"elementId":"<manifest element id, or null>","property":"<tracked property name>","evidence":"<file>:<line>"}, ...]}.\n'
} >"$PROMPT_FILE"

# ---- the agent pass: one call + one retry -----------------------------------
ENTRIES_FILE="$TMP_DIR/entries.json"
LAST_REASON=""
SUCCESS=0
attempt=1
while [ "$attempt" -le 2 ]; do
  RAW="$TMP_DIR/raw-$attempt.json"
  if [ -n "$OFFLINE" ]; then
    cp "$OFFLINE" "$RAW" 2>/dev/null || { LAST_REASON="--offline file unreadable"; attempt=$((attempt + 1)); continue; }
  else
    RETRY_NOTE=""
    [ "$attempt" -eq 1 ] || RETRY_NOTE="Your previous reply could not be parsed ($LAST_REASON). Reply with ONLY the fenced json code block, no other prose.\n\n"
    # word-split is deliberate: port_audit_model_flag emits `--model X` or
    # nothing at all (empty/inherit) — same reasoning as night-shift.sh's
    # own model_flag call sites.
    # shellcheck disable=SC2046
    ( cd "$PROJECT" && { [ -z "$RETRY_NOTE" ] || printf '%b' "$RETRY_NOTE"; cat "$PROMPT_FILE"; } | \
      claude -p $(port_audit_model_flag "$MODEL") $(port_audit_isolation_args) --output-format json ) >"$RAW" 2>"$RAW.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      LAST_REASON="claude -p exited $rc: $(head -c 200 "$RAW.err" 2>/dev/null | tr '\n' ' ')"
      attempt=$((attempt + 1))
      continue
    fi
  fi
  if port_audit_extract_reply "$RAW" "$ENTRIES_FILE" && port_audit_valid_entries "$ENTRIES_FILE"; then
    SUCCESS=1
    break
  fi
  LAST_REASON="could not extract a valid {entries:[...]} reply"
  attempt=$((attempt + 1))
done

if [ "$SUCCESS" -ne 1 ]; then
  port_audit_error_report "$SCREEN" "$MANIFEST_ARG" "$MODEL" "$LAST_REASON" "$OUT_FILE"
  log "agent pass failed after 2 attempts ($LAST_REASON) — wrote empty report to $OUT_FILE"
  exit 3
fi

port_audit_assemble "$MANIFEST" "$MATERIAL" "$ENTRIES_FILE" "$SCREEN" "$MANIFEST_ARG" "$MODEL" "$OUT_FILE"
[ -s "$OUT_FILE" ] || die "assembly produced no report"

# ---- --live: optional capture+odiff, reusing visual-capture.sh's guards ----
if [ "$LIVE" -eq 1 ]; then
  # shellcheck source=scripts/lib/visual-capture.sh
  source "$SCRIPT_DIR/lib/visual-capture.sh"
  live_reason="" pixel_pct=""
  if ! visual_capture_available; then
    live_reason="no simulator/diff tooling or NIGHT_SHIFT_VISUAL_CAPTURE!=1"
  else
    if [ -z "$REFERENCE" ]; then
      manifest_dir="$(dirname "$MANIFEST")"
      if [ -f "$manifest_dir/$SCREEN.png" ]; then
        REFERENCE="$manifest_dir/$SCREEN.png"
      else
        # cdp-extract's web-mode naming: <screen>-<W>x<H>.png. Globbing
        # without nullglob is deliberate (design-extract.sh's own idiom): an
        # unmatched glob stays a literal, non-existent path.
        for f in "$manifest_dir/$SCREEN"-*.png; do
          [ -e "$f" ] && REFERENCE="$f" && break
        done
      fi
    fi
    if [ -z "$REFERENCE" ] || [ ! -f "$REFERENCE" ]; then
      live_reason="no reference image found for screen '$SCREEN'"
    else
      SHOT="$TMP_DIR/live-shot.png"
      DIFF_IMG="$TMP_DIR/live-diff.png"
      if ! __visual_capture_screenshot "$SCREEN" "$STATE" "$DEVICE" "$SHOT"; then
        live_reason="capture unavailable (no booted/resolvable simulator or preview harness)"
      else
        frac="$(__visual_pixel_diff "$REFERENCE" "$SHOT" "$DIFF_IMG")" || frac=""
        if [ -z "$frac" ]; then
          live_reason="pixel diff unavailable (odiff produced no parseable result)"
        else
          # summary.pixelDiffPct is a 0-100 PERCENTAGE (the field name), while
          # __visual_pixel_diff returns a 0-1 fraction (the existing visual-
          # diff report convention) — convert once, here, at the boundary.
          pixel_pct="$(LC_ALL=C awk -v f="$frac" 'BEGIN{ printf "%.2f", f*100 }')"
        fi
      fi
    fi
  fi
  if [ -n "$pixel_pct" ]; then
    jq --argjson pct "$pixel_pct" '.summary.pixelDiffPct = $pct' "$OUT_FILE" >"$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
  else
    jq --arg reason "$live_reason" '.summary.pixelDiffPct = null | .summary.liveSkipped = $reason' \
      "$OUT_FILE" >"$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
    log "live capture skipped: $live_reason"
  fi
fi

log "wrote $OUT_FILE"
exit 0
