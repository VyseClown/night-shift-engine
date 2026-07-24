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
    { line=$0; off=0
      while ((i=index(line, needle)) > 0) { seen++
        if (seen==want) { print NR; exit }
        line=substr(line, i+length(needle)) } }' "$ENGINE_DIR/$1"
}

list_mutants() {
  # --file <relpath> targets that exact file directly (it need not be a
  # member of mutation_targets — e.g. the frozen self-test fixture under
  # scripts/test/fixtures/, which is otherwise excluded); with no --file,
  # every file in mutation_targets is enumerated.
  local only="${1:-}" f name needle repl lang n k ln
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

MODE="" ONLY_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --file) [ "$#" -ge 2 ] || { echo "--file requires a value" >&2; exit 2; }
            ONLY_FILE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$ONLY_FILE" ] && [ ! -f "$ENGINE_DIR/$ONLY_FILE" ]; then
  echo "--file: no such file: $ONLY_FILE" >&2
  exit 2
fi
case "$MODE" in
  list) list_mutants "$ONLY_FILE" ;;
  *) echo "usage: mutate.sh --list [--file <relpath>]" >&2; exit 2 ;;
esac
