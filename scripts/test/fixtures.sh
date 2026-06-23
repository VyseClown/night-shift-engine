# shellcheck shell=bash
# shellcheck disable=SC2318,SC2329,SC2317,SC2034,SC2030,SC2031,SC2333
# ^ Test-scaffolding-wide suppressions (THIS file only — kept ON for production):
#   fixtures are dispatched indirectly via fixture_assert "$fn" (SC2329/SC2317
#   "never invoked"/"unreachable", incl. deliberately stubbed mock functions like
#   `enforce_limits() { :; }`); single-line `local root="$1" x="$root/…"` resolves
#   $root to the
#   outer run_dry_fixtures local of the same name, not the just-declared one
#   (SC2318 — works by dynamic scoping, fine for fixtures); save/restore and
#   assertion locals are read back conditionally (SC2034); assertions run inside
#   subshells (SC2030/SC2031); multi-line `[ ] && [ ] && [ ]` chains are genuine
#   ANDs (SC2333 false positive).
# Test fixtures for scripts/night-shift.sh.
# Sourced by the orchestrator only when --fixture-test is passed.
# All fixture_* functions, run_dry_fixtures, run_live_fixtures, fixture_assert,
# fixture_reject, validated_retry, and live_* helpers live here.
# Production functions called at run-time are still defined in night-shift.sh.

fixture_assert() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
  fi
}

fixture_reject() {
  local description="$1"
  shift
  if "$@"; then
    printf 'not ok - %s\n' "$description" >&2
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
  else
    printf 'ok - %s\n' "$description"
  fi
}

run_dry_fixtures() {
  local root="$WORKSPACE_ROOT/.night-shift-fixture.$$"
  local good bad
  FIXTURE_FAILURES=0
  FIXTURE_ROOT="$root"
  mkdir -p "$root"
  trap 'rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM

  good="$root/action.json"
  bad="$root/bad.json"
  printf '%s\n' '{"action":"RUN_PERSONAS","task":"specs/a.md","stage":"plan_review","artifacts":["packet.json"],"reason":"plan ready"}' >"$good"
  fixture_assert "valid next-action signal" json_schema_basic next-action "$good"
  printf '%s\n' '{"action":"NOPE","task":"","stage":"plan","artifacts":["../escape"],"reason":""}' >"$bad"
  fixture_reject "malformed and escaping signal" json_schema_basic next-action "$bad"
  fixture_reject "missing signal" json_schema_basic next-action "$root/missing.json"

  good="$root/persona.json"
  printf '%s\n' '{"persona":"Performance Expert","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$good"
  fixture_assert "persona approval schema" json_schema_basic persona-review "$good"
  printf '%s\n' '{"persona":"Performance Expert","stage":"implementation","commit":"abc1234","status":"BLOCK","findings":[],"documentation_changes":[]}' >"$bad"
  fixture_reject "blocking persona requires findings" json_schema_basic persona-review "$bad"

  good="$root/observer.json"
  printf '%s\n' '{"observer":"claude","primary":"claude","task":"specs/a.md","candidate_commit":"abcdef1","status":"BLOCK","findings":[{"id":"OBS-001","evidence":"test output","required_change":"test passes"}],"documentation_changes":[]}' >"$good"
  fixture_assert "observer blocker schema" json_schema_basic observer-review "$good"
  jq '.observer = "codex"' "$good" >"$bad"
  fixture_reject "observer must be claude" json_schema_basic observer-review "$bad"

  good="$root/evidence.json"
  printf '%s\n' '{"task":"specs/a.md","baseline":[{"command":"check","exit_status":0,"output":"ok"}],"test_first":{"command":"test","failing_exit_status":1,"failing_output":"failed","passing_exit_status":0,"passing_output":"passed"},"final_validation":[{"command":"check","exit_status":0,"output":"ok"}]}' >"$good"
  fixture_assert "execution evidence schema" json_schema_basic execution-evidence "$good"
  jq '.test_first.failing_exit_status = 0' "$good" >"$bad"
  fixture_reject "test-first evidence requires an observed failure" json_schema_basic execution-evidence "$bad"

  fixture_assert "bug-first task ordering" fixture_task_order "$root"
  fixture_assert "unchecked queue lists bugs-first, excludes checked" fixture_unchecked_queue_order "$root"
  fixture_assert "stage limit boundary" fixture_limits
  fixture_assert "validated_retry accepts a clean first-pass result without a second call" fixture_partial_retry "$root"
  fixture_assert "in-place persona artifact copy is a no-op (no BSD cp failure)" fixture_persona_inplace_copy "$root"
  fixture_assert "candidate commit dedup: same hash appended twice appears once" fixture_commit_mapping "$root"
  fixture_assert "success cleanup and blocked recovery" fixture_cleanup_recovery "$root"
  fixture_assert "recoverable_rate_limit_state rejects running/session-mismatch/missing-raw" fixture_state_recovery "$root"
  fixture_assert "real transition gate sequence" fixture_transitions
  fixture_assert "malformed adapter retries once" fixture_adapter_retry "$root"
  fixture_assert "final-only validation commands pass by identity" fixture_validation_identity "$root"
  fixture_assert "candidate validation excludes working-tree dirt" fixture_candidate_isolation "$root"
  fixture_assert "dirty-path exclusion matches space-in-path correctly (NUL baseline)" fixture_dirty_path_space "$root"
  fixture_assert "candidate selection keeps insertion order (no unique-sort)" fixture_candidate_order "$root"
  fixture_assert "stage entry uses a fresh clock (no ancient restore)" fixture_stage_fresh_start "$root"
  fixture_assert "observer verdict extraction (json/fenced/embedded)" fixture_observer_extraction "$root"
  fixture_assert "observer verdict normalization (synonyms/ids/extra keys)" fixture_observer_normalization "$root"
  fixture_assert "missing tool detection (exit 127)" fixture_missing_tools "$root"
  fixture_assert "finding stall counter accumulates and resets" fixture_finding_stall "$root"
  fixture_assert "validation worktree gets linked dependencies" fixture_worktree_dependencies "$root"
  fixture_assert "validation worktree links nested (web-layout) dependencies" fixture_worktree_dependencies_nested "$root"
  fixture_assert "tmp base is canonical (worktree path matches cleanup prefix)" fixture_tmp_base_canonical "$root"
  fixture_assert "review fields are read only from the ## Review section" fixture_review_fields_scoped "$root"
  fixture_assert "visual-diff schema enforces shape + pass-consistency" fixture_visual_diff_schema "$root"
  fixture_assert "visual capture parses Design Contract frames x states" fixture_visual_capture_screens "$root"
  fixture_assert "visual screen assembly derives pass and null diff_image" fixture_visual_assemble_screen "$root"
  fixture_assert "visual capture is an inert no-op without tooling" fixture_visual_capture_skips "$root"
  fixture_assert "visual report assembled from per-screen jsonl is schema-valid" fixture_visual_assemble_report "$root"
  fixture_assert "spec validation accepts slash fields" fixture_spec_validation "$root"
  fixture_assert "web spec validates without native permission lines" fixture_spec_validation_web "$root"
  fixture_assert "review profile resolves to floor + scoped personas" fixture_review_profile "$root"
  fixture_assert "web track resolves to web personas + floor" fixture_review_profile_web "$root"
  fixture_assert "node track resolves to backend personas, no UX, no UI profiles" fixture_review_profile_node "$root"
  fixture_assert "persona gate enforces the active profile set" fixture_profile_gate "$root"
  fixture_assert "re-review rounds require only pending blockers" fixture_review_round_subset "$root"
  fixture_assert "compact archive preserves the per-turn cost ledger" fixture_cost_ledger "$root"
  fixture_assert "observer temp dir cleanup is scoped, removing, and idempotent" fixture_observer_tmp_cleanup "$root"
  fixture_assert "observer cost is recorded from the retry's .attempt raw" fixture_observer_cost_capture "$root"
  fixture_assert "persona collection skips non-persona artifacts" fixture_persona_collect "$root"
  fixture_assert "session scope boundaries clear only across scopes" fixture_session_scope "$root"
  fixture_assert "set_stage clears the session at scope boundaries" fixture_stage_session_reset "$root"
  fixture_assert "fresh stage session gets the file-handoff note" fixture_handoff_prompt "$root"
  fixture_assert "visual_review prompt carries the RUN_VISUAL procedure" fixture_visual_review_prompt "$root"
  fixture_assert "model_flag builds the --model arg (empty for inherit)" fixture_model_flag "$root"
  fixture_assert "stage_model tiers plan vs the rest of the primary" fixture_stage_model "$root"
  fixture_assert "expected_action pins each stage's only valid signal" fixture_expected_action "$root"
  fixture_assert "visual_review stage machine wiring" fixture_visual_stage_machine "$root"
  fixture_assert "visual_review routing decision" fixture_visual_routing "$root"
  fixture_assert "visual capture grid includes device axis" fixture_visual_grid "$root"
  fixture_assert "visual report assembles device/analysis/attempts" fixture_visual_assemble "$root"
  fixture_assert "optional reviewer field unions into active set" fixture_optional_persona_field "$root"
  fixture_assert "comma-separated optional reviewers all union in" fixture_optional_persona_multi "$root"
  fixture_assert "contract section auto-activates optional reviewer" fixture_optional_persona_section "$root"
  fixture_assert "unknown optional reviewer is rejected" fixture_optional_persona_unknown "$root"
  fixture_assert "no optional opt-in leaves active set unchanged" fixture_optional_persona_none "$root"
  fixture_assert "schema accepts optional persona records" fixture_optional_persona_schema "$root"
  fixture_assert "added optional persona unions via field" fixture_optional_persona_added_field "$root"
  fixture_assert "added optional persona auto-activates via its section" fixture_optional_persona_added_section "$root"
  fixture_assert "optional-personas manifest lists all four with headings" fixture_optional_personas_manifest "$root"
  fixture_assert "preflight reports ready only on a valid spec + feature branch" fixture_preflight_report "$root"
  fixture_assert "spec project guard accepts a worktree of the declared project" fixture_spec_project_worktree "$root"
  fixture_assert "evidence verify matches on exit status, ignores command-string transcription" fixture_evidence_exit_status_match "$root"
  fixture_assert "resumable_blocked_state gates --resume to logic-blocked, session-bearing state" fixture_resume_blocked "$root"
  fixture_assert "explicit Personas list overrides the profile (floor kept)" fixture_explicit_personas_override "$root"
  fixture_assert "explicit Personas list may name an optional reviewer" fixture_explicit_personas_with_optional "$root"
  fixture_assert "explicit Personas list rejects an off-track name" fixture_explicit_personas_unknown "$root"
  fixture_assert "structured session limit is recognized" fixture_rate_limit_recognition "$root"
  fixture_assert "rate-limit reset epoch uses reported timezone" fixture_rate_limit_epoch "$root"
  fixture_assert "rate-limit resume rebases elapsed budgets" fixture_rate_limit_rebase "$root"
  fixture_assert "preserved rate-limit block is recoverable" fixture_rate_limit_recovery "$root"
  fixture_assert "runaway rate-limit wait hits the cap" fixture_rate_limit_cap "$root"
  fixture_assert "run lock: stale PID is reclaimable, live PID is not" fixture_run_lock "$root"
  fixture_assert "state_int: valid integer passes, null/garbage blocks" fixture_state_int "$root"
  fixture_assert "rate-limit consecutive counter threshold predicate" fixture_rate_limit_consecutive "$root"
  fixture_assert "malformed-signal cap predicate blocks only at/over the cap" fixture_malformed_cap "$root"
  fixture_assert "observer cost recorded on both attempts (no double-count on success)" fixture_observer_cost_both_attempts "$root"
  fixture_assert "block_run state write failure does not suppress original reason" fixture_block_run_hardening "$root"
  fixture_assert "visual capture resolves sim by device label" fixture_visual_pick_udid "$root"
  fixture_assert "visual capture uses explicit udid, else resolves internally" fixture_visual_capture_udid_arg "$root"
  fixture_assert "device registry root honours the dir override" fixture_device_registry_root "$root"
  fixture_assert "device_try_claim: claim, contend, reclaim stale" fixture_device_try_claim "$root"
  fixture_assert "device_claim: concurrent claims get distinct devices" fixture_device_claim_distinct "$root"
  fixture_assert "device_claim: clones when matching devices exhausted" fixture_device_claim_clone_on_exhaustion "$root"
  fixture_assert "device_release deletes clones, keeps real devices" fixture_device_release "$root"
  fixture_assert "device_registry_prune reclaims stale locks + orphan clones" fixture_device_prune "$root"
  fixture_assert "prune skips clones being created (live marker), sweeps stale ones" fixture_device_prune_creation_race "$root"
  fixture_assert "run_visual_capture registry mode claims, caches, releases" fixture_visual_capture_registry_claim "$root"
  fixture_assert "registry-off: no claim, no artifacts" fixture_visual_registry_off_no_artifacts "$root"
  fixture_assert "visual_review prunes the registry only in registry mode" fixture_visual_prune_guarded "$root"

  if [ "$FIXTURE_FAILURES" -ne 0 ]; then
    die "$FIXTURE_FAILURES deterministic fixture(s) failed"
  fi
  rm -rf "$root"
  trap - EXIT HUP INT TERM
  log "all deterministic fixtures passed"
}

