#!/usr/bin/env node
'use strict';

// Figma-mode design extractor (port-fidelity Task 3). Parses the committed
// node-dump grammar produced by the Figma MCP server (a plain-text node tree
// + a YAML-subset globals file of layout/fill/style/effect references) into
// the SAME design manifest schema (night-shift-design-manifest/1) that
// scripts/lib/cdp-extract.js (Task 2, web mode) produces — so Task 4 can
// diff the two directly. node:* builtins only — no new dependency, no
// package.json anywhere in the repo. This file does not require or modify
// cdp-extract.js; the small id/slug/rollup helpers below intentionally
// mirror its conventions (documented inline) rather than importing them.
//
// CLI:
//   node scripts/lib/figma-manifest.js --nodes <screen.txt> --globals <_global-vars.txt>
//     --screen <name> --out <dir>
// Writes <out>/<screen>.json (manifest schema above, source.kind:"figma",
// unit:"pt"). Exit 0 on success, 1 with a one-line stderr reason otherwise.
// No chrome, no network, no simulator — pure text parsing, so its fixture
// test runs unconditionally.

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'night-shift-design-manifest/1';

// Node-dump line grammar (from the task brief, used verbatim):
//   [<TYPE>] "<optional name>" #<id> key=value key=value ...
const NODE_LINE_RE = /^(\s*)\[([A-Z-]+)\](?: "([^"]*)")? #(\S+)(.*)$/;

function fail(reason) {
  console.error(`figma-manifest: ${reason}`);
  process.exitCode = 1;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--nodes': args.nodes = argv[++i]; break;
      case '--globals': args.globals = argv[++i]; break;
      case '--screen': args.screen = argv[++i]; break;
      case '--out': args.out = argv[++i]; break;
      default: throw new Error(`unrecognized argument: ${a}`);
    }
  }
  if (!args.nodes) throw new Error('--nodes is required');
  if (!args.globals) throw new Error('--globals is required');
  if (!args.screen) throw new Error('--screen is required');
  if (!args.out) throw new Error('--out is required');
  return args;
}

// ---------------------------------------------------------------------------
// Globals parser: YAML-subset (no anchors, no flow maps other than the
// literal empty '{}'). Top-level keys (layout_*/fill_*/style_*/effect_*) map
// to either a nested 2-space-indented map, or a list of quoted-string
// scalars ('- '#FFFFFF''). Values are numbers, single/double-quoted
// strings, or bare words (e.g. 'none', '36px'). Generic indentation-based
// recursive descent — does not hardcode any specific key name, since the
// brief notes real dumps use hashed key names (layout_663d74ca: etc).
// ---------------------------------------------------------------------------

function indentOf(line) {
  const m = line.match(/^( *)/);
  return m[1].length;
}

function parseYamlScalar(raw) {
  const v = raw.trim();
  if (v === '{}') return {};
  if (v === '') return null;
  const singleQuoted = v.match(/^'(.*)'$/);
  if (singleQuoted) return singleQuoted[1];
  const doubleQuoted = v.match(/^"(.*)"$/);
  if (doubleQuoted) return doubleQuoted[1];
  if (/^-?\d+$/.test(v)) return parseInt(v, 10);
  if (/^-?\d+\.\d+$/.test(v)) return parseFloat(v);
  return v;
}

