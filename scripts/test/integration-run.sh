#!/usr/bin/env bash
# integration-run.sh — full-orchestration smoke test.
#
# Drives the REAL engine (scripts/night-shift.sh) through the entire node-track
# stage machine — planning -> plan_review -> implementation -> implementation_review
# -> implementation_ready -> observer_review -> completion — using a SCRIPTED `claude`
# stub on PATH. Nothing is mocked inside the engine: real main_run loop, real stage
# transitions + session handoff, real engine-spawned persona gate, the real TDD
# candidate gate (verify_candidate: red->green proof + isolated-worktree validation),
# the real observer gate, and real git. Only the model is scripted, so this needs no
# paid calls and no `--permission-mode bypassPermissions` (the stub ignores it) — it
# runs anywhere, including CI as root, where a live run cannot.
#
# Exit 0 + "ok - integration: ..." on success; non-zero + a diagnostic otherwise.
set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
ENGINE="$ENGINE_DIR/scripts/night-shift.sh"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
fail() { printf 'not ok - integration: %s\n' "$*" >&2; exit 1; }

PROJECT="$WORK/project"; BIN="$WORK/bin"; SPEC="$WORK/spec.md"
mkdir -p "$PROJECT" "$BIN"

# --- a throwaway node project: a test that is RED until add.js exists ----------
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

# --- a valid node-track spec --------------------------------------------------
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

# --- scripted `claude`: primary (writes stage files + signal), personas, observer -
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
is_primary=0; for a in "$@"; do [ "$a" = "bypassPermissions" ] && is_primary=1; done
emit(){ jq -cn --arg s "$1" --arg r "$2" '{session_id:$s,result:$r,total_cost_usd:0,num_turns:1,is_error:false}'; }
if [ "$is_primary" = "1" ]; then
  st=.night-shift/state.json; c=.night-shift/control; mkdir -p "$c"; sig="$c/next-action.json"
  stage="$(jq -r '.stage' "$st")"; spec="$(jq -r '.task' "$st")"
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
  emit stubprimary "done"; exit 0
fi
p="$(cat)"
if printf '%s' "$p" | grep -q 'independent Claude observer'; then
  cand="$(printf '%s' "$p" | sed -nE 's/.*Candidate commit: ([0-9a-f]{7,64}).*/\1/p' | head -1)"
  emit stubobs "$(jq -cn --arg c "${cand:-abcdef1}" '{observer:"claude",primary:"claude",task:"t",candidate_commit:$c,status:"APPROVE",findings:[],documentation_changes:[]}')"; exit 0
fi
emit stubpersona "$(jq -cn '{persona:"x",stage:"implementation",commit:null,status:"APPROVE",findings:[],documentation_changes:[]}')"; exit 0
STUB
chmod +x "$BIN/claude"

# --- run the real engine end-to-end ------------------------------------------
log="$WORK/run.log"
if ! timeout "${NS_INTEGRATION_TIMEOUT:-240}" \
     env PATH="$BIN:$PATH" NIGHT_SHIFT_ACCEPT_COSTS=YES \
     "$ENGINE" --project "$PROJECT" --spec "$SPEC" >"$log" 2>&1; then
  sed -n '$p;' "$log" >&2 || true
  fail "engine exited non-zero (see run log tail above)"
fi

# --- assertions: the full pipeline actually happened + the candidate is correct -
status="$(find "$PROJECT/.night-shift/archive" -name summary.json -exec jq -r .status {} \; 2>/dev/null | head -1)"
[ "$status" = "complete" ]                                    || fail "run status is '$status', not complete"
[ "$(grep -c 'personas .*APPROVE' "$log")" -ge 2 ]           || fail "persona gate did not run for both stages"
grep -q 'candidate .* validated' "$log"                       || fail "TDD candidate gate did not run"
grep -q 'observer: APPROVE' "$log"                            || fail "observer gate did not run"
[ -f "$PROJECT/add.js" ]                                      || fail "candidate did not create add.js"
( cd "$PROJECT" && node --test add.test.js >/dev/null 2>&1 )  || fail "candidate test is not green"
grep -q 'null byte' "$log"                                    && fail "unexpected 'null byte' warning in the run"

printf 'ok - integration: full node-track run reaches completion (personas + TDD gate + observer, candidate green)\n'
