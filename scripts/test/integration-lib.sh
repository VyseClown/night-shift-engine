# shellcheck shell=bash
# integration-lib.sh — shared scaffold for the full-orchestration tests
# (integration-run.sh = happy path, integration-adverse.sh = blocked/recovery,
# integration-cursor.sh = cursor implementer backend). Everything here is a
# verbatim extraction from integration-run.sh; the stub gained MODES so
# adverse scenarios can misbehave deterministically:
#   happy              — the original scripted pipeline (plan -> impl -> candidate
#                        -> observer APPROVE -> complete)
#   malformed          — the primary emits an invalid signal every turn (drives
#                        the consecutive-malformed cap into a block)
#   block-then-approve — the observer BLOCKs the first candidate with OBS-001;
#                        the re-entered implement turn appends a guard line so
#                        the SECOND candidate differs; second verdict APPROVEs.
#   cursor-fail        — write_cursor_stub only: the cursor-agent primary
#                        exits 1 with the verified stderr-only RetriableError
#                        shape and nothing on stdout, to drive
#                        invoke_primary's bounded-retry -> sticky-claude-
#                        fallback path.
#   cursor-empty       — write_cursor_stub only: the cursor-agent primary
#                        exits 0 with a valid JSON envelope but no session_id
#                        (envelope drift, not a CLI failure), to drive the
#                        SAME bounded-retry -> sticky-claude-fallback path via
#                        invoke_primary's rc==0-but-no-session_id guard.

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ENGINE="$ENGINE_DIR/scripts/night-shift.sh"
FAIL_PREFIX="${FAIL_PREFIX:-integration}"
CLEANUP_DIRS=""

fail() { printf 'not ok - %s: %s\n' "$FAIL_PREFIX" "$*" >&2; exit 1; }

# macOS has no GNU `timeout`; fall back to a perl alarm wrapper (stock perl).
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"
  fi
}

integration_cleanup() {
  [ -n "${REVIEW_BAK:-}" ] && cp "$REVIEW_BAK" "$REVIEW" 2>/dev/null || true
  rm -f "${REVIEW_BAK:-}" 2>/dev/null || true
  local d
  for d in $CLEANUP_DIRS; do rm -rf "$d" 2>/dev/null || true; done
}

