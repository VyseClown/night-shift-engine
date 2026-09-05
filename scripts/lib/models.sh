# shellcheck shell=bash
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
# Two layers, consulted in order:
#   1. NIGHT_SHIFT_MODEL_FALLBACK_CHAIN — an explicit, ordered, `>`-separated
#      list from scarcest to cheapest (e.g. `claude-fable-5-1>opus>sonnet`).
#      The successor of a model is the entry after its first EXACT match. This
#      is how a model the built-in ladder has never heard of gets a fallback:
#      name it in the chain, no engine edit needed. The chain OVERRIDES the
#      ladder for the models it names and leaves every other model to it, so
#      one exotic PLAN_MODEL entry never strips opus/sonnet of theirs.
#   2. The built-in ladder. It only ever steps DOWN in scarcity (fable -> opus
#      -> sonnet) so a fallback can never burn a scarcer budget than the one
#      that just capped; it matches by FAMILY substring so a full ID
#      (`claude-fable-5-1`, `claude-opus-4-8`) maps exactly like its alias —
#      knobs are documented to accept full IDs anywhere.
# sonnet (and any unknown name) has no successor: echo unchanged + return 1,
# and the caller blocks for manual resume rather than guessing. Whitespace in
# the chain is stripped outright (model names never contain spaces).
successor_model() {
  local model="$1" entry found=0
  local -a parts=()
  IFS='>' read -ra parts <<<"${NIGHT_SHIFT_MODEL_FALLBACK_CHAIN:-}"
  for entry in ${parts[@]+"${parts[@]}"}; do
    entry="${entry//[[:space:]]/}"
    [ -n "$entry" ] || continue
    [ "$found" -eq 1 ] && { printf '%s' "$entry"; return 0; }
    [ "$entry" = "$model" ] && found=1
  done
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
# recorded, then opus->sonnet later) with a hop bound — generous enough for
# any NIGHT_SHIFT_MODEL_FALLBACK_CHAIN an operator would write, small enough
# that a corrupt cyclic map cannot loop. No state / no mapping -> echoes the
# input unchanged.
resolve_effective_model() {
  local model="$1" mapped hops=0
  [ -n "${STATE:-}" ] && [ -f "${STATE:-}" ] || { printf '%s' "$model"; return 0; }
  while [ "$hops" -lt 16 ]; do
    mapped="$(jq -r --arg m "$model" '.model_fallbacks[$m] // empty' "$STATE" 2>/dev/null)"
    { [ -n "$mapped" ] && [ "$mapped" != "$model" ]; } || break
    model="$mapped"
    hops=$((hops + 1))
  done
  printf '%s' "$model"
}

# Pure: the complete `--model X` argv fragment for a knob value — the fallback
# map applied, then the inherit/empty rule. Every `claude -p` the engine
# spawns builds its model argv through this one-liner (word-split at the call
# site, like model_flag); only sites that need the bare resolved NAME (the
# primary turn, which hands it to handle_per_model_limit; the audit CLIs,
# which take --model) call resolve_effective_model directly.
claude_model_args() {
  model_flag "$(resolve_effective_model "$1")"
}

# The ONE table behind every per-step model knob: step -> its override knob,
# else its parent tier. EMPTY override = follow the tier (an unset knob is
# byte-identical to the tiering); `inherit` passes through to model_flag as
# "no --model". The tier fallbacks (`sonnet`) only matter when a lib is
# sourced without the orchestrator's knob block — under night-shift.sh every
# tier is always set. stage_model / persona_stage_model delegate here, every
# call site reads the same arm, and initialize_run iterates STEP_MODEL_STEPS
# to journal them, so a new step is one arm + one word in the list and the
# journal cannot drift from the call site. Unknown step -> "inherit".
# shellcheck disable=SC2034  # consumed by night-shift.sh's initialize_run (journal) and the fixtures
STEP_MODEL_STEPS="visual observe_request complete persona_plan persona_implementation feedback sweep_fix port_audit test_audit"
step_model() {
  case "$1" in
    visual) printf '%s' "${VISUAL_MODEL:-${IMPLEMENT_MODEL:-sonnet}}" ;;
    observe_request) printf '%s' "${OBSERVE_REQUEST_MODEL:-${IMPLEMENT_MODEL:-sonnet}}" ;;
    complete) printf '%s' "${COMPLETE_MODEL:-${IMPLEMENT_MODEL:-sonnet}}" ;;
    feedback) printf '%s' "${FEEDBACK_MODEL:-${IMPLEMENT_MODEL:-sonnet}}" ;;
    sweep_fix) printf '%s' "${SWEEP_FIX_MODEL:-${IMPLEMENT_MODEL:-sonnet}}" ;;
    persona_plan) printf '%s' "${PERSONA_PLAN_MODEL:-${PERSONA_MODEL:-sonnet}}" ;;
    persona_implementation) printf '%s' "${PERSONA_IMPLEMENTATION_MODEL:-${PERSONA_MODEL:-sonnet}}" ;;
    port_audit) printf '%s' "${PORT_AUDIT_MODEL:-${PERSONA_MODEL:-sonnet}}" ;;
    test_audit) printf '%s' "${TEST_AUDIT_MODEL:-sonnet}" ;;
    *) printf 'inherit' ;;
  esac
}
