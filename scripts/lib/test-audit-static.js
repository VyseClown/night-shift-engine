#!/usr/bin/env node
'use strict';

// Deterministic false-confidence test audit — static layer (agentic-gaps
// tranche Task 8, spec §C:
// docs/superpowers/specs/2026-07-11-agentic-gaps-tranche-design.md). Mirrors
// the port-audit two-layer architecture (scripts/lib/port-audit-static.js):
// this file does no judgment, just a mechanical zero-dep pass over test
// files hunting for tests that PASS while asserting nothing. Evidence:
// 2026-07-11, `expect(result.installmentGroupId).not.toBe("group-a")` passed
// vacuously because `installmentGroupId` doesn't exist on `result`
// (`undefined !== "group-a"` is trivially true) — only a sibling positive
// assertion elsewhere exposed the bug. `scripts/test-audit.sh` (agent layer,
// not this file) wraps this report with an LLM pass for judgment-tier smells
// (mocks tested against themselves, tautological round-trips, ...).
//
// node:* builtins only — no new dependency, no package.json anywhere in the
// repo. Small helpers (glob expansion, balanced-bracket matching) are
// re-implemented locally rather than pulled in, same convention as
// port-audit-static.js / figma-manifest.js / component-inventory.js.
//
// CLI:
//   node scripts/lib/test-audit-static.js
//     --tests <glob-or-dir-or-file...> [--src <dir>] --out <json>
// `--tests` accepts one or more paths/globs (consumes every following
// argument up to the next `--flag`); each may be a file, a directory (walked
// recursively for `*.test.*`/`*.spec.*` files), or a glob pattern containing
// `*`/`**`/`?` (matched against a full recursive walk of the glob's
// non-wildcard base directory — a tiny hand-rolled matcher, not node:fs's
// glob API, so this runs identically on any Node this repo already targets).
// `--src`, when given, enables `assert-on-unknown-property` (best-effort
// grep of a source dir); omitted, that rule is skipped entirely (its count
// still appears in `counts`, at 0). Writes the report to `--out` (parent
// dirs created as needed).
//
// Report shape, schema `night-shift-test-audit-static/1`:
//   { schema, generated_at,
//     findings: [ { file, line, rule, snippet }, ... ],   // sorted file,line,rule
//     counts: { <rule>: n, ... } }                        // every rule present, 0 included
//
// Exit 0 whenever scanning completed — findings are DATA, not errors, so a
// file full of vacuous tests still exits 0. Exit 3 only on unusable args/IO
// (no --tests, no --out, --tests resolves to zero files, --src given but not
// a directory, or the report can't be written) — mirrors the "3 = error"
// convention scripts/port-audit.sh already uses for its own layer.
//
// ---------------------------------------------------------------------------
// Scanning model + documented limits.
//
// This is a LINE-ORIENTED TEXT SCAN, not a JS/TS parser (same documented
// limitation as figma-manifest.js's node-dump parser and
// component-inventory.js's regex-based extraction). Two building blocks:
//
// 1. `findBalancedEnd` — given the index of an opening bracket char, returns
//    the index of its matching closer, skipping over `//` line comments,
//    `/* */` block comments, and quoted/template strings (so a `)` or `}`
//    inside a description string or comment never miscounts depth). It does
//    NOT descend into a template literal's `${...}` interpolations (a
//    backtick string is treated as opaque until its closing backtick) — a
//    documented gap, same spirit as port-audit-static.js's extractBalanced.
// 2. Test-block extents come from scanning for `it(`/`test(` calls (with an
//    optional `.modifier`, e.g. `it.skip(`), taking the matched call's full
//    paren extent via (1), then locating the FIRST arrow (`=> {`) or
//    `function (...) {` body inside that extent and taking ITS brace extent
//    via (1) as the test's body text. A call with no discoverable `{ ... }`
//    body (e.g. `it.todo('reason')`, or an implicit-return arrow with no
//    braces) is treated as having an empty body — best-effort, documented.
//
// A description string that itself contains the literal text `it(` or
// `expect(` can confuse the scan (rare in practice); this is a known,
// accepted limitation of a regex-based pass, not a bug to chase.
// ---------------------------------------------------------------------------

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'night-shift-test-audit-static/1';

const RULES = [
  'not-tobe-literal',
  'assert-on-unknown-property',
  'tobe-true-constant',
  'empty-test-body',
  'expectless-test',
  'skipped-test',
];

