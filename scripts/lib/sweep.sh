# shellcheck shell=bash
# scripts/lib/sweep.sh
# Branch sweep (NIGHT_SHIFT_BRANCH_SWEEP): one whole-branch strong-model
# review at run end. See docs/superpowers/specs/2026-07-11-agentic-gaps-
# tranche-design.md §A. Sourced by night-shift.sh after events/recovery libs.

# Print merge-base; write package.diff + package.meta.json into $2.
# Refuses to sweep a default-branch tip (nothing branch-shaped to review).
sweep_build_package() {
  local project="$1" out="$2" head branch mb default
  mkdir -p "$out" || return 1
  branch="$(git -C "$project" branch --show-current)"
  default="$(git -C "$project" rev-parse --verify -q main >/dev/null 2>&1 && echo main || echo master)"
  [ -n "$branch" ] && [ "$branch" != "$default" ] || {
    printf 'sweep: project is on %s — no feature branch to sweep\n' "${branch:-detached}" >&2
    return 1
  }
  head="$(git -C "$project" rev-parse HEAD)"
  mb="$(git -C "$project" merge-base "$default" HEAD)" || return 1
  [ "$mb" != "$head" ] || { printf 'sweep: branch has no commits over %s\n' "$default" >&2; return 1; }
  {
    printf '## commits\n'; git -C "$project" log --oneline "$mb..HEAD"
    printf '\n## stat\n';  git -C "$project" diff --stat "$mb..HEAD"
    printf '\n## diff\n';  git -C "$project" diff -U10 "$mb..HEAD"
  } >"$out/package.diff"
  jq -n --arg branch "$branch" --arg base "$mb" --arg head "$head" \
    --argjson commit_count "$(git -C "$project" rev-list --count "$mb..HEAD")" \
    '{branch:$branch, base:$base, head:$head, commit_count:$commit_count}' \
    >"$out/package.meta.json"
  printf '%s\n' "$mb"
}

# stdin: session text -> stdout: SWEEP_PASS | SWEEP_FINDINGS. Fail-closed:
# anything that doesn't contain an explicit SWEEP_PASS is findings.
sweep_parse_verdict() {
  if grep -q 'SWEEP_PASS' -; then printf 'SWEEP_PASS\n'; else printf 'SWEEP_FINDINGS\n'; fi
}

sweep_prompt() {
  local out="$1"
  cat <<'EOF'
You are the final whole-branch reviewer for an overnight autonomous run.
Per-task reviews already passed; you look for what they cannot see:
cross-task interactions, regressions between commits, accumulated minor
findings that add up, removed-behavior gaps, hygiene (test fixtures must be
neutral stand-ins, no company identifiers, i18n key pairs complete), and
tests weakened rather than updated. Read the package file below fully.
For each finding: severity (Critical/Important/Minor), file:line, a concrete
failure scenario, and the concrete fix. End your reply with exactly one line:
either `SWEEP_PASS` or `SWEEP_FINDINGS: <count>`.
EOF
  printf '\nPackage: %s/package.diff (read it with your file tools)\n' "$out"
}

# Run the sweep session. Writes $out/findings.md + $out/verdict.txt; emits
# sweep event. Never propagates failure (advisory contract) — a session
# error yields verdict SWEEP_ERROR in verdict.txt and a warn log.
sweep_run() {
  local project="$1" out="$2" raw rc=0 model verdict
  model="$(resolve_effective_model "$SWEEP_MODEL")"
  raw="$out/session.json"
  # model_flag intentionally word-splits into `--model X` (or nothing); same
  # idiom as invoke_observer_once.
  # shellcheck disable=SC2046
  (cd "$project" && sweep_prompt "$out" |
    claude -p $(model_flag "$model") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if command -v is_rate_limit_response >/dev/null 2>&1 && is_rate_limit_response "$raw"; then
      handle_rate_limit_wait "$raw" subagent || true
      rc=0
      # shellcheck disable=SC2046
      (cd "$project" && sweep_prompt "$out" |
        claude -p $(model_flag "$model") --output-format json) >"$raw" 2>"$raw.err" || rc=$?
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'SWEEP_ERROR\n' >"$out/verdict.txt"
    log "WARN: branch sweep session failed (rc=$rc, advisory; see $raw.err)"
    emit_event sweep "$(jq -cn '{verdict:"SWEEP_ERROR"}')"
    return 0
  fi
  jq -r '.result // empty' "$raw" >"$out/findings.md" 2>/dev/null || cp "$raw" "$out/findings.md"
  verdict="$(sweep_parse_verdict <"$out/findings.md")"
  printf '%s\n' "$verdict" >"$out/verdict.txt"
  [ -z "${RUN_ROOT:-}" ] || { integrity_put "$out/findings.md"; integrity_put "$out/verdict.txt"; }
  emit_event sweep "$(jq -cn --arg v "$verdict" '{verdict:$v}')"
  log "branch sweep verdict: $verdict"
  return 0
}
