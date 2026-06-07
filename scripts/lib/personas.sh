# shellcheck shell=bash
# Persona/profile resolution for night-shift.sh.
#
# Sourced by the orchestrator (not executed directly); it inherits the parent's
# shell options and relies on POSIX tools (sed/grep/tr/printf). It owns the
# persona/track constants and the pure functions that map a spec to its active
# review set: track/profile presets, optional reviewers (field + contract
# section), and the explicit `- Personas:` override. No side effects, no global
# state beyond the constants below — which is why it carries the bulk of the
# deterministic fixture suite.

# Persona sets per track. A spec's `- Track:` field (rn | web, default rn)
# selects which set and floor apply, so a React Native spec and a web spec each
# get reviewers that fit their stack. PERSONAS (the union) is used ONLY for the
# persona-review schema membership check; the per-track sets + floors below drive
# which personas a spec actually runs (see profile_personas/resolve_active_personas).
PERSONAS_RN="Mobile UX Designer|React Native Architect|Mobile Domain Expert|TypeScript & Code Quality Expert|Performance Expert|Human Advocate"
PERSONAS_WEB="Web UX & Accessibility Designer|Web Architect|Backend & Data Expert|TypeScript & Code Quality Expert|Performance Expert|Human Advocate"
# Optional, cross-track personas. They never run unless a spec opts in (an
# `- Optional reviewers:` field listing them, or a matching contract section —
# see optional_contract_heading / resolve_active_personas). They add nothing to
# the active set otherwise, so existing specs are unaffected. To add one: append
# it here, give it a section heading in optional_contract_heading(), add it to the
# PERSONAS union below + the persona-review.json enum, and document it in
# docs/review-personas.md.
PERSONAS_OPTIONAL="Product Reviewer|Design Fidelity Reviewer|Security Reviewer|API Contract Reviewer"
PERSONAS="Mobile UX Designer|React Native Architect|Mobile Domain Expert|Web UX & Accessibility Designer|Web Architect|Backend & Data Expert|TypeScript & Code Quality Expert|Performance Expert|Human Advocate|Product Reviewer|Design Fidelity Reviewer|Security Reviewer|API Contract Reviewer"
# Personas that ALWAYS run, regardless of the spec's review profile. They guard
# correctness and safety so per-spec cost cutting cannot drop them. Every named
# profile in profile_personas() must be a superset of the active track's floor;
# the resolver asserts it at runtime.
PERSONA_FLOOR_RN="React Native Architect|TypeScript & Code Quality Expert|Human Advocate"
PERSONA_FLOOR_WEB="Web Architect|TypeScript & Code Quality Expert|Human Advocate"
# Default track for specs that omit the `- Track:` field (backward compatible:
# every existing React Native spec keeps resolving to the RN persona set).
DEFAULT_TRACK="rn"

# Resolves a track name (rn|web) to its full persona set / floor / valid-profile
# list. An unknown track returns non-zero so callers can reject it.
persona_set() {
  case "$1" in
    rn)  printf '%s' "$PERSONAS_RN" ;;
    web) printf '%s' "$PERSONAS_WEB" ;;
    *)   return 1 ;;
  esac
}

persona_floor() {
  case "$1" in
    rn)  printf '%s' "$PERSONA_FLOOR_RN" ;;
    web) printf '%s' "$PERSONA_FLOOR_WEB" ;;
    *)   return 1 ;;
  esac
}

valid_profiles_for_track() {
  case "$1" in
    rn)  printf 'full, frontend, logic, native' ;;
    web) printf 'full, frontend, logic, data' ;;
    *)   return 1 ;;
  esac
}

