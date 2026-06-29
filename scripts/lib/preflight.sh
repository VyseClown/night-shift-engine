# shellcheck shell=bash
# scripts/lib/preflight.sh
# Spec parsing/validation, path canonicalization, launch-readiness preflight,
# and validation-command extraction/execution + evidence matching. Sourced by
# night-shift.sh; uses PROJECT/WORKSPACE_ROOT/RUN_ROOT globals + log/die at runtime.

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
          missing="${missing}\n- valid Track (one of: rn, web, node)"
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

run_test_command() {
  local phase="$1" command="$2" target="$3" run_dir="${4:-$PROJECT}" output rc=0
  output="$RUN_ROOT/raw/test-first-$phase.log"
  (cd "$run_dir" && bash -lc "$command") >"$output" 2>&1 </dev/null || rc=$?
  jq -n --arg command "$command" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$output")" \
    '{command:$command,exit_status:$exit_status,output:$output}' >"$target"
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
  local project="$1" base="$2" candidate="$3" command="$4" target="$5"
  local wt log f rc=0
  wt="$(tmp_base)/ns-redbase-$candidate-$$"
  rm -rf "$wt" 2>/dev/null
  git -C "$project" worktree add --detach "$wt" "$base" >/dev/null 2>&1 || return 2
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.test.*|*.spec.*|*/__tests__/*)
        if git -C "$project" cat-file -e "$candidate:$f" 2>/dev/null; then
          mkdir -p "$wt/$(dirname "$f")"
          git -C "$project" show "$candidate:$f" >"$wt/$f"
        else
          rm -f "$wt/$f"
        fi ;;
    esac
  done < <(git -C "$project" diff -z --name-only "$base..$candidate")
  link_worktree_dependencies "$wt" 2>/dev/null || true
  log="$target.log"
  (cd "$wt" && bash -lc "$command") >"$log" 2>&1 </dev/null || rc=$?
  jq -n --arg command "$command" --argjson exit_status "$rc" \
    --arg output "$(tail -c 20000 "$log")" \
    '{command:$command,exit_status:$exit_status,output:$output}' >"$target"
  git -C "$project" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt" 2>/dev/null || true
  return 0
}

run_validation_commands() {
  local kind="$1" target="$2" commands="$3" run_dir="${4:-$PROJECT}" command output rc first=1 tmp
  tmp="$target.tmp.$$"
  printf '[\n' >"$tmp"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    output="$RUN_ROOT/raw/validation-$kind-$(printf '%s' "$command" | cksum | awk '{print $1}').log"
    rc=0
    # Redirect stdin from /dev/null: a command that reads stdin (e.g.
    # `docker compose exec`) would otherwise drain this while-read loop's heredoc
    # and silently skip the remaining commands.
    (cd "$run_dir" && bash -lc "$command") >"$output" 2>&1 </dev/null || rc=$?
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