// Parses one map-or-list block starting at lines[idx], where every line
// belonging to the block is indented >= `indent` spaces. Returns
// [value, nextIndex]. A block is a list when its first non-blank line
// starts with '- '; otherwise it's a `key: value` map, where an empty
// `value` means "the block nests one level deeper, starting on the next
// line" (recursion).
function parseYamlBlock(lines, idx, indent) {
  while (idx < lines.length && lines[idx].trim() === '') idx++;
  if (idx >= lines.length || indentOf(lines[idx]) < indent) return [null, idx];

  if (lines[idx].trim().startsWith('- ')) {
    const arr = [];
    while (idx < lines.length) {
      if (lines[idx].trim() === '') { idx++; continue; }
      if (indentOf(lines[idx]) < indent) break;
      const trimmed = lines[idx].trim();
      if (!trimmed.startsWith('- ')) break;
      arr.push(parseYamlScalar(trimmed.slice(2)));
      idx++;
    }
    return [arr, idx];
  }

  const obj = {};
  while (idx < lines.length) {
    if (lines[idx].trim() === '') { idx++; continue; }
    if (indentOf(lines[idx]) < indent) break;
    if (indentOf(lines[idx]) > indent) break; // malformed indent jump; stop defensively
    const m = lines[idx].match(/^ *([^:]+):\s*(.*)$/);
    if (!m) { idx++; continue; }
    const key = m[1].trim();
    const rest = m[2];
    idx++;
    if (rest.trim() === '') {
      const [val, nextIdx] = parseYamlBlock(lines, idx, indent + 2);
      obj[key] = val;
      idx = nextIdx;
    } else {
      obj[key] = parseYamlScalar(rest);
    }
  }
  return [obj, idx];
}

function parseGlobals(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const [root] = parseYamlBlock(lines, 0, 0);
  return root || {};
}

// ---------------------------------------------------------------------------
// Node-dump parser: tokenizer (NODE_LINE_RE) + an attribute splitter that
// respects quoted strings and balanced {} (needed because inline layout
// JSON like {"dimensions":{"width":220,"height":32}} contains nested braces
// and colons that a naive split(' ') would mangle), + an indent-based tree
// builder (2 spaces per level, per the brief).
// ---------------------------------------------------------------------------

function parseAttrs(str) {
  const attrs = {};
  let i = 0;
  const n = str.length;
  while (i < n) {
    while (i < n && str[i] === ' ') i++;
    if (i >= n) break;
    const keyStart = i;
    while (i < n && str[i] !== '=') i++;
    if (i >= n) break;
    const key = str.slice(keyStart, i).trim();
    i++; // skip '='
    let value;
    if (str[i] === '"') {
      i++;
      const start = i;
      while (i < n && str[i] !== '"') {
        if (str[i] === '\\') i++;
        i++;
      }
      value = str.slice(start, i);
      i++; // skip closing quote
    } else if (str[i] === '{') {
      const start = i;
      let depth = 0;
      while (i < n) {
        if (str[i] === '"') {
          i++;
          while (i < n && str[i] !== '"') {
            if (str[i] === '\\') i++;
            i++;
          }
          i++;
          continue;
        }
        if (str[i] === '{') depth++;
        else if (str[i] === '}') {
          depth--;
          i++;
          if (depth === 0) break;
          continue;
        }
        i++;
      }
      value = str.slice(start, i);
    } else {
      const start = i;
      while (i < n && str[i] !== ' ') i++;
      value = str.slice(start, i);
    }
    attrs[key] = value;
  }
  return attrs;
}

function parseNodesFile(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n').filter((l) => l.trim() !== '');
  const flat = lines.map((line) => {
    const m = line.match(NODE_LINE_RE);
    if (!m) throw new Error(`unrecognized node line: ${JSON.stringify(line)}`);
    return {
      indent: m[1].length,
      type: m[2],
      name: m[3] !== undefined ? m[3] : null,
      id: m[4],
      attrs: parseAttrs(m[5] || ''),
      children: [],
    };
  });

  const roots = [];
  const stack = []; // [{indent, node}]
  for (const node of flat) {
    while (stack.length && stack[stack.length - 1].indent >= node.indent) stack.pop();
    if (stack.length === 0) roots.push(node);
    else stack[stack.length - 1].node.children.push(node);
    stack.push({ indent: node.indent, node });
  }
  return roots;
}

// ---------------------------------------------------------------------------
// Attribute resolution: `layout=`/`fills=`/`textStyle=` values are either an
// inline JSON object or a bare global-ref key looked up in the globals map;
// `borderRadius=8px` is always a literal.
// ---------------------------------------------------------------------------

