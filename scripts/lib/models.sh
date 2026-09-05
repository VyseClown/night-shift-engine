# shellcheck shell=bash
# shellcheck disable=SC2153
# ^ STATE is the orchestrator's run-state path global (night-shift.sh), not a
#   misspelling of a local `state`; resolve_effective_model reads it at runtime.
# scripts/lib/models.sh
# Model-name helpers shared by the orchestrator AND the standalone surfaces
# (scripts/visual-review.sh sources the visual libs without night-shift.sh),
# so every `claude -p` the engine spawns builds its --model argument the same
# way: `inherit`/empty means "no flag, the CLI's startup model", anything else
# is passed VERBATIM to `claude --model` (aliases like opus/sonnet/haiku or
# full IDs like claude-fable-5-1 — the engine never validates or rewrites a
# model name, which is what keeps it open to models that did not exist when
# this file was written). Pure functions only; no globals are written here.

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

# Pure: the model to fall back to when a per-model usage cap hits.
#
# NIGHT_SHIFT_MODEL_FALLBACK_CHAIN, when set, is the ONLY source of truth: an
# ordered, `>`-separated list from scarcest to cheapest (e.g.
# `claude-fable-5-1>opus>sonnet>haiku`). The successor of a model is the next
# entry after its first exact match; the last entry — and any model not in the
# chain — has no successor. This is how a model the built-in ladder has never
# heard of still gets a fallback: name it in the chain, no engine edit needed.
#
# Without the knob the built-in ladder applies. It only ever steps DOWN in
# scarcity (fable -> opus -> sonnet) so a fallback can never burn a scarcer
# budget than the one that just capped; it matches by FAMILY substring so a
# full ID (`claude-fable-5-1`, `claude-opus-4-8`) maps exactly like its alias —
# knobs are documented to accept full IDs anywhere. sonnet (and any unknown
# name) has no successor: echo unchanged + return 1, and the caller blocks for
# manual resume rather than guessing.
successor_model() {
  local model="$1" chain="${NIGHT_SHIFT_MODEL_FALLBACK_CHAIN:-}" entry found=0 next=""
  if [ -n "$chain" ]; then
    # Walk the chain once: the entry AFTER the first exact match is the
    # successor. Entries are trimmed of surrounding whitespace so a chain
    # written `a > b > c` behaves like `a>b>c`.
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"; entry="${entry%"${entry##*[![:space:]]}"}"
      [ -n "$entry" ] || continue
      if [ "$found" -eq 1 ]; then next="$entry"; break; fi
      [ "$entry" = "$model" ] && found=1
    done <<EOF
$(printf '%s' "$chain" | tr '>' '\n')
EOF
    if [ -n "$next" ]; then printf '%s' "$next"; return 0; fi
    printf '%s' "$model"; return 1
  fi
  case "$model" in
    *fable*) printf 'opus' ;;
    *opus*) printf 'sonnet' ;;
    *) printf '%s' "$model"; return 1 ;;
  esac
}

# Map a configured model through the run's persisted `.model_fallbacks` in
# state (written by handle_per_model_limit under NIGHT_SHIFT_MODEL_FALLBACK=1),
# so every consumer of a model knob — primary, personas, observer, port-audit —
# honors a fallback recorded earlier in the run. Follows chains (fable->opus
# recorded, then opus->sonnet later) with a small hop bound so a corrupt cyclic
# map cannot loop. No state / no mapping -> echoes the input unchanged.
resolve_effective_model() {
  local model="$1" mapped hops=0
  [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ] || { printf '%s' "$model"; return 0; }
  while [ "$hops" -lt 4 ]; do
    mapped="$(jq -r --arg m "$model" '.model_fallbacks[$m] // empty' "$STATE" 2>/dev/null)"
    { [ -n "$mapped" ] && [ "$mapped" != "$model" ]; } || break
    model="$mapped"
    hops=$((hops + 1))
  done
  printf '%s' "$model"
}

# Pure: the complete `--model X` argv fragment for a knob value — the fallback
# map applied, then the inherit/empty rule. The one-liner every call site
# should use (word-split at the call site, like model_flag). Exists so the
# visual libs, which run under scripts/visual-review.sh without the
# orchestrator, build their model args through exactly the same two rules.
claude_model_args() {
  model_flag "$(resolve_effective_model "$1")"
}