const TEST_FILE_RE = /\.(test|spec)\.[jt]sx?$/;
const IGNORE_DIR_NAMES = new Set(['node_modules', '.git', '.night-shift', 'dist', 'build', '.next', '.expo']);

function fail(reason) {
  console.error(`test-audit-static: ${reason}`);
  process.exitCode = 3;
}

function parseArgs(argv) {
  const args = { tests: [] };
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === '--tests') {
      i++;
      while (i < argv.length && !argv[i].startsWith('--')) {
        args.tests.push(argv[i]);
        i++;
      }
      continue;
    }
    if (a === '--src') { args.src = argv[i + 1]; i += 2; continue; }
    if (a === '--out') { args.out = argv[i + 1]; i += 2; continue; }
    throw new Error(`unrecognized argument: ${a}`);
  }
  if (!args.tests.length) throw new Error('--tests is required (at least one path/glob)');
  if (!args.out) throw new Error('--out is required');
  return args;
}

// ---------------------------------------------------------------------------
// Filesystem helpers (small, local — see file header).
// ---------------------------------------------------------------------------

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

function safeReaddir(dir) {
  try { return fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
}

function walkAllFiles(dir) {
  const out = [];
  const entries = safeReaddir(dir).sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (IGNORE_DIR_NAMES.has(entry.name)) continue;
      out.push(...walkAllFiles(full));
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

const GLOB_META_RE = /[*?[\]{}]/;

function isGlobPattern(p) {
  return GLOB_META_RE.test(p);
}

// Longest path prefix with no glob metacharacters — the directory we walk
// before filtering candidates against the full pattern.
function globBase(pattern) {
  const segments = pattern.split('/');
  const baseSegs = [];
  for (const seg of segments) {
    if (isGlobPattern(seg)) break;
    baseSegs.push(seg);
  }
  return baseSegs.length ? baseSegs.join('/') : '.';
}

// Minimal glob -> RegExp: `*` matches within one path segment, `**` matches
// across segments (incl. zero), `?` matches one char. No brace expansion,
// no character classes — sufficient for the dir-scoped patterns this CLI
// expects (`scripts/test/fixtures/test-audit/*.test.js`), not a general
// glob implementation.
function globToRegExp(pattern) {
  let re = '';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === '*') {
      if (pattern[i + 1] === '*') {
        re += '.*';
        i++;
        if (pattern[i + 1] === '/') i++;
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else if ('.+^${}()|[]\\'.includes(c)) {
      re += '\\' + c;
    } else {
      re += c;
    }
  }
  return new RegExp(`^${re}$`);
}

function expandGlob(pattern) {
  const base = globBase(pattern);
  if (!isDir(base)) return [];
  const re = globToRegExp(pattern);
  return walkAllFiles(base).filter((f) => re.test(f.split(path.sep).join('/')));
}

// Resolves one `--tests` entry (file, directory, or glob) to a list of file
// paths. Directories are filtered to test-shaped filenames; globs and
// explicit files are taken as given (a caller pointing `--tests` directly at
// a specific file is trusted to mean it).
function resolveTestEntry(entry) {
  if (isGlobPattern(entry)) return expandGlob(entry);
  if (isDir(entry)) return walkAllFiles(entry).filter((f) => TEST_FILE_RE.test(f));
  if (isFile(entry)) return [entry];
  return [];
}

function resolveTestPaths(entries) {
  const seen = new Set();
  const out = [];
  for (const entry of entries) {
    for (const f of resolveTestEntry(entry)) {
      const resolved = path.resolve(f);
      if (seen.has(resolved)) continue;
      seen.add(resolved);
      out.push(resolved);
    }
  }
  out.sort((a, b) => a.localeCompare(b));
  return out;
}

// ---------------------------------------------------------------------------
// Balanced-bracket scan (skips comments + quoted/template strings).
// ---------------------------------------------------------------------------

function findBalancedEnd(content, openIndex, openChar, closeChar) {
  let depth = 0;
  for (let i = openIndex; i < content.length; i++) {
    const c = content[i];
    if (c === '/' && content[i + 1] === '/') {
      const nl = content.indexOf('\n', i);
      i = nl === -1 ? content.length : nl;
      continue;
    }
    if (c === '/' && content[i + 1] === '*') {
      const end = content.indexOf('*/', i + 2);
      i = end === -1 ? content.length - 1 : end + 1;
      continue;
    }
    if (c === '\'' || c === '"' || c === '`') {
      const quote = c;
      i++;
      while (i < content.length && content[i] !== quote) {
        if (content[i] === '\\') i++;
        i++;
      }
      continue;
    }
    if (c === openChar) depth++;
    else if (c === closeChar) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1; // unterminated — malformed/truncated input, caller treats as "no extent found"
}

// ---------------------------------------------------------------------------
// Test-block extraction.
// ---------------------------------------------------------------------------

const TEST_CALL_RE = /\b(?:it|test)(?:\.\w+)?\s*\(/g;
const CALLBACK_BODY_RE = /(?:=>\s*\{|\bfunction\s*\([^)]*\)\s*\{)/;

// Byte-offset -> 1-based line number, via a precomputed sorted array of
// line-start offsets (binary search) — avoids repeated slice+split over the
// same file content for every match.
function computeLineStarts(content) {
  const starts = [0];
  for (let i = 0; i < content.length; i++) {
    if (content[i] === '\n') starts.push(i + 1);
  }
  return starts;
}

function lineNumberFor(lineStarts, index) {
  let lo = 0;
  let hi = lineStarts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (lineStarts[mid] <= index) lo = mid;
    else hi = mid - 1;
  }
  return lo + 1;
}

// Strips a trailing `//` line comment before a line is fed to any rule
// regex — same convention as port-audit-static.js's scanFileUsages, and
// necessary here for the same reason: without it, a doc comment that
// mentions `expect(...)`/`.skip(`/etc. as PROSE (this very file's header
// does, quoting the real 2026-07-11 bug) gets misread as code. Known,
// accepted gap: a `//` inside a string/template literal truncates the rest
// of that line too (matches the established convention's tradeoff).
function stripLineComment(line) {
  return line.replace(/\/\/.*/, '');
}

// Locates every `it(`/`test(` (with optional `.modifier`) call in `content`
// and returns `{ startLine, bodyStart, body }` for each, where `body` is the
// callback's brace-delimited text and `bodyStart` its absolute offset in
// `content` (bodyStart === -1 when no braced callback could be found — see
// header limits, e.g. `it.todo('x')`). Because `bodyStart` need not sit at
// the start of a source line (a callback typically opens `() => {` mid-
// line), a match found at offset `k` within `body` maps back to absolute
// line `lineNumberFor(lineStarts, bodyStart) + linesBefore(body, k)` — see
// scanNotTobeLiteral, the one rule that needs a line number INSIDE a body
// rather than at the block's own start line.
function findTestBlocks(content) {
  const blocks = [];
  TEST_CALL_RE.lastIndex = 0;
  let m;
  while ((m = TEST_CALL_RE.exec(content))) {
    let openParenIndex = m.index + m[0].length - 1;
    let closeParenIndex = findBalancedEnd(content, openParenIndex, '(', ')');
    if (closeParenIndex === -1) continue; // malformed — skip, don't crash

    // Curried parameterized form: `it.each([...])('desc', fn)`. The first call
    // is the each-table; the real test callback lives in the SECOND call. Without
    // this, findBalancedEnd stops at the table's `)` and the callback (outside
    // that extent) is never seen — flagging every it.each as empty/expectless.
    let after = closeParenIndex + 1;
    while (after < content.length && /\s/.test(content[after])) after += 1;
    if (content[after] === '(') {
      const secondClose = findBalancedEnd(content, after, '(', ')');
      if (secondClose !== -1) {
        openParenIndex = after;
        closeParenIndex = secondClose;
      }
    }
    const callText = content.slice(openParenIndex, closeParenIndex + 1);

    let bodyStart = -1;
    let body = '';
    const bodyMatch = CALLBACK_BODY_RE.exec(callText);
    if (bodyMatch) {
      const braceIndexInCall = bodyMatch.index + bodyMatch[0].length - 1;
      const braceOpenIndex = openParenIndex + braceIndexInCall;
      const braceCloseIndex = findBalancedEnd(content, braceOpenIndex, '{', '}');
      if (braceCloseIndex !== -1) {
        bodyStart = braceOpenIndex + 1;
        body = content.slice(bodyStart, braceCloseIndex);
      }
    }

    blocks.push({
      startIndex: m.index,
      startLine: content.slice(0, m.index).split('\n').length,
      bodyStart,
      body,
    });
    TEST_CALL_RE.lastIndex = closeParenIndex + 1;
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Rule scans.
// ---------------------------------------------------------------------------

// Matches expect(...) and both node:assert styles: bare assert(...) and the
// method forms assert.equal(...) / assert.strictEqual(...) / assert.throws(...)
// etc. Without the optional `.member`, the engine's own `node` track (node:test
// + node:assert) false-positived every well-asserted test as expectless-test.
const EXPECT_ASSERT_CALL_RE = /\b(?:expect|assert)(?:\.\w+)?\s*\(/;

const NOT_TOBE_LINE_RE = /expect\(([\w$]+(?:\.[\w$]+)+)\)\.not\.toBe\(\s*([^)]*)\)/;
const LITERAL_ARG_RE = /^(['"`][^'"`]*['"`]|-?\d+(?:\.\d+)?|true|false|null|undefined)$/;
// A "positive" assertion on the same property access: expect(X).<method>(
// where <method> isn't `not` — proves X is asserted truthy/equal somewhere
// in the block, which makes a sibling `.not.toBe(<literal>)` non-vacuous.
const POSITIVE_ASSERT_RE = /expect\(([^()]+)\)\.(?!not\.)(\w+)\(/g;

function collectPositivelyAssertedProps(blockText) {
  const positive = new Set();
  POSITIVE_ASSERT_RE.lastIndex = 0;
  let m;
  while ((m = POSITIVE_ASSERT_RE.exec(blockText))) {
    positive.add(m[1].trim());
  }
  return positive;
}

function scanNotTobeLiteral(relFile, lines, lineStarts, blocks, findings) {
  for (const block of blocks) {
    if (block.bodyStart === -1) continue; // no braced body — nothing to scan
    const positive = collectPositivelyAssertedProps(block.body);
    const baseLine = lineNumberFor(lineStarts, block.bodyStart);
    block.body.split('\n').forEach((line, k) => {
      const m = NOT_TOBE_LINE_RE.exec(stripLineComment(line));
      if (!m) return;
      const propAccess = m[1];
      const argRaw = m[2].trim();
      if (!LITERAL_ARG_RE.test(argRaw)) return; // not a literal — not this rule's concern
      if (positive.has(propAccess)) return; // asserted truthy/equal elsewhere in the same block
      const absLine = baseLine + k; // bodyStart's own line is k=0 (see findTestBlocks doc)
      findings.push({
        file: relFile,
        line: absLine,
        rule: 'not-tobe-literal',
        snippet: (lines[absLine - 1] ?? line).trim(),
      });
    });
  }
}

const TOBE_TRUE_CONSTANT_RE =
  /expect\(\s*(true|false|-?\d+(?:\.\d+)?|'[^']*'|"[^"]*")\s*\)\.toBe\(\s*(true|false|-?\d+(?:\.\d+)?|'[^']*'|"[^"]*")\s*\)/;

function scanTobeTrueConstant(relFile, lines, findings) {
  lines.forEach((line, idx) => {
    if (TOBE_TRUE_CONSTANT_RE.test(stripLineComment(line))) {
      findings.push({ file: relFile, line: idx + 1, rule: 'tobe-true-constant', snippet: line.trim() });
    }
  });
}

// Anchor `.skip` to the test constructors — a bare `\.skip\(` false-positived
// unrelated method calls (e.g. `cursor.skip(10)` pagination). Cover the `x`
// aliases including xtest (a jest-supported alias the old pattern missed).
const SKIPPED_TEST_RE = /\b(?:it|test|describe|context)\.skip\(|\bx(?:it|test|describe)\(/;

function scanSkippedTest(relFile, lines, findings) {
  lines.forEach((line, idx) => {
    if (SKIPPED_TEST_RE.test(stripLineComment(line))) {
      findings.push({ file: relFile, line: idx + 1, rule: 'skipped-test', snippet: line.trim() });
    }
  });
}

function scanEmptyAndExpectlessTests(relFile, blocks, findings) {
  for (const block of blocks) {
    const codeBody = block.body.split('\n').map(stripLineComment).join('\n');
    const trimmedBody = codeBody.trim();
    if (trimmedBody === '') {
      findings.push({
        file: relFile,
        line: block.startLine,
        rule: 'empty-test-body',
        snippet: block.snippetLine,
      });
    } else if (!EXPECT_ASSERT_CALL_RE.test(trimmedBody)) {
      findings.push({
        file: relFile,
        line: block.startLine,
        rule: 'expectless-test',
        snippet: block.snippetLine,
      });
    }
  }
}

const PROPERTY_ACCESS_RE = /expect\(([\w$]+(?:\.[\w$]+)+)\)/g;

function scanAssertOnUnknownProperty(relFile, lines, srcWords, findings) {
  if (!srcWords) return; // --src not given: rule skipped entirely
  lines.forEach((line, idx) => {
    const codeLine = stripLineComment(line);
    PROPERTY_ACCESS_RE.lastIndex = 0;
    let m;
    while ((m = PROPERTY_ACCESS_RE.exec(codeLine))) {
      const propPath = m[1];
      const prop = propPath.slice(propPath.lastIndexOf('.') + 1);
      if (!srcWords.has(prop)) {
        findings.push({
          file: relFile,
          line: idx + 1,
          rule: 'assert-on-unknown-property',
          snippet: line.trim(),
        });
      }
    }
  });
}

// Collects every identifier-shaped word appearing anywhere in --src's source
// files, for a word-boundary "does this property name exist anywhere in the
// source under test" check. Best-effort by design (brief: "heuristic grep"):
// this is NOT type-aware — it cannot tell a real export from a coincidental
// identifier of the same name, so it only catches properties that are
// genuinely absent from the source tree, never subtler mismatches.
const IDENTIFIER_RE = /[A-Za-z_$][\w$]*/g;

// Only real source is "source under test" — the test files themselves must be
// excluded from the word set, or the property a test asserts on is always
// "known" (it appears in the very file being audited) and the
// assert-on-unknown-property rule goes inert. This is the wired-path bug: the
// engine passes --src="${WORKDIR:-.}" (the project root), so the audited test
// file sits INSIDE the walk unless filtered here. Also skip non-code files
// (JSON/markdown/lockfiles) whose identifier-shaped tokens are noise.
const SOURCE_EXT_RE = /\.(?:[cm]?[jt]sx?)$/;

function collectSourceWords(srcDir) {
  const words = new Set();
  for (const file of walkAllFiles(srcDir)) {
    const norm = file.split(path.sep).join('/');
    if (TEST_FILE_RE.test(norm)) continue;
    if (!SOURCE_EXT_RE.test(norm)) continue;
    let content;
    try { content = fs.readFileSync(file, 'utf8'); } catch { continue; }
    let m;
    IDENTIFIER_RE.lastIndex = 0;
    while ((m = IDENTIFIER_RE.exec(content))) words.add(m[0]);
  }
  return words;
}

// ---------------------------------------------------------------------------
// Orchestration.
// ---------------------------------------------------------------------------

function auditFile(absPath, relFile, srcWords, findings) {
  const content = fs.readFileSync(absPath, 'utf8');
  const lines = content.split('\n');
  const lineStarts = computeLineStarts(content);
  const blocks = findTestBlocks(content).map((b) => ({
    ...b,
    snippetLine: lines[b.startLine - 1] ? lines[b.startLine - 1].trim() : '',
  }));

  scanNotTobeLiteral(relFile, lines, lineStarts, blocks, findings);
  scanTobeTrueConstant(relFile, lines, findings);
  scanSkippedTest(relFile, lines, findings);
  scanEmptyAndExpectlessTests(relFile, blocks, findings);
  scanAssertOnUnknownProperty(relFile, lines, srcWords, findings);
}

function buildReport(testFiles, srcDir) {
  const cwd = process.cwd();
  const srcWords = srcDir ? collectSourceWords(srcDir) : null;
  const findings = [];
  for (const absPath of testFiles) {
    const relFile = path.relative(cwd, absPath).split(path.sep).join('/');
    auditFile(absPath, relFile, srcWords, findings);
  }
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.rule.localeCompare(b.rule));

  const counts = {};
  for (const rule of RULES) counts[rule] = 0;
  for (const f of findings) counts[f.rule] = (counts[f.rule] || 0) + 1;

  return {
    schema: SCHEMA,
    generated_at: new Date().toISOString(),
    findings,
    counts,
  };
}

function run(args) {
  const testFiles = resolveTestPaths(args.tests);
  if (testFiles.length === 0) {
    throw new Error(`--tests resolved to zero files: ${args.tests.join(', ')}`);
  }
  if (args.src !== undefined && !isDir(args.src)) {
    throw new Error(`--src not found: ${args.src}`);
  }
  const report = buildReport(testFiles, args.src);

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
    const total = report.findings.length;
    console.log(`test-audit-static: ${total} finding(s) across ${report.findings.length ? new Set(report.findings.map((f) => f.file)).size : 0} file(s) -> ${outPath}`);
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
  isGlobPattern,
  globBase,
  globToRegExp,
  expandGlob,
  resolveTestEntry,
  resolveTestPaths,
  findBalancedEnd,
  findTestBlocks,
  collectPositivelyAssertedProps,
  collectSourceWords,
  buildReport,
  run,
};