function resolveLayout(node, globals) {
  const raw = node.attrs.layout;
  if (raw === undefined) return { location: { x: 0, y: 0 }, dimensions: null };
  const obj = raw.startsWith('{') ? JSON.parse(raw) : globals[raw];
  if (!obj) return { location: { x: 0, y: 0 }, dimensions: null };
  const loc = obj.locationRelativeToParent || { x: 0, y: 0 };
  const dims = obj.dimensions || null;
  return {
    location: { x: Number(loc.x) || 0, y: Number(loc.y) || 0 },
    dimensions: dims ? { width: Number(dims.width), height: Number(dims.height) } : null,
  };
}

function resolveFill(node, globals) {
  const raw = node.attrs.fills;
  if (raw === undefined) return null;
  const arr = globals[raw];
  if (!Array.isArray(arr) || !arr.length) return null;
  // Figma dumps carry uppercase hex (#30437A); the web extractor
  // (cdp-extract.js) emits lowercase — normalize here so figma- and web-mode
  // manifests (element color/background and, downstream, the rollup palette)
  // compare byte-equal without a case-folding pass in Task 4's comparator.
  return typeof arr[0] === 'string' ? arr[0].toLowerCase() : arr[0];
}

function resolveTextStyle(node, globals) {
  const raw = node.attrs.textStyle;
  if (raw === undefined) return null;
  const style = globals[raw];
  if (!style) return null;
  const lineHeight = typeof style.lineHeight === 'string' ? parseFloat(style.lineHeight) : style.lineHeight;
  return {
    fontFamily: style.fontFamily != null ? String(style.fontFamily) : '',
    fontSize: round1(Number(style.fontSize)),
    fontWeight: Number(style.fontWeight) || 400,
    lineHeight: round1(lineHeight),
    letterSpacing: round1(Number(style.letterSpacing) || 0),
  };
}

// Returns null when the node has no borderRadius attr at all (matches
// resolveFill's/resolveTextStyle's "null means unset" convention above), so
// callers can tell "no radius data" apart from an explicit radius of 0.
function resolveRadius(node) {
  const raw = node.attrs.borderRadius;
  if (raw === undefined) return null;
  const n = parseFloat(raw);
  return Number.isNaN(n) ? null : n;
}

function findFirstFrame(nodes) {
  for (const node of nodes) {
    if (node.type === 'FRAME') return node;
    const found = findFirstFrame(node.children);
    if (found) return found;
  }
  return null;
}