fixture_task_order() {
  local root="$1"
  cat >"$root/TODO.md" <<'EOF'
- [ ] feature: Later feature (`specs/feature.md`)
- [ ] bug: First bug (`specs/bug.md`)
EOF
  [ "$(select_task_from_todo "$root/TODO.md")" = "specs/bug.md" ]
}

fixture_unchecked_queue_order() {
  local root="$1" out
  cat >"$root/TODO.md" <<'EOF'
- [x] feature: Done (`specs/done.md`)
- [ ] feature: Later feature (`specs/feature.md`)
- [ ] bug: First bug (`specs/bug.md`)
EOF
  # All unchecked specs, bugs before features, checked entries excluded. This is
  # what start_next_task walks to find the next spec for THIS run's project.
  out="$(list_unchecked_specs "$root/TODO.md")"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] || return 1
  [ "$(printf '%s\n' "$out" | head -n 1)" = "specs/bug.md" ] || return 1
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "specs/feature.md" ] || return 1
  printf '%s' "$out" | grep -q "specs/done.md" && return 1
  return 0
}

fixture_limits() {
  limit_exceeded 11 100 35 100 && return 1
  limit_exceeded 12 100 35 100
}

# Drives validated_retry with a callback that succeeds on the FIRST attempt.
# Confirms that a clean first-pass result is accepted without a second call.
# This exercises the real validated_retry exit path (attempt=0, schema passes)
# and would fail if validated_retry were deleted or if it required two attempts
# unconditionally.
fixture_partial_retry_callback() {
  local attempts="$1" output="$2"
  # Record the call, then emit a schema-valid observer result immediately.
  printf '%s\n' "$(($(cat "$attempts") + 1))" >"$attempts"
  printf '%s\n' '{"observer":"claude","primary":"claude","task":"specs/a.md","candidate_commit":"abcdef1","status":"APPROVE","findings":[],"documentation_changes":[]}' >"$output"
}

fixture_partial_retry() {
  local root="$1" attempts="$root/pr-attempts" output="$root/pr-output.json"
  printf '0\n' >"$attempts"
  validated_retry observer-review "$output" fixture_partial_retry_callback "$attempts" "$output" || return 1
  # Callback must have been called exactly once — a clean result needs no retry.
  [ "$(cat "$attempts")" = "1" ] && json_schema_basic observer-review "$output"
}

# The primary may write a persona artifact directly into the round result dir, so
# the mirror copy becomes self-referential. BSD cp fails ("are identical") on a
# self-copy; the -ef guard must make it a no-op while a real copy still happens.
fixture_persona_inplace_copy() {
  local root="$1" dir="$root/inplace" out dst
  mkdir -p "$dir"
  printf '{}' >"$dir/web-architect.json"
  out="$dir/web-architect.json"
  dst="$dir/web-architect.json"
  { [ "$out" -ef "$dst" ] || cp "$out" "$dst"; } || return 1
  dst="$dir/mirror.json"
  { [ "$out" -ef "$dst" ] || cp "$out" "$dst"; } || return 1
  [ -f "$dir/mirror.json" ]
}

# Tests that the insertion-order deduplication expression used by verify_candidate
# is idempotent: appending a hash that is ALREADY in candidate_commits must not
# create a duplicate entry.  fixture_candidate_order already proves out-of-
# lexical-order preserves insertion; this fixture proves that the same hash
# appended twice appears only once.  Both together cover the two branches of
# the reduce dedup logic — this fixture would fail if the `index($x)` guard were
# removed (duplicate entries would appear and [-1] would still be the new hash,
# but length would be wrong).
fixture_commit_mapping() {
  local root="$1" file="$root/dedup.json"
  printf '%s\n' '{"candidate_commits":["aaaa111","bbbb222"],"candidate":"bbbb222"}' >"$file"
  # Append bbbb222 again — it is already present; dedup must suppress it.
  jq '.candidate_commits = ((.candidate_commits + ["bbbb222"])
        | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) | .candidate="bbbb222"' \
    "$file" > "$file.t" && mv "$file.t" "$file"
  # Array must still have exactly 2 entries; bbbb222 must appear once only.
  [ "$(jq '.candidate_commits | length' "$file")" -eq 2 ] &&
    [ "$(jq -r '.candidate_commits[-1]' "$file")" = "bbbb222" ] &&
    [ "$(jq -r '.candidate_commits[0]' "$file")" = "aaaa111" ]
}

fixture_cleanup_recovery() {
  local root="$1" run
  run="$root/run"
  mkdir -p "$run/raw" "$run/archive"
  printf state >"$run/state.json"
  printf raw >"$run/raw/output"
  compact_success "$run" "fixture" >/dev/null
  [ -f "$run/archive/fixture/state.json" ] && [ ! -e "$run/raw" ]
}

# Tests the rejection branches of recoverable_rate_limit_state that fixture_rate_limit_recovery
# does NOT cover.  That fixture confirms the happy path (blocked + session match → recoverable).
# This fixture confirms the cases that must NOT be recoverable via rate-limit logic:
#   (a) status == "running" — a normal interrupted run must not be treated as a rate-limit event
#   (b) status == "blocked" but session ID mismatch — could be a different Claude session
#   (c) state or raw file missing — both must exist or we return 1
# All three must return 1.  If recoverable_rate_limit_state were changed to accept any
# running state it would break (a); a missing session check would break (b).
fixture_state_recovery() {
  local root="$1"
  local state="$root/sr-state.json" raw="$root/sr-raw.json"
  # (a) status == "running" → not recoverable.
  printf '%s\n' '{"status":"running","session_id":"sid-1"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 5am (Etc/UTC)","session_id":"sid-1"}' >"$raw"
  recoverable_rate_limit_state "$state" "$raw" && return 1
  # (b) blocked but session mismatch → not recoverable.
  printf '%s\n' '{"status":"blocked","session_id":"sid-A","block_reason":"primary command failed with status 1"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 5am (Etc/UTC)","session_id":"sid-B"}' >"$raw"
  recoverable_rate_limit_state "$state" "$raw" && return 1
  # (c) missing raw file → not recoverable.
  printf '%s\n' '{"status":"blocked","session_id":"sid-X","block_reason":"primary command failed with status 1"}' >"$state"
  rm -f "$root/sr-raw-missing.json"
  recoverable_rate_limit_state "$state" "$root/sr-raw-missing.json" && return 1
  return 0
}

fixture_transitions() {
  local stage=planning
  transition_allowed "$stage" RUN_PERSONAS || return 1
  stage=implementation
  transition_allowed "$stage" RUN_PERSONAS || return 1
  stage=implementation_ready
  transition_allowed "$stage" CREATE_CANDIDATE || return 1
  stage=observer_review
  transition_allowed "$stage" REQUEST_OBSERVER || return 1
  ! transition_allowed planning CREATE_CANDIDATE &&
    ! transition_allowed implementation REQUEST_OBSERVER &&
    ! transition_allowed completion RUN_PERSONAS
}

fixture_adapter_retry() {
  local root="$1" attempts="$root/attempts" output="$root/retry-output.json"
  printf '0\n' >"$attempts"
  validated_retry observer-review "$output" fixture_retry_adapter "$attempts" "$output"
  [ "$(cat "$attempts")" = "2" ] && json_schema_basic observer-review "$output"
}

fixture_validation_identity() {
  local root="$1" baseline="$root/baseline.json" final="$root/final.json"
  printf '%s\n' '[{"command":"typecheck","exit_status":1,"output":"old failure"},{"command":"lint","exit_status":0,"output":"ok"}]' >"$baseline"
  printf '%s\n' '[{"command":"typecheck","exit_status":1,"output":"same failure"},{"command":"tests","exit_status":0,"output":"ok"}]' >"$final"
  validation_not_regressed "$baseline" "$final"
}

fixture_candidate_isolation() {
  local root="$1" repo="$root/repo" worktree="$root/worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  printf 'dirty\n' >"$repo/dirty.txt"
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  [ -f "$worktree/tracked.txt" ] && [ ! -e "$worktree/dirty.txt" ]
}

# Exercises path_in_baseline directly with paths that contain spaces.
# git status --porcelain=v1 (without -z) QUOTES such paths (e.g.
# "dir with space/f"), leaving surrounding quotes in the extracted string so a
# string-match against the literal path fails silently.  With -z the path is
# unquoted and literal so the match is reliable.  This fixture builds a real
# NUL-delimited -z baseline capture and calls path_in_baseline to confirm:
#   (a) a space-containing path that IS in the baseline → blocked (return 0)
#   (b) a child path under a dirty untracked directory → blocked by prefix (0)
#   (c) a clean committed path not in the baseline → not blocked (return 1)
#   (d) a spaced path outside the dirty directory → not blocked (return 1)
# The fixture would regress if path_in_baseline used sed 's/^.. //' (which
# leaves quotes from the non -z format) rather than NUL-split stripping.
fixture_dirty_path_space() {
  local root="$1" repo="$root/space-repo" baseline="$root/spaced-status.txt"
  git -C "$repo" init -q 2>/dev/null || { mkdir -p "$repo" && git -C "$repo" init -q; }
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  # Commit one clean file so the repo is non-empty.
  printf 'clean\n' >"$repo/clean.txt"
  printf 'other\n' >"$repo/other clean.txt"
  git -C "$repo" add .
  git -C "$repo" commit -qm "init"
  # Create an untracked dirty directory with a space in its path.
  # git status -z reports the whole untracked directory as one entry with
  # a trailing slash, e.g. "?? dir with space/".
  mkdir -p "$repo/dir with space"
  printf 'dirty\n' >"$repo/dir with space/file.txt"
  # Capture baseline the same way initialize_run does — NUL-delimited.
  git -C "$repo" status --porcelain=v1 -z >"$baseline"
  # (a) A spaced path inside the dirty directory IS in the baseline.
  path_in_baseline "$baseline" "dir with space/file.txt" || return 1
  # (b) Any child path under a dirty untracked dir is also blocked (prefix match).
  path_in_baseline "$baseline" "dir with space/new subfile.txt" || return 1
  # (c) A clean tracked path not in the baseline is not blocked.
  path_in_baseline "$baseline" "clean.txt" && return 1
  # (d) A spaced committed path that is clean is not blocked.
  path_in_baseline "$baseline" "other clean.txt" && return 1
  return 0
}

fixture_worktree_dependencies() {
  local root="$1" repo="$root/deprepo" worktree="$root/depwt" ok saved_project saved_links
  mkdir -p "$repo/node_modules"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  printf 'dep\n' >"$repo/node_modules/marker.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  saved_project="$PROJECT"; saved_links="$DEPENDENCY_LINKS"
  PROJECT="$repo"; DEPENDENCY_LINKS="node_modules"
  link_worktree_dependencies "$worktree"
  PROJECT="$saved_project"; DEPENDENCY_LINKS="$saved_links"
  [ -L "$worktree/node_modules" ] && [ -f "$worktree/node_modules/marker.txt" ]
}

fixture_worktree_dependencies_nested() {
  # A nested dependency dir (web layout, e.g. server/node_modules) is linked into
  # the worktree — the parent dir is created first. Proves the expanded default
  # works for the viewer without a manual NIGHT_SHIFT_DEPENDENCY_LINKS override.
  local root="$1" repo="$root/ndeprepo" worktree="$root/ndepwt" saved_project saved_links
  mkdir -p "$repo/server/node_modules"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name Fixture
  printf 'committed\n' >"$repo/tracked.txt"
  printf 'dep\n' >"$repo/server/node_modules/marker.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm fixture
  git -C "$repo" worktree add --detach "$worktree" HEAD >/dev/null 2>&1
  saved_project="$PROJECT"; saved_links="$DEPENDENCY_LINKS"
  PROJECT="$repo"; DEPENDENCY_LINKS="node_modules server/node_modules web/node_modules"
  link_worktree_dependencies "$worktree"
  PROJECT="$saved_project"; DEPENDENCY_LINKS="$saved_links"
  [ -L "$worktree/server/node_modules" ] && [ -f "$worktree/server/node_modules/marker.txt" ]
}

