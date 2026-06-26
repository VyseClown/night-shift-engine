# Flow B — create-from-Figma (implement-stage methodology) — design

Date: 2026-06-26. Repo: `night-shift-engine`. Increment 2 of the two-flow
design-fidelity vision (see [[design-fidelity-two-flows]]). **Flow A** (validate an
existing screen → capture → diff → auto-fix) already ships. **Flow B** is the
*first-time creation* path: build a screen/component from a Figma design, then hand off
to Flow A for pixel validation/repair.

## 1. Summary

When a spec has a `## Design Contract` and the screen is being built for the first
time, the night-shift **implement** stage should follow a **build-from-Figma
procedure**: pull the Figma node (structure + annotations/comments + image) via the
**MCP**, decompose it into components, **reuse the repo's existing components** and
build only what's missing, assemble the screen wired to real app state, and keep
`tsc`/`eslint`/tests green. The existing `visual_review` stage (Flow A) then captures,
diffs against the Figma image, and auto-fixes the pixel residual.

Flow B is **implement-stage guidance** (a procedure block added to `primary_prompt`) +
a **model bump to opus** for design-fidelity implements — *not* a new stage or command.
It reuses the night-shift stages end to end.

## 2. Goals / non-goals

**Goals**
- A "design-fidelity build (Flow B)" procedure in the implement-stage prompt, active
  only when the spec declares a `## Design Contract`.
- The implement agent pulls the Figma node via the **MCP** — `get_figma_data`
  (structure + **Dev Mode annotations / notes / comments**) AND `download_figma_images`
  (frame image) — and treats the **annotations/comments as first-class requirements**.
- It **decomposes** the design, **greps the repo for existing components to reuse**,
  builds only the missing ones, and assembles the screen wired to real state.
- The implement model is **opus** for Design-Contract specs (judgment-heavy).

**Non-goals**
- No new stage or standalone command (chosen: implement-stage methodology).
- No change to `visual_review` / Flow A — it already validates + auto-fixes (keep-best).
- No engine-side caching of the Figma structure (the agent pulls it live via MCP).
- No `FIGMA_TOKEN`/REST anywhere — MCP only ([[figma-mcp-not-token]]).

## 3. Architecture

### 3.1 The build-from-Figma procedure (`primary_prompt`, `night-shift.sh`)

Add a `design_build_note` to `primary_prompt`, interpolated into the prompt **only when
`spec_has_design_contract "$SPEC"`** (a `## Design Contract` is present) and the stage
is `implementation`/`implementation_review`. The note (verbatim intent):

> **Design-fidelity build (this spec has a `## Design Contract`).** You are building
> this screen to match its Figma design. Before/while implementing:
> 1. **Pull the design via the Figma MCP** (never a token): `mcp__figma__get_figma_data`
>    for the node's structure (layout, text, sizes, colors, typography, tokens) AND its
>    **Dev Mode annotations / notes / comments**, and `mcp__figma__download_figma_images`
>    for the frame image — open and VIEW it. Treat the **annotations and comments as
>    requirements** (states, spacing rationale, behavior), not just the pixels.
> 2. **Decompose** the design into a component breakdown.
> 3. **Reuse what exists:** Grep/Glob `src/ui/components` and `src/features/*` for
>    components that already satisfy each piece and REUSE them; build only what is
>    genuinely missing.
> 4. **Build** the missing components to the design (the project's tokens/sizes/spacing
>    from `src/ui`), following the layer boundaries.
> 5. **Assemble** them on the screen, wired to **real app state** (per this spec) — do
>    NOT hardcode the Figma's sample values.
> 6. Keep `tsc`/`eslint`/tests green. The engine's `visual_review` then pixel-diffs your
>    screen against the Figma image and auto-repairs the residual — get the structure +
>    tokens right here; it tightens the pixels.

(The exact node id + fileKey come from the spec's Design Contract, which the agent
reads; `figma_key_for`/`node_id_for` already parse them.)

### 3.2 Model: opus for Design-Contract implements (`stage_model`)

`stage_model` currently maps `implement|visual|observe|complete → IMPLEMENT_MODEL`.
Split `implement` out: when `spec_has_design_contract "$SPEC"`, the **implement** scope
uses `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` (default **opus**); otherwise `IMPLEMENT_MODEL`
(unchanged). `visual|observe|complete` keep `IMPLEMENT_MODEL`. Add a small helper
`spec_has_design_contract spec` = `grep -Eq '^## Design Contract([ \t]|$)' "$spec"`
(the model bump applies regardless of `VISUAL_CAPTURE`, so it does not reuse
`visual_stage_enabled`, which also requires the capture flag).

### 3.3 Detection / gate

Both the procedure note and the model bump are gated on `spec_has_design_contract` —
the same `## Design Contract` marker that already activates the Design Fidelity Reviewer
and `visual_review`. A spec without a Design Contract is completely unaffected
(byte-identical prompt, `IMPLEMENT_MODEL` unchanged).

## 4. Data flow (end to end)

Spec (with Design Contract) → **plan** (opus) → **implement** (now **opus**, follows the
build-from-Figma procedure: MCP pull incl. annotations/comments → decompose → reuse →
build-missing → assemble) → persona review → CREATE_CANDIDATE → **visual_review** (Flow
A: the engine stages the Figma ref via the MCP [increment 1], captures, odiff %,
keep-best auto-fix) → observer. No hardcoded Figma data; real app state throughout.

## 5. Testing

Deterministic fixtures (no MCP/agent calls — they assert the prompt + model wiring):
- **procedure present iff Design Contract:** with a spec that has a `## Design Contract`,
  `primary_prompt` (at the implementation stage) contains the "Design-fidelity build"
  procedure (assert key phrases: "Pull the design via the Figma MCP", "annotations",
  "Reuse what exists", "real app state"); with a spec lacking it, the procedure is
  absent. (Drive `primary_prompt` via the existing fixture harness with a stubbed STATE,
  as the engine fixtures already do for prompt assertions.)
- **opus for Design-Contract implement:** `stage_model implement` with a Design-Contract
  `$SPEC` → the `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL` default (`opus`); without a Design
  Contract → `IMPLEMENT_MODEL`. `visual`/`observe`/`complete` → `IMPLEMENT_MODEL`
  either way.
- **MCP-only:** the procedure text names `mcp__figma__get_figma_data` /
  `download_figma_images` and never `FIGMA_TOKEN`/`api.figma.com`.

Shellcheck default severity (`find scripts -name '*.sh' -exec shellcheck -s bash {} +`
exit 0); full fixture suite green.

## 6. Risks

- **Prompt length / focus:** the procedure adds guidance to the implement prompt only
  for Design-Contract specs; it is bounded (one block) and gated, so non-design runs are
  unaffected.
- **Reuse over-/under-matching:** the agent may miss a reusable component or wrongly
  reuse one. This is judgment work (hence opus); the persona review (RN Architect /
  Design Fidelity Reviewer) and `visual_review` are the safety nets.
- **Cost:** opus on the implement grind is pricier than sonnet, applied only to
  Design-Contract specs (the design-fidelity case where it pays off — [[opus-for-design-fidelity]]).
  `NIGHT_SHIFT_DESIGN_IMPLEMENT_MODEL=inherit`/`sonnet` overrides it.
