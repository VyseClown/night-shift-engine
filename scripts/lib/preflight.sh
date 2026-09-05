# shellcheck shell=bash
# scripts/lib/preflight.sh
# Spec parsing/validation, path canonicalization, launch-readiness preflight,
# and validation-command extraction/execution + evidence matching. Sourced by
# night-shift.sh; uses PROJECT/WORKSPACE_ROOT/RUN_ROOT/SPEC/SMOKE_TIMEOUT
# globals + log/die/emit_event/integrity_put at runtime.

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
          missing="${missing}\n- valid Track (one of: rn, web, node, fullstack)"
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

# Read-only launch-readiness report for a (project, spec): is the spec valid, is
# the project on the spec's feature branch, is the tree clean, is .night-shift
# ignored, any worktree conflict. Reuses validate_spec + the check_branch_and_worktree
# field logic as a REPORT (never a guard / never mutates). Emits JSON, exit 0. The
# viewer renders this as a checklist before a (paid) run. Single source of truth.
emit_preflight() {
  local proj="$1" spec="$2"
  local base feature current spec_valid spec_errors dirty nightignored
  local on_feature on_base worktree_conflict blockers_json conflicts

  # Spec validity: validate_spec prints its missing-field list to stderr and
  # returns non-zero; capture stderr and turn the "- <field>" lines into an array.
  local verr
  if verr="$(validate_spec "$spec" 2>&1 >/dev/null)"; then
    spec_valid=true
  else
    spec_valid=false
  fi
  spec_errors="$(printf '%s\n' "$verr" | sed -nE 's/^- (.*)/\1/p' | jq -R . | jq -sc .)"

  # Does the spec's declared Project path match --project (or a worktree of it)?
  # The live run enforces this (validate_spec_project); preflight must report it
  # too, or --dry-run gives a false green that the real run then blocks on.
  local project_match
  if validate_spec_project "$spec" "$proj" 2>/dev/null; then project_match=true; else project_match=false; fi

  base="$(sed -nE 's/^- Base branch: `([^`]+)`.*/\1/p' "$spec" | head -n 1)"
  feature="$(sed -nE 's/^- Feature branch: `([^`]+)`.*/\1/p' "$spec" | head -n 1)"
  current="$(git -C "$proj" branch --show-current 2>/dev/null || true)"
  [ "$current" = "$feature" ] && [ -n "$feature" ] && on_feature=true || on_feature=false
  [ "$current" = "$base" ] && [ -n "$base" ] && on_base=true || on_base=false

  conflicts="$(git -C "$proj" worktree list --porcelain 2>/dev/null | awk -v project="$proj" -v branch="refs/heads/$feature" '
    /^worktree / { path=substr($0,10) }
    /^branch / { if (substr($0,8) == branch && path != project) print path }
  ' || true)"
  [ -z "$conflicts" ] && worktree_conflict=false || worktree_conflict=true

  dirty="$(git -C "$proj" status --porcelain=v1 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$dirty" ] || dirty=0
  if git -C "$proj" check-ignore -q .night-shift/ 2>/dev/null; then
    nightignored=true
  else
    nightignored=false
  fi

  # Blockers (newline list → JSON array). ready = no blockers.
  local b=""
  [ "$spec_valid" = true ] || b="${b}spec invalid"$'\n'
  [ "$project_match" = true ] || b="${b}spec Project path does not match --project"$'\n'
  [ "$on_feature" = true ] || b="${b}not on feature branch ${feature:-?}"$'\n'
  [ "$dirty" -eq 0 ] || b="${b}working tree dirty"$'\n'
  [ "$nightignored" = true ] || b="${b}.night-shift not gitignored"$'\n'
  [ "$worktree_conflict" = false ] || b="${b}feature branch checked out in another worktree"$'\n'
  blockers_json="$(printf '%s' "$b" | sed -e '/^$/d' | jq -R . | jq -sc .)"
  local ready=false
  [ -z "$b" ] && ready=true

  jq -n \
    --argjson spec_valid "$spec_valid" --argjson spec_errors "$spec_errors" \
    --argjson project_match "$project_match" \
    --arg base "$base" --arg feature "$feature" --arg current "$current" \
    --argjson on_feature "$on_feature" --argjson on_base "$on_base" \
    --argjson worktree_conflict "$worktree_conflict" \
    --argjson dirty "$dirty" --argjson nightignored "$nightignored" \
    --argjson ready "$ready" --argjson blockers "$blockers_json" \
    '{
      spec: { valid: $spec_valid, errors: $spec_errors, projectMatch: $project_match },
      branch: { base: $base, feature: $feature, current: $current,
                onFeature: $on_feature, onBase: $on_base, worktreeConflict: $worktree_conflict },
      tree: { clean: ($dirty == 0), dirtyCount: $dirty },
      gitignore: { nightShiftIgnored: $nightignored },
      ready: $ready,
      blockers: $blockers
    }'
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

