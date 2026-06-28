# Changelog

Completed work is recorded here only after validation, an approval from each
active review persona (the spec's Track + Review Profile select the set), and
observer approval.

## Unreleased

### Cost & model tiering

- **Per-role model tiering.** The primary plans on `NIGHT_SHIFT_PLAN_MODEL`
  (default `opus`, the high-leverage step) and does the implement grind,
  observe-request, and completion on `NIGHT_SHIFT_IMPLEMENT_MODEL` (default
  `sonnet`); personas run on `NIGHT_SHIFT_PERSONA_MODEL` (default `sonnet`) and
  the independent observer on `NIGHT_SHIFT_OBSERVER_MODEL` (default `opus`). The
  model switches only at stage-scope boundaries (which already start a fresh
  session), so it is constant within a scope and resumes never re-pass `--model`;
  any knob set to `inherit` uses the CLI's startup model.
- **Stage-scoped primary sessions** (`NIGHT_SHIFT_SESSION_SCOPE=stage`, default):
  a fresh `claude` session per stage scope (plan → implement → observe), handing
  off through files on disk, instead of one pinned session replaying its whole
  history each turn. Set `=run` for the legacy single pinned session.
- **Per-turn cost telemetry at the source** — each finished turn's cost/usage is
  appended to an incremental `cost-ledger.jsonl` the instant it completes (the
  observer recorded per retry attempt), so a costly turn is never lost to a raw
  file rewritten or cleaned later.
- **Stage-gated primary signal**: the wrapper advances stages one step at a time
  and the prompt states the single valid action for the stage; an out-of-stage
  signal is rejected instead of skipping a gate.

### Review & personas

- Per-spec **review profiles**: specs declare a `Review Profile`
  (`full`/`frontend`/`logic`/`native`) that selects which personas review, cutting
  cost on focused tasks. A track-specific mandatory floor plus the observer always
  run; the resolver asserts the floor independently so the table can't drop a
  safety reviewer. Spec validation requires a valid profile and demands
  documentation ownership only for active personas; the persona gate enforces the
  active set and count instead of a hardcoded six.
- **Multi-track review**: a spec declares `- Track: rn | web | node` (default
  `rn`), selecting the persona set, template, and validation checklist. Added a
  generic `node` track for plain Node/CLI/backend repos (backend floor,
  `full`/`logic` only, no UX persona).
- **Optional cross-track reviewers** (Product, Design Fidelity, Security, API
  Contract), off by default — opt in via an `- Optional reviewers:` line or by
  including the matching `## … Contract` section; each must own a Documentation
  line. A per-spec `- Personas:` override names the exact specialists to run
  (floor always kept). New `--list-optional-personas` subcommand emits the
  manifest the viewer renders.
- **Re-review rounds run only the blockers** — approvals don't expire; a BLOCK
  round re-runs only the personas with open findings (each verifies its own) and
  earlier approvals carry forward. `review_round` resets at stage-scope boundaries
  so the implementation gate reads the round the primary actually wrote.
- Personas review from one primary-prepared bundle (spec + plan + diff + test
  output) rather than each re-exploring the repo; a near-miss persona result is
  normalized on collection (`verdict`→`status`, fill empty fields) so a genuine
  APPROVE/BLOCK isn't rejected on a format nit.

### Claude-only flow & observer

- **Claude-only flow:** Claude is the primary, the persona sub-agents, and the
  observer (a fresh, independent session — no shared context). Removed the Codex
  primary/observer/persona paths, the `--output-schema`/session helpers, and the
  cross-model observer-review constraint. Observer output is parsed from the
  result text (tolerating a code fence) and validated with one retry.
- **Observer is context-isolated:** a fresh session (no `--resume`) from a neutral
  empty temp directory in the default (non-bypass) permission mode — tool use is
  not auto-approved and it cannot inspect the repo, reviewing only the supplied
  evidence. (`--allowedTools` is not passed; it is variadic and would swallow the
  prompt.) Output normalization coerces a sloppy verdict into the strict shape,
  biased fail-closed so a malformed BLOCK halts the run rather than being dropped.

### Visual fidelity (opt-in, off by default)

- **Token-free Figma via MCP.** Reference export and the per-run `get_figma_data`
  fetch go through the Figma MCP (`get_figma_data`/`download_figma_images`); the
  `FIGMA_TOKEN`/REST path was removed. `visual_stage_ref`/`visual_stage_refs_for_spec`
  MCP-stage the Design-Contract matrix as PNGs before capture. The engine's
  headless `claude -p` MCP calls run with `--permission-mode bypassPermissions`
  (MCP tools are otherwise deferred headless), and the raw `get_figma_data` node
  tree is cached once per run for the repair agent.
- **`visual_review` stage wired into the live loop** (engine-invoked): with
  `NIGHT_SHIFT_VISUAL_CAPTURE=1` and a `## Design Contract`, the candidate routes
  through capture (Figma reference → iOS-simulator screenshot → `odiff` pixel-diff
  → `visual-diff-*.json`) to the observer; cleanly SKIPs when tooling/frames are
  absent. `RUN_VISUAL` added to the `next-action` enum; the `visual-diff` schema
  gained `device`, `analysis`, per-screen `attempts`, and `unmet_brief`.
- **In-loop + standalone agent auto-repair.** Opt-in in-loop repair
  (`NIGHT_SHIFT_VISUAL_REPAIR=1`) fixes over-tolerance screens and lands a
  `fix(visual)` commit before the observer; `scripts/visual-review.sh --repair`
  is the standalone one-command pass. The bounded, worst-first, scope-gated loop
  is **keep-best / converge-to-diminishing-returns** (never worse than baseline),
  snapshots/restores in-scope trees, and records per-attempt + baseline images
  with a "what changed" analysis. The repair agent runs on
  `NIGHT_SHIFT_VISUAL_REPAIR_MODEL` (default `opus`) and reads the cached Figma
  data + the spec's design sections. A Metro fast-reload harness drives
  re-capture (reuse-or-start one Metro per run; freshness guards defeat the
  watcher race).
- **Flow B — create-from-Figma.** A `## Design Contract` spec implements on
  `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` (default `opus`) with a build-from-Figma
  procedure in the implement prompt (decompose → verify-existing → build-missing
  → assemble → validate).
- **Maestro drive mode** (`--drive maestro`, `NIGHT_SHIFT_MAESTRO_DIR`): push each
  screen/state into the app via a Maestro flow when deep links/launch-args don't
  fit; the Maestro test is timeout-guarded so a hung flow SKIPs.
- Capture robustness: re-capture retry instead of recording a 1.0 diff; iOS-26
  status-bar `--time` must be `HH:MM` (ISO datetime is silently rejected);
  parse `odiff --parsable-stdout` as a percentage, not a pixel count.
- **Opt-in device registry** (`NIGHT_SHIFT_DEVICE_REGISTRY=1`) so parallel
  `visual_review` across worktrees each claim a dedicated simulator from a
  machine-global registry, cloning when a pool is exhausted and pruning stale
  clones on the next registry-mode run.

### Robustness, recovery & safety

- Block runs when a validation/test-first command exits 127, so missing tooling
  can't pass the regression gate silently.
- Three-round stall detection on persona review loops (was observer-only);
  fingerprints fold in a material token (full diff vs base) plus test-first
  evidence, so changed code/tests/evidence reset the counter and legitimate
  resolution attempts aren't falsely blocked.
- Cap on consecutive malformed/absent primary signals
  (`NIGHT_SHIFT_MAX_MALFORMED_SIGNALS`, default 5) — fails fast instead of
  grinding the whole turn budget on junk.
- **Concurrency run-lock** acquired before touching `state.json`; atomic
  acquisition closes the `mkdir`→write-pid window so two runs on one project can't
  corrupt shared state.
- Explicit `--resume` for a preserved logic-blocked run (re-enters the blocked
  stage and retries only the step that blocked); **auto-resume supervisor**
  (`scripts/night-shift-supervised.sh`) bounds automatic resume and escalates when
  stuck.
- Verify candidate evidence by **exit status**, not command strings, so an
  LLM-transcribed command can't drive control flow; accept a spec run from inside
  a worktree of the declared project.
- Isolated validation worktree symlinks ignored dependency dirs (`node_modules`,
  `ios/Pods`, `server/node_modules`, `web/node_modules`; override via
  `NIGHT_SHIFT_DEPENDENCY_LINKS`) so type-check/lint/test run without reinstalling.
- `state_set` and `record_findings` fail loudly instead of leaving stale state on
  `jq` errors.

### Tooling, structure & CI

- Decomposed `night-shift.sh` into cohesive sourced libs
  (`locking`/`recovery`/`preflight`/`personas`/`visual-capture`/`visual-repair`/`device-registry`).
- Extracted the test fixtures into `scripts/test/fixtures.sh` (sourced only under
  `--fixture-test`); the deterministic suite makes no network or model calls.
- **Shellcheck CI gate** (pinned `0.11.0` + `.shellcheckrc`, consolidated into
  `ci.yml`) plus a fixture-tests job on every push and PR.
- `--preflight` read-only launch-readiness JSON report (spec validity,
  on-feature-branch, clean tree, `.night-shift` gitignored, worktree conflicts) —
  the viewer renders it as a checklist.
- `scripts/parallel-worktrees.sh` wrapper for fan-out runs across worktrees;
  design + plan docs are kept local-only (gitignored, same policy as specs).
