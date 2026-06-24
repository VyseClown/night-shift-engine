#!/usr/bin/env bash
# shellcheck shell=bash
# Decision logic for the auto-resume supervisor (scripts/night-shift-supervised.sh).
# Kept in a lib so the policy is pure and fixture-tested in isolation.

# supervisor_next REASON PROGRESS LAST_REASON LAST_PROGRESS RESUMES MAX
#
# Decide what to do after the engine exited on a preserved block. Pure: prints
# exactly one of:
#   resume                 — auto-resume (transient, or progress was made)
#   escalate:stuck         — same block reason AND no progress since the last block
#                            → genuinely stuck, a human/code fix is needed
#   escalate:resume-cap-N  — the safety cap on total auto-resumes was reached
#
# "Progress" is any change in PROGRESS vs LAST_PROGRESS (e.g. a new candidate
# commit or advancing to the next task). A block that repeats with the SAME
# reason AND the SAME progress token is the signature of a real, non-transient
# block — exactly the "same block twice" case that should stop and ask a human,
# rather than burning resumes forever (which is what bare `--resume` did).
supervisor_next() {
  local reason="$1" progress="$2" last_reason="$3" last_progress="$4" resumes="$5" max="$6"
  if [ "$resumes" -ge "$max" ]; then
    printf 'escalate:resume-cap-%s' "$max"
    return 0
  fi
  if [ -n "$last_reason" ] && [ "$reason" = "$last_reason" ] && [ "$progress" = "$last_progress" ]; then
    printf 'escalate:stuck'
    return 0
  fi
  printf 'resume'
}
