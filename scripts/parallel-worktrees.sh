#!/usr/bin/env bash
# scripts/parallel-worktrees.sh
# Fan out independent night-shift runs across one git worktree per spec.
# Each spec runs on its own feature branch in its own worktree, so each run
# gets an independent .night-shift/ (state + run-lock) with zero contention.
#
# The worktrees are first-class: each is a clean, isolated checkout you can also
# attach a separate Claude Code instance to. For that reason worktrees are KEPT
# by default; pass --prune to remove clean ones after a run.
#
# Usage:
#   scripts/parallel-worktrees.sh --project ~/work/web-app \
#       specs/feature-a.md specs/feature-b.md specs/feature-c.md
#
# Flags:
#   --project PATH     target repo (required)
#   --jobs N           max concurrent runs (default 2 — paid + rate limits)
#   --worktree-root D  where worktrees live (default <project>/../.ns-worktrees)
#   --prune            remove clean worktrees on success (default: keep all)
#   --dry-run          create worktrees + engine --preflight only; no paid run
#
# Compatible with bash 3.2 (stock macOS /bin/bash): no associative arrays,
# no `wait -n`, all empty-array expansions guarded under `set -u`.

set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/night-shift.sh"
JOBS=2
PRUNE=0
DRY_RUN=0
PROJECT=""
WT_ROOT=""
SPECS=()

log() { printf '[parallel] %s\n' "$*" >&2; }
die() { printf '[parallel] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- args -----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --project)       [ $# -ge 2 ] || die "--project requires a value";       PROJECT="$2"; shift 2 ;;
    --jobs)          [ $# -ge 2 ] || die "--jobs requires a value";          JOBS="$2";    shift 2 ;;
    --worktree-root) [ $# -ge 2 ] || die "--worktree-root requires a value"; WT_ROOT="$2"; shift 2 ;;
    --prune)         PRUNE=1;      shift ;;
    --dry-run)       DRY_RUN=1;    shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)              die "unknown flag: $1" ;;
    *)               SPECS+=("$1"); shift ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required"
git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $PROJECT"
[ "${#SPECS[@]}" -gt 0 ] || die "give at least one spec path"
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
PROJECT="$(cd "$PROJECT" && pwd)"
WT_ROOT="${WT_ROOT:-$(cd "$PROJECT/.." && pwd)/.ns-worktrees}"
mkdir -p "$WT_ROOT"
[ -x "$ENGINE" ] || die "engine not found/executable: $ENGINE"

# Each worktree inherits the committed .gitignore, but warn early if the engine
# would refuse the run (it skips repos that don't ignore .night-shift/).
git -C "$PROJECT" check-ignore -q .night-shift/ 2>/dev/null \
  || die ".night-shift/ is not gitignored in $PROJECT — engine will refuse the run"