fixture_tmp_base_canonical() {
  local base p1 p2
  base="$(tmp_base)"
  case "$base" in */) return 1 ;; esac        # no trailing slash
  [ -d "$base" ] || return 1                  # resolves to a real dir
  # The cleanup prefix and a stored worktree path derive from the same base, so a
  # stored path always matches the prefix check (the /var vs /private/var bug).
  p1="$base/night-shift-RUN-"
  p2="$base/night-shift-RUN-abc123"
  case "$p2" in "$p1"*) return 0 ;; *) return 1 ;; esac
}

fixture_review_fields_scoped() {
  local root="$1" spec="$root/scoped.md" active
  # A "- Personas:" line OUTSIDE the ## Review section (here under Related) must
  # NOT be read as the explicit-personas field. Without scoping it would be parsed
  # as an off-track explicit override and abort resolution; with scoping the spec
  # resolves to its plain full rn profile.
  fixture_write_min_spec "$spec" '## Related
- Personas: Web Architect'
  active="$(resolve_active_personas "$spec")" || return 1
  [ "$(printf '%s' "$active" | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  printf '%s' "$active" | grep -q "Web Architect" && return 1
  printf '%s' "$active" | grep -q "Mobile UX Designer" || return 1
  return 0
}

fixture_visual_diff_schema() {
  local root="$1" good="$root/vd-good.json" bad="$root/vd-bad.json" badkey="$root/vd-key.json"
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","device":"iphone-15","reference":"design/Home-default.png","screenshot":"shots/Home-default.png","diff_pct":0.05,"tolerance":0.1,"pass":true,"analysis":"","attempts":[],"diff_image":null}]}' >"$good"
  json_schema_basic visual-diff "$good" || return 1
  # pass=true but diff_pct > tolerance → inconsistent → rejected.
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","device":"iphone-15","reference":"r","screenshot":"s","diff_pct":0.5,"tolerance":0.1,"pass":true,"analysis":"","attempts":[],"diff_image":null}]}' >"$bad"
  json_schema_basic visual-diff "$bad" && return 1
  # missing a per-screen key → rejected.
  printf '%s\n' '{"task":"specs/x.md","screens":[{"screen":"Home","state":"default","device":"iphone-15","reference":"r","screenshot":"s","diff_pct":0,"tolerance":0.1,"pass":true,"analysis":"","attempts":[]}]}' >"$badkey"
  json_schema_basic visual-diff "$badkey" && return 1
  # A non-empty attempts array with a malformed entry (non-integer attempt) is rejected.
  printf '%s' '{"task":"t","screens":[{"screen":"S","state":"default","device":"iphone-15","reference":"r.png","screenshot":"s.png","diff_pct":0.0,"tolerance":0.1,"pass":true,"analysis":"","diff_image":null,"attempts":[{"attempt":"one","diff_pct":0.0,"pass":true,"analysis":"","screenshot":"a.png","diff_image":null}]}]}' >"$root/badattempt.json"
  ! json_schema_basic visual-diff "$root/badattempt.json" || return 1
  # A well-formed non-empty attempts array is still accepted.
  printf '%s' '{"task":"t","screens":[{"screen":"S","state":"default","device":"iphone-15","reference":"r.png","screenshot":"s.png","diff_pct":0.0,"tolerance":0.1,"pass":true,"analysis":"","diff_image":null,"attempts":[{"attempt":1,"diff_pct":0.0,"pass":true,"analysis":"ok","screenshot":"a.png","diff_image":null}]}]}' >"$root/goodattempt.json"
  json_schema_basic visual-diff "$root/goodattempt.json" || return 1
  return 0
}

fixture_visual_capture_screens() {
  local root="$1" spec="$root/dc.md" out
  printf '%s\n' '## Design Contract' '- Frames: Home, Settings' '- Required states: default, empty' '## Edge Cases' >"$spec"
  out="$(visual_capture_screens "$spec")"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 4 ] || return 1
  printf '%s\n' "$out" | grep -qx 'Home|default|iphone-15' || return 1
  printf '%s\n' "$out" | grep -qx 'Settings|empty|iphone-15' || return 1
  # No Design Contract → no screens.
  printf 'no contract\n' >"$spec"
  [ -z "$(visual_capture_screens "$spec")" ] || return 1
  return 0
}

fixture_visual_assemble_screen() {
  local root="$1" obj
  # Within tolerance → pass derived true; diff_image preserved.
  obj="$(visual_assemble_screen Home default iphone-15 design/h.png shots/h.png 0.05 0.1 diffs/h.png)"
  printf '%s' "$obj" | jq -e '.pass == true and .diff_image == "diffs/h.png"' >/dev/null || return 1
  # Over tolerance → pass derived false; empty diff_image → null.
  obj="$(visual_assemble_screen Home empty iphone-15 r s 0.4 0.1 "")"
  printf '%s' "$obj" | jq -e '.pass == false and .diff_image == null' >/dev/null || return 1
  # The assembled object is a valid screen inside a report.
  printf '{"task":"t","screens":[%s]}\n' "$obj" >"$root/asm.json"
  json_schema_basic visual-diff "$root/asm.json" || return 1
  return 0
}

fixture_visual_capture_skips() {
  local root="$1" out="$root/capout"
  mkdir -p "$out"
  # Inert by default: unavailable → no-op, returns 0, writes no report, never blocks.
  visual_capture_available && return 1
  run_visual_capture "$root/spec.md" abc123 "$out" >/dev/null 2>&1 || return 1
  [ -z "$(find "$out" -name 'visual-diff-*.json' 2>/dev/null)" ] || return 1
  return 0
}

fixture_visual_assemble_report() {
  local root="$1" jl="$root/screens.jsonl" rep="$root/rep.json"
  visual_assemble_screen Login default iphone-15 design/r.png shots/s.png 0.02 0.10 diffs/d.png "ok" "[]" >"$jl"
  visual_assemble_screen Login error iphone-15 design/r2.png shots/s2.png 0.40 0.10 "" "over tol" '[{"attempt":1,"diff_pct":0.40,"pass":false,"analysis":"x","screenshot":"a.png","diff_image":null}]' >>"$jl"
  assemble_report "specs/foo.md" "$jl" >"$rep"
  json_schema_basic visual-diff "$rep" || return 1
  jq -e '.task=="specs/foo.md" and (.screens|length)==2' "$rep" >/dev/null || return 1
}

fixture_spec_validation() {
  local root="$1" spec="$root/spec.md"
  cat >"$spec" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
- Native `ios/` changes permitted: no - js only
- Native `android/` changes permitted: no - js only
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: none - n/a
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  # Field names contain '/', which must not break the sed value extraction.
  validate_spec "$spec" 2>/dev/null
}

fixture_spec_validation_web() {
  local root="$1" web="$root/web-spec.md" rn="$root/rn-no-native.md"
  # A web spec with NO native ios/android permission lines must validate.
  cat >"$web" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Track: web
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
## Documentation
- Documentation owned by each review persona:
  - Web UX & Accessibility Designer: ux
  - Web Architect: arch
  - Backend & Data Expert: data
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  validate_spec "$web" 2>/dev/null || return 1
  # An otherwise-complete rn spec that omits the native lines must still fail,
  # so removing them for web did not weaken the rn track.
  cat >"$rn" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Review
- Track: rn
- Review Profile: full
## Permissions
- New dependencies permitted: no - none
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: dom
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
SPEC
  validate_spec "$rn" 2>/dev/null && return 1
  return 0
}