# Fresh throwaway workspace: node project with a RED test on feat/add, a valid
# node-track spec, and the NIGHT_SHIFT_REVIEW.md backup/restore trap. Safe to
# call more than once per script (each call gets its own $WORK; all are removed
# on exit).
integration_setup() {
  WORK="$(mktemp -d)"
  CLEANUP_DIRS="$CLEANUP_DIRS $WORK"
  # The engine appends each observer verdict to $WORKSPACE_ROOT/NIGHT_SHIFT_REVIEW.md
  # (the engine repo) — that is intended for real runs, but tests must not leave
  # throwaway entries in that tracked file, so back it up and restore it on exit.
  REVIEW="$ENGINE_DIR/NIGHT_SHIFT_REVIEW.md"
  if [ -z "${REVIEW_BAK:-}" ]; then
    REVIEW_BAK="$(mktemp)"; cp "$REVIEW" "$REVIEW_BAK" 2>/dev/null || REVIEW_BAK=""
  fi
  trap integration_cleanup EXIT

  PROJECT="$WORK/project"; BIN="$WORK/bin"; SPEC="$WORK/spec.md"
  mkdir -p "$PROJECT" "$BIN"

  # --- a throwaway node project: a test that is RED until add.js exists --------
  (
    cd "$PROJECT"
    git init -q; git config user.email t@t; git config user.name t
    printf '.night-shift/\nnode_modules/\n' > .gitignore
    cat > add.test.js <<'JS'
const test = require('node:test');
const assert = require('node:assert');
const { add } = require('./add.js');
test('add sums two numbers', () => { assert.strictEqual(add(2, 3), 5); });
JS
    git add .gitignore add.test.js
    git commit -qm "baseline: failing test (add.js missing)"
    git branch -M main
    git checkout -q -b feat/add
  ) || fail "project setup failed"

  # --- a valid node-track spec ------------------------------------------------
  cat > "$SPEC" <<SPEC
# Spec: add() helper

## Repository
- Project path: \`$PROJECT\`
- Base branch: \`main\`
- Feature branch: \`feat/add\`

## Review
- Track: node
- Review Profile: logic

## Permissions
- New dependencies permitted: no - stdlib test runner only

## Documentation
- Documentation owned by each review persona:
  - Backend & Data Expert: none — trivial pure function
  - TypeScript & Code Quality Expert: none — single-file helper
  - Performance Expert: none — O(1)
  - Human Advocate: none — no user-facing surface

## Test Plan
- First failing test or executable check: \`node --test add.test.js\`
- Baseline validation commands (run before edits):
  1. \`node --version\`
- Final validation commands (run in this order):
  1. \`node --version\`
  2. \`node --test add.test.js\`
SPEC
}

# Scripted `cursor-agent` on PATH (specs/cursor-implementer-backend.md Task 2):
# the cursor implementer backend. Unlike write_stub's `claude` binary, this is
# the primary ONLY — no role multiplexing needed, since plan/persona/observer
# turns stay on the claude stub regardless of the backend knob. --trust is
# asserted defensively as the expected discriminator (the primary's cursor
# invocation always passes it; a call missing it is a wiring bug). Appends one
# line per invocation to $WORK/.cursor-calls (proves cursor actually ran the
# turns it was supposed to). MODE=cursor-fail exits 1 with the verified
# stderr-only RetriableError shape and nothing on stdout, to drive the
# bounded-retry -> sticky-fallback path.
write_cursor_stub() {
  local mode="${1:-happy}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'MODE=%q\n' "$mode"
    printf 'WORK=%q\n' "$WORK"
    cat <<'STUB'
has_trust=0; for a in "$@"; do [ "$a" = "--trust" ] && has_trust=1; done
[ "$has_trust" = "1" ] || { printf 'Error: expected --trust in argv (not the cursor primary?)\n' >&2; exit 1; }
emit(){ jq -cn --arg s "$1" --arg r "$2" '{type:"result",subtype:"success",is_error:false,result:$r,session_id:$s,usage:{inputTokens:1,outputTokens:1,cacheReadTokens:0,cacheWriteTokens:0}}'; }
# Stage-dispatch mirrors write_stub's primary branch below (LOCKSTEP: any stage
# case added there must be mirrored here too, and vice versa — see the
# reciprocal comment on write_stub's own case statement). Planning branches
# are unreachable in cursor mode (the plan scope always stays on the claude
# stub) but kept for lockstep/documentation.
st=.night-shift/state.json; c=.night-shift/control; mkdir -p "$c"; sig="$c/next-action.json"
stage="$(jq -r '.stage' "$st")"; spec="$(jq -r '.task' "$st")"
# One line per invocation, keyed on stage (NOT the raw multi-line prompt in
# "$*" — that would inflate the line count with the prompt's own newlines).
printf '%s\n' "$stage" >> "$WORK/.cursor-calls"
if [ "$MODE" = "cursor-fail" ]; then
  printf 'Error: RetriableError: [resource_exhausted]\n' >&2
  exit 1
fi
if [ "$MODE" = "cursor-empty" ]; then
  # Envelope drift: rc 0 (a clean exit — no stderr, no nonzero status) but the
  # JSON envelope carries no session_id. invoke_primary must treat this the
  # same as a cursor invocation failure (routes into the SAME bounded-retry ->
  # sticky-fallback branch), not the post-loop "primary emitted no resumable
  # session ID" block_run.
  jq -cn --arg r "done" '{type:"result",subtype:"success",is_error:false,result:$r,usage:{inputTokens:1,outputTokens:1,cacheReadTokens:0,cacheWriteTokens:0}}'
  exit 0
fi
case "$stage" in
  planning|plan_review)
    printf '# Plan\n- create add.js exporting add(a,b)=>a+b.\n' > "$c/plan.md"
    jq -cn --arg t "$spec" '{action:"RUN_PERSONAS",task:$t,stage:"planning",reason:"plan",artifacts:[]}' > "$sig" ;;
  implementation|implementation_review)
    printf 'module.exports.add = (a, b) => a + b;\n' > add.js
    jq -cn --arg t "$spec" '{action:"RUN_PERSONAS",task:$t,stage:"implementation",reason:"impl",artifacts:[]}' > "$sig" ;;
  implementation_ready)
    git add add.js >/dev/null 2>&1; git commit -qm "feat: add() helper" >/dev/null 2>&1
    jq -cn --arg t "$spec" '{task:$t,
      baseline:[{command:"node --version",exit_status:0,output:"v"}],
      test_first:{command:"node --test add.test.js",failing_exit_status:1,failing_output:"red",passing_exit_status:0,passing_output:"green"},
      final_validation:[{command:"node --version",exit_status:0,output:"v"},{command:"node --test add.test.js",exit_status:0,output:"green"}]}' > "$c/evidence.json"
    jq -cn --arg t "$spec" '{action:"CREATE_CANDIDATE",task:$t,stage:"implementation_ready",reason:"cand",artifacts:[".night-shift/control/evidence.json"]}' > "$sig" ;;
  observer_review)
    jq -cn --arg t "$spec" '{action:"REQUEST_OBSERVER",task:$t,stage:"observer_review",reason:"obs",artifacts:[]}' > "$sig" ;;
  completion)
    jq -cn --arg t "$spec" '{action:"COMPLETE",task:$t,stage:"completion",reason:"done",artifacts:[]}' > "$sig" ;;
  *) jq -cn --arg t "$spec" --arg s "$stage" '{action:"BLOCKED",task:$t,stage:$s,reason:("stub stage "+$s),artifacts:[]}' > "$sig" ;;
esac
emit stubcursor "done"; exit 0
STUB
  } > "$BIN/cursor-agent"
  chmod +x "$BIN/cursor-agent"
}

# Scripted `claude` on PATH: primary (writes stage files + signal), personas,
# observer — behavior selected by mode (see header).
write_stub() {
  local mode="${1:-happy}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'MODE=%q\n' "$mode"
    printf 'WORK=%q\n' "$WORK"
    cat <<'STUB'
# --version FIRST, before any stdin read: the engine's rate-limit contract
# canary calls `claude --version`, and a stub that falls through to the
# prompt path blocks on `cat` until the harness timeout whenever the
# harness inherited an open stdin (the intermittent SIGALRM-at-240s flake:
# see the run_engine xtrace note in this file's history).
for a in "$@"; do [ "$a" = "--version" ] && { printf '9.9.9 (Claude Code)\n'; exit 0; }; done
is_primary=0; for a in "$@"; do [ "$a" = "bypassPermissions" ] && is_primary=1; done
emit(){ jq -cn --arg s "$1" --arg r "$2" '{session_id:$s,result:$r,total_cost_usd:0,num_turns:1,is_error:false}'; }
if [ "$is_primary" = "1" ]; then
  st=.night-shift/state.json; c=.night-shift/control; mkdir -p "$c"; sig="$c/next-action.json"
  stage="$(jq -r '.stage' "$st")"; spec="$(jq -r '.task' "$st")"
  if [ "$MODE" = "malformed" ]; then
    jq -cn --arg t "$spec" '{action:"FLABBERGAST",task:$t,stage:"planning",reason:"nope",artifacts:[]}' > "$sig"
    emit stubprimary "done"; exit 0
  fi
  # Stage-dispatch is mirrored in write_cursor_stub's own case above (LOCKSTEP:
  # any stage case added here must be mirrored there too, and vice versa).
  case "$stage" in
    planning|plan_review)
      printf '# Plan\n- create add.js exporting add(a,b)=>a+b.\n' > "$c/plan.md"
      jq -cn --arg t "$spec" '{action:"RUN_PERSONAS",task:$t,stage:"planning",reason:"plan",artifacts:[]}' > "$sig" ;;
    implementation|implementation_review)
      printf 'module.exports.add = (a, b) => a + b;\n' > add.js
      # Re-entered after an observer BLOCK: append the requested guard line so
      # the second candidate genuinely differs from the blocked one.
      if [ "$MODE" = "block-then-approve" ] && [ -f "$WORK/.obs-count" ]; then
        printf '// observer fix: guard non-numeric inputs upstream\n' >> add.js
      fi
      jq -cn --arg t "$spec" '{action:"RUN_PERSONAS",task:$t,stage:"implementation",reason:"impl",artifacts:[]}' > "$sig" ;;
    implementation_ready)
      git add add.js >/dev/null 2>&1; git commit -qm "feat: add() helper" >/dev/null 2>&1
      jq -cn --arg t "$spec" '{task:$t,
        baseline:[{command:"node --version",exit_status:0,output:"v"}],
        test_first:{command:"node --test add.test.js",failing_exit_status:1,failing_output:"red",passing_exit_status:0,passing_output:"green"},
        final_validation:[{command:"node --version",exit_status:0,output:"v"},{command:"node --test add.test.js",exit_status:0,output:"green"}]}' > "$c/evidence.json"
      jq -cn --arg t "$spec" '{action:"CREATE_CANDIDATE",task:$t,stage:"implementation_ready",reason:"cand",artifacts:[".night-shift/control/evidence.json"]}' > "$sig" ;;
    observer_review)
      jq -cn --arg t "$spec" '{action:"REQUEST_OBSERVER",task:$t,stage:"observer_review",reason:"obs",artifacts:[]}' > "$sig" ;;
    completion)
      jq -cn --arg t "$spec" '{action:"COMPLETE",task:$t,stage:"completion",reason:"done",artifacts:[]}' > "$sig" ;;
    *) jq -cn --arg t "$spec" --arg s "$stage" '{action:"BLOCKED",task:$t,stage:$s,reason:("stub stage "+$s),artifacts:[]}' > "$sig" ;;
  esac
  emit stubprimary "done"; exit 0
fi
p="$(cat)"
if printf '%s' "$p" | grep -q 'independent Claude observer'; then
  cand="$(printf '%s' "$p" | sed -nE 's/.*Candidate commit: ([0-9a-f]{7,64}).*/\1/p' | head -1)"
  if [ "$MODE" = "block-then-approve" ]; then
    n="$(cat "$WORK/.obs-count" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$WORK/.obs-count"
    if [ "$n" -eq 1 ]; then
      emit stubobs "$(jq -cn --arg c "${cand:-abcdef1}" '{observer:"claude",primary:"claude",task:"t",candidate_commit:$c,status:"BLOCK",
        findings:[{id:"OBS-001",evidence:"add() propagates NaN for non-numeric input",required_change:"guard or document non-numeric input handling in add.js"}],
        documentation_changes:[]}')"; exit 0
    fi
  fi
  emit stubobs "$(jq -cn --arg c "${cand:-abcdef1}" '{observer:"claude",primary:"claude",task:"t",candidate_commit:$c,status:"APPROVE",findings:[],documentation_changes:[]}')"; exit 0
fi
emit stubpersona "$(jq -cn '{persona:"x",stage:"implementation",commit:null,status:"APPROVE",findings:[],documentation_changes:[]}')"; exit 0
STUB
  } > "$BIN/claude"
  chmod +x "$BIN/claude"
}

# Timeout-wrapped engine invocation; output appends to $WORK/run.log.
# The engine runs under `bash -x` with a timestamped PS4 tracing to fd 9
# ($WORK/xtrace.log): an intermittent early hang has been observed (SIGALRM
# after 240s with ZERO engine output — see integration-run.sh's failure
# branch), and the trace is the only way the next occurrence can name the
# exact command that hung. On success the trace dies with $WORK; the failure
# branch preserves it.
run_engine() {
  # </dev/null: no stub call may ever block on the harness's inherited stdin
  # (belt to the stub's --version suspenders — the root cause of the flake).
  run_with_timeout "${NS_INTEGRATION_TIMEOUT:-240}" \
    env PATH="$BIN:$PATH" NIGHT_SHIFT_ACCEPT_COSTS=YES \
    BASH_XTRACEFD=9 PS4='+ $EPOCHREALTIME ${BASH_SOURCE##*/}:$LINENO ' \
    bash -x "$ENGINE" --project "$PROJECT" "$@" \
    </dev/null 9>>"$WORK/xtrace.log" >>"$WORK/run.log" 2>&1
}
