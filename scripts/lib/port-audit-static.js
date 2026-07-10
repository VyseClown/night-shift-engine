#!/usr/bin/env node
'use strict';

// Static audit material extractor (port-fidelity Task 7). Opens Phase B
// (port-audit): a deterministic, zero-dep pass over a single RN screen's
// design-token module + its own source file(s), producing the raw material
// (flattened token table + resolved style-property usages) that Task 8's
// agent pass reasons over — this file does no judgment, it just extracts.
// node:* builtins only — no new dependency, no package.json anywhere in the
// repo, no tsc/npm (same "best effort, documented as such" spirit as
// scripts/lib/figma-manifest.js and scripts/lib/component-inventory.js;
// this file does not require either of them — small helpers are
// intentionally re-implemented locally, per that established convention).
//
// CLI:
//   node scripts/lib/port-audit-static.js --project <repo> --scope <dir>
//     [--tokens src/ui/tokens.ts]
// Writes nothing; prints the manifest JSON to stdout:
//   { "schema": "night-shift-port-audit-material/1",
//     "tokens": { "colors.ink": "#123456", "spacing.lg": 24, "type.h1": 28 },
//     "usages": [ { "file": "src/features/sample/SampleScreen.tsx", "line": 19,
//       "property": "fontSize", "raw": "type.h1", "resolved": 28 } ] }
// Exit 0 on success, 1 with a one-line stderr reason otherwise.
//
// Token parsing: `export const <name> = { ... } as const` blocks, flattened
// one level (`colors.ink` from `export const colors = { ink: ... }`). A real
// app's tokens.ts (unlike this fixture) may spread the object literal over
// many lines, drop the trailing semicolon (ASI), use either quote style for
// string values, or carry `//`/`/* */` comments between entries — all
// tolerated here (see parseTokenGroups/parseFlatEntries below).
//
// Usage scan: within --scope, walks source files and matches style-object
// lines shaped `property: value` for a FIXED set of layout/typography
// properties (fontSize, fontWeight, fontFamily, lineHeight, letterSpacing,
// color, backgroundColor, padding*, margin*, gap, borderRadius, width,
// height). A `group.key` value (e.g. `type.h1`) resolves through the token
// table; anything else (a string/number literal, or an expression this
// best-effort line scan doesn't understand) is kept as its literal text.
// This is a line-oriented text scan, NOT a TS/JSX parser — same documented
// limitation as figma-manifest.js's node-dump parser and
// component-inventory.js's regex-based component/prop extraction.

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'night-shift-port-audit-material/1';
const DEFAULT_TOKENS_PATH = 'src/ui/tokens.ts';

const SOURCE_EXT_RE = /\.(tsx|ts|jsx|js)$/;
const IGNORE_FILE_RE = /\.(test|spec|stories|d)\.[tj]sx?$/;
const IGNORE_DIR_NAMES = new Set(['node_modules', '.git', '.night-shift', 'dist', 'build', '.next', '.expo']);

// Fixed style-property set from the task brief. padding*/margin* cover the
// directional variants (paddingTop, marginHorizontal, ...) via suffix match
// rather than an exhaustive enumeration.
const FIXED_PROPERTIES = new Set([
  'fontSize', 'fontWeight', 'fontFamily', 'lineHeight', 'letterSpacing',
  'color', 'backgroundColor', 'gap', 'borderRadius', 'width', 'height',
]);
const PADDING_MARGIN_RE = /^(padding|margin)([A-Z][A-Za-z]*)?$/;

function isTrackedProperty(name) {
  return FIXED_PROPERTIES.has(name) || PADDING_MARGIN_RE.test(name);
}

function fail(reason) {
  console.error(`port-audit-static: ${reason}`);
  process.exitCode = 1;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--project': args.project = argv[++i]; break;
      case '--scope': args.scope = argv[++i]; break;
      case '--tokens': args.tokens = argv[++i]; break;
      default: throw new Error(`unrecognized argument: ${a}`);
    }
  }
  if (!args.project) throw new Error('--project is required');
  if (!args.scope) throw new Error('--scope is required');
  return args;
}

// ---------------------------------------------------------------------------
// Small shared helpers (deliberately re-implemented here, not imported — see
// file header). Same shapes as component-inventory.js's helpers of the same
// name.
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

// Recursively lists source files under `dir`, sorted for deterministic
// output regardless of the underlying filesystem's directory-entry order.
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

// Returns the substring strictly between the balanced pair of `open`/`close`
// characters, given the index of the opening character.
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