# Optional `- Workdir: `<subdir>`` spec field: every validation phase
# (baseline, test-first red/green, final) runs in this project-relative
# subdirectory, so a monorepo app spec can use natural app-local commands while
# --project stays the repo root. Git worktrees always root at the repo top
# level, which is why the subdir must be re-applied on BOTH $PROJECT and the
# validation worktree — workdir_path composes it onto whichever base a phase
# runs against. Same dialect as the other Repository fields (Base branch,
# Project path): mandatory backticks, trailing annotation tolerated.
spec_workdir() {
  sed -nE 's/^- Workdir: `([^`]+)`.*/\1/p' "$1" | head -n 1
}

# Validate + install the spec's workdir into the WORKDIR global. An absent
# field (or `none`) leaves WORKDIR empty — single-repo behavior byte-for-byte.
# Everything else fails LOUDLY at spec selection, never silently mid-run:
# - a present-but-unparseable field (bare value, missing backticks) is an
#   error, not an ignored line — otherwise app-local commands silently run at
#   the repo root and fail confusingly at baseline;
# - absolute paths and `..` traversal are rejected lexically, and the resolved
#   physical path must stay under the project (a committed symlink pointing at
#   a sibling repo passes -d but must not route validation outside the repo);
# - the directory must be TRACKED at HEAD: validation worktrees are fresh
#   `git worktree add` checkouts that materialize only tracked files, so an
#   untracked/gitignored dir would pass here and then cd-fail hours later in
#   the candidate worktree (and, worse, make a red-against-base cd failure
#   read as a genuine RED — see verify_red_against_base).
set_spec_workdir() {
  local wd resolved projreal
  wd="$(spec_workdir "$1")"
  if [ -z "$wd" ]; then
    if grep -Eq '^- Workdir:' "$1" &&
       ! grep -Eq '^- Workdir:[[:space:]]*(`none`|none)?[[:space:]]*$' "$1"; then
      printf 'malformed Workdir field — use: - Workdir: `apps/<app>` (backticks required)\n' >&2
      return 1
    fi
    WORKDIR=""; return 0
  fi
  case "$wd" in none) WORKDIR=""; return 0 ;; esac
  case "$wd" in /*) printf 'Workdir must be project-relative: %s\n' "$wd" >&2; return 1 ;; esac
  case "/$wd/" in *"/../"*) printf 'Workdir escapes the project: %s\n' "$wd" >&2; return 1 ;; esac
  [ -d "$PROJECT/$wd" ] ||
    { printf 'Workdir does not exist under the project: %s\n' "$wd" >&2; return 1; }
  resolved="$(cd "$PROJECT/$wd" 2>/dev/null && pwd -P)" &&
    projreal="$(cd "$PROJECT" 2>/dev/null && pwd -P)" ||
    { printf 'Workdir could not be resolved: %s\n' "$wd" >&2; return 1; }
  case "$resolved/" in
    "$projreal"/*) ;;
    *) printf 'Workdir resolves outside the project (symlink?): %s -> %s\n' "$wd" "$resolved" >&2; return 1 ;;
  esac
  if git -C "$PROJECT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    [ -n "$(git -C "$PROJECT" ls-tree -d HEAD -- "$wd" 2>/dev/null)" ] ||
      { printf 'Workdir is not tracked at HEAD (fresh validation worktrees would lack it): %s\n' "$wd" >&2; return 1; }
  fi
  WORKDIR="$wd"
}

workdir_path() { printf '%s%s' "$1" "${WORKDIR:+/$WORKDIR}"; }

# Optional `- Smoke: `<command>`` (+ `- Smoke URL: `<url>``) spec fields: same
# backticked-value dialect as Workdir. spec_smoke_field/spec_smoke_url_field are
# bare extractors (empty when absent OR malformed — a bare, unbackticked value
# is indistinguishable from absent at this layer, which is why validation below
# re-checks presence via grep); validate_spec_smoke is the loud spec-selection
# gate, mirroring set_spec_workdir: a present-but-unparseable Smoke field, a
# Smoke URL without a Smoke command, or a non-loopback Smoke URL all fail
# LOUDLY here rather than silently no-op'ing run_smoke_phase mid-run.
spec_smoke_field() {
  sed -nE 's/^- Smoke: `([^`]+)`.*/\1/p' "$1" | head -n 1
}

spec_smoke_url_field() {
  sed -nE 's/^- Smoke URL: `([^`]+)`.*/\1/p' "$1" | head -n 1
}