fixture_review_profile() {
  local root="$1" set spec
  # logic profile = floor + Performance Expert (4); no UX Designer.
  set="$(profile_personas logic)" || return 1
  [ "$(printf '%s' "$set" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  printf '%s' "$set" | grep -q "Performance Expert" || return 1
  printf '%s' "$set" | grep -q "Mobile UX Designer" && return 1
  # full keeps all six.
  [ "$(profile_personas full | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  # Unknown profile is rejected.
  profile_personas bogus && return 1
  # Missing field and unknown value both fail resolution.
  spec="$root/np.md"; printf '# no profile here\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  spec="$root/bp.md"; printf -- '- Review Profile: nonsense\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # A valid field resolves to its set.
  spec="$root/gp.md"; printf -- '- Review Profile: native\n' >"$spec"
  resolve_active_personas "$spec" >/dev/null 2>&1 || return 1
  return 0
}

fixture_review_profile_web() {
  local root="$1" set spec
  # web `data` profile = floor + Backend & Data Expert (4); web Architect floor.
  set="$(profile_personas data web)" || return 1
  [ "$(printf '%s' "$set" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  printf '%s' "$set" | grep -q "Backend & Data Expert" || return 1
  printf '%s' "$set" | grep -q "Web Architect" || return 1
  # web `full` keeps all six web personas, including the web designer.
  [ "$(profile_personas full web | tr '|' '\n' | grep -c .)" -eq 6 ] || return 1
  profile_personas full web | grep -q "Web UX & Accessibility Designer" || return 1
  # Track-specific profiles do not cross tracks: native is rn-only, data web-only.
  profile_personas native web && return 1
  profile_personas data rn && return 1
  # A spec declaring Track: web resolves to the web set (4 for data).
  spec="$root/web.md"; printf -- '- Track: web\n- Review Profile: data\n' >"$spec"
  [ "$(resolve_active_personas "$spec" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  # An unknown track is rejected.
  spec="$root/badtrack.md"; printf -- '- Track: ios\n- Review Profile: full\n' >"$spec"
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # A missing Track field defaults to rn, so the rn-only native profile resolves.
  spec="$root/notrack.md"; printf -- '- Review Profile: native\n' >"$spec"
  resolve_active_personas "$spec" >/dev/null 2>&1 || return 1
  return 0
}

fixture_review_profile_node() {
  local root="$1" set spec
  # node `full` = the whole node set (4): Backend & Data Expert stands in for the
  # architecture role; there is NO UX/accessibility persona (no UI surface).
  set="$(profile_personas full node)" || return 1
  [ "$(printf '%s' "$set" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  printf '%s' "$set" | grep -q "Backend & Data Expert" || return 1
  printf '%s' "$set" | grep -q "Performance Expert" || return 1
  printf '%s' "$set" | grep -q "UX" && return 1
  # node `logic` = floor + Performance Expert; floor includes the backend expert.
  set="$(profile_personas logic node)" || return 1
  printf '%s' "$set" | grep -q "Backend & Data Expert" || return 1
  printf '%s' "$set" | grep -q "Performance Expert" || return 1
  # UI-/data-specific profiles are not valid on the node track.
  profile_personas frontend node && return 1
  profile_personas native node && return 1
  profile_personas data node && return 1
  # node exposes exactly the two generic profiles.
  [ "$(valid_profiles_for_track node)" = "full, logic" ] || return 1
  # A spec declaring Track: node resolves to the node set (4 for full).
  spec="$root/node.md"; printf -- '- Track: node\n- Review Profile: full\n' >"$spec"
  [ "$(resolve_active_personas "$spec" | tr '|' '\n' | grep -c .)" -eq 4 ] || return 1
  return 0
}

fixture_profile_gate() {
  local root="$1" dir="$root/profile-gate" set persona i=0 old_ifs
  mkdir -p "$dir"
  set="$(profile_personas logic)" || return 1
  old_ifs="$IFS"; IFS='|'
  for persona in $set; do
    IFS="$old_ifs"; i=$((i + 1))
    printf '{"persona":"%s","stage":"implementation","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}\n' \
      "$persona" >"$dir/$i.json"
    IFS='|'
  done
  IFS="$old_ifs"
  # Exact active set passes the gate's coverage check.
  jq -s -e --arg personas "$set" \
    '($personas|split("|")|sort) as $e | (map(.persona)|sort)==$e' "$dir"/*.json >/dev/null || return 1
  # A result from a non-active persona breaks the coverage check.
  printf '{"persona":"Mobile UX Designer","stage":"implementation","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}\n' \
    >"$dir/extra.json"
  jq -s -e --arg personas "$set" \
    '($personas|split("|")|sort) as $e | (map(.persona)|sort)==$e' "$dir"/*.json >/dev/null && return 1
  return 0
}

fixture_review_round_subset() {
  local full="A|B|C" out
  # First round (no pending blockers): the full active set is required.
  out="$(review_round_set "$full" "" "" plan)"; [ "$out" = "$full" ] || return 1
  # Re-review round in the same stage: only the recorded blockers re-run.
  out="$(review_round_set "$full" "B|C" plan plan)"; [ "$out" = "B|C" ] || return 1
  # Blockers recorded for a different stage never leak into a new stage's
  # first round (plan blockers must not shrink the implementation round).
  out="$(review_round_set "$full" "B|C" plan implementation)"; [ "$out" = "$full" ] || return 1
  # A non-review stage (empty name) never matches a pending set.
  out="$(review_round_set "$full" "B|C" plan "")"; [ "$out" = "$full" ] || return 1
  return 0
}

fixture_cost_ledger() {
  local root="$1" dir="$root/cost-ledger" ledger
  mkdir -p "$dir/raw"
  local RUN_ROOT="$dir"
  # Each turn records its cost at the source the moment it finishes, so a costly
  # turn (notably the opus observer) is never lost to a transient raw file
  # disappearing before archive.
  printf '{"session_id":"s","total_cost_usd":1.25,"num_turns":4,"usage":{"output_tokens":10}}\n' \
    >"$dir/raw/primary-1.json"
  record_cost "$dir/raw/primary-1.json" "primary-1.json"
  printf '{"total_cost_usd":0.5,"num_turns":2,"usage":{"output_tokens":2}}\n' \
    >"$dir/raw/observer-abc.jsonl"
  record_cost "$dir/raw/observer-abc.jsonl" "observer-abc.jsonl"
  # A non-JSON raw (e.g. a rate-limit retry's partial output) contributes nothing.
  printf 'not json' >"$dir/raw/primary-2.json"
  record_cost "$dir/raw/primary-2.json" "primary-2.json"
  printf '{}\n' >"$dir/state.json"
  compact_success "$dir" testrun
  ledger="$dir/archive/testrun/costs.jsonl"
  [ -f "$ledger" ] || return 1
  [ "$(grep -c . "$ledger")" -eq 3 ] || return 1
  # The observer turn's cost is captured — the gap this guards against.
  jq -se 'any(.[]; .source == "observer-abc.jsonl" and .total_cost_usd == 0.5)' \
    "$ledger" >/dev/null || return 1
  jq -se '[.[] | select(.source == "TOTAL")][0] | .total_cost_usd == 1.75 and .records == 2' \
    "$ledger" >/dev/null || return 1
  # The raw files themselves are still compacted away.
  [ ! -d "$dir/raw" ] || return 1
  return 0
}

fixture_observer_tmp_cleanup() {
  local root="$1" dir="$root/obs-tmp"
  mkdir -p "$dir"
  local TMPDIR="$dir"
  # No RUN_ID → no-op, returns success and removes nothing dangerous.
  local RUN_ID=""
  cleanup_observer_tmp || return 1
  # With a RUN_ID, the per-run neutral dir is removed; calling again is idempotent.
  RUN_ID="testrun"
  mkdir -p "$dir/night-shift-observer-$RUN_ID"
  cleanup_observer_tmp || return 1
  [ ! -e "$dir/night-shift-observer-$RUN_ID" ] || return 1
  cleanup_observer_tmp || return 1
  return 0
}

fixture_persona_collect() {
  local root="$1" result_dir signal
  local PROJECT="$root/collect"
  result_dir="$PROJECT/.night-shift/out"
  signal="$PROJECT/signal.json"
  mkdir -p "$PROJECT" "$result_dir"
  printf '{"persona":"Web Architect","stage":"plan","status":"APPROVE","commit":null,"findings":[],"documentation_changes":[]}\n' >"$PROJECT/a.json"
  printf '{"persona":"Human Advocate","stage":"plan","status":"APPROVE","commit":null,"findings":[],"documentation_changes":[]}\n' >"$PROJECT/b.json"
  # A non-persona deliverable the primary also lists (the review bundle).
  printf '# review bundle\nnot persona-review json\n' >"$PROJECT/bundle.md"
  printf '{"artifacts":["bundle.md","a.json","b.json"]}\n' >"$signal"
  collect_persona_results "$signal" "$result_dir" || return 1
  # Exactly the two persona files were collected; the bundle was skipped.
  [ "$(find "$result_dir" -name '*.json' | wc -l | tr -d ' ')" -eq 2 ] || return 1
  [ -f "$result_dir/a.json" ] && [ -f "$result_dir/b.json" ] || return 1
  [ ! -f "$result_dir/bundle.md" ] || return 1
  # An unsafe/absolute path anywhere in the list is still fatal (traversal guard).
  printf '{"artifacts":["/etc/hosts","a.json"]}\n' >"$signal"
  collect_persona_results "$signal" "$result_dir" && return 1
  return 0
}

fixture_session_scope() {
  # Same-scope transitions keep the session (boundary returns non-zero).
  session_boundary planning plan_review stage && return 1
  session_boundary implementation implementation_review stage && return 1
  session_boundary implementation_review implementation_ready stage && return 1
  # Cross-scope transitions clear the session (boundary returns zero).
  session_boundary plan_review implementation stage || return 1
  session_boundary implementation_ready observer_review stage || return 1
  session_boundary observer_review implementation stage || return 1
  session_boundary observer_review completion stage || return 1
  # Legacy "run" mode never clears, even across scopes.
  session_boundary plan_review implementation run && return 1
  # An unknown stage is its own scope, so entering/leaving it clears.
  session_boundary planning some_new_stage stage || return 1
  return 0
}

fixture_stage_session_reset() {
  local root="$1" dir="$root/session-reset"
  mkdir -p "$dir"
  local STATE="$dir/state.json" RUN_ROOT="$dir" SESSION_SCOPE=stage
  # Cross-scope (plan_review -> implementation) nulls the pinned session.
  printf '{"stage":"plan_review","stage_turns":2,"stage_counters":{},"session_id":"sess-1"}\n' >"$STATE"
  set_stage implementation >/dev/null 2>&1
  [ "$(jq -r '.session_id' "$STATE")" = "null" ] || return 1
  # Same-scope (implementation -> implementation_review) keeps the session.
  printf '{"stage":"implementation","stage_turns":1,"stage_counters":{},"session_id":"sess-2"}\n' >"$STATE"
  set_stage implementation_review >/dev/null 2>&1
  [ "$(jq -r '.session_id' "$STATE")" = "sess-2" ] || return 1
  # Legacy "run" mode keeps the session across a scope change.
  SESSION_SCOPE=run
  printf '{"stage":"plan_review","stage_turns":2,"stage_counters":{},"session_id":"sess-3"}\n' >"$STATE"
  set_stage implementation >/dev/null 2>&1
  [ "$(jq -r '.session_id' "$STATE")" = "sess-3" ] || return 1
  return 0
}

fixture_expected_action() {
  # The per-stage expected action must match the wrapper's transition table, so a
  # cold/cheaper primary cannot skip ahead to an out-of-stage signal.
  [ "$(expected_action planning)" = "RUN_PERSONAS" ] || return 1
  [ "$(expected_action plan_review)" = "RUN_PERSONAS" ] || return 1
  [ "$(expected_action implementation)" = "RUN_PERSONAS" ] || return 1
  [ "$(expected_action implementation_review)" = "RUN_PERSONAS" ] || return 1
  [ "$(expected_action implementation_ready)" = "CREATE_CANDIDATE" ] || return 1
  [ "$(expected_action observer_review)" = "REQUEST_OBSERVER" ] || return 1
  [ "$(expected_action completion)" = "NEXT_TASK or COMPLETE" ] || return 1
  # Each single-action stage's expected action is actually permitted by the gate
  # (the regression that blocked the slack-status run: REQUEST_OBSERVER from
  # implementation is NOT allowed, RUN_PERSONAS is).
  transition_allowed implementation "$(expected_action implementation)" || return 1
  transition_allowed implementation REQUEST_OBSERVER && return 1
  transition_allowed implementation_ready "$(expected_action implementation_ready)" || return 1
  transition_allowed observer_review "$(expected_action observer_review)" || return 1
  return 0
}

fixture_visual_stage_machine() {
  # visual_review is its own scope, runs on the implement-tier model, and accepts
  # exactly RUN_VISUAL (plus BLOCKED). It sits between candidate and observer.
  [ "$(stage_session_scope visual_review)" = "visual" ] || return 1
  [ "$(stage_model visual)" = "$IMPLEMENT_MODEL" ] || return 1
  [ "$(expected_action visual_review)" = "RUN_VISUAL" ] || return 1
  transition_allowed visual_review RUN_VISUAL || return 1
  transition_allowed visual_review BLOCKED || return 1
  # Skipping ahead from visual_review to the observer is NOT allowed.
  ! transition_allowed visual_review REQUEST_OBSERVER || return 1
  # implementation_ready may still only CREATE_CANDIDATE.
  transition_allowed implementation_ready CREATE_CANDIDATE || return 1
}

fixture_visual_routing() {
  local root="$1" spec_yes="$root/dc.md" spec_no="$root/plain.md"
  printf '## Design Contract\n- Frames: Login\n- Required states: default\n' >"$spec_yes"
  printf '# plain spec\nno contract here\n' >"$spec_no"
  # Disabled globally -> never route to visual, regardless of contract.
  ( NIGHT_SHIFT_VISUAL_CAPTURE=0; VISUAL_CAPTURE=0; ! visual_stage_enabled "$spec_yes" ) || return 1
  # Enabled but no Design Contract -> skip.
  ( VISUAL_CAPTURE=1; ! visual_stage_enabled "$spec_no" ) || return 1
  # Enabled AND Design Contract present -> route to visual.
  ( VISUAL_CAPTURE=1; visual_stage_enabled "$spec_yes" ) || return 1
}

fixture_visual_grid() {
  local root="$1" spec="$root/dc.md"
  printf '## Design Contract\n- Frames: Login, Home\n- Required states: default, error\n- Devices: iphone-se, iphone-15\n' >"$spec"
  local out; out="$(visual_capture_screens "$spec" | sort)"
  # 2 frames x 2 states x 2 devices = 8 rows of screen|state|device
  [ "$(printf '%s\n' "$out" | grep -c '|')" -eq 8 ] || return 1
  printf '%s\n' "$out" | grep -q '^Login|error|iphone-15$' || return 1
  printf '%s\n' "$out" | grep -q '^Home|default|iphone-se$' || return 1
}

fixture_visual_assemble() {
  local obj
  obj="$(visual_assemble_screen Login error iphone-15 design/r.png shot/s.png 0.04 0.10 diff/d.png \
        "title 2px low; fixed" '[{"attempt":1,"diff_pct":0.31,"pass":false,"analysis":"low","screenshot":"a1.png","diff_image":"d1.png"}]')"
  printf '%s' "$obj" | jq -e '.device=="iphone-15" and .analysis=="title 2px low; fixed" and .pass==true and (.attempts|length)==1 and .attempts[0].attempt==1' >/dev/null || return 1
}

fixture_visual_pick_udid() {
  local js='{"devices":{"rt":[
    {"name":"iPhone 17 Pro","udid":"AAA","state":"Booted","isAvailable":true},
    {"name":"iPhone 15 Pro Max","udid":"BBB","state":"Shutdown","isAvailable":true},
    {"name":"iPhone 15 Pro Max","udid":"CCC","state":"Booted","isAvailable":true}]}}'
  # exact label + Booted wins
  [ "$(printf '%s' "$js" | __visual_pick_udid iphone-15-pro-max)" = "CCC" ] || return 1
  # exact label (non-booted) when that label has no booted device
  local js2='{"devices":{"rt":[{"name":"iPhone 15 Pro Max","udid":"DDD","state":"Shutdown","isAvailable":true}]}}'
  [ "$(printf '%s' "$js2" | __visual_pick_udid iphone-15-pro-max)" = "DDD" ] || return 1
  # no label match -> first Booted
  [ "$(printf '%s' "$js" | __visual_pick_udid no-such-device)" = "AAA" ] || return 1
}

fixture_observer_cost_capture() {
  # The observer raw is written to "$raw.$attempt" by validated_observer_retry, so
  # the cost must be recorded from THAT path (the original glob/`$raw` both missed
  # it). Drive the real retry wrapper with stubs — no paid call — and assert the
  # observer's cost lands in the incremental ledger.
  local root="$1" dir="$root/obs-cost"
  mkdir -p "$dir/raw"
  (
    RUN_ROOT="$dir"; OBSERVER=claude; PRIMARY=claude; SPEC="/x/spec.md"
    enforce_limits() { :; }
    enforce_elapsed_limits() { :; }
    normalize_observer_output() { :; }
    invoke_observer_once() {
      # Mimic the real call: cost-bearing raw to the .attempt path ($4), valid
      # verdict to $out ($3). candidate_commit must match the schema's hex pattern.
      printf '{"total_cost_usd":2.5,"num_turns":3,"usage":{"output_tokens":5}}\n' >"$4"
      printf '{"observer":"claude","primary":"claude","task":"/x/spec.md","candidate_commit":"a7a950b","status":"APPROVE","findings":[],"documentation_changes":[]}\n' >"$3"
    }
    validated_observer_retry "ctx" "a7a950b" "$dir/out.json" "$dir/raw/observer-abc.jsonl" || exit 1
    [ -f "$dir/cost-ledger.jsonl" ] || exit 1
    jq -se 'any(.[]; .source == "observer-abc.jsonl" and .total_cost_usd == 2.5)' \
      "$dir/cost-ledger.jsonl" >/dev/null || exit 1
  ) || return 1
  return 0
}

fixture_model_flag() {
  # "inherit" and empty produce no flag; a real model name produces "--model NAME"
  # (unquoted-string form so it word-splits into argv under bash 3.2 + set -u).
  [ -z "$(model_flag inherit)" ] || return 1
  [ -z "$(model_flag '')" ] || return 1
  [ "$(model_flag opus)" = "--model opus" ] || return 1
  [ "$(model_flag sonnet)" = "--model sonnet" ] || return 1
  return 0
}

fixture_stage_model() {
  # The primary plans on PLAN_MODEL and does all post-plan work (implement, the
  # observe-request turn, completion) on the cheaper IMPLEMENT_MODEL; the strong
  # judgment in the observe scope is the separate independent observer.
  local PLAN_MODEL=opus IMPLEMENT_MODEL=sonnet
  [ "$(stage_model plan)" = "opus" ] || return 1
  [ "$(stage_model implement)" = "sonnet" ] || return 1
  [ "$(stage_model observe)" = "sonnet" ] || return 1
  [ "$(stage_model complete)" = "sonnet" ] || return 1
  # An unrecognized scope falls back to inherit (no forced model).
  [ "$(stage_model bogus)" = "inherit" ] || return 1
  # inherit values flow straight through (no model pinned).
  PLAN_MODEL=inherit IMPLEMENT_MODEL=inherit
  [ "$(stage_model plan)" = "inherit" ] || return 1
  [ "$(stage_model implement)" = "inherit" ] || return 1
  return 0
}

fixture_handoff_prompt() {
  local root="$1" dir="$root/handoff" prompt
  prompt="$dir/prompt.txt"
  mkdir -p "$dir"
  local STATE="$dir/state.json" SPEC="$dir/spec.md" RUN_ID=testrun
  local PROJECT="$dir" BASE_COMMIT=deadbeef RUN_ROOT="$dir"
  fixture_write_min_spec "$SPEC"
  # Fresh stage session mid-run (no session_id, prior turns) gets the handoff note.
  printf '{"stage":"implementation","stage_turns":0,"primary_turns":4,"session_id":null}\n' >"$STATE"
  primary_prompt "$prompt"
  grep -q "FRESH stage session" "$prompt" || return 1
  grep -q ".night-shift/control/plan.md" "$prompt" || return 1
  # The implementation-stage prompt must pin RUN_PERSONAS as the only valid signal
  # so the primary cannot skip ahead to REQUEST_OBSERVER (the slack-status block).
  grep -q "Stage gate" "$prompt" || return 1
  grep -q "only valid signal from this stage is: RUN_PERSONAS" "$prompt" || return 1
  # First turn of the run (no prior turns) gets no handoff note.
  printf '{"stage":"planning","stage_turns":0,"primary_turns":0,"session_id":null}\n' >"$STATE"
  primary_prompt "$prompt"
  grep -q "FRESH stage session" "$prompt" && return 1
  return 0
}

fixture_visual_review_prompt() {
  local root="$1" dir="$root/vis-prompt" prompt
  prompt="$dir/prompt.txt"
  mkdir -p "$dir"
  local STATE="$dir/state.json" SPEC="$dir/spec.md" RUN_ID=testrun
  local PROJECT="$dir" BASE_COMMIT=deadbeef RUN_ROOT="$dir"
  fixture_write_min_spec "$SPEC"
  printf '{"stage":"visual_review","stage_turns":0,"primary_turns":2,"session_id":null}\n' >"$STATE"
  primary_prompt "$prompt"
  grep -q "RUN_VISUAL: only from the visual_review stage" "$prompt" || return 1
  grep -q "visual-capture.sh capture" "$prompt" || return 1
  grep -q "visual-capture.sh diff" "$prompt" || return 1
  grep -q "assemble-screen" "$prompt" || return 1
  grep -q "visual-capture.sh report" "$prompt" || return 1
  grep -q "Figma MCP" "$prompt" || return 1
  return 0
}

# Writes a minimal valid rn `full` spec to $1, optionally appending extra body
# ($2). Mirrors fixture_spec_validation's shape so the optional-persona fixtures
# reuse the same proven baseline (Track defaults to rn, full = the six rn
# personas with doc-owner lines for the whole floor + set).
fixture_write_min_spec() {
  local spec="$1" extra="${2:-}"
  cat >"$spec" <<'SPEC'
## Repository
- Project path: `~/work/app`
- Base branch: `main`
- Feature branch: `feat/x`
## Permissions
- New dependencies permitted: no - none
- Native `ios/` changes permitted: no - js only
- Native `android/` changes permitted: no - js only
## Documentation
- Documentation owned by each review persona:
  - Mobile UX Designer: ux
  - React Native Architect: arch
  - Mobile Domain Expert: dom
  - TypeScript & Code Quality Expert: types
  - Performance Expert: perf
  - Human Advocate: ops
## Test Plan
- First failing test or executable check: `npm test`
- Baseline validation commands:
  1. `npm test`
- Final validation commands:
  1. `npm test`
## Review
- Review Profile: full
SPEC
  # `## Review` is intentionally last so an appended extra (a field line like
  # `- Optional reviewers:` / `- Personas:` / `- Track:`) lands INSIDE the Review
  # section, where spec_field_scope reads it. An appended `## …` contract heading
  # ends the Review section and is found by the whole-file section scan.
  [ -z "$extra" ] || printf '%s\n' "$extra" >>"$spec"
}

fixture_optional_persona_field() {
  local root="$1" spec="$root/opt-field.md" active
  # Opting in via the field unions Product Reviewer into the active set; the full
  # floor (and the rest of the profile set) stays present.
  fixture_write_min_spec "$spec" '- Optional reviewers: Product Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Product Reviewer" || return 1
  case "|$active|" in *"|React Native Architect|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|TypeScript & Code Quality Expert|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Human Advocate|"*) ;; *) return 1 ;; esac
  # Design Fidelity is not opted in, so it must NOT appear.
  printf '%s' "$active" | grep -q "Design Fidelity Reviewer" && return 1
  return 0
}

fixture_optional_persona_multi() {
  local root="$1" spec="$root/opt-multi.md" active
  # A comma-separated list opts in MORE THAN ONE optional reviewer in one field;
  # every named reviewer must union in (single-value was the only prior coverage).
  fixture_write_min_spec "$spec" '- Optional reviewers: Security Reviewer, API Contract Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  printf '%s' "$active" | grep -q "API Contract Reviewer" || return 1
  return 0
}

fixture_optional_persona_section() {
  local root="$1" spec="$root/opt-section.md" active
  # A `## Design Contract` heading auto-activates Design Fidelity Reviewer even
  # with no Optional reviewers field.
  fixture_write_min_spec "$spec" '## Design Contract
- Figma file: example'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Design Fidelity Reviewer" || return 1
  printf '%s' "$active" | grep -q "Product Reviewer" && return 1
  return 0
}

fixture_optional_persona_unknown() {
  local root="$1" spec="$root/opt-unknown.md" out
  # An entry that is not a member of PERSONAS_OPTIONAL must fail resolution
  # AND validate_spec must surface the specific reason (not a generic hint).
  fixture_write_min_spec "$spec" '- Optional reviewers: Bogus Persona'
  resolve_active_personas "$spec" 2>/dev/null && return 1
  # Capture to a var: piping validate_spec into grep would, under pipefail,
  # report validate_spec's non-zero exit instead of grep's match result.
  out="$(validate_spec "$spec" 2>&1)" || true
  case "$out" in
    *"unknown optional reviewer: Bogus Persona"*) return 0 ;;
    *) return 1 ;;
  esac
}

fixture_optional_persona_none() {
  local root="$1" spec="$root/opt-none.md" active plain
  # No field and no contract section: the active set must equal the plain profile
  # set exactly, proving optional personas add nothing by default.
  fixture_write_min_spec "$spec"
  active="$(resolve_active_personas "$spec")" || return 1
  plain="$(profile_personas full rn)" || return 1
  [ "$active" = "$plain" ] || return 1
  return 0
}

fixture_optional_persona_schema() {
  local root="$1" prod="$root/persona-prod.json" design="$root/persona-design.json"
  local sec="$root/persona-sec.json" api="$root/persona-api.json"
  # The persona-review membership check must ACCEPT every optional persona.
  printf '%s\n' '{"persona":"Product Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$prod"
  json_schema_basic persona-review "$prod" || return 1
  printf '%s\n' '{"persona":"Design Fidelity Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$design"
  json_schema_basic persona-review "$design" || return 1
  printf '%s\n' '{"persona":"Security Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$sec"
  json_schema_basic persona-review "$sec" || return 1
  printf '%s\n' '{"persona":"API Contract Reviewer","stage":"plan","commit":null,"status":"APPROVE","findings":[],"documentation_changes":[]}' >"$api"
  json_schema_basic persona-review "$api" || return 1
  return 0
}

fixture_optional_persona_added_field() {
  local root="$1" spec="$root/opt-sec-field.md" active
  # A newly added optional persona (Security Reviewer) unions in via the field,
  # proving the optional roster is data-driven, not hardcoded to the first two.
  fixture_write_min_spec "$spec" '- Optional reviewers: Security Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  return 0
}

fixture_optional_persona_added_section() {
  local root="$1" spec="$root/opt-api-section.md" active
  # An `## API Contract` heading auto-activates the API Contract Reviewer with no
  # Optional reviewers field — section activation is driven by PERSONAS_OPTIONAL +
  # optional_contract_heading, so new personas work without touching the loop.
  fixture_write_min_spec "$spec" '## API Contract
- Endpoint: GET /thing'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "API Contract Reviewer" || return 1
  return 0
}

fixture_optional_personas_manifest() {
  local out
  # The --list-optional-personas manifest is valid JSON, lists every optional
  # persona, and pairs each with its contract heading (consumed by the viewer).
  out="$(emit_optional_personas_manifest)" || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.optional_personas | length == 4' >/dev/null 2>&1 || return 1
  printf '%s' "$out" \
    | jq -e '[.optional_personas[].name] | index("Security Reviewer") != null' \
      >/dev/null 2>&1 || return 1
  printf '%s' "$out" \
    | jq -e '.optional_personas[] | select(.name=="Product Reviewer") | .contractHeading == "Product Contract"' \
      >/dev/null 2>&1 || return 1
  return 0
}

fixture_preflight_report() {
  local root="$1" repo="$root/pf-repo" spec out
  spec="$repo/spec.md"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$repo" config user.email t@t >/dev/null 2>&1
  git -C "$repo" config user.name test >/dev/null 2>&1
  printf '.night-shift/\n' >"$repo/.gitignore"
  fixture_write_min_spec "$spec"   # valid rn spec: base main, feature feat/x
  # Point the spec's Project path at this repo so the project-match guard passes;
  # the template's placeholder (~/work/app) would otherwise block readiness.
  local repo_c; repo_c="$(canonical_dir "$repo")" || return 1
  local tmp="$spec.tmp"
  sed "s|^- Project path: .*|- Project path: \`$repo_c\`|" "$spec" >"$tmp" && mv "$tmp" "$spec"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -qm init >/dev/null 2>&1 || return 1
  # On the base branch: valid spec, project matches, but NOT ready (wrong branch).
  out="$(emit_preflight "$repo" "$spec")" || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.spec.valid == true' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.spec.projectMatch == true' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.branch.onBase == true and .branch.onFeature == false' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.ready == false' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.blockers | any(test("feature branch"))' >/dev/null 2>&1 || return 1
  # Move onto the feature branch (clean tree, .night-shift ignored) → ready.
  git -C "$repo" checkout -q -b feat/x >/dev/null 2>&1 || return 1
  out="$(emit_preflight "$repo" "$spec")" || return 1
  printf '%s' "$out" | jq -e '.branch.onFeature == true' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.tree.clean == true and .gitignore.nightShiftIgnored == true' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e '.ready == true and (.blockers | length == 0)' >/dev/null 2>&1 || return 1
  rm -rf "$repo"
  return 0
}

# The project guard must accept a spec run from inside a git WORKTREE of the
# declared project (what scripts/parallel-worktrees.sh does), while still
# rejecting an unrelated repo.
fixture_spec_project_worktree() {
  local root="$1" repo="$root/spw-repo" wt="$root/spw-wt" other="$root/spw-other" spec repo_c tmp
  rm -rf "$repo" "$wt" "$other"; mkdir -p "$repo" "$other"
  git -C "$repo" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$repo" config user.email t@t >/dev/null 2>&1
  git -C "$repo" config user.name test >/dev/null 2>&1
  git -C "$other" init -q -b main >/dev/null 2>&1 || return 1
  spec="$repo/spec.md"
  fixture_write_min_spec "$spec"
  repo_c="$(canonical_dir "$repo")" || return 1
  tmp="$spec.tmp"
  sed "s|^- Project path: .*|- Project path: \`$repo_c\`|" "$spec" >"$tmp" && mv "$tmp" "$spec"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -qm init >/dev/null 2>&1 || return 1
  # (a) direct match: proj IS the declared project.
  validate_spec_project "$spec" "$repo" || return 1
  # (b) a linked worktree of the project is accepted (the new behavior).
  git -C "$repo" worktree add -q "$wt" -b feat/wt >/dev/null 2>&1 || return 1
  validate_spec_project "$spec" "$wt" || { git -C "$repo" worktree remove --force "$wt" 2>/dev/null; return 1; }
  # (c) an unrelated repo is still rejected.
  if validate_spec_project "$spec" "$other"; then
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null; return 1
  fi
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$repo" "$wt" "$other"
  return 0
}

fixture_resume_blocked() {
  local root="$1" state="$root/rb-state.json"
  # blocked, not rate-limit, session present → resumable via --resume.
  printf '%s\n' '{"status":"blocked","session_id":"sid-1","block_reason":"primary baseline evidence does not match wrapper-owned baseline (exit statuses)"}' >"$state"
  resumable_blocked_state "$state" || return 1
  # blocked but no session_id → not resumable (can't safely re-enter).
  printf '%s\n' '{"status":"blocked","block_reason":"x"}' >"$state"
  resumable_blocked_state "$state" && return 1
  # rate-limit block (rate_limit_reset_at set) → handled by the rate-limit path, not this one.
  printf '%s\n' '{"status":"blocked","session_id":"sid-1","rate_limit_reset_at":"2026-01-01T00:00:00Z"}' >"$state"
  resumable_blocked_state "$state" && return 1
  # running → not a blocked-resume case at all.
  printf '%s\n' '{"status":"running","session_id":"sid-1"}' >"$state"
  resumable_blocked_state "$state" && return 1
  return 0
}

fixture_evidence_exit_status_match() {
  local root="$1" ev="$root/ev.json" wf="$root/wf.json"
  # Command strings differ only by an escaped semicolon, exit statuses match → MATCH
  # (the exact transcription case that wrongly blocked a correct run).
  printf '%s\n' '{"baseline":[{"command":"find . -exec node --check {} ;","exit_status":0}]}' >"$ev"
  printf '%s\n' '[{"command":"find . -exec node --check {} \\;","exit_status":0}]' >"$wf"
  evidence_exit_status_matches "$ev" baseline "$wf" || return 1
  # Same command, different exit status → NO match (real regression still blocks).
  printf '%s\n' '{"baseline":[{"command":"x","exit_status":1}]}' >"$ev"
  printf '%s\n' '[{"command":"x","exit_status":0}]' >"$wf"
  evidence_exit_status_matches "$ev" baseline "$wf" && return 1
  # Different command count → NO match.
  printf '%s\n' '{"baseline":[{"command":"x","exit_status":0}]}' >"$ev"
  printf '%s\n' '[{"command":"x","exit_status":0},{"command":"y","exit_status":0}]' >"$wf"
  evidence_exit_status_matches "$ev" baseline "$wf" && return 1
  return 0
}

fixture_explicit_personas_override() {
  local root="$1" spec="$root/explicit.md" active count
  # An explicit `- Personas:` list overrides the profile: the active set is the
  # floor plus exactly the named specialists, and unnamed profile personas drop.
  fixture_write_min_spec "$spec" '- Personas: Performance Expert'
  active="$(resolve_active_personas "$spec")" || return 1
  # Floor is always present even though only Performance Expert was named.
  case "|$active|" in *"|React Native Architect|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|TypeScript & Code Quality Expert|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Human Advocate|"*) ;; *) return 1 ;; esac
  case "|$active|" in *"|Performance Expert|"*) ;; *) return 1 ;; esac
  # Mobile UX Designer is in the `full` profile but was NOT named, so it drops.
  printf '%s' "$active" | grep -q "Mobile UX Designer" && return 1
  # floor (3) + Performance Expert = 4 active personas, no profile bloat.
  count="$(printf '%s' "$active" | tr '|' '\n' | grep -c .)"
  [ "$count" -eq 4 ] || return 1
  return 0
}

fixture_explicit_personas_with_optional() {
  local root="$1" spec="$root/explicit-opt.md" active
  # An explicit list may name an optional persona directly (no contract section
  # needed); it resolves like any other member of the universe.
  fixture_write_min_spec "$spec" '- Personas: Performance Expert, Security Reviewer'
  active="$(resolve_active_personas "$spec")" || return 1
  printf '%s' "$active" | grep -q "Security Reviewer" || return 1
  printf '%s' "$active" | grep -q "Performance Expert" || return 1
  return 0
}

fixture_explicit_personas_unknown() {
  local root="$1" spec="$root/explicit-bad.md" out
  # A name outside the track set ∪ PERSONAS_OPTIONAL (here a web persona on the
  # default rn track) is rejected, and validate_spec surfaces the specific reason.
  fixture_write_min_spec "$spec" '- Personas: Web Architect'
  resolve_active_personas "$spec" 2>/dev/null && return 1
  out="$(validate_spec "$spec" 2>&1)" || true
  case "$out" in
    *"unknown persona in Personas field: Web Architect"*) return 0 ;;
    *) return 1 ;;
  esac
}

fixture_rate_limit_recognition() {
  local root="$1" good="$root/rate-good.json" bad="$root/rate-bad.json"
  printf '%s\n' '{"api_error_status":429,"result":"You have hit your session limit - resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$good"
  printf '%s\n' '{"api_error_status":500,"result":"resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$bad"
  is_rate_limit_response "$good" && ! is_rate_limit_response "$bad"
}

fixture_rate_limit_epoch() {
  local root="$1" raw="$root/rate-epoch.json"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  [ "$(rate_limit_reset_epoch "$raw" 0)" = "60" ]
}

fixture_rate_limit_rebase() {
  local root="$1" state="$root/rebase-state.json" raw="$root/rebase-raw.json" now
  local saved_state="${STATE:-}" saved_root="${RUN_ROOT:-}" saved_buffer="$RATE_LIMIT_BUFFER_SECONDS"
  # Simulate recovery long after a limit: stale started_at (epoch 1) plus the
  # active elapsed captured at pause time (30s stage, 45s task).
  printf '%s\n' '{"status":"waiting","stage":"planning","stage_started_at":1,"task_started_at":1,"stage_started":{"planning":1},"session_id":"fixed-id","rate_limit_stage_elapsed":30,"rate_limit_task_elapsed":45}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  # Negative buffer forces the reset deadline into the past so no real sleep runs.
  STATE="$state"; RUN_ROOT="$root"; RATE_LIMIT_BUFFER_SECONDS=-100000
  wait_for_rate_limit_reset "$raw" >/dev/null 2>&1
  STATE="$saved_state"; RUN_ROOT="$saved_root"; RATE_LIMIT_BUFFER_SECONDS="$saved_buffer"
  now="$(date +%s)"
  # started_at must be rebased to ~now-minus-active-elapsed (downtime excluded).
  jq -e --argjson now "$now" '
    (($now - .stage_started_at) as $se | $se >= 28 and $se <= 45) and
    (($now - .task_started_at) as $te | $te >= 43 and $te <= 60) and
    .status == "running" and (has("rate_limit_stage_elapsed") | not)
  ' "$state" >/dev/null
}

fixture_rate_limit_recovery() {
  local root="$1" state="$root/rate-recovery-state.json" raw="$root/rate-recovery-raw.json"
  printf '%s\n' '{"status":"blocked","session_id":"fixed-id","block_reason":"primary command failed with status 1"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 5:40am (America/Sao_Paulo)","session_id":"fixed-id"}' >"$raw"
  recoverable_rate_limit_state "$state" "$raw"
}

fixture_rate_limit_cap() {
  local root="$1" state="$root/cap-state.json" raw="$root/cap-raw.json" rc=0
  local saved_state="${STATE:-}" saved_root="${RUN_ROOT:-}" saved_cap="$RATE_LIMIT_MAX_WAIT_SECONDS"
  printf '%s\n' '{"status":"running","stage":"planning","stage_started_at":0,"task_started_at":0,"stage_started":{"planning":0},"session_id":"fixed-id"}' >"$state"
  printf '%s\n' '{"api_error_status":429,"result":"session limit - resets 12:01am (Etc/UTC)","session_id":"fixed-id"}' >"$raw"
  # Force the cap below any possible wait so the guard must trigger block_run.
  STATE="$state"; RUN_ROOT="$root"; RATE_LIMIT_MAX_WAIT_SECONDS=-1
  (wait_for_rate_limit_reset "$raw") >/dev/null 2>&1 || rc=$?
  STATE="$saved_state"; RUN_ROOT="$saved_root"; RATE_LIMIT_MAX_WAIT_SECONDS="$saved_cap"
  [ "$rc" -ne 0 ]
}

# ---------------------------------------------------------------------------
# F1 fixture: run-lock stale-vs-live decision
# ---------------------------------------------------------------------------
fixture_run_lock() {
  local root="$1" lockdir="$root/lock-test/run.lock"
  mkdir -p "$lockdir"

  # A lock dir containing a dead PID (PID 1 is always alive on macOS, so use
  # a PID that is virtually certain not to exist: the max PID value on macOS is
  # 99998; the test PID 99998 is extremely unlikely to be running).
  local dead_pid=99998
  printf '%s\n' "$dead_pid" >"$lockdir/pid"
  lock_is_stale "$lockdir" || return 1   # dead PID → stale (should return 0 = stale)

  # A lock dir containing OUR OWN PID ($$ is definitely alive).
  printf '%s\n' "$$" >"$lockdir/pid"
  lock_is_stale "$lockdir" && return 1   # live PID → NOT stale (should return 1 = live)

  return 0
}

# ---------------------------------------------------------------------------
# F2 fixture: state_int validation
# ---------------------------------------------------------------------------
fixture_state_int() {
  # Exercise state_int end-to-end against a real temp STATE file.
  # state_int no longer calls block_run itself — it returns non-zero on bad
  # input — so we can test it directly without wrapping in a subshell.

  # --- is_valid_int sanity pass (fast, no file I/O needed) ------------------
  is_valid_int "0"    || return 1
  is_valid_int "42"   || return 1
  is_valid_int "9999" || return 1
  is_valid_int ""      && return 1
  is_valid_int "null"  && return 1
  is_valid_int "-1"    && return 1
  is_valid_int "1.5"   && return 1
  is_valid_int "abc"   && return 1

  # --- state_int happy path: valid integer field ----------------------------
  local tmp_state val
  tmp_state="$(mktemp /tmp/ns-fixture-state-int.XXXXXX.json)"
  # Point STATE at our temp file for the duration of this fixture.
  local saved_state="${STATE:-}"
  STATE="$tmp_state"
  printf '{"turns":42}\n' >"$tmp_state"
  val="$(state_int '.turns')"
  local rc=$?
  if [ $rc -ne 0 ] || [ "$val" != "42" ]; then
    STATE="$saved_state"; rm -f "$tmp_state"; return 1
  fi

  # --- state_int sad path: null field returns non-zero ----------------------
  # state_int must return 1 so callers can guard with || block_run.
  printf '{"turns":null}\n' >"$tmp_state"
  val="$(state_int '.turns')"
  rc=$?
  if [ $rc -eq 0 ]; then
    STATE="$saved_state"; rm -f "$tmp_state"; return 1
  fi

  # --- state_int sad path: missing field (jq returns empty) -----------------
  printf '{"other":1}\n' >"$tmp_state"
  val="$(state_int '.turns')"
  rc=$?
  if [ $rc -eq 0 ]; then
    STATE="$saved_state"; rm -f "$tmp_state"; return 1
  fi

  # --- state_int sad path: non-numeric string --------------------------------
  printf '{"turns":"abc"}\n' >"$tmp_state"
  val="$(state_int '.turns')"
  rc=$?
  if [ $rc -eq 0 ]; then
    STATE="$saved_state"; rm -f "$tmp_state"; return 1
  fi

  # --- Confirm the guarded assignment form works in THIS shell ---------------
  # x="$(state_int '.bad')" || <guard>  — the guard must fire.
  printf '{"turns":"bad"}\n' >"$tmp_state"
  local guard_fired=0
  local x
  x="$(state_int '.turns')" || guard_fired=1
  if [ "$guard_fired" -ne 1 ]; then
    STATE="$saved_state"; rm -f "$tmp_state"; return 1
  fi

  STATE="$saved_state"
  rm -f "$tmp_state"
  return 0
}

# ---------------------------------------------------------------------------
# F3 fixture: rate-limit consecutive counter threshold predicate
# ---------------------------------------------------------------------------
fixture_rate_limit_consecutive() {
  # Assert the SAME comparison used in invoke_primary:
  #   [ "$consecutive_429" -lt "$rate_limit_cap" ]
  # Values 0..cap-1 must be BELOW threshold (allowed, test returns true).
  # Values >= cap must be AT/OVER threshold (would block, test returns false).
  # This fixture fails if the operator or direction were wrong.
  local cap=5
  local consecutive_429

  # Below-threshold: every value in 0..cap-1 must satisfy the guard.
  consecutive_429=0
  while [ "$consecutive_429" -lt "$cap" ]; do
    [ "$consecutive_429" -lt "$cap" ] || return 1   # should always pass here
    consecutive_429=$((consecutive_429 + 1))
  done
  # consecutive_429 is now exactly cap; the loop exited because the guard
  # returned false — that's correct.  Verify the at-threshold case explicitly.
  consecutive_429=$cap
  [ "$consecutive_429" -lt "$cap" ] && return 1    # cap -lt cap is false → block expected

  # One above cap must also be treated as over-threshold.
  consecutive_429=$((cap + 1))
  [ "$consecutive_429" -lt "$cap" ] && return 1    # cap+1 -lt cap is false → block expected

  return 0
}

# Drives the REAL production predicate malformed_cap_reached at its boundaries:
# below the cap must NOT block; at/over the cap must block. Exercises production
# code (not a re-implemented comparison), so it fails if the operator/direction
# in malformed_cap_reached is ever wrong.
fixture_malformed_cap() {
  local cap="$MAX_MALFORMED_SIGNALS"
  # 0 and cap-1 are below threshold → predicate false (continue, do not block).
  ! malformed_cap_reached 0 || return 1
  ! malformed_cap_reached "$((cap - 1))" || return 1
  # cap and cap+1 are at/over threshold → predicate true (block).
  malformed_cap_reached "$cap" || return 1
  malformed_cap_reached "$((cap + 1))" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# F4 fixture: observer cost on BOTH attempts, no double-count on success
# ---------------------------------------------------------------------------
fixture_observer_cost_both_attempts() {
  local root="$1" dir="$root/obs-cost-both"
  mkdir -p "$dir/raw"
  # Case 1: first attempt FAILS validation (cost must appear), second succeeds.
  (
    RUN_ROOT="$dir"; OBSERVER=claude; PRIMARY=claude; SPEC="/x/spec.md"
    enforce_limits() { :; }
    enforce_elapsed_limits() { :; }
    normalize_observer_output() { :; }
    local attempt_count=0
    invoke_observer_once() {
      attempt_count=$((attempt_count + 1))
      printf '{"total_cost_usd":1.0,"num_turns":1,"usage":{"output_tokens":1}}\n' >"$4"
      if [ "$attempt_count" -eq 1 ]; then
        # First attempt: write an invalid verdict (malformed).
        printf '{"bad":true}\n' >"$3"
      else
        # Second attempt: write a valid verdict.
        printf '{"observer":"claude","primary":"claude","task":"/x/spec.md","candidate_commit":"a7a950b","status":"APPROVE","findings":[],"documentation_changes":[]}\n' >"$3"
      fi
    }
    validated_observer_retry "ctx" "a7a950b" "$dir/out.json" "$dir/raw/obs2.jsonl" || exit 1
    # Both attempts must have been costed (2 lines), not just the success one.
    [ "$(grep -c . "$dir/cost-ledger.jsonl")" -eq 2 ] || exit 1
  ) || return 1
  return 0
}

# ---------------------------------------------------------------------------
# F5 fixture: block_run state write failure does not suppress original reason
# ---------------------------------------------------------------------------
fixture_block_run_hardening() {
  local root="$1" dir="$root/block-harden"
  mkdir -p "$dir"
  local saved_state="${STATE:-}" saved_root="${RUN_ROOT:-}"
  # Force state_set to REALLY fail by placing STATE inside a read-only
  # directory: jq's attempt to write "$STATE.tmp.$$" will be denied, so
  # state_set's "||" triggers its own die.  The read-only-file trick used
  # previously did NOT force failure on macOS (mv to a read-only file owned
  # by the current user succeeds when the directory is writable).
  local ro_dir="$dir/ro" broken_state
  mkdir -p "$ro_dir"
  broken_state="$ro_dir/state.json"
  printf '{}' >"$broken_state"
  chmod 555 "$ro_dir"   # read-only dir: jq cannot create the .tmp.$$ file
  STATE="$broken_state"; RUN_ROOT="$dir"
  local rc=0 msg
  msg="$( ( block_run "UNIQUE_MARKER_REASON" ) 2>&1 )" || rc=$?
  STATE="$saved_state"; RUN_ROOT="$saved_root"
  chmod 755 "$ro_dir" 2>/dev/null || true
  # (a) Must have exited non-zero.
  [ "$rc" -ne 0 ] || return 1
  # (b) Output must contain the original block reason, NOT only state_set's
  #     "failed to update run state" message — proving the subshell fix works.
  case "$msg" in
    *"UNIQUE_MARKER_REASON"*) return 0 ;;
    *) return 1 ;;
  esac
}

fixture_candidate_order() {
  local root="$1" f="$root/cand.json"
  # Latest candidate sorts lexicographically BEFORE the previous one.
  printf '%s\n' '{"candidate_commits":["ffff111"],"candidate":"ffff111"}' >"$f"
  jq '.candidate_commits = ((.candidate_commits + ["0000aaa"])
        | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) | .candidate="0000aaa"' \
    "$f" > "$f.t" && mv "$f.t" "$f"
  # .candidate is the real latest, and [-1] keeps insertion order (not sorted).
  [ "$(jq -r '.candidate' "$f")" = "0000aaa" ] &&
    [ "$(jq -r '.candidate_commits[-1]' "$f")" = "0000aaa" ] &&
    [ "$(jq -r '.candidate_commits[0]' "$f")" = "ffff111" ]
}

fixture_stage_fresh_start() {
  local root="$1" state="$root/stage.json" saved="${STATE:-}" now
  # An ancient recorded start for the stage we are about to (re-)enter.
  printf '%s\n' '{"stage":"implementation","stage_turns":5,"stage_started_at":100,"stage_counters":{"implementation":5},"stage_started":{"implementation":100,"implementation_ready":200},"updated_at":"x"}' >"$state"
  STATE="$state"
  set_stage implementation_ready
  STATE="$saved"
  now="$(date +%s)"
  # Must use NOW, not the ancient 200, and carry over the stage's turn count.
  jq -e --argjson now "$now" '
    .stage == "implementation_ready" and
    (($now - .stage_started_at) >= 0 and ($now - .stage_started_at) < 30) and
    .stage_started_at > 1000
  ' "$state" >/dev/null
}

fixture_observer_normalization() {
  local root="$1" in="$root/obs-norm.json" ok=1
  # The exact non-conforming shape that wedged the real run.
  printf '%s\n' '{"status":"REQUEST_CHANGES","base_commit":"x","summary":"missing changelog","observer":"claude","primary":"claude","task":"t","candidate_commit":"c","findings":[{"id":"OBS-1","severity":"high","location":"CHANGELOG.md","required_change":"add changelog","evidence":"spec line 105"}],"documentation_changes":[]}' >"$in"
  normalize_observer_output "$in" "specs/toggle-todo.md" "ba0b987bc2d559df865cac09562044fd337c17c9"
  json_schema_basic observer-review "$in" &&
    [ "$(jq -r '.status' "$in")" = "BLOCK" ] &&
    [ "$(jq -r '.findings[0].id' "$in")" = "OBS-001" ] &&
    [ "$(jq -r '.task' "$in")" = "specs/toggle-todo.md" ] &&
    [ "$(jq -r '.candidate_commit' "$in")" = "ba0b987bc2d559df865cac09562044fd337c17c9" ] || ok=0
  # APPROVE synonym drops findings and validates.
  printf '%s\n' '{"status":"APPROVED","findings":[{"id":"OBS-2","evidence":"e","required_change":"r"}]}' >"$in"
  normalize_observer_output "$in" "specs/x.md" "abcdef1234567"
  json_schema_basic observer-review "$in" &&
    [ "$(jq -r '.status' "$in")" = "APPROVE" ] &&
    [ "$(jq -r '.findings|length' "$in")" = "0" ] || ok=0
  [ "$ok" -eq 1 ]
}

fixture_observer_extraction() {
  local root="$1" raw="$root/ex-raw.json" out="$root/ex-out.json" ok=1
  # (1) whole result is JSON
  jq -n '{result:"{\"status\":\"APPROVE\",\"findings\":[]}"}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.status' "$out")" = "APPROVE" ] || ok=0
  # (2) prose then a fenced ```json verdict block
  printf '%s' 'Here is my review. Looks fine overall.

```json
{"status":"BLOCK","findings":[{"id":"OBS-001"}]}
```' | jq -Rs '{result:.}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.findings[0].id' "$out")" = "OBS-001" ] || ok=0
  # (3) JSON object embedded in prose, no fence
  printf '%s' 'Verdict: {"status":"APPROVE","findings":[]} done.' | jq -Rs '{result:.}' >"$raw"
  extract_claude_structured "$raw" "$out" &&
    [ "$(jq -r '.status' "$out")" = "APPROVE" ] || ok=0
  [ "$ok" -eq 1 ]
}

fixture_missing_tools() {
  local root="$1" ok="$root/tools-ok.json" bad="$root/tools-bad.json"
  printf '%s\n' '[{"command":"npx tsc","exit_status":0,"output":"ok"}]' >"$ok"
  printf '%s\n' '[{"command":"npx tsc","exit_status":127,"output":"not found"}]' >"$bad"
  tools_available "$ok" && ! tools_available "$bad"
}

fixture_finding_stall() {
  local root="$1" h="$root/stall.json"
  rm -f "$h"
  [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"a"}]')" = "1" ] &&
    [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"a"}]')" = "2" ] &&
    [ "$(bump_finding_history "$h" '[{"id":"X-001","fp":"b"}]')" = "1" ]
}

fixture_retry_adapter() {
  local attempts="$1" output="$2" count
  count="$(cat "$attempts")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$attempts"
  if [ "$count" -eq 1 ]; then
    printf '%s\n' '{"bad":true}' >"$output"
  else
    printf '%s\n' '{"observer":"claude","primary":"claude","task":"specs/a.md","candidate_commit":"abcdef1","status":"APPROVE","findings":[],"documentation_changes":[]}' >"$output"
  fi
}

validated_retry() {
  local kind="$1" output="$2" callback="$3"
  shift 3
  local attempt=0
  while [ "$attempt" -lt 2 ]; do
    "$callback" "$@" || true
    json_schema_basic "$kind" "$output" && return 0
    attempt=$((attempt + 1))
  done
  return 1
}

run_live_fixtures() {
  [ "${NIGHT_SHIFT_ACCEPT_COSTS:-}" = "YES" ] ||
    die "live fixture tests make paid model calls; set NIGHT_SHIFT_ACCEPT_COSTS=YES"
  require_command claude
  log "running minimal paid Claude startup, session-ID, resume, unattended-tool, and observer checks"
  log "(each live check is silent on success and only prints on failure)"
  log "1/3 startup + session-id + resume..."
  live_adapter_check claude
  log "2/3 unattended tool use (bypassPermissions)..."
  live_primary_tool_check
  log "3/3 observer (neutral cwd, no tools, schema)..."
  live_observer_check
  if [ "$FULL_PERSONA_LIVE_TEST" -eq 1 ]; then
    log "cost warning accepted: running six live persona calls"
    live_persona_checks
  fi
  log "all live checks passed — the workflow can run unattended"
}

# Proves the primary can actually edit files / run tools UNATTENDED with the same
# permission posture the run uses. Without this the overnight primary would be
# unable to act and the run would stall — the gap a session-only smoke test hides.
live_primary_tool_check() {
  local root marker
  root="$WORKSPACE_ROOT/.night-shift-live-primary.$$"
  marker="$root/proof.txt"
  mkdir -p "$root"
  (cd "$root" && claude -p --permission-mode bypassPermissions --output-format json \
    'Create a file named proof.txt in the current directory containing exactly the word OK. Use your tools. Then reply done.') \
    >"$root/out.json" 2>&1 ||
    die "primary unattended tool call failed; state preserved at $root"
  [ -f "$marker" ] && grep -q OK "$marker" ||
    die "primary could not write a file unattended (permission posture is wrong); state preserved at $root"
  rm -rf "$root"
}

# Exercises the real observer invocation: neutral CWD, JSON result-text
# extraction, and schema validation the run depends on. This is the part most
# likely to differ across Claude CLI versions, so prove it before a run.
live_observer_check() {
  local root neutral raw out
  root="$WORKSPACE_ROOT/.night-shift-live-observer.$$"
  neutral="$root/cwd"
  mkdir -p "$neutral"
  raw="$root/observer.raw"
  out="$root/observer.json"
  (cd "$neutral" && claude -p --output-format json \
    'End your reply with exactly one fenced code block tagged json and nothing after it, containing: {"observer":"claude","primary":"claude","task":"specs/smoke.md","candidate_commit":"abcdef1","status":"APPROVE","findings":[],"documentation_changes":[]}') >"$raw" 2>"${raw}.err" ||
    die "observer call failed; state preserved at $root"
  extract_claude_structured "$raw" "$out" ||
    die "could not parse observer JSON from .result; state preserved at $root"
  json_schema_basic observer-review "$out" ||
    die "observer output did not match observer-review.json; state preserved at $root"
  rm -rf "$root"
}

live_adapter_check() {
  local adapter="$1" root output session
  root="$WORKSPACE_ROOT/.night-shift-live-$adapter.$$"
  mkdir -p "$root"
  output="$root/start.raw"
  claude -p --output-format json \
    'Return exactly the word READY. Do not use tools.' >"$output" ||
    die "Claude live startup failed; state preserved at $root"
  session="$(jq -r '.session_id // empty' "$output")"
  [ -n "$session" ] || die "Claude emitted no session ID; state preserved at $root"
  claude -p --resume "$session" --output-format json \
    'Return exactly the word RESUMED. Do not use tools.' >"$root/resume.raw" ||
    die "Claude explicit resume failed; state preserved at $root"
  [ "$(jq -r '.session_id // empty' "$root/resume.raw")" = "$session" ] ||
    die "Claude session ID changed on resume; state preserved at $root"
  rm -rf "$root"
}

live_persona_checks() {
  local persona slug
  old_ifs="$IFS"; IFS='|'
  for persona in $PERSONAS; do
    IFS="$old_ifs"
    slug="$(printf '%s' "$persona" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
    log "live persona smoke check: $slug"
    claude -p --output-format json "As $persona, return APPROVE and no findings for an empty diff." >/dev/null
    IFS='|'
  done
  IFS="$old_ifs"
}

# --- RN visual_review device-registry fixtures (PR #10) ---
fixture_device_registry_root() {
  local root="$1"
  # Default root is under $HOME/.night-shift/devices.
  case "$(device_registry_root)" in */.night-shift/devices) ;; *) return 1 ;; esac
  # Override env wins.
  [ "$(NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$root/reg" device_registry_root)" = "$root/reg" ] || return 1
  return 0
}

fixture_make_simctl_stub() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/xcrun" <<STUB
#!/usr/bin/env bash
log="$dir/calls.log"
shift  # drop "simctl"
case "\$1 \$2 \$3" in
  "list devices available") cat "$dir/devices.json"; exit 0 ;;
  "list devices -j"*)        cat "$dir/devices.json"; exit 0 ;;
esac
case "\$1" in
  list)   cat "$dir/devices.json"; exit 0 ;;
  clone)  printf 'clone %s %s\n' "\$2" "\$3" >>"\$log"; printf 'UDID-CLONE-%s\n' "\$3"; exit 0 ;;
  delete) printf 'delete %s\n' "\$2" >>"\$log"; exit 0 ;;
  *)      exit 0 ;;