# Maps a named review profile to its pipe-delimited active persona set for a
# given track (default rn). Every profile is the track's mandatory floor plus the
# personas relevant to that kind of work. `full` keeps the original six-persona
# behavior per track. Track-specific profiles (`native` for rn, `data` for web)
# are rejected on the other track.
profile_personas() {
  local profile="$1" track="${2:-$DEFAULT_TRACK}" floor set
  floor="$(persona_floor "$track")" || return 1
  set="$(persona_set "$track")" || return 1
  case "$track:$profile" in
    *:full)       printf '%s' "$set" ;;
    rn:frontend)  printf '%s' "$floor|Mobile UX Designer|Performance Expert" ;;
    web:frontend) printf '%s' "$floor|Web UX & Accessibility Designer|Performance Expert" ;;
    *:logic)      printf '%s' "$floor|Performance Expert" ;;
    rn:native)    printf '%s' "$floor|Mobile Domain Expert" ;;
    web:data)     printf '%s' "$floor|Backend & Data Expert" ;;
    *)            return 1 ;;
  esac
}

# Extracts the `- Track: <value>` field from a spec, normalized to a lowercase,
# whitespace-free token. Falls back to DEFAULT_TRACK when the field is absent so
# pre-existing specs (which never declared a track) keep resolving to rn.
spec_track() {
  local t
  t="$(sed -nE 's/^- Track: ?(.*)/\1/p' "$1" | head -n 1 |
    tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ -n "$t" ] || t="$DEFAULT_TRACK"
  printf '%s' "$t"
}

# Extracts the `- Review Profile: <value>` field from a spec, normalized to a
# lowercase, whitespace-free token. Empty when the field is absent.
spec_review_profile() {
  sed -nE 's/^- Review Profile: ?(.*)/\1/p' "$1" | head -n 1 |
    tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

# Maps an optional persona to the `## <heading>` whose presence in a spec
# auto-activates it. The single source of truth for section-based activation;
# adding an optional persona means adding one line here (and to PERSONAS_OPTIONAL,
# the PERSONAS union, the schema enum, and the persona docs).
optional_contract_heading() {
  case "$1" in
    "Product Reviewer")         printf 'Product Contract' ;;
    "Design Fidelity Reviewer") printf 'Design Contract' ;;
    "Security Reviewer")        printf 'Security Contract' ;;
    "API Contract Reviewer")    printf 'API Contract' ;;
    *) return 1 ;;
  esac
}

# Echoes the optional personas a spec opts into, one per line, in a stable order
# (field entries first in declared order, then section-presence auto-activations).
# An `- Optional reviewers:` entry that is not a member of PERSONAS_OPTIONAL is
# rejected (non-zero, message on stderr). Absent field + no contract sections =
# no output, so a spec that does not opt in adds nothing to the active set.
spec_optional_personas() {
  local file="$1" raw entry match opt heading old_ifs sec_ifs
  raw="$(sed -nE 's/^- Optional reviewers: ?(.*)/\1/p' "$file" | head -n 1)"
  old_ifs="$IFS"; IFS=',|'
  for entry in $raw; do
    IFS="$old_ifs"
    entry="$(printf '%s' "$entry" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$entry" in ""|none) IFS=',|'; continue ;; esac
    match=""
    local inner_ifs="$IFS"; IFS='|'
    for opt in $PERSONAS_OPTIONAL; do
      [ "$opt" = "$entry" ] && match="$opt"
    done
    IFS="$inner_ifs"
    [ -n "$match" ] || { printf 'unknown optional reviewer: %s\n' "$entry" >&2; IFS="$old_ifs"; return 1; }
    printf '%s\n' "$match"
    IFS=',|'
  done
  IFS="$old_ifs"
  # Section-presence auto-activation. A contract heading anywhere in the spec
  # activates the matching reviewer even if it was not listed in the field.
  sec_ifs="$IFS"; IFS='|'
  for opt in $PERSONAS_OPTIONAL; do
    IFS="$sec_ifs"
    heading="$(optional_contract_heading "$opt")" || { IFS='|'; continue; }
    grep -Eq "^## ${heading}([[:space:]]|$)" "$file" && printf '%s\n' "$opt"
    IFS='|'
  done
  IFS="$sec_ifs"
  return 0
}