validate_spec_smoke() {
  local file="$1" url
  if grep -Eq '^- Smoke:' "$file"; then
    [ -n "$(spec_smoke_field "$file")" ] ||
      { printf 'malformed Smoke field — use: - Smoke: `<command>` (backticks required)\n' >&2; return 1; }
  elif grep -Eq '^- Smoke URL:' "$file"; then
    printf 'Smoke URL present without a Smoke field — add: - Smoke: `<command>`\n' >&2
    return 1
  else
    return 0
  fi
  if grep -Eq '^- Smoke URL:' "$file"; then
    url="$(spec_smoke_url_field "$file")"
    [ -n "$url" ] ||
      { printf 'malformed Smoke URL field — use: - Smoke URL: `http://127.0.0.1:<port>/...` (backticks required)\n' >&2; return 1; }
    # Reject userinfo BEFORE the loopback check. `http://127.0.0.1:80@evil.com/`
    # puts `127.0.0.1:80` in the userinfo and `evil.com` as the real host, yet
    # the `:*` port glob below would swallow `80@evil.com/` and accept it — a
    # verified bypass of the "never reaches out" invariant. Extract the authority
    # (between `://` and the first `/`) and refuse any `@` in it.
    local smoke_authority="${url#*://}"
    smoke_authority="${smoke_authority%%/*}"
    case "$smoke_authority" in
      *@*) printf 'Smoke URL must not contain userinfo (@ before the path) — the real host is whatever follows @, not the loopback address: %s\n' "$url" >&2; return 1 ;;
    esac
    # Anchored — NOT a prefix match: `http://127.0.0.1*`/`http://localhost*`
    # would also accept `http://localhost.evil.com/` (hostname-prefix bypass).
    # Each accepted host form is spelled out fully: bare, `:<port>`, or `/<path>`.
    case "$url" in
      http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*|http://localhost|http://localhost:*|http://localhost/*) ;;
      *) printf 'Smoke URL must be loopback-only (http://127.0.0.1 or http://localhost — a smoke probe never reaches out): %s\n' "$url" >&2; return 1 ;;
    esac
  fi
  return 0
}