// Walks the node tree (CANVAS -> root FRAME -> descendants), accumulating
// ancestor locationRelativeToParent into absolute bounds, and pushes one raw
// element fact per mapping rule from the brief:
//   TEXT            -> role 'text' (or 'heading' when fontSize >= 24)
//   GROUP/INSTANCE with a RECTANGLE(radius) + TEXT child -> one 'button'
//     element (bounds from the group, background from the rectangle fill,
//     typography/text from the text child) — its own children are NOT
//     walked individually, they're consumed into the button.
//   IMAGE-SVG       -> role 'icon' (iconSize = max dimension)
//   standalone RECTANGLE (not consumed by a button match) with a visible
//     fill or radius -> role 'container'
//   CANVAS/FRAME and any other GROUP/INSTANCE -> transparent: not emitted,
//     just recursed into (mirrors the web extractor skipping see-through
//     containers, and matches the brief's mapping rules which name no role
//     for the page/screen root itself).
function walk(node, globals, ancestorOrigin, out) {
  if (node.type === 'CANVAS') {
    for (const child of node.children) walk(child, globals, ancestorOrigin, out);
    return;
  }

  const layout = resolveLayout(node, globals);
  const origin = { x: ancestorOrigin.x + layout.location.x, y: ancestorOrigin.y + layout.location.y };

  if (node.type === 'FRAME') {
    for (const child of node.children) walk(child, globals, origin, out);
    return;
  }

  if (node.type === 'TEXT') {
    const text = node.attrs.text !== undefined ? node.attrs.text : null;
    const typography = resolveTextStyle(node, globals);
    const color = resolveFill(node, globals);
    const fontSize = typography ? typography.fontSize : 0;
    out.push({
      figmaId: node.id,
      role: fontSize >= 24 ? 'heading' : 'text',
      text,
      typography,
      color,
      background: null,
      bounds: {
        x: origin.x,
        y: origin.y,
        w: layout.dimensions ? layout.dimensions.width : 0,
        h: layout.dimensions ? layout.dimensions.height : 0,
      },
      radius: 0,
      iconSize: null,
    });
    return;
  }

  if (node.type === 'IMAGE-SVG') {
    const w = layout.dimensions ? layout.dimensions.width : 0;
    const h = layout.dimensions ? layout.dimensions.height : 0;
    out.push({
      figmaId: node.id,
      role: 'icon',
      text: null,
      typography: null,
      color: null,
      background: null,
      bounds: { x: origin.x, y: origin.y, w, h },
      radius: 0,
      iconSize: Math.max(w, h),
    });
    return;
  }

  if (node.type === 'GROUP' || node.type === 'INSTANCE') {
    const rect = node.children.find((c) => c.type === 'RECTANGLE');
    const textChild = node.children.find((c) => c.type === 'TEXT');
    if (rect && textChild) {
      const typography = resolveTextStyle(textChild, globals);
      const color = resolveFill(textChild, globals);
      const text = textChild.attrs.text !== undefined ? textChild.attrs.text : null;
      const background = resolveFill(rect, globals);
      // Explicit null check, not `||`: a legitimate radius of 0 on the
      // RECTANGLE child (a square button) is falsy and must NOT fall
      // through to the GROUP/INSTANCE node's own radius.
      const rectRadius = resolveRadius(rect);
      const radius = rectRadius !== null && rectRadius !== undefined ? rectRadius : resolveRadius(node);
      out.push({
        figmaId: node.id,
        role: 'button',
        text,
        typography,
        color,
        background,
        bounds: {
          x: origin.x,
          y: origin.y,
          w: layout.dimensions ? layout.dimensions.width : 0,
          h: layout.dimensions ? layout.dimensions.height : 0,
        },
        radius,
        iconSize: null,
      });
      return;
    }
    for (const child of node.children) walk(child, globals, origin, out);
    return;
  }

  if (node.type === 'RECTANGLE') {
    const background = resolveFill(node, globals);
    const radius = resolveRadius(node);
    if (background || radius) {
      const w = layout.dimensions ? layout.dimensions.width : 0;
      const h = layout.dimensions ? layout.dimensions.height : 0;
      out.push({
        figmaId: node.id,
        role: 'container',
        text: null,
        typography: null,
        color: null,
        background,
        bounds: { x: origin.x, y: origin.y, w, h },
        radius,
        iconSize: null,
      });
    }
    return;
  }

  // Unknown node type: recurse defensively rather than silently dropping a
  // whole subtree the mapping rules didn't anticipate.
  for (const child of node.children) walk(child, globals, origin, out);
}

// ---------------------------------------------------------------------------
// Manifest assembly — mirrors scripts/lib/cdp-extract.js's conventions
// exactly (documented there): round1, kebabCase/slugFor for
// `<role>.<slug>` ids with -2/-3 de-dupe suffixes, gapToPrev via a y,x sort,
// and a sorted/deduped rollup. Duplicated here (not required/imported) per
// the task brief: cdp-extract.js is read-only for this task.
// ---------------------------------------------------------------------------

function round1(n) {
  if (typeof n !== 'number' || Number.isNaN(n)) return null;
  return Math.round(n * 10) / 10;
}

