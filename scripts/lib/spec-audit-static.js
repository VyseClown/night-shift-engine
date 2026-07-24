#!/usr/bin/env node
'use strict';

// Deterministic pre-run spec-quality scanner — static layer (spec-audit
// design, docs/superpowers/specs/2026-07-24-spec-audit-design.md, "Static
// layer" section). Mirrors the test-audit two-layer architecture
// (scripts/lib/test-audit-static.js): this file does no judgment, just a
// mechanical zero-dep pass over ONE spec markdown file hunting for
// authoring-time smells (placeholders, missing/empty Acceptance Criteria,
// vague ACs, open-ended scope, no biting test command, no final validation,
// visual-fidelity language with no Design Contract). `scripts/spec-audit.sh`
// (agent layer, not this file) wraps this report with an LLM pass for
// judgment-tier smells (untestable ACs, validation that wouldn't exercise
// the change, implied-but-omitted edge cases).
//
// node:* builtins only — no new dependency, no package.json anywhere in the
// repo, same convention as test-audit-static.js / port-audit-static.js.
//
// CLI:
//   node scripts/lib/spec-audit-static.js --spec <file> --out <json>
// Both flags are required; missing either throws. Writes the report to
// `--out` (parent dirs created as needed).
//
// Report shape: { spec, findings: [ { rule, line, excerpt }, ... ],
//                 counts: { <rule>: n, ..., total: n } }
// `findings` is sorted by line then rule. `counts` always lists every one of
// the 7 rules (0 included) plus `total`, so the report shape is stable even
// when nothing fired.
//
// Rules (see the design doc for the authoritative definition of each):
//   1. placeholder              — literal TODO/TBD/FIXME/XXX, or an unfilled
//      `<...>` angle-placeholder, in PROSE (fenced code blocks are exempt —
//      one finding per offending line).
//   2. no-acceptance-criteria   — no `## Acceptance Criteria` section, or the
//      section has zero `- [ ]`/`- [x]` items (whole-spec, max one finding).
//   3. vague-ac                 — a Summary/Scope/Acceptance line carrying a
//      weasel phrase with NO concrete predicate on the same line (one
//      finding per offending line).
//   4. scope-ambiguity          — an open-ended scope marker (`etc.`, `and
//      more`, ...) on a Summary/Scope/Acceptance line (one per line).
//   5. no-test-command          — neither the Test Plan's "First failing
//      test" field nor its "Final validation commands" list names a
//      test-runner invocation (whole-spec, max one finding).
//   6. no-final-validation      — the Test Plan's "Final validation
//      commands" list is missing or empty (whole-spec, max one finding).
//   7. missing-design-contract  — the spec mentions visual-fidelity intent
//      but has no `## Design Contract` section and Track isn't `node`
//      (whole-spec, max one finding).
//
// Exit 0 whenever scanning completed — findings are DATA, not errors, so a
// spec riddled with placeholders still exits 0. Exit 3 only on unusable args
// (missing --spec/--out, --spec not a readable file, or the report can't be
// written) — mirrors the "3 = error" convention test-audit-static.js /
// port-audit-static.js already use.
//
// ---------------------------------------------------------------------------
// Scanning model + documented limits.
//
// This is a LINE-ORIENTED TEXT SCAN over markdown, not a markdown parser
// (same documented limitation as test-audit-static.js's regex-based test
// scan). Sections are detected by `## Heading` lines only (the template's
// convention); nesting/`###` sub-headings are not tracked. Fenced code
// blocks (```) are tracked for rule 1 only, per the design's explicit
// carve-out ("not inside a fenced code block, which legitimately shows
// placeholders") — the other line rules scan Summary/Scope/Acceptance/Test
// Plan prose, where a code fence would be unusual.
// ---------------------------------------------------------------------------

const fs = require('node:fs');
const path = require('node:path');

const RULES = [
  'placeholder',
  'no-acceptance-criteria',
  'vague-ac',
  'scope-ambiguity',
  'no-test-command',
  'no-final-validation',
  'missing-design-contract',
];

function fail(reason) {
  console.error(`spec-audit-static: ${reason}`);
  process.exitCode = 3;
}

function parseArgs(argv) {
  const args = {};
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === '--spec') { args.spec = argv[i + 1]; i += 2; continue; }
    if (a === '--out') { args.out = argv[i + 1]; i += 2; continue; }
    throw new Error(`unrecognized argument: ${a}`);
  }
  if (!args.spec) throw new Error('--spec is required');
  if (!args.out) throw new Error('--out is required');
  return args;
}