# ---- per-spec field extraction (same parser the engine uses) --------------
spec_field() { sed -nE "s/^- $1: \`([^\`]+)\`.*/\1/p" "$2" | head -n 1; }
wt_path()    { printf '%s/%s' "$WT_ROOT" "$(basename "${1//\//-}")"; }  # $1 = feature branch

# ---- worktree + run for one spec ------------------------------------------
run_one() {
  local spec="$1"
  local base feature wt logf
  base="$(spec_field 'Base branch' "$spec")"
  feature="$(spec_field 'Feature branch' "$spec")"
  [ -n "$feature" ] || { log "SKIP $spec: no '- Feature branch:' field"; return 2; }
  base="${base:-main}"

  wt="$(wt_path "$feature")"
  logf="$wt.log"

  # Create (or reuse) the worktree on the spec's feature branch.
  if [ -d "$wt" ]; then
    # A git worktree always has a `.git` gitfile at its root; a stale plain
    # directory (e.g. from a partially-removed worktree) does not. Checking
    # `rev-parse --is-inside-work-tree` would wrongly pass when WT_ROOT itself
    # sits inside an enclosing repo (the default <project>/../.ns-worktrees does).
    [ -e "$wt/.git" ] \
      || { log "FAIL $wt exists but is not a git worktree; remove it or use --worktree-root"; return 3; }
    log "reuse worktree $wt"
  elif git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$feature"; then
    git -C "$PROJECT" worktree add "$wt" "$feature"            >>"$logf" 2>&1 \
      || { log "FAIL worktree add $feature (branch in use elsewhere?)"; return 3; }
  else
    git -C "$PROJECT" worktree add "$wt" -b "$feature" "$base" >>"$logf" 2>&1 \
      || { log "FAIL worktree add -b $feature from $base"; return 3; }
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[$feature] preflight"
    "$ENGINE" --preflight --project "$wt" --spec "$spec" >>"$logf" 2>&1
    return $?
  fi

  log "[$feature] launching run -> $logf"
  NIGHT_SHIFT_ACCEPT_COSTS=YES "$ENGINE" --project "$wt" --spec "$spec" >>"$logf" 2>&1
}

# Heal stale registrations: if a worktree dir was removed out-of-band (rm -rf,
# external cleanup) git still lists it and `worktree add` would fail with
# "missing but already registered". prune only drops entries whose dir is gone,
# so a worktree a live instance is using is never touched.
git -C "$PROJECT" worktree prune 2>/dev/null || true

# ---- bounded fan-out (bash 3.2: parallel indexed arrays, poll to reap) -----
PIDS=()
PID_SPECS=()
FAILED=()

reap_finished() {
  local new_pids=() new_specs=()
  local i pid rc
  for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      new_pids+=("$pid")
      new_specs+=("${PID_SPECS[$i]}")
    else
      if wait "$pid"; then rc=0; else rc=$?; fi
      [ "$rc" -eq 0 ] || FAILED+=("${PID_SPECS[$i]} (exit $rc)")
    fi
  done
  # Guarded reassignment: expanding an empty array under set -u errors on 3.2.
  PIDS=(${new_pids[@]+"${new_pids[@]}"})
  PID_SPECS=(${new_specs[@]+"${new_specs[@]}"})
}

for spec in ${SPECS[@]+"${SPECS[@]}"}; do
  [ -f "$spec" ] || { log "SKIP missing spec: $spec"; FAILED+=("$spec (missing)"); continue; }
  while [ "${#PIDS[@]}" -ge "$JOBS" ]; do
    reap_finished
    [ "${#PIDS[@]}" -ge "$JOBS" ] && sleep 1
  done
  run_one "$spec" &
  PIDS+=("$!")
  PID_SPECS+=("$spec")
  log "started $spec (pid $!); ${#PIDS[@]}/$JOBS slots in use"
done
while [ "${#PIDS[@]}" -gt 0 ]; do
  reap_finished
  [ "${#PIDS[@]}" -gt 0 ] && sleep 1
done

# ---- summary + optional prune ---------------------------------------------
if [ "${#FAILED[@]}" -gt 0 ]; then
  log "FAILURES:"
  for f in ${FAILED[@]+"${FAILED[@]}"}; do log "  - $f"; done
fi

if [ "$PRUNE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  for spec in ${SPECS[@]+"${SPECS[@]}"}; do
    [ -f "$spec" ] || continue
    feature="$(spec_field 'Feature branch' "$spec")"
    [ -n "$feature" ] || continue
    wt="$(wt_path "$feature")"
    [ -d "$wt" ] || continue
    if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      git -C "$PROJECT" worktree remove "$wt" 2>/dev/null \
        && log "pruned clean worktree $wt (branch $feature kept)"
    else
      log "kept dirty worktree $wt — inspect before removing"
    fi
  done
else
  log "worktrees kept under $WT_ROOT (attach another Claude Code instance here; --prune to clean)"
fi

[ "${#FAILED[@]}" -eq 0 ]