# Optional `- Engines: role=vendor role=vendor` spec field (Codex+Claude engine
# split): opts the implement stage and/or the advisory codex review into codex.
# Same bare-token dialect as `- Track:` — no backticks — validated LOUDLY at
# spec selection (initial select, resume, NEXT_TASK chain), mirroring
# set_spec_workdir/validate_spec_smoke above. Absent field -> both roles at
# their default (ENGINE_IMPLEMENT=claude, ENGINE_REVIEW="" — inherit whatever
# NIGHT_SHIFT_CODEX_REVIEW says), byte-for-byte today's behavior.
#
# Grammar: space-separated `role=vendor` pairs, each role at most once.
#   implement ∈ {claude (default), codex} — the implement STAGE SCOPE vendor
#     only; plan, observe-request, and completion always stay claude (stage_engine
#     enforces this regardless of what this field says).
#   review    ∈ {codex, off} — per-spec override of NIGHT_SHIFT_CODEX_REVIEW;
#     the spec wins over the env knob in BOTH directions (codex_review_active
#     below is what actually applies the override — this function only
#     records which override, if any, the spec asked for, so a later spec in
#     the same run's NEXT_TASK chain that omits the field is not left with a
#     stale override from an earlier task).
#   plan / observer are rejected outright: those are the judgment gates that
#     make a second vendor safe, and are Claude-only in v1.
#
# Side effects on success: sets ENGINE_IMPLEMENT (claude|codex) and ENGINE_REVIEW
# ("", "codex", or "off") — mirrors set_spec_workdir's WORKDIR side effect. Both
# are reset unconditionally on every call (never carries over from a previous
# spec/call), which is what keeps a NEXT_TASK chain from leaking one task's
# Engines field onto the next task's defaults.
validate_spec_engines() {
  local file="$1" raw pair role vendor seen_implement=0 seen_review=0
  local scoped_text engines_line_count
  ENGINE_IMPLEMENT="claude"
  ENGINE_REVIEW=""
  # Presence check scoped exactly like the extractor (spec_engines uses
  # spec_field_scope internally) — Engines lives in the `## Review` section,
  # the same dialect as Track/Personas, NOT the whole-file dialect Workdir/
  # Smoke use. An unscoped grep here would treat a stray "- Engines:" mention
  # elsewhere in the spec (e.g. prose under Related Files) as a malformed
  # field, exactly the bug fixture_review_fields_scoped guards against for
  # Personas. Captured once into a var (spec_field_scope now also strips CRLF
  # and skips fenced code blocks — see its own comment) so the presence count,
  # the near-miss check, and the strict extractor all see the same text.
  scoped_text="$(spec_field_scope "$file")"
  engines_line_count="$(printf '%s\n' "$scoped_text" | grep -Ec '^- Engines:')"
  if [ "$engines_line_count" -gt 1 ]; then
    printf 'duplicate Engines field\n' >&2
    return 1
  fi
  if [ "$engines_line_count" -eq 0 ]; then
    # Near-miss spellings must never be silently treated as absent: widen ONLY
    # this presence check so near-miss ATTEMPTS at the field — `- Engines :`,
    # `- engines:`, colon-less `- Engines implement=codex` — hit the loud
    # malformed-field error below instead of resolving to today's silent
    # claude/inherit-env defaults. The match is shape-constrained (the word
    # "engines" must be followed by a colon, or by a role=vendor-looking
    # token), NOT a bare prefix: prose bullets like "- engines overview lives
    # in docs/" or "- EnginesRoom: 3" must stay valid non-fields, especially
    # on legacy no-## Review specs where the scope is the whole file. The
    # strict extractor (spec_engines) is unchanged — only detection of
    # "something was attempted here" widens.
    if printf '%s\n' "$scoped_text" | grep -Eiq '^-[[:space:]]?engines([[:space:]]*:|[[:space:]]+[a-z]+=)'; then
      printf 'malformed Engines field — use: - Engines: implement=claude|codex review=codex|off (space-separated role=vendor pairs)\n' >&2
      return 1
    fi
    return 0
  fi
  raw="$(spec_engines "$file")"
  if [ -z "$raw" ]; then
    printf 'malformed Engines field — use: - Engines: implement=claude|codex review=codex|off (space-separated role=vendor pairs)\n' >&2
    return 1
  fi
  for pair in $raw; do
    case "$pair" in
      *=*) role="${pair%%=*}"; vendor="${pair#*=}" ;;
      *) printf 'malformed Engines pair "%s" — use role=vendor (e.g. implement=codex)\n' "$pair" >&2; return 1 ;;
    esac
    if [ -z "$role" ] || [ -z "$vendor" ]; then
      printf 'malformed Engines pair "%s" — use role=vendor (e.g. implement=codex)\n' "$pair" >&2
      return 1
    fi
    case "$role" in
      plan|observer)
        printf 'plan and observer are Claude-only (the judgment gates that make a second vendor safe)\n' >&2
        return 1 ;;
      implement)
        if [ "$seen_implement" -ne 0 ]; then
          printf 'duplicate Engines role: implement\n' >&2; return 1
        fi
        seen_implement=1
        case "$vendor" in
          claude|codex) ENGINE_IMPLEMENT="$vendor" ;;
          *) printf 'unknown Engines vendor for implement: %s (valid: claude, codex)\n' "$vendor" >&2; return 1 ;;
        esac ;;
      review)
        if [ "$seen_review" -ne 0 ]; then
          printf 'duplicate Engines role: review\n' >&2; return 1
        fi
        seen_review=1
        case "$vendor" in
          codex|off) ENGINE_REVIEW="$vendor" ;;
          *) printf 'unknown Engines vendor for review: %s (valid: codex, off)\n' "$vendor" >&2; return 1 ;;
        esac ;;
      *) printf 'unknown Engines role: %s (valid: implement, review)\n' "$role" >&2; return 1 ;;
    esac
  done
  if [ "$ENGINE_IMPLEMENT" = "codex" ] && ! codex_available; then
    printf 'Engines implement=codex requires the codex CLI on PATH\n' >&2
    return 1
  fi
  # Proven live: codex keeps .git READ-ONLY under its workspace-write sandbox
  # policy, with no config escape hatch — a workspace-write implement run can
  # never `git commit` a candidate, so it would fail every time, not just
  # occasionally. Reject at spec selection rather than let a run discover the
  # dead end hours into implementation. danger-full-access (the default) is
  # the only sandbox that lets a codex primary create a candidate today.
  if [ "$ENGINE_IMPLEMENT" = "codex" ] && [ "$CODEX_SANDBOX" = "workspace-write" ]; then
    printf 'implement=codex cannot run under NIGHT_SHIFT_CODEX_SANDBOX=workspace-write — codex keeps .git read-only so the primary can never commit a candidate; use danger-full-access (the default)\n' >&2
    return 1
  fi
  # Session ids are vendor-specific and never cross vendors (`codex exec
  # resume <claude-uuid>` is meaningless). SESSION_SCOPE=run pins ONE session
  # for the whole run and only nulls it at scope boundaries the run may never
  # reach in a single-task invocation, so a codex implement stage under
  # SESSION_SCOPE=run risks resuming a Claude session id (or vice versa).
  # SESSION_SCOPE=stage (the default) always starts implement fresh, which is
  # the only shape codex's per-vendor session ids are safe under.
  if [ "$ENGINE_IMPLEMENT" = "codex" ] && [ "${SESSION_SCOPE:-stage}" != "stage" ]; then
    printf 'Engines implement=codex requires NIGHT_SHIFT_SESSION_SCOPE=stage (run-scoped sessions never null at scope boundaries, so Claude/codex session ids would cross vendors)\n' >&2
    return 1
  fi
  return 0
}

