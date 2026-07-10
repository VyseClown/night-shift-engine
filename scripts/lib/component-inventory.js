#!/usr/bin/env node
'use strict';

// Component inventory extractor (port-fidelity Task 5). Opens Phase C
// (component-reuse gate): walks a target app's component directories,
// extracts one entry per exported capitalized function/const component per
// file (name, source-relative file, best-effort props, cross-project usage
// count), and writes a single JSON inventory that Task 6 diffs a Figma/web
// design manifest's element list against to flag "you already have a
// component for this, reuse it" before a spec proposes a brand-new one.
// node:* builtins only — no new dependency, no package.json anywhere in the
// repo, no tsc/npm (this is regex/text based, same "best effort, documented
// as such" spirit as scripts/lib/figma-manifest.js's node-dump parser).
//
// CLI:
//   node scripts/lib/component-inventory.js --project <repo>
//     [--dirs 'glob1,glob2'] [--out <file>]
// Writes <out> (default <project>/.night-shift/component-inventory.json):
//   { "schema": "night-shift-component-inventory/1", "generatedAt": "<iso>",
//     "components": [ { "name": "Badge", "file": "src/ui/components/Badge.tsx",
//       "props": ["label", "tone"], "usageCount": 2 } ] }
// Exit 0 on success, 1 with a one-line stderr reason otherwise.
//
// --dirs precedence: --dirs > NIGHT_SHIFT_COMPONENT_DIRS (comma-separated) >
// defaults (src/ui/components, src/components, src/features/*/components —
// a single '*' path segment is expanded against the directories actually
// present, non-recursively per segment). Each resolved components dir is
// then walked recursively for .ts/.tsx/.js/.jsx files (excluding
// .test./.spec./.stories. and .d.ts files).
//
// Prop extraction (best effort, NOT a type-checker): for each component,
// first look for a `type <Name>Props = { ... }` or `interface <Name>Props
// { ... }` declaration anywhere in the same file and collect its top-level
// keys; if neither exists, fall back to the component's own destructured
// parameter object `({ a, b }: ...)` (a bare, non-destructured parameter
// like `(props: { title: string })` yields no props — this is intentionally
// shallow, not a TS parser).
//
// usageCount counts *importing files* (not JSX occurrences): every file
// under <project>/src whose import line(s) contain the component name as a
// whole word, minus the component's own defining file.
//
// Component detection also covers default exports (a Task 5 review found the
// plain export-function/export-const regexes drop these, which would let a
// default-exported component slip past Task 6's reuse gate undetected):
//   export default function Name(...) { ... }   -- same paren-terminated
//                                                   extraction as a named
//                                                   export-function.
//   export default Name;                        -- bare identifier; props are
//                                                   recovered (best effort)
//                                                   from a same-file `function
//                                                   Name(` / `const Name = (`
//                                                   declaration if one exists,
//                                                   else empty.
//
// ... and HOC-wrapped const exports (a live run against a real RN app found
// these hid its most-reused components from the inventory):
//   export const Name = memo(function Name({...}: Props) { ... })
//   export const Name = forwardRef((props, ref) => ...)
//   export const Name = memo(forwardRef(...)), React.memo(...) variants
// The wrapped inner function's own parameter list is the props source (same
// Props-type-first, destructured-params-fallback extraction as everywhere
// else). A bare identifier wrap (`memo(Name)`) stays undetected.
//
// Two flags used by Task 6's reuse gate (scripts/night-shift.sh's
// check_component_reuse), CALLED DIRECTLY on this js — the CLI wrapper
// (component-inventory.sh) does not forward them, it only builds the full
// inventory:
//   --single-file <file>     print the exported component names of one file,
//                             one per line (skips the directory walk and
//                             usage-count pass entirely; no --project needed).
//   --closest <name> --inventory <file>
//                             read the night-shift-component-inventory/1 JSON
//                             at <file> and print the component name with the
//                             smallest case-insensitive Levenshtein distance
//                             to <name> (empty stdout if the inventory has no
//                             components).

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'night-shift-component-inventory/1';
const DEFAULT_DIRS = ['src/ui/components', 'src/components', 'src/features/*/components'];
const SOURCE_EXT_RE = /\.(tsx|ts|jsx|js)$/;
const IGNORE_FILE_RE = /\.(test|spec|stories|d)\.[tj]sx?$/;
const IGNORE_DIR_NAMES = new Set(['node_modules', '.git', '.night-shift', 'dist', 'build', '.next', '.expo']);