// ---------------------------------------------------------------------------
// Line-level trigger patterns.
// ---------------------------------------------------------------------------

const TODO_RE = /\b(?:TODO|TBD|FIXME|XXX)\b/;
// An unfilled `<...>` angle-placeholder: excludes HTML/markdown comments
// (`<!-- ... -->`) and multi-line-unfriendly noise by capping length and
// disallowing a leading `!`.
const ANGLE_PLACEHOLDER_RE = /<(?!!)[^<>\n]{1,80}>/;

const WEASEL_RE =
  /\b(?:looks good|works (?:properly|correctly)|handle[sd]? (?:it )?appropriately|as expected|make it (?:nice|pretty)|and so on)\b/i;

const CONCRETE_BACKTICK_RE = /`[^`]+`/;
const CONCRETE_EQUALS_RE = /={2,3}/;
const CONCRETE_NUMBER_RE = /\b\d+(?:\.\d+)?\b/;
const CONCRETE_FILE_PATH_RE = /\b[\w.-]+\/[\w./-]+\.[A-Za-z0-9]+\b/;

function hasConcretePredicate(line) {
  return (
    CONCRETE_BACKTICK_RE.test(line) ||
    CONCRETE_EQUALS_RE.test(line) ||
    CONCRETE_NUMBER_RE.test(line) ||
    CONCRETE_FILE_PATH_RE.test(line)
  );
}

// `etc.` ends in punctuation, not a word char, so a trailing `\b` after it
// would never match (no word/non-word transition between "." and the space
// or EOL that follows) — that alternative gets its own boundary-free tail.
const SCOPE_AMBIGUITY_RE = /\betc\.|\b(?:and more|among others|similar things|and so forth)\b/i;

// The bare "test" alternative (a `pnpm ... test` invocation, e.g. `pnpm
// test` / `pnpm --filter x test` / `pnpm run test`) needs a negative
// lookahead after its own `\btest\b` — otherwise "test-setup.js" false-
// matches too: `\b` only checks a word/non-word transition, and "-" is a
// non-word char, so `\btest\b` alone is satisfied by "test-setup" (bounded
// by the space before "test" and the hyphen after it). `(?![-\w])` rejects
// that hyphenated-compound case while still matching "test" followed by
// whitespace, punctuation-that-isn't-a-word-char, or end of line.
const TEST_RUNNER_RE =
  /\b(?:vitest|jest|node --test|pytest|go test|mocha)\b|\bpnpm[^\n]*\btest\b(?![-\w])/i;

// Deliberately conservative keyword set — this is an advisory static pass,
// not a design-fidelity judge, so it only fires on strong, low-noise
// visual-intent signals. A bare "design" keyword was tried and dropped: it
// false-fired on ordinary prose like "a clean design decision" that has
// nothing to do with pixel/Figma parity. The agent layer (scripts/spec-audit.sh)
// is where subtler design-fidelity gaps get judged.
const VISUAL_INTENT_RE = /\b(?:pixel|figma|screenshot)\b|\bvisual parity\b|\blooks like\b/i;

// ---------------------------------------------------------------------------
// Markdown structure helpers (local, minimal — see file header).
// ---------------------------------------------------------------------------

// Returns every `## Heading` in the doc as
// { name, nameLower, lineNum, contentStart, contentEnd } (1-indexed lines;
// contentEnd is inclusive, the line before the next heading or EOF).
function parseHeadings(lines) {
  const headingLineRe = /^##\s+(.+?)\s*$/;
  const raw = [];
  lines.forEach((line, idx) => {
    const m = headingLineRe.exec(line);
    if (m) raw.push({ name: m[1].trim(), lineNum: idx + 1 });
  });
  return raw.map((h, i) => {
    const contentStart = h.lineNum + 1;
    const contentEnd = i + 1 < raw.length ? raw[i + 1].lineNum - 1 : lines.length;
    return { name: h.name, nameLower: h.name.toLowerCase(), lineNum: h.lineNum, contentStart, contentEnd };
  });
}

function findHeading(headings, predicate) {
  return headings.find(predicate) || null;
}