# Whether the advisory codex review (codex_review_candidate) should run for
# THIS spec: the spec's own `- Engines: review=...` wins over the env knob in
# BOTH directions (review=codex turns it on even if NIGHT_SHIFT_CODEX_REVIEW=0;
# review=off turns it off even if =1); an absent field falls through to the
# env-configured CODEX_REVIEW exactly as before. ENGINE_REVIEW is reset by
# validate_spec_engines on every spec selection, so this can never read a
# stale override from an earlier task in a NEXT_TASK chain.
codex_review_active() {
  case "$ENGINE_REVIEW" in
    codex) return 0 ;;
    off) return 1 ;;
    *) [ "$CODEX_REVIEW" = "1" ] ;;
  esac
}

run_test_command() {
  local phase="$1" command="$2" target="$3" run_dir="${4:-$PROJECT}" output rc=0 exec_dir
  output="$RUN_ROOT/raw/test-first-$phase.log"
  exec_dir="$(workdir_path "$run_dir")"
  # A missing exec dir must not masquerade as a test failure (cd exits 1, the
  # same code a failing suite uses). 127 routes it to the tooling/infra
  # diagnosis, and the output names the real cause.
  if [ ! -d "$exec_dir" ]; then
    printf 'night-shift: Workdir "%s" does not exist under %s — not present in this commit/worktree\n' \
      "${WORKDIR:-}" "$run_dir" >"$output"
    rc=127
  else
    (cd "$exec_dir" && bash -lc "$command") >"$output" 2>&1 </dev/null || rc=$?
  fi
  jq -n --arg command "$command" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$output")" \
    '{command:$command,exit_status:$exit_status,output:$output}' >"$target"
  # Wrapper-owned evidence: seed the engine-private integrity anchor. Defined in
  # night-shift.sh (the only sourcer today); the command -v guard keeps this lib
  # safe to source standalone, and keeps the function's exit status clean.
  ! command -v integrity_put >/dev/null 2>&1 || integrity_put "$target"
}