// Removes /* block */ and // line comments — applied to a token object's
// body before splitting its entries, so a comment between two token keys
// doesn't glue itself onto a neighboring entry.
function stripComments(str) {
  return str.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

// Splits `str` on a single delimiter char at depth 0 only: commas inside
// nested {}/()/[] or inside a quoted string don't split (a token value could
// in principle be a quoted string containing a comma).
function splitTopLevel(str, delimiter) {
  const parts = [];
  let depth = 0;
  let start = 0;
  let quote = null;
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (quote) {
      if (c === '\\') { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; continue; }
    if (c === '{' || c === '(' || c === '[') depth++;
    else if (c === '}' || c === ')' || c === ']') depth--;
    else if (depth === 0 && c === delimiter) {
      parts.push(str.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(str.slice(start));
  return parts.map((p) => p.trim()).filter(Boolean);
}

// A scalar token value: single- or double-quoted string, integer/decimal
// number, or (fallback) the raw trimmed text unchanged.
function parseScalarValue(raw) {
  const singleQuoted = raw.match(/^'([^']*)'$/);
  if (singleQuoted) return singleQuoted[1];
  const doubleQuoted = raw.match(/^"([^"]*)"$/);
  if (doubleQuoted) return doubleQuoted[1];
  if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
  return raw;
}

// One level of `{ key: value, ... }` entries -> [[key, scalarValue], ...].
function parseFlatEntries(body) {
  const cleaned = stripComments(body);
  const entries = [];
  for (const part of splitTopLevel(cleaned, ',')) {
    const m = part.match(/^['"]?([A-Za-z_$][\w$]*)['"]?\s*:\s*([\s\S]+)$/);
    if (!m) continue;
    entries.push([m[1], parseScalarValue(m[2].trim())]);
  }
  return entries;
}

// ---------------------------------------------------------------------------
// Token parsing: `export const <name> = { ... } as const` blocks.
// ---------------------------------------------------------------------------

// Tolerant of: multi-line object bodies, comments inside the body (stripped
// by parseFlatEntries), a missing trailing semicolon (ASI — the "as const"
// check only looks at the text immediately after the closing brace, not at
// what follows it), and either quote style for string values.
function parseTokenGroups(content) {
  const tokens = {};
  const re = /export\s+const\s+([A-Za-z_$][\w$]*)\s*=\s*\{/g;
  let m;
  while ((m = re.exec(content))) {
    const name = m[1];
    const openIndex = m.index + m[0].length - 1;
    const body = extractBalanced(content, openIndex, '{', '}');
    const afterIndex = openIndex + body.length + 2; // past the closing '}'
    const rest = content.slice(afterIndex);
    if (!/^\s*as\s+const\s*;?/.test(rest)) continue; // not a token block
    for (const [key, value] of parseFlatEntries(body)) {
      tokens[`${name}.${key}`] = value;
    }
    re.lastIndex = afterIndex;
  }
  return tokens;
}

// ---------------------------------------------------------------------------
// Usage scan.
// ---------------------------------------------------------------------------

const KV_LINE_RE = /^\s*['"]?([A-Za-z_$][\w$]*)['"]?\s*:\s*(.+?),?\s*$/;

// `group.key` (e.g. `type.h1`) resolves through the token table; a quoted
// string or bare number literal resolves to itself; anything else (an
// expression this line scan doesn't understand) is returned unresolved —
// the raw text stands in for both fields.
function resolveValue(raw, tokens) {
  const tokenRef = raw.match(/^([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)$/);
  if (tokenRef) {
    const key = `${tokenRef[1]}.${tokenRef[2]}`;
    if (Object.prototype.hasOwnProperty.call(tokens, key)) return tokens[key];
  }
  return parseScalarValue(raw);
}

function scanFileUsages(filePath, relFile, tokens) {
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  const usages = [];
  lines.forEach((rawLine, idx) => {
    const line = rawLine.replace(/\/\/.*/, '');
    const m = KV_LINE_RE.exec(line);
    if (!m) return;
    const property = m[1];
    if (!isTrackedProperty(property)) return;
    const raw = m[2].trim();
    if (!raw) return;
    usages.push({
      file: relFile,
      line: idx + 1,
      property,
      raw,
      resolved: resolveValue(raw, tokens),
    });
  });
  return usages;
}

function buildMaterial(projectRoot, scope, tokensPath) {
  const tokensFile = path.resolve(projectRoot, tokensPath);
  if (!fs.existsSync(tokensFile)) throw new Error(`--tokens not found: ${tokensPath}`);
  const tokens = parseTokenGroups(fs.readFileSync(tokensFile, 'utf8'));

  const scopeDir = path.resolve(projectRoot, scope);
  if (!isDir(scopeDir)) throw new Error(`--scope not found: ${scope}`);

  const usages = [];
  for (const file of walkSourceFiles(scopeDir)) {
    if (path.resolve(file) === tokensFile) continue; // token defs aren't usages
    const relFile = path.relative(projectRoot, file).split(path.sep).join('/');
    usages.push(...scanFileUsages(file, relFile, tokens));
  }

  return { schema: SCHEMA, tokens, usages };
}

function run(args) {
  const projectRoot = path.resolve(args.project);
  if (!isDir(projectRoot)) throw new Error(`--project not found: ${args.project}`);
  const tokensPath = args.tokens || DEFAULT_TOKENS_PATH;
  return buildMaterial(projectRoot, args.scope, tokensPath);
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
    const material = run(args);
    console.log(JSON.stringify(material, null, 2));
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
  extractBalanced,
  splitTopLevel,
  parseScalarValue,
  parseFlatEntries,
  parseTokenGroups,
  isTrackedProperty,
  resolveValue,
  walkSourceFiles,
  scanFileUsages,
  buildMaterial,
};