function fail(reason) {
  console.error(`component-inventory: ${reason}`);
  process.exitCode = 1;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--project': args.project = argv[++i]; break;
      case '--dirs': args.dirs = argv[++i]; break;
      case '--out': args.out = argv[++i]; break;
      case '--single-file': args.singleFile = argv[++i]; break;
      case '--closest': args.closest = argv[++i]; break;
      case '--inventory': args.inventory = argv[++i]; break;
      default: throw new Error(`unrecognized argument: ${a}`);
    }
  }
  // --project is only required for the full directory-walk build; --single-file
  // and --closest each operate on an explicit file argument instead.
  if (!args.project && args.singleFile === undefined && args.closest === undefined) {
    throw new Error('--project is required');
  }
  if (args.closest !== undefined && !args.inventory) {
    throw new Error('--closest requires --inventory <file>');
  }
  return args;
}

// ---------------------------------------------------------------------------
// Dir-glob resolution: only a single '*' path segment is supported (matches
// the one shape the defaults need — "src/features/*/components"), expanded
// against whatever directories actually exist on disk. Fixed segments must
// exist as directories or the whole pattern contributes nothing (silently —
// a project without src/components is normal, not an error).
// ---------------------------------------------------------------------------

function globSegmentToRegExp(segment) {
  const escaped = segment.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  return new RegExp(`^${escaped}$`);
}

function expandPattern(baseDir, segments) {
  if (segments.length === 0) {
    return isDir(baseDir) ? [baseDir] : [];
  }
  const [segment, ...rest] = segments;
  if (!segment.includes('*')) {
    return expandPattern(path.join(baseDir, segment), rest);
  }
  if (!isDir(baseDir)) return [];
  const re = globSegmentToRegExp(segment);
  const entries = safeReaddir(baseDir)
    .filter((e) => e.isDirectory() && re.test(e.name))
    .map((e) => e.name)
    .sort();
  return entries.flatMap((name) => expandPattern(path.join(baseDir, name), rest));
}