function kebabCase(text) {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function slugFor(text, index) {
  if (!text) return String(index);
  const k = kebabCase(text);
  if (!k) return String(index);
  return k.slice(0, 24);
}

function uniqSorted(values, numeric) {
  const seen = new Set();
  const out = [];
  for (const v of values) {
    if (v === null || v === undefined) continue;
    const key = String(v);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(v);
  }
  out.sort(numeric ? (a, b) => a - b : undefined);
  return out;
}

// raw: array of per-element facts from walk(), in file-encounter order.
// Sorts top-left to bottom-right (exactly like the web extractor's in-page
// EXTRACTOR), computes gapToPrev over that order, then formats each into a
// manifest element (ids, rounding, typography/color nulled without text).
function buildElements(raw) {
  const sorted = raw.slice().sort((a, b) => a.bounds.y - b.bounds.y || a.bounds.x - b.bounds.x);

  let prevBottom = null;
  const withGap = sorted.map((r) => {
    const gapToPrev = prevBottom === null ? 0 : round1(r.bounds.y - prevBottom);
    prevBottom = prevBottom === null ? r.bounds.y + r.bounds.h : Math.max(prevBottom, r.bounds.y + r.bounds.h);
    return Object.assign({}, r, { gapToPrev });
  });

  const elements = withGap.map((r, index) => {
    const hasText = r.text !== null;
    return {
      id: `${r.role}.${slugFor(r.text, index)}`,
      role: r.role,
      match: { web: null, figma: r.figmaId },
      text: r.text,
      typography: hasText ? r.typography : null,
      color: hasText ? r.color : null,
      background: r.background,
      bounds: {
        x: round1(r.bounds.x),
        y: round1(r.bounds.y),
        w: round1(r.bounds.w),
        h: round1(r.bounds.h),
      },
      spacing: {
        marginTop: 0,
        paddingH: 0,
        gapToPrev: r.gapToPrev,
      },
      radius: round1(r.radius),
      iconSize: r.role === 'icon' ? round1(r.iconSize) : null,
    };
  });

  const idCounts = new Map();
  for (const el of elements) {
    const base = el.id;
    const count = (idCounts.get(base) || 0) + 1;
    idCounts.set(base, count);
    if (count > 1) el.id = `${base}-${count}`;
  }
  return elements;
}

function buildRollup(elements) {
  return {
    palette: uniqSorted(elements.flatMap((e) => [e.color, e.background])),
    fontFamilies: uniqSorted(elements.map((e) => e.typography && e.typography.fontFamily)),
    fontSizes: uniqSorted(elements.map((e) => e.typography && e.typography.fontSize), true),
    // Negative values (e.g. gapToPrev when a container overlaps its children
    // in the y-sorted gap chain, or negative margins) stay raw on the
    // elements but are excluded here: a spacing SCALE is the set of design
    // tokens a port should reuse, and negatives are overlap artifacts.
    spacingScale: uniqSorted(
      elements
        .flatMap((e) => [e.spacing.marginTop, e.spacing.paddingH, e.spacing.gapToPrev])
        .filter((v) => v !== null && v >= 0),
      true
    ),
    radii: uniqSorted(elements.map((e) => e.radius), true),
    iconSizes: uniqSorted(elements.map((e) => e.iconSize), true),
  };
}

function run(args) {
  const nodesText = fs.readFileSync(args.nodes, 'utf8');
  const globalsText = fs.readFileSync(args.globals, 'utf8');
  const globals = parseGlobals(globalsText);
  const roots = parseNodesFile(nodesText);

  const frame = findFirstFrame(roots);
  const viewport = frame ? resolveLayout(frame, globals).dimensions : null;

  const raw = [];
  for (const root of roots) walk(root, globals, { x: 0, y: 0 }, raw);
  const elements = buildElements(raw);

  const manifest = {
    schema: SCHEMA,
    screen: args.screen,
    source: {
      kind: 'figma',
      ref: frame ? frame.id : args.screen,
      extractedAt: new Date().toISOString(),
      viewport: viewport || { width: 0, height: 0 },
      unit: 'pt',
    },
    elements,
    rollup: buildRollup(elements),
  };

  fs.mkdirSync(args.out, { recursive: true });
  const jsonPath = path.join(args.out, `${args.screen}.json`);
  fs.writeFileSync(jsonPath, JSON.stringify(manifest, null, 2) + '\n');
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
    run(args);
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
  parseGlobals,
  parseNodesFile,
  parseAttrs,
  resolveLayout,
  resolveFill,
  resolveTextStyle,
  resolveRadius,
  buildElements,
  buildRollup,
  kebabCase,
  slugFor,
  round1,
};
