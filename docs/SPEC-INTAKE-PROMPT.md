# Spec Intake Prompt — from feature ticket to launch-ready spec suite

> The reusable prompt that turns a raw feature ticket into validated night-shift
> specs. Paste the block below into a Claude Code session started in the
> **workspace container** (so it can see both the engine repo and the target
> project), fill the `{PLACEHOLDERS}`, and attach or paste the ticket.
>
> What it produces: sliced spec files in `specs/`, an ordered `TODO.md` queue,
> a branch/topology plan (what chains, what fans out), and the launch commands —
> **not** an implementation. Authoring is cheap; the night is expensive. This
> prompt front-loads every decision the unattended run cannot make.

---

## How to use

1. Start a Claude Code session in the workspace container.
2. Paste the prompt with placeholders filled:
   - `{TICKET}` — the feature ticket, pasted in full (or a path to it).
   - `{PROJECT_PATH}` — the target repo (e.g. `<workspace>/water-tracker-app`).
   - `{TRACK}` — `rn` | `web` | `node` | `fullstack`.
   - `{TRUNK_BRANCH}` — the feature branch the suite lands on (e.g. `feat/place-sheet-v2`).
   - `{FIGMA_LINKS}` — design handoff URLs, if any (else `none`).
   - `{PORT_SOURCE}` — path/repo of an existing implementation being ported
     (e.g. the web app when porting web → RN), or `none`.
3. Review its Phase-5 deliverable, resolve anything it surfaced as OPEN, then launch.

---

## The prompt