// Line numbers (1-indexed) treated as Summary/Scope/Acceptance for rules 3+4
// — any section whose heading name mentions summary, scope, or acceptance.
function summaryScopeAcceptanceLines(headings) {
  const lineNums = [];
  for (const h of headings) {
    if (/summary|scope|acceptance/.test(h.nameLower)) {
      for (let n = h.contentStart; n <= h.contentEnd; n++) lineNums.push(n);
    }
  }
  return lineNums;
}

// Set of 1-indexed line numbers that sit inside a fenced (```) code block.
function fencedLineSet(lines) {
  const fenced = new Set();
  let inFence = false;
  lines.forEach((line, idx) => {
    const isFenceMarker = /^\s*```/.test(line);
    if (isFenceMarker) {
      inFence = !inFence;
      fenced.add(idx + 1); // the fence delimiter line itself is not prose either
      return;
    }
    if (inFence) fenced.add(idx + 1);
  });
  return fenced;
}

function trackField(content) {
  const m = /^-\s*Track:\s*(.+?)\s*$/im.exec(content);
  return m ? m[1].trim().toLowerCase() : 'rn'; // template default when the field is absent
}

// ---------------------------------------------------------------------------
// Rule scans.
// ---------------------------------------------------------------------------

// Strips inline backtick-delimited code spans (`` `...` ``) before the
// placeholder scan — same spirit as the fenced-block skip, one level down.
// rn specs routinely write inline JSX like `<ScrollView>` or `<Text>` as
// prose-documentation; without this, every such mention false-fires as an
// "unfilled angle-placeholder". A literal TODO written inside inline code
// (documenting the marker itself, not authoring an unfilled one) is exempt
// for the same reason.
function stripInlineCode(line) {
  return line.replace(/`[^`]*`/g, '');
}

function scanPlaceholder(lines, fenced, findings) {
  lines.forEach((line, idx) => {
    const lineNum = idx + 1;
    if (fenced.has(lineNum)) return;
    const scanned = stripInlineCode(line);
    if (TODO_RE.test(scanned) || ANGLE_PLACEHOLDER_RE.test(scanned)) {
      findings.push({ rule: 'placeholder', line: lineNum, excerpt: line.trim() });
    }
  });
}

function scanNoAcceptanceCriteria(lines, headings, findings) {
  const heading = findHeading(headings, (h) => h.nameLower === 'acceptance criteria');
  if (!heading) {
    findings.push({ rule: 'no-acceptance-criteria', line: 1, excerpt: (lines[0] || '').trim() });
    return;
  }
  const itemRe = /^\s*-\s*\[[ xX]\]/;
  for (let n = heading.contentStart; n <= heading.contentEnd; n++) {
    if (itemRe.test(lines[n - 1] || '')) return; // at least one checklist item — rule satisfied
  }
  findings.push({ rule: 'no-acceptance-criteria', line: heading.lineNum, excerpt: lines[heading.lineNum - 1].trim() });
}

function scanVagueAc(lines, ssaLines, findings) {
  for (const n of ssaLines) {
    const line = lines[n - 1] || '';
    if (WEASEL_RE.test(line) && !hasConcretePredicate(line)) {
      findings.push({ rule: 'vague-ac', line: n, excerpt: line.trim() });
    }
  }
}

function scanScopeAmbiguity(lines, ssaLines, findings) {
  for (const n of ssaLines) {
    const line = lines[n - 1] || '';
    if (SCOPE_AMBIGUITY_RE.test(line)) {
      findings.push({ rule: 'scope-ambiguity', line: n, excerpt: line.trim() });
    }
  }
}

// Extracts the Test Plan's "First failing test" field text and its "Final
// validation commands" numbered-list lines. Both are `null`/`[]` when the
// Test Plan section (or the specific field) is absent — that absence is
// itself meaningful to rules 5 and 6, not an error.
function extractTestPlanFields(lines, headings) {
  const heading = findHeading(headings, (h) => h.nameLower === 'test plan');
  const result = { heading, firstFailingTestLine: null, finalValidationBulletLine: null, finalValidationLines: [] };
  if (!heading) return result;

  const firstFailingRe = /first failing test.*?:\s*(.*)$/i;
  const finalValidationBulletRe = /final validation commands/i;
  const numberedItemRe = /^\s*\d+\.\s+/;

  for (let n = heading.contentStart; n <= heading.contentEnd; n++) {
    const line = lines[n - 1] || '';
    if (result.firstFailingTestLine === null && firstFailingRe.test(line)) {
      result.firstFailingTestLine = n;
    }
    if (result.finalValidationBulletLine === null && finalValidationBulletRe.test(line)) {
      result.finalValidationBulletLine = n;
      // Collect the numbered items immediately following the bullet.
      for (let k = n + 1; k <= heading.contentEnd; k++) {
        const itemLine = lines[k - 1] || '';
        if (!numberedItemRe.test(itemLine)) break;
        result.finalValidationLines.push({ line: k, text: itemLine });
      }
    }
  }
  return result;
}

function scanNoTestCommand(lines, testPlan, findings) {
  const haystack = [];
  if (testPlan.firstFailingTestLine !== null) haystack.push(lines[testPlan.firstFailingTestLine - 1]);
  for (const item of testPlan.finalValidationLines) haystack.push(item.text);

  const hasRunner = haystack.some((line) => TEST_RUNNER_RE.test(line));
  if (hasRunner) return;

  const anchorLine = testPlan.heading ? testPlan.heading.lineNum : 1;
  findings.push({ rule: 'no-test-command', line: anchorLine, excerpt: lines[anchorLine - 1].trim() });
}

function scanNoFinalValidation(lines, testPlan, findings) {
  if (testPlan.finalValidationLines.length > 0) return; // present and non-empty — rule satisfied

  const anchorLine = testPlan.finalValidationBulletLine || (testPlan.heading ? testPlan.heading.lineNum : 1);
  findings.push({ rule: 'no-final-validation', line: anchorLine, excerpt: lines[anchorLine - 1].trim() });
}

function scanMissingDesignContract(lines, fenced, headings, track, findings) {
  if (track === 'node') return;
  const hasDesignContract = headings.some((h) => h.nameLower === 'design contract');
  if (hasDesignContract) return;

  for (let i = 0; i < lines.length; i++) {
    const lineNum = i + 1;
    if (fenced.has(lineNum)) continue;
    if (VISUAL_INTENT_RE.test(lines[i])) {
      findings.push({ rule: 'missing-design-contract', line: lineNum, excerpt: lines[i].trim() });
      return; // whole-spec finding — at most one
    }
  }
}

// ---------------------------------------------------------------------------
// Orchestration.
// ---------------------------------------------------------------------------

function buildReport(specPath, content) {
  const lines = content.split('\n');
  const headings = parseHeadings(lines);
  const fenced = fencedLineSet(lines);
  const ssaLines = summaryScopeAcceptanceLines(headings);
  const track = trackField(content);
  const testPlan = extractTestPlanFields(lines, headings);

  const findings = [];
  scanPlaceholder(lines, fenced, findings);
  scanNoAcceptanceCriteria(lines, headings, findings);
  scanVagueAc(lines, ssaLines, findings);
  scanScopeAmbiguity(lines, ssaLines, findings);
  scanNoTestCommand(lines, testPlan, findings);
  scanNoFinalValidation(lines, testPlan, findings);
  scanMissingDesignContract(lines, fenced, headings, track, findings);

  findings.sort((a, b) => a.line - b.line || a.rule.localeCompare(b.rule));

  const counts = { total: findings.length };
  for (const rule of RULES) counts[rule] = 0;
  for (const f of findings) counts[f.rule] = (counts[f.rule] || 0) + 1;
  counts.total = findings.length;

  return { spec: specPath, findings, counts };
}

function run(args) {
  const absSpec = path.resolve(args.spec);
  let content;
  try {
    content = fs.readFileSync(absSpec, 'utf8');
  } catch (err) {
    throw new Error(`--spec not readable: ${args.spec} (${err.message})`);
  }
  const relSpec = path.relative(process.cwd(), absSpec).split(path.sep).join('/');
  const report = buildReport(relSpec, content);

  const outPath = path.resolve(args.out);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + '\n');
  return { report, outPath };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    fail(err.message);
    return;
  }
  try {
    const { report, outPath } = run(args);
    console.log(`spec-audit-static: ${report.counts.total} finding(s) in ${report.spec} -> ${outPath}`);
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
  parseHeadings,
  findHeading,
  summaryScopeAcceptanceLines,
  fencedLineSet,
  trackField,
  extractTestPlanFields,
  hasConcretePredicate,
  buildReport,
  run,
};