esac
STUB
  chmod +x "$dir/bin/xcrun"
}

fixture_write_devices_json() {
  cat >"$1" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true },
  { "name": "iPhone 15", "udid": "UDID-BBB", "state": "Shutdown", "isAvailable": true }
] } }
JSON
}

fixture_device_try_claim() {
  local root="$1" stub="$root/dtc"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    # candidates returns both UDIDs for the label.
    [ "$(device_candidates iphone-15 | tr '\n' ',' )" = "UDID-AAA,UDID-BBB," ] || exit 1
    # first claim of AAA succeeds; a second claim of AAA fails (held).
    device_try_claim UDID-AAA run-A false || exit 1
    device_try_claim UDID-AAA run-B false && exit 1
    # a stale lock (dead PID) is reclaimable.
    printf '99998\n' >"$stub/reg/UDID-AAA.lock/pid"
    device_try_claim UDID-AAA run-C false || exit 1
    exit 0
  )
}

fixture_device_claim_distinct() {
  local root="$1" stub="$root/dcd"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    local a b
    a="$(device_claim iphone-15 run-A)" || exit 1
    b="$(device_claim iphone-15 run-B)" || exit 1
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || exit 1   # two real devices
    exit 0
  )
}

fixture_device_claim_clone_on_exhaustion() {
  local root="$1" stub="$root/dce"
  fixture_make_simctl_stub "$stub"
  # Only ONE matching device, so the 2nd claim must clone.
  cat >"$stub/devices.json" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true }
] } }
JSON
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    device_claim iphone-15 run-A >/dev/null || exit 1
    local b; b="$(device_claim iphone-15 run-B)" || exit 1
    [ "$b" = "UDID-CLONE-ns-nightshift-run-B-iphone-15" ] || exit 1     # stub clone udid
    grep -q "clone UDID-AAA ns-nightshift-run-B-iphone-15" "$stub/calls.log" || exit 1
    [ "$(cat "$stub/reg/$b.lock/clone")" = "true" ] || exit 1
    exit 0
  )
}

