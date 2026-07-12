# shellcheck shell=bash
# scripts/lib/doc-freshness.sh
# Doc-freshness candidate mapper (checklist item 2). See
# docs/superpowers/specs/2026-07-11-agentic-gaps-tranche-design.md §B.
#
# Deterministically maps a candidate diff's touched files to the docs most
# likely to have gone stale (CLAUDE.md/AGENTS.md/README.md/docs/**/*.md
# tracked in the project) so an implement session can be handed a short,
# proximity-ranked list instead of having to guess or grep the whole tree
# itself. Non-gating: this file only produces the candidate list; enforcement
# (update-or-declare-unaffected) is the caller's/observer's job.
#
# Pure bash + jq + grep/sed — no node — and sourceable standalone: no top-
# level statements run at source time, and the one function below only
# touches its own locals plus $PROJECT/$BASE/$OUT-style arguments, never a
# run-scoped global (RUN_ROOT/STATE/...), so it is safe to `.` this file from
# anywhere, in or out of a night-shift run, under `set -u`.

# doc_freshness_candidates <project> <base_commit> <out_json>
#
# Diffs base_commit..HEAD inside <project> and writes a JSON object to
# <out_json>:
#   {"docs":[{"path":..., "reason":..., "score":...}, ...], "truncated":bool}
#
# Scoring (max evidence wins when a doc matches more than one way):
#   3 - the doc sits in the SAME directory as a touched file.
#   2 - the doc sits in an ANCESTOR directory of a touched file's directory
#       (the chain from the touched file's dir up to, but excluding, the
#       project root — a root-level README/CLAUDE/AGENTS would otherwise
#       "ancestor-match" every diff in the repo, which is not useful signal;
#       it can still score 3 via same-dir when a touched file is itself at
#       the project root, or 1 via mention/symbol below).
#   1 - the doc's tracked content mentions a touched file's basename, or an
#       exported symbol name added by the diff, as a whole word (grep -w).
#
# Sort: score desc; within a tie, deeper paths (more path segments) first,
# and the repo-root README.md last of all (it already sorts last by depth
# among same-score root-level docs, but this is an explicit tiebreak so a
# root README never outranks another root-level doc, e.g. a root CLAUDE.md,
# at the same score). Capped at 10 with truncated:true when the cap bites.
#
# Contract: empty diff or no matching candidate docs -> {"docs":[],
# "truncated":false}, return 0. This function is NEVER supposed to fail just
# because it found nothing — it returns non-zero ONLY for unusable arguments
# or an underlying git failure (bad project path, unresolvable base_commit,
# not a git repo, unwritable out_json).
doc_freshness_candidates() {
  [ "$#" -eq 3 ] || return 1
  local project="$1" base="$2" out="$3"
  [ -n "$project" ] && [ -n "$base" ] && [ -n "$out" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$project" rev-parse --verify -q "$base" >/dev/null 2>&1 || return 1
  git -C "$project" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1

  local touched
  touched="$(git -C "$project" diff --name-only "$base" HEAD -- . 2>/dev/null)" || return 1
  if [ -z "$touched" ]; then
    printf '{"docs":[],"truncated":false}\n' >"$out" || return 1
    return 0
  fi

  local docs
  # Candidate docs: every tracked CLAUDE.md/AGENTS.md/README.md at any depth,
  # plus every tracked docs/**/*.md.
  docs="$(git -C "$project" ls-tree -r --name-only HEAD 2>/dev/null |
    grep -E '(^|/)(CLAUDE|AGENTS|README)\.md$|^docs/.*\.md$')"
  if [ -z "$docs" ]; then
    printf '{"docs":[],"truncated":false}\n' >"$out" || return 1
    return 0
  fi

  local patch
  patch="$(git -C "$project" diff "$base" HEAD -- . 2>/dev/null)"

  # Touched-directory sets, as newline-separated membership lists (no
  # associative arrays — this file targets plain POSIX-ish bash, matching the
  # rest of scripts/lib). same_dirs: the exact directory of each touched
  # file (may include "." for a top-level touched file). ancestor_dirs: every
  # directory strictly between a touched file's dir and the project root,
  # excluding the root itself (see the score-2 comment above).
  local same_dirs="" ancestor_dirs="" f d cur parent
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d="$(dirname -- "$f")"
    same_dirs="$same_dirs
$d"
    cur="$d"
    while :; do
      parent="$(dirname -- "$cur")"
      [ "$parent" != "." ] || break
      ancestor_dirs="$ancestor_dirs
$parent"
      cur="$parent"
    done
  done <<<"$touched"

  local basenames=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    basenames="$basenames
$(basename -- "$f")"
  done <<<"$touched"

  # Symbol extraction: best-effort, NOT a parser. Scans only ADDED lines
  # (single leading '+', excluding the "+++ b/file" diff-header line via the
  # '[^+]' after it) for `export function|const|class NAME` or a bare
  # top-level `function NAME`, via one sed capture. Known limits (documented,
  # not fixed, per the task brief): misses symbols whose declaration spans
  # multiple lines, `export default`, re-exports (`export { foo }`), and
  # arrow-function consts split across a line break; can over-match a
  # keyword sequence that happens to appear inside a string or comment. Good
  # enough to widen the candidate-doc net, never a source of truth.
  # (`\b` word-boundary is a GNU sed extension, not portable to BSD sed
  # (macOS) — it silently fails to match there. Portable substitute: an
  # optional greedy prefix group that, if used at all, must end on a
  # non-identifier character right before the keyword — this rejects a
  # keyword found only as a substring of a longer identifier (e.g. does NOT
  # extract "fooBar" out of "myfunction fooBar()") while still matching the
  # keyword immediately after the diff's leading '+' with no separator.)
  local symbols
  symbols="$(printf '%s\n' "$patch" | grep -E '^\+[^+]' |
    sed -nE 's/^\+(.*[^A-Za-z0-9_$])?(export[[:space:]]+(function|const|class)|function)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*).*/\4/p' |
    sort -u)"

  local entries
  entries="$(mktemp "${TMPDIR:-/tmp}/doc-freshness.XXXXXX")" || return 1

  local docpath doc_dir score reason content bn sym esc depth is_root
  while IFS= read -r docpath; do
    [ -n "$docpath" ] || continue
    doc_dir="$(dirname -- "$docpath")"
    score=0
    reason=""
    if printf '%s\n' "$same_dirs" | grep -qFx -- "$doc_dir"; then
      score=3
      reason="dir:$doc_dir"
    elif printf '%s\n' "$ancestor_dirs" | grep -qFx -- "$doc_dir"; then
      score=2
      reason="dir:$doc_dir"
    fi

    if [ "$score" -eq 0 ]; then
      content="$(git -C "$project" show "HEAD:$docpath" 2>/dev/null)"
      while IFS= read -r bn; do
        [ -n "$bn" ] || continue
        esc="$(printf '%s' "$bn" | sed -e 's/[\]/\\\\/g' -e 's/[.[*^$]/\\&/g')"
        if printf '%s\n' "$content" | grep -qw -- "$esc"; then
          score=1
          reason="mentions:$bn"
          break
        fi
      done <<<"$basenames"
    fi

    if [ "$score" -eq 0 ] && [ -n "$symbols" ]; then
      content="${content:-$(git -C "$project" show "HEAD:$docpath" 2>/dev/null)}"
      while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        esc="$(printf '%s' "$sym" | sed -e 's/[\]/\\\\/g' -e 's/[.[*^$]/\\&/g')"
        if printf '%s\n' "$content" | grep -qw -- "$esc"; then
          score=1
          reason="symbol:$sym"
          break
        fi
      done <<<"$symbols"
    fi

    [ "$score" -gt 0 ] || continue
    depth="$(printf '%s' "$docpath" | grep -o '/' | wc -l | tr -d ' ')"
    is_root=0
    [ "$docpath" != "README.md" ] || is_root=1
    jq -cn --arg path "$docpath" --arg reason "$reason" --argjson score "$score" \
      --argjson depth "$depth" --argjson is_root "$is_root" \
      '{path:$path, reason:$reason, score:$score, depth:$depth, is_root:$is_root}' \
      >>"$entries"
  done <<<"$docs"

  if [ ! -s "$entries" ]; then
    rm -f "$entries"
    printf '{"docs":[],"truncated":false}\n' >"$out" || return 1
    return 0
  fi

  local total truncated
  total="$(jq -s 'length' "$entries")"
  truncated=false
  [ "$total" -le 10 ] || truncated=true
  jq -s --argjson truncated "$truncated" '
    sort_by([-.score, -.depth, .is_root])
    | map({path, reason, score})
    | .[0:10]
    | {docs: ., truncated: $truncated}
  ' "$entries" >"$out"
  local rc=$?
  rm -f "$entries"
  return "$rc"
}