# Red-against-base proof for a spec that MODIFIES an already-tested module (the
# first-failing-test passes at baseline). Overlays the candidate's added/modified/
# deleted TEST files onto a worktree at BASE production code and runs the test there,
# writing {command,exit_status,output} to $target. A genuine red→green change leaves
# the updated tests FAILING (exit != 0) against the old code; a change-blind test stays
# green (exit 0), which the caller treats as "no real red proof" and blocks. Test files
# are matched by the conventional *.test.* / *.spec.* / __tests__ patterns; production
# files are left at BASE so the proof isolates the test change.
verify_red_against_base() {
  local repo="$1" base="$2" candidate="$3" command="$4" target="$5"
  local wt log f rc=0 overlaid=0
  wt="$(tmp_base)/ns-redbase-$candidate-$$"
  rm -rf "$wt" 2>/dev/null
  git -C "$repo" worktree add --detach "$wt" "$base" >/dev/null 2>&1 || return 2
  # Fail CLOSED if the workdir is absent at BASE — checked BEFORE the overlay
  # loop, which mkdir-p's test-file parents and would otherwise recreate the
  # dir (leaving a test-files-only workdir whose runner exits 1 for missing
  # scaffolding — the same code as a genuine RED). A workdir that does not
  # exist at base has no base production code to prove red against anyway.
  if [ ! -d "$(workdir_path "$wt")" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$wt" 2>/dev/null || true
    return 6
  fi
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    # Match conventional test files anywhere, INCLUDING a top-level __tests__/ dir
    # (the leading * also matches an empty leading path component).
    case "$f" in
      *.test.*|*.spec.*|*__tests__/*)
        if git -C "$repo" cat-file -e "$candidate:$f" 2>/dev/null; then
          mkdir -p "$wt/$(dirname "$f")"
          git -C "$repo" show "$candidate:$f" >"$wt/$f"
        else
          rm -f "$wt/$f"
        fi
        overlaid=1 ;;
    esac
  done < <(git -C "$repo" diff -z --name-only "$base..$candidate")
  link_worktree_dependencies "$wt" 2>/dev/null || true
  log="$target.log"
  (cd "$(workdir_path "$wt")" && bash -lc "$command") >"$log" 2>&1 </dev/null || rc=$?
  jq -n --arg command "$command" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$log")" \
    '{command:$command,exit_status:$exit_status,output:$output}' >"$target" || rc=-1
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt" 2>/dev/null || true
  # Signal a setup failure (caller blocks with a clear message) when: no test file was
  # overlaid (the diff named none → the proof would be vacuous), the test runner was
  # not found (127), the result JSON could not be written (-1), or — earlier, return
  # 6 — the workdir is absent in the BASE worktree. A genuine run returns 0 and the
  # caller judges red/green from the JSON exit_status.
  [ "$overlaid" -eq 1 ] || return 3
  [ "$rc" -ne 127 ] || return 4
  [ "$rc" -ne -1 ] || return 5
  return 0
}

run_validation_commands() {
  local kind="$1" target="$2" commands="$3" run_dir="${4:-$PROJECT}" command output rc first=1 tmp exec_dir
  tmp="$target.tmp.$$"
  exec_dir="$(workdir_path "$run_dir")"
  printf '[\n' >"$tmp"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    output="$RUN_ROOT/raw/validation-$kind-$(printf '%s' "$command" | cksum | awk '{print $1}').log"
    rc=0
    # Redirect stdin from /dev/null: a command that reads stdin (e.g.
    # `docker compose exec`) would otherwise drain this while-read loop's heredoc
    # and silently skip the remaining commands. A missing exec dir is reported
    # as 127 (infra), never as a command failure — see run_test_command.
    if [ ! -d "$exec_dir" ]; then
      printf 'night-shift: Workdir "%s" does not exist under %s — not present in this commit/worktree\n' \
        "${WORKDIR:-}" "$run_dir" >"$output"
      rc=127
    else
      (cd "$exec_dir" && bash -lc "$command") >"$output" 2>&1 </dev/null || rc=$?
    fi
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
  # Wrapper-owned evidence: seed the engine-private integrity anchor. Defined in
  # night-shift.sh (the only sourcer today); the command -v guard keeps this lib
  # safe to source standalone, and keeps the function's exit status clean.
  ! command -v integrity_put >/dev/null 2>&1 || integrity_put "$target"
}

# The smoke server process group this run currently owns, if any — set by
# run_smoke_phase's server mode, cleared by cleanup_smoke_pgid. night-shift.sh
# registers cleanup_smoke_pgid on both the HUP/INT/TERM abort path (block_run)
# and the EXIT trap, so a run interrupted mid-poll (or crashing elsewhere)
# never leaves a zombie dev server behind.
SMOKE_PGID=""

cleanup_smoke_pgid() {
  [ -n "${SMOKE_PGID:-}" ] || return 0
  local pgid="$SMOKE_PGID"
  SMOKE_PGID=""
  # Group first (the common case — see run_smoke_phase); bare-pid fallback
  # mirrors reap_persona_workers, in case the group somehow already exited.
  kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
  smoke_pgid_record ""
}

# The in-memory SMOKE_PGID dies with the engine process, so a SIGKILL/panic
# mid-poll used to orphan the dev server (port held, the next run's smoke
# phase fails against it). Mirror the pgid into state.json while the server
# lives (the same pre-creation-record idea .validation_worktree uses) so
# reap_recorded_smoke_pgid can stop it on recovery. Best-effort, never fatal:
# a state write failure must not fail the smoke phase, and the EXIT-trap
# cleanup can run after compaction removed state.json. $1 = pgid, "" = clear.
smoke_pgid_record() {
  local pgid="${1:-}" started=""
  [ -f "${STATE:-}" ] || return 0
  command -v state_set >/dev/null 2>&1 || return 0
  if [ -n "$pgid" ]; then
    # The leader's start time is the identity a later reap verifies: a pid
    # (and pgid) is reused after a reboot, and killing whatever now owns it
    # would be killing a stranger.
    started="$(smoke_pgid_identity "$pgid")"
    ( state_set '.smoke_pgid=$p | .smoke_pgid_started=$s' --argjson p "$pgid" --arg s "$started" ) >/dev/null 2>&1 || true
  else
    ( state_set 'del(.smoke_pgid, .smoke_pgid_started)' ) >/dev/null 2>&1 || true
  fi
}

# The process's start time as `ps` reports it (whitespace-normalized), empty
# when the process is gone. Portable: `-o lstart=` exists on macOS and Linux.
smoke_pgid_identity() {
  local id
  id="$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
  # busybox ps has no lstart column: fall back to the command name, still a
  # positive identity (a reused pid running something else is left alone).
  [ -n "$id" ] || id="$(ps -o comm= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//; s/^/comm:/' | grep -v '^comm:$')"
  printf '%s' "$id"
}

# Recovery: stop a still-live smoke server the interrupted run recorded in
# state (see smoke_pgid_record), journal it, and clear the record. A dead or
# absent pgid just clears. Called by recover_run before anything else uses
# the project.
reap_recorded_smoke_pgid() {
  [ -f "${STATE:-}" ] || return 0
  local pgid started now_started
  pgid="$(jq -r '.smoke_pgid // empty' "$STATE" 2>/dev/null)"
  case "$pgid" in ''|*[!0-9]*) return 0 ;; esac
  started="$(jq -r '.smoke_pgid_started // empty' "$STATE" 2>/dev/null)"
  now_started="$(smoke_pgid_identity "$pgid")"
  if [ -n "$now_started" ] && [ "$started" = "$now_started" ]; then
    # Alive and still the process we recorded: the one kill ladder
    # (cleanup_smoke_pgid) stops it and clears the record.
    log "recovery: the previous run's smoke server is still alive (pgid $pgid); stopping it so this run's smoke phase gets its port back"
    SMOKE_PGID="$pgid"
    cleanup_smoke_pgid
    ! command -v emit_event >/dev/null 2>&1 || emit_event smoke_reaped "$(jq -cn --argjson p "$pgid" '{pgid:$p}')"
  else
    # Gone, recorded without an identity, or a DIFFERENT process now owns
    # the pid (reuse after a reboot): never kill a stranger — drop the record.
    [ -z "$now_started" ] ||
      log "recovery: pid $pgid recorded as the previous run's smoke server now belongs to a different process (started $now_started); leaving it alone"
    smoke_pgid_record ""
  fi
}

# Spec-declared smoke-run validation phase: proves the app actually BOOTS, not
# just that tsc/eslint/jest pass (evidence: a Release-bundle break that passed
# every one of those). Skips silently (return 0, write nothing) when the spec
# has no `- Smoke:` field. Two modes selected by the presence of `- Smoke URL:`:
#   - server mode: start $cmd under `set -m` (monitor mode), which makes the
#     backgrounded job its OWN process group (pid == pgid) — the same portable
#     idiom reap_persona_workers already uses for the persona workers, chosen
#     over the external `setsid` binary because stock macOS ships no `setsid`
#     (only via a non-default util-linux install). Poll the URL every 2s for
#     an HTTP 200 until NIGHT_SHIFT_SMOKE_TIMEOUT, then TERM-then-KILL the
#     whole group via cleanup_smoke_pgid; a server that dies before timeout
#     breaks the poll loop early. A self-daemonizing command (one that
#     double-forks/disowns its real listener — live-proven against Next 16
#     Turbopack) can survive that group kill, so server mode is bracketed by
#     a port-scoped guard on BOTH sides: before booting, if the Smoke URL
#     names a port and something already LISTENs on it, refuse to spawn at
#     all (rc=1, loud message, no singleton-steal collision) — which is also
#     what makes the after-cleanup step safe: since the port was confirmed
#     free at boot, anything still LISTENing on it after cleanup_smoke_pgid
#     can only be a survivor of OUR command, so it's swept directly by port
#     (TERM, wait 1s, re-check, KILL). Both steps need `lsof` and a parsed
#     port (a Smoke URL with no explicit `:<port>` skips them and falls back
#     to the plain group-kill).
#   - exit mode: the command itself must exit 0 within the timeout (a portable
#     watchdog — no GNU `timeout` on macOS — same TERM-based pattern as
#     codex_review_candidate's advisory review timeout), escalating to KILL
#     if the TERM hasn't landed ~2s later.
# Writes $target shaped exactly like a run_validation_commands entry list
# (single-element array) so validation_not_regressed and the viewer render it
# unchanged; returns the smoke command's exit status (or the poll's timeout
# rc=1) so callers can gate on it exactly like any other validation command.
run_smoke_phase() {
  local kind="$1" target="$2" run_dir="${3:-$PROJECT}" cmd url rc=0 pid out wd exec_dir port survivors
  # shellcheck disable=SC2153
  # ^ $SPEC is the night-shift.sh runtime global (the current task's spec
  # path) — not a typo of the unrelated lowercase `spec` locals other
  # functions in this file use for their own file-path parameters.
  cmd="$(spec_smoke_field "$SPEC")"; [ -n "$cmd" ] || return 0
  url="$(spec_smoke_url_field "$SPEC")"
  out="$RUN_ROOT/raw/smoke-$kind.log"
  exec_dir="$(workdir_path "$run_dir")"
  if [ -n "$url" ]; then
    # server mode: own process group (see comment above) so the whole tree
    # (e.g. a package-manager wrapper spawning the real dev server) dies
    # together on kill, not just the shim.
    port="$(printf '%s' "$url" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')"
    if [ -n "$port" ] && command -v lsof >/dev/null 2>&1 && [ -n "$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null)" ]; then
      # Pre-boot collision: something is already LISTENing on this port.
      # Never spawn — a singleton-steal race here would be worse than a
      # loud, cheap failure, and it's the precondition that makes the
      # post-cleanup sweep below provably safe.
      printf 'night-shift: smoke port %s already in use before boot — free it or pick an exclusive Smoke URL port\n' "$port" >"$out"
      rc=1
    else
      set -m
      (cd "$exec_dir" && bash -lc "$cmd" >"$out" 2>&1 </dev/null) & pid=$!
      set +m
      SMOKE_PGID="$pid"
      smoke_pgid_record "$pid"
      rc=1
      # WALL-CLOCK deadline, not a sleep counter: each poll's curl can itself
      # burn up to --max-time 5s, so counting only the sleeps would stretch a
      # declared SMOKE_TIMEOUT of 120s to ~7min against a server that accepts
      # TCP but never answers. now_epoch is the engine's portable clock.
      local deadline http_code
      deadline=$(( $(now_epoch) + SMOKE_TIMEOUT ))
      while [ "$(now_epoch)" -lt "$deadline" ]; do
        # Boot proof is a real 2xx, not merely "curl didn't error": bare
        # `curl -fsS` also exits 0 on a 3xx redirect (an auth/login redirect or
        # redirect loop is NOT the app serving its content), so capture the code
        # and require 200-299.
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || printf '000')"
        case "$http_code" in 2[0-9][0-9]) rc=0; break ;; esac
        kill -0 "$pid" 2>/dev/null || break   # server died early
        sleep 2
      done
      cleanup_smoke_pgid
      wait "$pid" 2>/dev/null || true
      # Port-scoped survivor sweep: the pre-boot check above proved the port
      # was free, so anything still LISTENing on it now descends from our
      # (possibly self-daemonizing) command, never a bystander.
      if [ -n "$port" ] && command -v lsof >/dev/null 2>&1; then
        survivors="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null)"
        if [ -n "$survivors" ]; then
          # shellcheck disable=SC2086  # word-splitting intentional: space-separated PID list
          kill -TERM $survivors 2>/dev/null || true
          sleep 1
          survivors="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null)"
          # shellcheck disable=SC2086
          [ -z "$survivors" ] || kill -KILL $survivors 2>/dev/null || true
        fi
      fi
    fi
  else
    # exit mode: command must succeed within the timeout (portable watchdog —
    # same TERM-based pattern as codex_review_candidate). If TERM hasn't
    # landed ~2s later, escalate to KILL rather than leave a stuck process
    # running past the declared timeout.
    (cd "$exec_dir" && bash -lc "$cmd") >"$out" 2>&1 </dev/null & pid=$!
    ( sleep "$SMOKE_TIMEOUT"; kill -TERM "$pid" 2>/dev/null
      sleep 2; kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    ) & wd=$!
    wait "$pid"; rc=$?; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null || true
  fi
  jq -n --arg command "smoke: $cmd" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$out")" \
    '[{command:$command, exit_status:$exit_status, output:$output}]' >"$target"
  ! command -v integrity_put >/dev/null 2>&1 || integrity_put "$target"
  ! command -v emit_event >/dev/null 2>&1 || emit_event smoke "$(jq -cn --arg kind "$kind" --argjson rc "$rc" '{kind:$kind, exit_status:$rc}')"
  return "$rc"
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

# True when the exit_status sequence the primary echoed under `.<field>` of its
# execution-evidence matches the wrapper-owned `<wrapper_file>` exit_status sequence
# (same values, order, and count). Command STRINGS are intentionally not compared:
# the wrapper owns and runs every validation command, so matching exit statuses is
# the integrity signal — an LLM-transcribed command string (e.g. `\;`→`;`) must not
# block a correct run. A malformed/unreadable file yields non-zero (treated as a
# mismatch, which fails safe).
evidence_exit_status_matches() {
  local evidence="$1" field="$2" wrapper_file="$3"
  jq -e --slurpfile w "$wrapper_file" --arg f "$field" '
    [ .[$f][] | .exit_status ] == [ $w[0][] | .exit_status ]
  ' "$evidence" >/dev/null 2>&1
}

validate_spec_project() {
  local file="$1" proj="${2:-$PROJECT}" declared main
  declared="$(sed -nE 's/^- Project path: `([^`]+)`.*/\1/p' "$file" | head -n 1)"
  # The spec literally contains "~/…"; the case matches that text and expands it
  # manually (it is data read from the spec, not a path for the shell to expand).
  # shellcheck disable=SC2088
  case "$declared" in
    "~/"*) declared="$HOME/${declared#\~/}" ;;
    /*) ;;
    *) declared="$WORKSPACE_ROOT/$declared" ;;
  esac
  declared="$(canonical_dir "$declared")" || return 1
  proj="$(canonical_dir "$proj")" || return 1
  [ "$declared" = "$proj" ] && return 0
  # Accept a git worktree whose MAIN working tree is the declared project: a
  # worktree of the project IS the project (same repo + history, just a different
  # branch and working dir). `git worktree list` always lists the main working
  # tree first, so its path is the canonical project root. This lets a per-feature
  # worktree run a spec without weakening the guard's intent — the spec still only
  # runs against the project it declares, never a different one.
  main="$(git -C "$proj" worktree list --porcelain 2>/dev/null | sed -n '1{s/^worktree //;p;}')"
  [ -n "$main" ] || return 1
  main="$(canonical_dir "$main")" || return 1
  [ "$declared" = "$main" ]
}

resolve_artifact() {
  local rel="$1" resolved
  case "$rel" in /*|*"../"*|*/..) return 1 ;; esac
  [ -f "$PROJECT/$rel" ] || return 1
  resolved="$(canonical_file "$PROJECT/$rel")" || return 1
  case "$resolved" in "$PROJECT"/*) printf '%s\n' "$resolved" ;; *) return 1 ;; esac
}