function resolveComponentDirs(projectRoot, dirsSpec) {
  const patterns = dirsSpec
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean);
  const dirs = [];
  const seen = new Set();
  for (const pattern of patterns) {
    const segments = pattern.split('/').filter(Boolean);
    for (const dir of expandPattern(projectRoot, segments)) {
      if (seen.has(dir)) continue;
      seen.add(dir);
      dirs.push(dir);
    }
  }
  return dirs;
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function safeReaddir(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

// Recursively lists source files under `dir`, skipping ignored dir names and
// test/story/declaration files. Sorted for deterministic output regardless
// of the underlying filesystem's directory-entry order.
function walkSourceFiles(dir) {
  const out = [];
  const entries = safeReaddir(dir).sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (IGNORE_DIR_NAMES.has(entry.name)) continue;
      out.push(...walkSourceFiles(full));
    } else if (entry.isFile() && SOURCE_EXT_RE.test(entry.name) && !IGNORE_FILE_RE.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Component + prop extraction (regex-based, best effort — see file header).
// ---------------------------------------------------------------------------

// Returns the substring strictly between the balanced pair of `open`/`close`
// characters, given the index of the opening character. Needed because prop
// bodies and parameter lists can themselves contain nested {}/() (e.g. a
// union type or a default-value call) that a naive "up to the next close
// char" scan would truncate early.
function extractBalanced(str, openIndex, open, close) {
  let depth = 0;
  for (let i = openIndex; i < str.length; i++) {
    if (str[i] === open) depth++;
    else if (str[i] === close) {
      depth--;
      if (depth === 0) return str.slice(openIndex + 1, i);
    }
  }
  return '';
}

// Splits `str` on `delimiters` (a string of single chars) at depth 0 only —
// commas/semicolons inside nested {}/()/[] don't split. Used for both
// interface/type member lists and destructured-parameter lists. An `=>`
// arrow's '>' is NOT a closing angle bracket (a function-typed member like
// `onChange: (p: P) => void` would otherwise drive the depth negative and
// stop every later member from splitting — found live on a real app's
// Props interfaces).
function splitTopLevel(str, delimiters) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (c === '>' && str[i - 1] === '=') continue; // `=>` arrow, not a bracket
    if (c === '{' || c === '(' || c === '[' || c === '<') depth++;
    else if (c === '}' || c === ')' || c === ']' || c === '>') depth--;
    else if (depth === 0 && delimiters.includes(c)) {
      parts.push(str.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(str.slice(start));
  return parts.map((p) => p.trim()).filter(Boolean);
}

// Removes /* block */ and // line comments. Applied to a Props type body
// before member splitting: a doc comment between members otherwise glues
// itself onto the FOLLOWING member ("/** why */\n  hasData: boolean" fails
// memberKey and the real member silently vanishes — found live on a real
// app whose Props interfaces are doc-commented per field).
function stripComments(str) {
  return str.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

// One member of a `type X = { ... }` / `interface X { ... }` body, e.g.
// `tone?: 'info' | 'warn'` or `padded: boolean` -> the key name before the
// (optional-marker +) colon; also TS method shorthand (`onChange(p): void`),
// whose key ends at '(' instead. Members with neither (rare in practice;
// e.g. a bare `extends` clause fragment) are skipped rather than guessed at.
function memberKey(member) {
  const m = member.match(/^['"]?([A-Za-z_$][\w$]*)['"]?\s*\??\s*[(:]/);
  return m ? m[1] : null;
}

function propsFromTypeBody(content, name) {
  const re = new RegExp(`(?:type\\s+${name}Props\\s*=\\s*|interface\\s+${name}Props\\s*)\\{`);
  const m = re.exec(content);
  if (!m) return null;
  const openIndex = m.index + m[0].length - 1;
  const body = extractBalanced(content, openIndex, '{', '}');
  return splitTopLevel(stripComments(body), ';,')
    .map(memberKey)
    .filter((k) => k !== null);
}

// Fallback when no named Props type/interface exists: the component's own
// destructured parameter object, e.g. `({ label, tone }: BadgeProps)` ->
// ["label", "tone"]. A non-destructured parameter (`props: { title: string
// }`) is NOT unwrapped here — this is a params-list scan, not a type parser,
// so it intentionally yields no props (documented in the file header).
function propsFromDestructuredParams(paramsStr) {
  const trimmed = paramsStr.trim();
  if (!trimmed.startsWith('{')) return [];
  const body = extractBalanced(trimmed, 0, '{', '}');
  return splitTopLevel(body, ',')
    .filter((entry) => !entry.startsWith('...'))
    .map((entry) => entry.split(/[:=]/)[0].trim())
    .filter(Boolean);
}

function extractProps(content, name, paramsStr) {
  const fromType = propsFromTypeBody(content, name);
  if (fromType !== null) return fromType;
  return propsFromDestructuredParams(paramsStr);
}

const EXPORT_FUNCTION_RE = /export\s+function\s+([A-Z][A-Za-z0-9_]*)\s*\(/g;
const EXPORT_CONST_RE = /export\s+const\s+([A-Z][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*(?:function\s*[A-Za-z0-9_]*\s*)?\(/g;
// `export const <Name> = memo(function <anything>(` and friends — a live
// verification against a real RN app found its MOST-reused components (all
// `export const X = memo(function X({...}: XProps) {...})`) were invisible to
// EXPORT_CONST_RE, whose `=\s*(?:function ...)?\(` requires the paren right
// after the `=`. This pattern additionally skips one or more HOC wrapper
// calls — `memo(`, `forwardRef(`, `React.memo(`, and the nested
// `memo(forwardRef(` — before the same inner shape (optional named/anonymous
// `function`, then the opening paren of the real parameter list). The match
// still ends in that inner '(' so the shared parenTerminated extraction reads
// the wrapped component's own params (`({ label, active }: Props)` or
// forwardRef's `(props, ref)`), to which the usual XProps-type-first,
// destructured-params-fallback prop extraction applies unchanged. A bare
// identifier wrap (`export const X = memo(Y)`) has no parameter list here
// and stays undetected — best effort, like the rest of this file.
const EXPORT_CONST_WRAPPED_RE = /export\s+const\s+([A-Z][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*(?:(?:React\s*\.\s*)?(?:memo|forwardRef)\s*\(\s*)+(?:function\s*[A-Za-z0-9_]*\s*)?\(/g;
// `export default function Name(` — same paren-terminated shape as
// EXPORT_FUNCTION_RE, just with the `default` keyword in between.
const EXPORT_DEFAULT_FUNCTION_RE = /export\s+default\s+function\s+([A-Z][A-Za-z0-9_]*)\s*\(/g;
// `export default Name;` (or `export default Name` at EOF) — a bare
// identifier reference, not a declaration; the next token after `default`
// being lowercase (`function`, `class`, `{`, ...) never matches the
// capitalized-identifier class, so this never collides with the pattern above.
const EXPORT_DEFAULT_NAME_RE = /export\s+default\s+([A-Z][A-Za-z0-9_]*)\s*;?/g;

// Patterns tried in order; `parenTerminated` says whether the match itself
// ends in the component's opening '(' (so `re.lastIndex - 1` is that paren's
// index, from which extractBalanced reads the full, possibly multi-line,
// possibly nested parameter list) or whether it is a bare identifier that
// needs a separate lookup (findLooseDeclarationParams) to find any params.
const COMPONENT_PATTERNS = [
  { re: EXPORT_FUNCTION_RE, parenTerminated: true },
  { re: EXPORT_CONST_RE, parenTerminated: true },
  { re: EXPORT_CONST_WRAPPED_RE, parenTerminated: true },
  { re: EXPORT_DEFAULT_FUNCTION_RE, parenTerminated: true },
  { re: EXPORT_DEFAULT_NAME_RE, parenTerminated: false },
];

// Best-effort parameter lookup for a bare `export default Name;` reference:
// finds a same-file `function Name(` or `const Name = (...)` declaration
// (NOT required to itself be exported) and returns its raw parameter-list
// text, or '' if no such declaration is found (component is still recorded,
// just with no recoverable props — same "best effort" spirit as the rest of
// this file).
function findLooseDeclarationParams(content, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const funcRe = new RegExp(`\\bfunction\\s+${escaped}\\s*\\(`);
  let m = funcRe.exec(content);
  if (!m) {
    // Same optional HOC-wrapper skip as EXPORT_CONST_WRAPPED_RE, so a bare
    // `export default Name;` referencing `const Name = memo(function ...)`
    // still recovers the wrapped component's own parameter list.
    const constRe = new RegExp(`\\bconst\\s+${escaped}\\s*(?::[^=]+)?=\\s*(?:(?:React\\s*\\.\\s*)?(?:memo|forwardRef)\\s*\\(\\s*)*(?:function\\s*[A-Za-z0-9_]*\\s*)?\\(`);
    m = constRe.exec(content);
  }
  if (!m) return '';
  const openIndex = m.index + m[0].length - 1;
  return extractBalanced(content, openIndex, '(', ')');
}

// One component per exported capitalized function/const per file (per the
// task brief), including default exports (see COMPONENT_PATTERNS above).
function extractComponentsFromFile(content) {
  const found = [];
  const seenNames = new Set();
  for (const { re, parenTerminated } of COMPONENT_PATTERNS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(content))) {
      const name = m[1];
      if (seenNames.has(name)) continue; // don't double-count re-declarations
      seenNames.add(name);
      const paramsStr = parenTerminated
        ? extractBalanced(content, re.lastIndex - 1, '(', ')')
        : findLooseDeclarationParams(content, name);
      found.push({ name, props: extractProps(content, name, paramsStr) });
    }
  }
  return found;
}

// ---------------------------------------------------------------------------
// Usage counting: importing FILES (not JSX occurrences) across
// <project>/src, excluding the component's own file. Literal grep-style
// match on import lines, per the task brief — not an import-specifier AST.
// ---------------------------------------------------------------------------

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function computeUsageCount(name, ownFile, allFileContents) {
  const nameRe = new RegExp(`\\b${escapeRegExp(name)}\\b`);
  let count = 0;
  for (const [file, content] of allFileContents) {
    if (file === ownFile) continue;
    const importingLine = content
      .split('\n')
      .some((line) => /\bimport\b/.test(line) && nameRe.test(line));
    if (importingLine) count++;
  }
  return count;
}

function buildInventory(projectRoot, dirsSpec) {
  const componentDirs = resolveComponentDirs(projectRoot, dirsSpec);
  const componentFiles = [];
  const seenFiles = new Set();
  for (const dir of componentDirs) {
    for (const file of walkSourceFiles(dir)) {
      if (seenFiles.has(file)) continue;
      seenFiles.add(file);
      componentFiles.push(file);
    }
  }

  const srcRoot = path.join(projectRoot, 'src');
  const allSourceFiles = isDir(srcRoot) ? walkSourceFiles(srcRoot) : [];
  const allFileContents = allSourceFiles.map((f) => [f, fs.readFileSync(f, 'utf8')]);
  const contentByFile = new Map(allFileContents);

  const components = [];
  for (const file of componentFiles) {
    const content = contentByFile.get(file) ?? fs.readFileSync(file, 'utf8');
    for (const { name, props } of extractComponentsFromFile(content)) {
      components.push({
        name,
        file: path.relative(projectRoot, file).split(path.sep).join('/'),
        props,
        usageCount: computeUsageCount(name, file, allFileContents),
      });
    }
  }
  components.sort((a, b) => a.name.localeCompare(b.name) || a.file.localeCompare(b.file));

  return {
    schema: SCHEMA,
    generatedAt: new Date().toISOString(),
    components,
  };
}

function run(args) {
  const projectRoot = path.resolve(args.project);
  if (!isDir(projectRoot)) throw new Error(`--project not found: ${args.project}`);
  const dirsSpec = args.dirs || process.env.NIGHT_SHIFT_COMPONENT_DIRS || DEFAULT_DIRS.join(',');
  const out = args.out ? path.resolve(args.out) : path.join(projectRoot, '.night-shift', 'component-inventory.json');

  const inventory = buildInventory(projectRoot, dirsSpec);

  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(inventory, null, 2) + '\n');
  return out;
}

// --single-file: one exported component name per line (no directory walk, no
// usage-count pass — just this file's own extraction).
function componentNamesInFile(filePath) {
  const content = fs.readFileSync(path.resolve(filePath), 'utf8');
  return extractComponentsFromFile(content).map((c) => c.name);
}

// --closest: classic Wagner–Fischer edit distance, case-insensitive (a
// full-width DP table — inventories are small enough that this need not be
// space-optimized for readability's sake, but a rolling single row keeps it
// linear in memory since a component name can legitimately run long).
function levenshteinDistance(a, b) {
  a = String(a).toLowerCase();
  b = String(b).toLowerCase();
  const m = a.length, n = b.length;
  const row = new Array(n + 1);
  for (let j = 0; j <= n; j++) row[j] = j;
  for (let i = 1; i <= m; i++) {
    let prevDiag = row[0];
    row[0] = i;
    for (let j = 1; j <= n; j++) {
      const tmp = row[j];
      row[j] = a[i - 1] === b[j - 1] ? prevDiag : 1 + Math.min(prevDiag, row[j], row[j - 1]);
      prevDiag = tmp;
    }
  }
  return row[n];
}

// The inventory component name with the smallest case-insensitive Levenshtein
// distance to `name`; '' when `components` is empty. Ties keep the first
// (lowest name.file sort order, since buildInventory sorts its output before
// writing) rather than the arbitrary last — deterministic across runs.
function closestComponentName(name, components) {
  if (!Array.isArray(components) || components.length === 0) return '';
  let best = components[0].name;
  let bestDist = levenshteinDistance(name, best);
  for (const c of components.slice(1)) {
    const d = levenshteinDistance(name, c.name);
    if (d < bestDist) {
      bestDist = d;
      best = c.name;
    }
  }
  return best;
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
    if (args.singleFile !== undefined) {
      for (const name of componentNamesInFile(args.singleFile)) console.log(name);
      return;
    }
    if (args.closest !== undefined) {
      const raw = JSON.parse(fs.readFileSync(path.resolve(args.inventory), 'utf8'));
      const best = closestComponentName(args.closest, raw.components);
      if (best) console.log(best);
      return;
    }
    const out = run(args);
    console.log(out);
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
  resolveComponentDirs,
  walkSourceFiles,
  extractBalanced,
  splitTopLevel,
  extractProps,
  extractComponentsFromFile,
  computeUsageCount,
  buildInventory,
  componentNamesInFile,
  levenshteinDistance,
  closestComponentName,
  DEFAULT_DIRS,
};
