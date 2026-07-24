#!/usr/bin/env bash
# mutate.sh — zero-dep mutation harness for the engine's own test suite.
# Enumerates deterministic single-edit mutants of scripts/lib/*.sh and the
# two static-scan .js libs; --run (Task 2) executes the fixture suite per
# mutant and enforces the shrink-only survivors ratchet
# (scripts/test/surviving-mutants.txt). Fixed-string rules only: matching is
# awk index(), so ids are stable and no regex escaping exists to get wrong.
set -u
ENGINE_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SEP=$'\x1f'
RULE_TABLE=$(cat <<EOF
eq_ne${SEP} -eq ${SEP} -ne ${SEP}sh
ne_eq${SEP} -ne ${SEP} -eq ${SEP}sh
lt_ge${SEP} -lt ${SEP} -ge ${SEP}sh
gt_le${SEP} -gt ${SEP} -le ${SEP}sh
z_n${SEP} -z ${SEP} -n ${SEP}sh
n_z${SEP} -n ${SEP} -z ${SEP}sh
def01${SEP}:-0}${SEP}:-1}${SEP}sh
def10${SEP}:-1}${SEP}:-0}${SEP}sh
ret_true${SEP}|| return 1${SEP}|| true${SEP}sh
exit_true${SEP}|| exit 1${SEP}|| true${SEP}sh
seq_sneq${SEP}===${SEP}!==${SEP}js
sneq_seq${SEP}!==${SEP}===${SEP}js
jlt_jge${SEP} < ${SEP} >= ${SEP}js
jgt_jle${SEP} > ${SEP} <= ${SEP}js
EOF
)

# Measured 2026-07-24: the default suite-cmd (NIGHT_SHIFT_ACCEPT_COSTS=YES
# bash scripts/night-shift.sh --fixture-test --dry-run) takes 82s wall
# (1:22.38 total). Default --timeout budget is 900s; 900/82 ~= 10, so a
# whole-codebase run (no --file) caps its default sample at 10 mutants.
DEFAULT_SAMPLE=10