# Echoes the personas named in an explicit `- Personas:` field, one per line in
# declared order. This field is the per-spec override: when present, the active
# set becomes the track floor plus exactly these personas (plus any opted-in
# optional reviewers), ignoring the Review Profile preset. Each entry must be a
# member of the spec's track persona set OR PERSONAS_OPTIONAL; an unknown or
# cross-track name is rejected (non-zero, message on stderr). Absent / empty /
# `none` field yields no output, so the profile path stays in effect.
spec_explicit_personas() {
  local file="$1" track universe raw entry match cand old_ifs inner_ifs
  track="$(spec_track "$file")"
  universe="$(persona_set "$track" 2>/dev/null)|$PERSONAS_OPTIONAL"
  raw="$(sed -nE 's/^- Personas: ?(.*)/\1/p' "$file" | head -n 1)"
  old_ifs="$IFS"; IFS=',|'
  for entry in $raw; do
    IFS="$old_ifs"
    entry="$(printf '%s' "$entry" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$entry" in ""|none) IFS=',|'; continue ;; esac
    match=""
    inner_ifs="$IFS"; IFS='|'
    for cand in $universe; do
      [ "$cand" = "$entry" ] && match="$cand"
    done
    IFS="$inner_ifs"
    [ -n "$match" ] || { printf 'unknown persona in Personas field: %s\n' "$entry" >&2; IFS="$old_ifs"; return 1; }
    printf '%s\n' "$match"
    IFS=',|'
  done
  IFS="$old_ifs"
  return 0
}

# Resolves a spec's profile to its active persona set, echoing the set on
# success. Fails (non-zero, message on stderr) when the field is missing, names
# an unknown profile, or — as a guard against a mis-edited table — yields a set
# missing any mandatory floor persona. Optional personas (PERSONAS_OPTIONAL) the
# spec opts into are unioned in after the floor guard, deduplicated and in order.
resolve_active_personas() {
  local file="$1" profile track set floor persona old_ifs optional explicit
  track="$(spec_track "$file")"
  persona_set "$track" >/dev/null 2>&1 ||
    { printf 'unknown Track "%s"; valid: rn, web\n' "$track" >&2; return 1; }
  floor="$(persona_floor "$track")"
  # Explicit per-spec override. A `- Personas:` field names the exact specialists
  # to run; the active set is the floor plus those names. The Review Profile is
  # ignored (and not required) in this mode. An unknown name aborts resolution.
  explicit="$(spec_explicit_personas "$file")" || return 1
  if [ -n "$explicit" ]; then
    set="$floor"
    while IFS= read -r persona; do
      [ -n "$persona" ] || continue
      case "|$set|" in *"|$persona|"*) ;; *) set="$set|$persona" ;; esac
    done <<EOF
$explicit
EOF
  else
    profile="$(spec_review_profile "$file")"
    [ -n "$profile" ] || { printf 'spec is missing a Review Profile field (or an explicit Personas list)\n' >&2; return 1; }
    set="$(profile_personas "$profile" "$track")" ||
      { printf 'unknown Review Profile "%s" for track %s; valid: %s\n' \
          "$profile" "$track" "$(valid_profiles_for_track "$track")" >&2; return 1; }
    old_ifs="$IFS"; IFS='|'
    for persona in $floor; do
      IFS="$old_ifs"
      case "|$set|" in
        *"|$persona|"*) ;;
        *) printf 'profile "%s" is missing mandatory persona: %s\n' "$profile" "$persona" >&2; return 1 ;;
      esac
      IFS='|'
    done
    IFS="$old_ifs"
  fi
  # Union in opted-in optional personas. An unknown optional reviewer aborts the
  # whole resolution so callers (prompt/gate/validate_spec) all reject it.
  optional="$(spec_optional_personas "$file")" || return 1
  while IFS= read -r persona; do
    [ -n "$persona" ] || continue
    case "|$set|" in
      *"|$persona|"*) ;;
      *) set="$set|$persona" ;;
    esac
  done <<EOF
$optional
EOF
  printf '%s' "$set"
}