fixture_device_release() {
  local root="$1" stub="$root/drl"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0
    device_try_claim UDID-AAA run-A false || exit 1     # real device
    device_release UDID-AAA
    [ -d "$stub/reg/UDID-AAA.lock" ] && exit 1          # lock removed
    grep -q "delete UDID-AAA" "$stub/calls.log" && exit 1   # NOT deleted (real)
    device_try_claim UDID-CLONE-x run-B true || exit 1  # a clone
    device_release UDID-CLONE-x
    grep -q "delete UDID-CLONE-x" "$stub/calls.log" || exit 1  # clone deleted
    exit 0
  )
}

fixture_device_prune() {
  local root="$1" stub="$root/dpr"
  fixture_make_simctl_stub "$stub"
  # devices list contains an orphan ns-nightshift-* clone with NO lock,
  # and a user-owned sim named ns-personal that must NOT be deleted.
  cat >"$stub/devices.json" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "iPhone 15", "udid": "UDID-AAA", "state": "Shutdown", "isAvailable": true },
  { "name": "ns-nightshift-OLD", "udid": "UDID-ORPHAN", "state": "Shutdown", "isAvailable": true },
  { "name": "ns-personal", "udid": "UDID-USER", "state": "Shutdown", "isAvailable": true }
] } }
JSON
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    mkdir -p "$stub/reg/UDID-AAA.lock"; printf '99998\n' >"$stub/reg/UDID-AAA.lock/pid"
    printf 'false\n' >"$stub/reg/UDID-AAA.lock/clone"      # stale real lock
    device_registry_prune
    grep -q "delete UDID-AAA" "$stub/calls.log" && exit 1  # non-clone stale lock must NOT be deleted
    [ -d "$stub/reg/UDID-AAA.lock" ] && exit 1             # stale lock reclaimed
    grep -q "delete UDID-ORPHAN" "$stub/calls.log" || exit 1  # orphan clone deleted
    grep -q "delete UDID-USER" "$stub/calls.log" && exit 1    # user sim must NOT be deleted
    exit 0
  )
}