mutation_targets() {
  ( cd "$ENGINE_DIR" &&
    ls scripts/lib/*.sh &&
    printf '%s\n' scripts/lib/test-audit-static.js scripts/lib/port-audit-static.js )
}

# count_occurrences <file> <needle> — total fixed-string occurrences.
count_occurrences() {
  awk -v needle="$2" '
    { line=$0; c=0
      while ((i=index(line, needle)) > 0) { c++; line=substr(line, i+length(needle)) }
      total+=c }
    END { print total+0 }' "$ENGINE_DIR/$1"
}

# line_of_occurrence <file> <needle> <ordinal> — line number holding it.
line_of_occurrence() {
  awk -v needle="$2" -v want="$3" '
    { line=$0
      while ((i=index(line, needle)) > 0) { seen++
        if (seen==want) { print NR; exit }
        line=substr(line, i+length(needle)) } }' "$ENGINE_DIR/$1"
}

list_mutants() {
  # --file <relpath> targets that exact file directly (it need not be a
  # member of mutation_targets — e.g. the frozen self-test fixture under
  # scripts/test/fixtures/, which is otherwise excluded); with no --file,
  # every file in mutation_targets is enumerated.
  local only="${1:-}" f name needle repl rlang lang n k ln
  while IFS= read -r f; do
    case "$f" in *.js) lang="js" ;; *) lang="sh" ;; esac
    while IFS="$SEP" read -r name needle repl rlang; do
      [ "$rlang" = "$lang" ] || continue
      n="$(count_occurrences "$f" "$needle")"
      k=1
      while [ "$k" -le "$n" ]; do
        ln="$(line_of_occurrence "$f" "$needle" "$k")"
        printf '%s#%s#%s\t%s\t%s\t%s\t%s -> %s\n' \
          "$f" "$name" "$k" "$f" "$ln" "$name" "$needle" "$repl"
        k=$((k + 1))
      done
    done <<<"$RULE_TABLE"
  done < <(if [ -n "$only" ]; then printf '%s\n' "$only"; else mutation_targets; fi)
}

# apply_mutant <scratchdir> <id> — id = file#rule#ordinal. awk performs a
# fixed-string replace of the id's ordinal occurrence of the rule's needle.
apply_mutant() {
  local scratch="$1" id="$2" f rule k needle repl
  f="${id%%#*}"; rule="${id#*#}"; rule="${rule%%#*}"; k="${id##*#}"
  needle="$(awk -F"$SEP" -v r="$rule" '$1==r{print $2; exit}' <<<"$RULE_TABLE")"
  repl="$(awk -F"$SEP" -v r="$rule" '$1==r{print $3; exit}' <<<"$RULE_TABLE")"
  awk -v needle="$needle" -v repl="$repl" -v want="$k" '
    { out=""; line=$0
      while ((i=index(line, needle)) > 0) { seen++
        if (seen==want) {
          out = out substr(line,1,i-1) repl; line=substr(line,i+length(needle))
        } else {
          out = out substr(line,1,i-1) needle; line=substr(line,i+length(needle))
        } }
      print out line }' "$scratch/$f" >"$scratch/$f.mut" &&
  mv "$scratch/$f.mut" "$scratch/$f"
}

# macOS has no GNU `timeout`; verbatim from scripts/test/integration-lib.sh:22-26.
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"
  fi
}

# ratchet_ids <allowlist-file> — one clean id per line: blank lines and
# `#`-prefixed comment lines are skipped, and an optional trailing
# " # reason" is stripped (ids themselves contain bare, unspaced `#`
# separators, so only a SPACE-then-hash introduces a reason comment).
# Missing file prints nothing (not an error).
ratchet_ids() {
  local file="$1" line
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "${line%% #*}"
  done <"$file"
}

# sample_mutants <n> <seed> — reads full mutant rows (tab-separated, id in
# the first field) on stdin; n<=0 means "no limit" (pass every row through).
# Otherwise: portable-deterministic ranking (NOT awk srand, which differs
# across awk implementations) — rank = cksum("<seed> <id>"), numeric sort,
# keep the first n rows.
sample_mutants() {
  local n="$1" seed="$2" full id rest rank
  full="$(cat)"
  [ -n "$full" ] || return 0
  if [ "$n" -le 0 ]; then
    printf '%s\n' "$full"
    return 0
  fi
  while IFS=$'\t' read -r id rest; do
    [ -n "$id" ] || continue
    rank="$(printf '%s %s' "$seed" "$id" | cksum | awk '{print $1}')"
    printf '%s\t%s\t%s\n' "$rank" "$id" "$rest"
  done <<<"$full" | sort -n | head -n "$n" | cut -f2-
}

# run_mutants <only-file> — Task 2 mechanics: one pristine scratch checkout,
# per-mutant apply/run/restore, and the shrink-only survivors ratchet against
# $ALLOWLIST (default scripts/test/surviving-mutants.txt, override via
# MUTATE_ALLOWLIST). A --file run always executes that file's full mutant
# set (it is already a manual, narrow scope); DEFAULT_SAMPLE only caps an
# unscoped whole-codebase run, unless --sample/--full say otherwise.
run_mutants() {
  local only="$1" full sample_n run_list row id f rc fail=0 allow_list
  local total_run=0 killed=0 survived=0 ratcheted=0
  # NOT local: the EXIT trap below fires at script exit, after this function
  # has already returned — a `local` scratch/pristine would be unbound by
  # then under `set -u`. run_mutants runs at most once per invocation, so
  # script-global scope is safe.
  scratch="" pristine=""

  full="$(list_mutants "$only")"
  if [ -z "$full" ]; then
    printf '# mutants: 0 run, 0 killed, 0 survived (0 ratcheted), score 0/0\n'
    return 0
  fi

  if [ "$FULL" = "1" ]; then
    sample_n=0
  elif [ -n "$SAMPLE" ]; then
    sample_n="$SAMPLE"
  elif [ -n "$only" ]; then
    sample_n=0
  else
    sample_n="$DEFAULT_SAMPLE"
  fi
  run_list="$(printf '%s\n' "$full" | sample_mutants "$sample_n" "$SEED")"

  scratch="$(mktemp -d)"; pristine="$(mktemp -d)"
  trap 'rm -rf "$scratch" "$pristine"' EXIT
  git -C "$ENGINE_DIR" ls-files -z | tar --null -T - -cf - -C "$ENGINE_DIR" | tar -xf - -C "$scratch"
  # $scratch now holds tracked files only (never a raw cp -R of $ENGINE_DIR,
  # whose root holds untracked company screenshots under design/); a plain
  # recursive copy FROM $scratch is safe as the second, per-mutant-restore
  # baseline.
  cp -R "$scratch/." "$pristine/"

  allow_list="$(ratchet_ids "$ALLOWLIST")"

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="${row%%$'\t'*}"
    f="${id%%#*}"
    if ! apply_mutant "$scratch" "$id"; then
      printf 'not ok - apply failed: %s\n' "$id" >&2
      fail=1
      continue
    fi
    rc=0
    ( cd "$scratch" && run_with_timeout "$TIMEOUT_SECS" bash -c "$SUITE_CMD" ) >/dev/null 2>&1 || rc=$?
    # Restore immediately, not "before applying the next mutant": mutants
    # are processed one at a time but do not all target the same file, so
    # a restore-before-next-apply would leave THIS mutant's edit sitting in
    # $scratch indefinitely once a later mutant targets a different file —
    # restoring right after the run keeps $scratch pristine at every
    # loop boundary regardless of file-touch order.
    cp "$pristine/$f" "$scratch/$f"
    total_run=$((total_run + 1))
    if [ "$rc" -ne 0 ]; then
      killed=$((killed + 1))
      printf 'ok - killed %s\n' "$id"
      if grep -qxF "$id" <<<"$allow_list"; then
        printf 'not ok - stale ratchet entry (now killed): %s\n' "$id" >&2
        fail=1
      fi
    else
      survived=$((survived + 1))
      if grep -qxF "$id" <<<"$allow_list"; then
        ratcheted=$((ratcheted + 1))
        printf 'ok - survived (ratcheted) %s\n' "$id"
      else
        printf 'not ok - SURVIVED %s\n' "$id" >&2
        fail=1
      fi
    fi
  done <<<"$run_list"

  printf '# mutants: %s run, %s killed, %s survived (%s ratcheted), score %s/%s\n' \
    "$total_run" "$killed" "$survived" "$ratcheted" "$killed" "$total_run"
  [ "$fail" -eq 0 ]
}

MODE="" ONLY_FILE="" FULL=0 SAMPLE="" SEED="0" SUITE_CMD="" TIMEOUT_SECS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --run) MODE=run; shift ;;
    --full) MODE=run; FULL=1; shift ;;
    --file) [ "$#" -ge 2 ] || { echo "--file requires a value" >&2; exit 2; }
            ONLY_FILE="$2"; shift 2 ;;
    --sample) [ "$#" -ge 2 ] || { echo "--sample requires a value" >&2; exit 2; }
              SAMPLE="$2"; shift 2 ;;
    --seed) [ "$#" -ge 2 ] || { echo "--seed requires a value" >&2; exit 2; }
            SEED="$2"; shift 2 ;;
    --suite-cmd) [ "$#" -ge 2 ] || { echo "--suite-cmd requires a value" >&2; exit 2; }
                 SUITE_CMD="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { echo "--timeout requires a value" >&2; exit 2; }
               TIMEOUT_SECS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$ONLY_FILE" ] && [ ! -f "$ENGINE_DIR/$ONLY_FILE" ]; then
  echo "--file: no such file: $ONLY_FILE" >&2
  exit 2
fi
SUITE_CMD="${SUITE_CMD:-NIGHT_SHIFT_ACCEPT_COSTS=YES bash scripts/night-shift.sh --fixture-test --dry-run}"
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"
# MUTATE_ALLOWLIST overrides the default ratchet file path (used by the
# fixture_mutate_ratchet self-test to point at a throwaway allowlist).
ALLOWLIST="${MUTATE_ALLOWLIST:-$ENGINE_DIR/scripts/test/surviving-mutants.txt}"
case "$MODE" in
  list) list_mutants "$ONLY_FILE" ;;
  run) run_mutants "$ONLY_FILE" ;;
  *) echo "usage: mutate.sh --list [--file <relpath>] | mutate.sh --run [--full] [--sample N] [--seed S] [--file <relpath>] [--suite-cmd <cmd>] [--timeout <secs>]" >&2
     echo "  env: MUTATE_ALLOWLIST=<path>  override the survivors-ratchet file (default: scripts/test/surviving-mutants.txt)" >&2
     exit 2 ;;
esac