```text
You are the spec author for the night-shift engine. Your job is to convert a
feature ticket into a launch-ready suite of night-shift specs. You produce
specs, a queue, and a launch plan — you do NOT implement the feature, and you
do NOT modify the target project beyond reading it.

INPUTS
- Ticket: {TICKET}
- Target project: {PROJECT_PATH}   (track: {TRACK})
- Trunk feature branch for the suite: {TRUNK_BRANCH}
- Design references: {FIGMA_LINKS}
- Port source (existing implementation to port from, or none): {PORT_SOURCE}

PHASE 0 — READ THE CONTRACTS (before anything else)
Read, in the engine repo: docs/SPEC-AUTHORING.md (the three tiers, right-sizing,
checklist, anti-patterns), docs/PARALLEL-AND-SEQUENCING.md (chain vs fan-out
rules), the {TRACK} spec template in specs/, AGENTS.md (validation checklist for
{TRACK}, review floor/profiles), and docs/COMMAND-PLAYBOOK.md §1 (the Figma MCP
rule). Read the target project's CLAUDE.md for its real validation commands.
Do not restate these docs back to me; apply them.

PHASE 1 — DECOMPOSE THE TICKET
1. Extract every distinct deliverable: each section/field mapping, each business
   rule, each Definition-of-Done bullet. Compound bullets get split — one
   observable behavior per line.
2. Classify each line: already binary/testable as written, convertible (rewrite
   it as a binary check), or unfalsifiable (e.g. "meets WCAG AA" → convert to
   the concrete checks that apply per part).
3. Map external dependencies: for every cross-referenced ticket/story, determine
   from the codebase whether it has LANDED (its code/fields exist) or NOT.
   A not-landed dependency needs an explicit in-spec fallback contract (what
   renders/happens without it, keyed for later swap-in) — or it parks that part
   of the suite. Never let a dependency survive as an implicit assumption.

PHASE 2 — RESEARCH (evidence, not memory; cite file paths for every claim)
A. Foundation audit: what does the ticket assume already exists (shells,
   components, routes, stores)? Find it in {PROJECT_PATH} and name the actual
   files. If an assumed foundation is missing, that is a finding, not a detail.
B. Backend/wire verification: for EVERY field, endpoint, or schema path the
   ticket names, locate the corresponding type/client/fixture in the codebase
   and confirm the exact path exists (e.g. does `narrative.overview.headline`
   exist in the response types or fixtures?). Three outcomes per item: VERIFIED
   (cite the file), MISMATCH (ticket says X, code says Y — record both), or
   ABSENT (the integration itself needs review/build — this becomes its own
   spec or an OPEN item, never a silent assumption). Never invent wire fields;
   specs inherit the engine's never-invent rule.
C. Design extraction: for each Figma link, use the Figma MCP (get_figma_data;
   download_figma_images for reference frames) — never the REST API or a token.
   Build the frame → screen/state matrix. Where the ticket names a section with
   NO frame, capture the intended pattern in prose for the spec and list it
   under Approved deviations so a visual pass cannot fail on it. Note known-bad
   mock content in frames the same way.
D. Port analysis (only if {PORT_SOURCE} is not none): read the existing
   implementation and extract its BEHAVIOR contract — states, edge cases,
   ordering, error handling — not its code. List platform deltas (navigation,
   gestures, styling system, storage) that make a literal port wrong. The specs
   you write must state target-platform behavior; reference the source only as
   evidence.
E. Reuse inventory: existing components/utilities/tests the specs should name
   in "Existing components to reuse" and Technical Approach — the cheapest
   guard against the agent rebuilding what exists.
F. Validation reality check: run the project's baseline commands (tsc, lint,
   test) yourself, now. Record any pre-existing red — it either gets fixed
   before launch or explicitly noted; a dirty baseline muddies every downstream
   signal.

PHASE 3 — SLICE AND CHOOSE TOPOLOGY
1. Group the Phase-1 lines into specs of 3–7 binary ACs each. Slice VERTICALLY
   (each spec independently green: data → logic → UI wiring → polish), never
   horizontally.
2. Build the dependency graph between specs: spec B depends on spec A only if B
   cannot pass ITS OWN validation without A's landed code. Be strict — shared
   file surface is a merge concern, not a dependency.
3. Apply the topology rule from docs/PARALLEL-AND-SEQUENCING.md:
   - Dependent chain → sequential NEXT_TASK queue, ALL on {TRUNK_BRANCH}
     (the engine never switches branches mid-chain).
   - Independent specs → eligible for parallel fan-out: each gets its OWN
     feature branch based off {TRUNK_BRANCH} (backticked values — they are
     load-bearing for the parsers).
   - Specs whose file surfaces overlap heavily should stay in the chain even if
     logically independent — engine time is cheaper than your merge conflicts.
4. Order the chain riskiest-foundation-first; a BLOCKED stops everything behind it.

PHASE 4 — WRITE THE SPECS
For each spec, copy the {TRACK} template and fill EVERY section per
docs/SPEC-AUTHORING.md:
- ACs binary, dependency-ordered, each mapped to a named test file.
- First failing test named precisely; state whether net-new (absent → red) or
  modify-mode (exists, green at baseline).
- Baseline/Final commands from the project's CLAUDE.md — deterministic,
  non-interactive, fastest-first; remember these run VERBATIM unattended, so a
  spec is executable code.
- Permissions explicit: every yes with details, everything else no.
- Review config trimmed per spec (- Personas: for focused slices; contract
  sections only where filled — an optional reviewer without a filled contract
  is cost without depth). Design-heavy specs get a ## Design Contract with the
  frame/state/device matrix and tolerance from Phase 2C.
- Out of Scope: the ticket's cross-referenced tickets, the tempting adjacent
  refactors, and every not-landed dependency's real scope.
- Open Questions: MUST end empty. Anything you cannot resolve from the ticket,
  the codebase, or the designs goes in the Phase-5 OPEN list for the human —
  do not guess, and do not launch-qualify a spec that still carries one.

PHASE 5 — VALIDATE AND DELIVER
1. Add the ordered TODO.md entries (chain order; bugs before features).
2. Sanity-check each spec against the engine's validator expectations
   (backticked Repository fields, yes/no - details permissions, an owner line
   per active persona, all three Test Plan fields). If the engine is runnable
   here, do the free preflight: scripts/night-shift.sh --preflight (or
   --fixture-test --dry-run) per spec, and report results.
3. Deliver, in one final message:
   - Suite table: spec file · one-line scope · #ACs · branch · topology
     (chain position or fan-out) · personas/profile · model notes (design
     contract bumps, strongest-model cases per CLAUDE.md's Model ruling).
   - The dependency graph (which specs gate which).
   - Launch plan: the exact commands — night-1 chain launch (no --spec, from
     the engine dir) and, if any fan-out, the parallel-worktrees.sh command
     with --dry-run rehearsal first.
   - OPEN items: every unresolved question, MISMATCH, or ABSENT integration,
     each with what you found, where you looked, and what decision is needed.
   - Baseline status from Phase 2F.

HARD RULES
- Evidence over memory: every claim about the codebase, wire, or design cites a
  file path or MCP result. If you didn't read it, you don't know it.
- Never invent wire fields, endpoints, or design details.
- Do not implement. Do not modify {PROJECT_PATH}. Specs, TODO.md, and this
  report are your only outputs.
- If the ticket and the codebase contradict each other, surface the
  contradiction in OPEN items — do not pick a side silently.
```

---

## Why the phases are ordered this way

- **Contracts before ticket** (Phase 0) — the templates and topology rules shape
  *how* to read the ticket; reading them second produces specs that need rework.
- **Backend verification before slicing** (Phase 2B → 3) — an ABSENT integration
  changes the slice list itself (it becomes its own spec), so it must be known
  before the suite shape is fixed.
- **Topology before writing** (Phase 3 → 4) — branch names go *inside* the spec
  files (`Base branch:` / `Feature branch:`), so chain-vs-fan-out must be
  decided first.
- **Open Questions must end empty** — a launched spec with an open question is a
  scheduled `BLOCKED`; the OPEN list moves those decisions to you, before the
  night, where they're cheap.

## Related

- `docs/SPEC-AUTHORING.md` — the quality bar each produced spec is held to
- `docs/PARALLEL-AND-SEQUENCING.md` — the topology rules Phase 3 applies
- `specs/_template.md` / `_template-web.md` / `_template-fullstack.md` — the skeletons Phase 4 fills
- `docs/COMMAND-PLAYBOOK.md` — §1 Figma MCP rule; §6/§8 the launch commands Phase 5 emits