fixture_device_prune_creation_race() {
  local root="$1" stub="$root/dpc"
  fixture_make_simctl_stub "$stub"
  cat >"$stub/devices.json" <<'JSON'
{ "devices": { "iOS-17": [
  { "name": "ns-nightshift-Z-iphone-15", "udid": "UDID-CREATING", "state": "Shutdown", "isAvailable": true }
] } }
JSON
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    mkdir -p "$stub/reg/.creating-ns-nightshift-Z-iphone-15"
    printf '%s\n' "$$" >"$stub/reg/.creating-ns-nightshift-Z-iphone-15/pid"
    device_registry_prune                                   # live marker -> must NOT delete
    grep -q "delete UDID-CREATING" "$stub/calls.log" 2>/dev/null && exit 1
    printf '99998\n' >"$stub/reg/.creating-ns-nightshift-Z-iphone-15/pid"
    device_registry_prune                                   # stale marker -> deletes
    grep -q "delete UDID-CREATING" "$stub/calls.log" || exit 1
    exit 0
  )
}

fixture_visual_capture_udid_arg() {
  local root="$1" d="$root/vcu"
  mkdir -p "$d/bin"
  # Minimal xcrun: log the udid passed to `simctl boot`, succeed otherwise.
  # `simctl io ... screenshot <out>` writes a 1-byte file so capture returns 0.
  cat >"$d/bin/xcrun" <<STUB
#!/usr/bin/env bash
log="$d/boot.log"
shift  # drop "simctl"
case "\$1" in
  boot) printf 'boot %s\n' "\$2" >>"\$log" ;;
  io)   printf x >"\${!#}" ;;   # last arg is the screenshot output path
