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
// Reserved for Task 6 (not implemented here — Task 6 wires these against
// this same inventory JSON):
//   --single-file <file>   emit just the exported component names of one
//                           file, one per line (skips the directory walk
//                           and usage-count pass entirely).
//   --closest <name>       given the inventory, print the inventory
//                           component name with the smallest case-insensitive
//                           Levenshtein distance to <name>.

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
      // Reserved for Task 6 — accepted here only so a shared parseArgs can
      // grow into them without a breaking CLI change; not acted on yet.
      case '--single-file': args.singleFile = argv[++i]; break;
      case '--closest': args.closest = argv[++i]; break;
      default: throw new Error(`unrecognized argument: ${a}`);
    }
  }
  if (!args.project) throw new Error('--project is required');
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
// interface/type member lists and destructured-parameter lists.
function splitTopLevel(str, delimiters) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
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

// One member of a `type X = { ... }` / `interface X { ... }` body, e.g.
// `tone?: 'info' | 'warn'` or `padded: boolean` -> the key name before the
// (optional-marker +) colon. Members with no colon (rare in practice; e.g. a
// bare `extends` clause fragment) are skipped rather than guessed at.
function memberKey(member) {
  const m = member.match(/^['"]?([A-Za-z_$][\w$]*)['"]?\s*\??\s*:/);
  return m ? m[1] : null;
}

function propsFromTypeBody(content, name) {
  const re = new RegExp(`(?:type\\s+${name}Props\\s*=\\s*|interface\\s+${name}Props\\s*)\\{`);
  const m = re.exec(content);
  if (!m) return null;
  const openIndex = m.index + m[0].length - 1;
  const body = extractBalanced(content, openIndex, '{', '}');
  return splitTopLevel(body, ';,')
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

// One component per exported capitalized function/const per file (per the
// task brief). Both regexes end in a literal '(' so `re.lastIndex - 1` is
// always that opening paren's index, from which extractBalanced reads the
// full (possibly multi-line, possibly nested) parameter list.
function extractComponentsFromFile(content) {
  const found = [];
  const seenNames = new Set();
  for (const re of [EXPORT_FUNCTION_RE, EXPORT_CONST_RE]) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(content))) {
      const name = m[1];
      if (seenNames.has(name)) continue; // don't double-count re-declarations
      seenNames.add(name);
      const openParenIndex = re.lastIndex - 1;
      const paramsStr = extractBalanced(content, openParenIndex, '(', ')');
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

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    fail(err.message);
    return;
  }
  try {
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
  DEFAULT_DIRS,
};