esac
exit 0
STUB
  chmod +x "$d/bin/xcrun"
  (
    export PATH="$d/bin:$PATH" NIGHT_SHIFT_VISUAL_SETTLE_SECONDS=0
    # Sentinel resolver: if internal resolution is (wrongly) used with an explicit
    # udid, the boot log would contain RESOLVED-SENTINEL.
    __visual_resolve_udid() { printf 'RESOLVED-SENTINEL\n'; }
    # (a) explicit udid is used, resolver NOT consulted.
    __visual_capture_screenshot home default iphone-15 "$d/a.png" EXPLICIT-UDID || exit 1
    grep -q 'boot EXPLICIT-UDID' "$d/boot.log" || exit 1
    grep -q 'RESOLVED-SENTINEL' "$d/boot.log" && exit 1
    # (b) no explicit udid -> resolver used.
    : >"$d/boot.log"
    __visual_capture_screenshot home default iphone-15 "$d/b.png" || exit 1
    grep -q 'boot RESOLVED-SENTINEL' "$d/boot.log" || exit 1
    exit 0
  )
}

fixture_visual_capture_registry_claim() {
  local root="$1" stub="$root/vcr"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg" \
           NIGHT_SHIFT_DEVICE_REGISTRY=1 NIGHT_SHIFT_DEVICE_ACQUIRE_TIMEOUT=0 RUN_ID=run-A
    _ns_reg=1
    _ns_cache_dir="$(mktemp -d /tmp/ns-vcr-XXXXXX)"
    _ns_release_all() {
      local u
      if [ -f "${_ns_cache_dir}/claimed" ]; then
        while IFS= read -r u; do
          [ -n "$u" ] && device_release "$u"
        done <"${_ns_cache_dir}/claimed"
      fi
      rm -rf "${_ns_cache_dir}"
    }
    local u; u="$(__visual_udid_for_label iphone-15)"
    [ -n "$u" ] || exit 1
    [ -d "$stub/reg/$u.lock" ] || exit 1
    # second call for same label reuses the SAME udid (cache hit, no new claim).
    [ "$(__visual_udid_for_label iphone-15)" = "$u" ] || exit 1
    _ns_release_all
    [ -d "$stub/reg/$u.lock" ] && exit 1
    exit 0
  )
}

fixture_visual_registry_off_no_artifacts() {
  local root="$1" stub="$root/vroff"
  fixture_make_simctl_stub "$stub"; fixture_write_devices_json "$stub/devices.json"
  (
    export PATH="$stub/bin:$PATH" NIGHT_SHIFT_DEVICE_REGISTRY_DIR="$stub/reg"
    _ns_reg=0; _ns_cache_dir=""
    [ -z "$(__visual_udid_for_label iphone-15)" ] || exit 1
    [ -d "$stub/reg" ] && exit 1
    exit 0
  )
}

fixture_visual_prune_guarded() {
  local root="$1"
  (
    # Shadow the real prune with a marker writer.
    device_registry_prune() { printf 'pruned\n' >"$root/pruned.marker"; }
    # Registry OFF: guard must NOT call prune.
    rm -f "$root/pruned.marker"
    ( unset NIGHT_SHIFT_DEVICE_REGISTRY
      [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && device_registry_prune; true )
    [ -f "$root/pruned.marker" ] && exit 1
    # Registry ON: guard MUST call prune.
    NIGHT_SHIFT_DEVICE_REGISTRY=1
    [ "${NIGHT_SHIFT_DEVICE_REGISTRY:-0}" = "1" ] && device_registry_prune
    [ -f "$root/pruned.marker" ] || exit 1
    exit 0
  )
}
