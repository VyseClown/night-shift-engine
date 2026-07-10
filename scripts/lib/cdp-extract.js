#!/usr/bin/env node
'use strict';

// Web-mode design extractor (port-fidelity Task 2). Drives real Chrome over
// the zero-dep CDP client from Task 1 (scripts/lib/cdp-ws.js) to pull a
// design manifest (night-shift-design-manifest/1) out of a live page: one
// JSON manifest + one PNG screenshot per screen. node:* builtins only — no
// new dependency, no package.json anywhere in the repo.
//
// CLI:
//   node scripts/lib/cdp-extract.js --url <u> --screen <name> --out <dir>
//     [--viewport 430x932] [--cookie k=v]... [--header 'K: V']...
// Writes <out>/<screen>.json and <out>/<screen>-<W>x<H>.png. Exit 0 on
// success, 1 with a one-line stderr reason otherwise.

const fs = require('node:fs');
const path = require('node:path');
const { launchChrome, connect } = require('./cdp-ws.js');

const SCHEMA = 'night-shift-design-manifest/1';
const DEFAULT_VIEWPORT = '430x932';
const LOAD_TIMEOUT_MS = 15000;
const SETTLE_MS = 500;

// In-page extractor core (verbatim per the port-fidelity Task 2 brief).
// Walks every visible element under <body>, assigns a role, filters out
// see-through containers and li-row overflow past 2 rows, sorts top-left to
// bottom-right, and returns the raw per-element facts as a JSON string —
// evaluated in-page via Runtime.evaluate so no DOM ever crosses the wire
// except this already-serialized string.
// NOTE: the brief's verbatim `String(function extract(){...}) + '()'` is not
// actually a valid IIFE — a bare function declaration followed by `()` is a
// SyntaxError ("Unexpected token ')'"), confirmed live via Runtime.evaluate.
// Wrapping the source in parens is the minimal fix to make it callable.
// NOTE: hex() extends the brief's rgb()/rgba()-only version with a 1x1-canvas
// fallback. Live verification against a real Tailwind v4 app showed every
// color/background coming back null: modern pages compute colors to
// oklch(...) / lab(...) / color(srgb ...), which the regex can't parse. The
// canvas normalizes ANY css color to sRGB bytes; the fast regex path stays
// first, and fully transparent values still return null on both paths.
const EXTRACTOR = '(' + String(function extract() {
  let cv = null, cx = null;
  function hex(c) {
    if (!c) return null;
    const m = c.match(/rgba?\((\d+), ?(\d+), ?(\d+)(?:, ?([\d.]+))?\)/);
    if (m) {
      if (m[4] !== undefined && parseFloat(m[4]) === 0) return null;
      return '#' + [m[1], m[2], m[3]].map(n => (+n).toString(16).padStart(2, '0')).join('');
    }
    if (!cx) {
      cv = document.createElement('canvas'); cv.width = cv.height = 1;
      cx = cv.getContext('2d', { willReadFrequently: true });
      if (!cx) return null;
    }
    cx.clearRect(0, 0, 1, 1);
    cx.fillStyle = '#000';
    try { cx.fillStyle = c; } catch (_e) { return null; }
    cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data;
    if (d[3] === 0) return null;
    return '#' + [d[0], d[1], d[2]].map(n => n.toString(16).padStart(2, '0')).join('');
  }
  function role(el, cs) { const t = el.tagName.toLowerCase();
    if (/^h[1-6]$/.test(t)) return 'heading';
    if (t === 'button' || (t === 'a' && cs.display !== 'inline')) return 'button';
    if (t === 'input' || t === 'textarea' || t === 'select') return 'input';
    if (t === 'svg') return 'icon';
    if (t === 'img') return 'image';
    const own = Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim());
    return own ? 'text' : 'container'; }
  const out = []; let prevBottom = null; const seenRowText = {};
  for (const el of document.querySelectorAll('body *')) {
    const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2 || cs.visibility === 'hidden' || cs.display === 'none') continue;
    const rl = role(el, cs);
    if (rl === 'container' && !hex(cs.backgroundColor) && cs.borderRadius === '0px') continue;
    if (el.parentElement && el.parentElement.tagName === 'LI') continue;
    if (el.tagName === 'LI') { const key = el.parentElement.tagName + '.' + Math.round(r.height);
      seenRowText[key] = (seenRowText[key] || 0) + 1; if (seenRowText[key] > 2) continue; }
    const textOwn = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join(' ').trim() || null;
    out.push({ tag: el.tagName.toLowerCase(), role: rl, text: textOwn,
      path: el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).join('.') : ''),
      fontFamily: cs.fontFamily.split(',')[0].replace(/"/g, '').trim(), fontSize: parseFloat(cs.fontSize),
      fontWeight: parseInt(cs.fontWeight, 10) || 400, lineHeight: parseFloat(cs.lineHeight) || null,
      letterSpacing: parseFloat(cs.letterSpacing) || 0,
      color: hex(cs.color), background: hex(cs.backgroundColor),
      bounds: { x: +r.x.toFixed(1), y: +r.y.toFixed(1), w: +r.width.toFixed(1), h: +r.height.toFixed(1) },
      marginTop: parseFloat(cs.marginTop), paddingH: parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight),
      radius: parseFloat(cs.borderRadius) || 0 });
  }
  out.sort((a, b) => a.bounds.y - b.bounds.y || a.bounds.x - b.bounds.x);
  for (const e of out) { e.gapToPrev = prevBottom === null ? 0 : +(e.bounds.y - prevBottom).toFixed(1); prevBottom = Math.max(prevBottom ?? 0, e.bounds.y + e.bounds.h); }
  return JSON.stringify(out);
}) + ')()';

function fail(reason) {
  console.error(`cdp-extract: ${reason}`);
  process.exitCode = 1;
}

function parseArgs(argv) {
  const args = { cookies: [], headers: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--url': args.url = argv[++i]; break;
      case '--screen': args.screen = argv[++i]; break;
      case '--out': args.out = argv[++i]; break;
      case '--viewport': args.viewport = argv[++i]; break;
      case '--cookie': args.cookies.push(argv[++i]); break;
      case '--header': args.headers.push(argv[++i]); break;
      default: throw new Error(`unrecognized argument: ${a}`);
    }
  }
  if (!args.url) throw new Error('--url is required');
  if (!args.screen) throw new Error('--screen is required');
  if (!args.out) throw new Error('--out is required');
  const vp = args.viewport || DEFAULT_VIEWPORT;
  const m = vp.match(/^(\d+)x(\d+)$/);
  if (!m) throw new Error(`--viewport must look like WxH, got ${JSON.stringify(vp)}`);
  args.width = Number(m[1]);
  args.height = Number(m[2]);
  return args;
}

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

// slug = first 24 chars of kebab-cased text, else the node/DOM index
// (falling back to the index whenever the text kebab-cases to nothing, e.g.
// pure punctuation/emoji).
function slugFor(text, index) {
  if (!text) return String(index);
  const k = kebabCase(text);
  if (!k) return String(index);
  return k.slice(0, 24);
}

// Sorted, deduped values for the manifest rollup section. Numeric arrays
// sort ascending; everything else (hex colors, font family names) sorts
// lexicographically, which is stable and good enough for a rollup summary.
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

// Raw per-element facts (from EXTRACTOR, already sorted top-left to
// bottom-right) -> manifest elements per the night-shift-design-manifest/1
// schema: ids, typography/color nulled for text-less elements, iconSize only
// for icons, everything numeric rounded to 1 decimal.
function buildElements(raw) {
  const elements = raw.map((r, index) => {
    const hasText = r.text !== null;
    return {
      id: `${r.role}.${slugFor(r.text, index)}`,
      role: r.role,
      match: { web: r.path, figma: null },
      text: r.text,
      typography: hasText ? {
        fontFamily: r.fontFamily,
        fontSize: round1(r.fontSize),
        fontWeight: r.fontWeight,
        lineHeight: round1(r.lineHeight),
        letterSpacing: round1(r.letterSpacing),
      } : null,
      color: hasText ? r.color : null,
      background: r.background,
      bounds: {
        x: round1(r.bounds.x),
        y: round1(r.bounds.y),
        w: round1(r.bounds.w),
        h: round1(r.bounds.h),
      },
      spacing: {
        marginTop: round1(r.marginTop),
        paddingH: round1(r.paddingH),
        gapToPrev: round1(r.gapToPrev),
      },
      radius: round1(r.radius),
      iconSize: r.role === 'icon' ? round1(Math.max(r.bounds.w, r.bounds.h)) : null,
    };
  });

  // Duplicate ids get -2, -3, ... suffixes, in encounter order.
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Races an event listener registered via cdp.on(event, ...) against a
// timeout, so a page whose load event never fires (bad url, hung request)
// fails loudly instead of hanging the whole CLI forever.
function waitForEvent(cdp, event, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`timed out after ${timeoutMs}ms waiting for ${event}`));
    }, timeoutMs);
    cdp.on(event, () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

async function run(args) {
  fs.mkdirSync(args.out, { recursive: true });

  const { port, proc } = await launchChrome({});
  try {
    const cdp = await connect(port);
    try {
      const created = await cdp.send('Target.createTarget', { url: 'about:blank' });
      const attached = await cdp.send('Target.attachToTarget', {
        targetId: created.targetId,
        flatten: true,
      });
      const sessionId = attached.sessionId;

      await cdp.send(
        'Emulation.setDeviceMetricsOverride',
        { width: args.width, height: args.height, deviceScaleFactor: 2, mobile: true },
        sessionId
      );

      if (args.cookies.length || args.headers.length) {
        await cdp.send('Network.enable', {}, sessionId);
      }
      for (const raw of args.cookies) {
        const idx = raw.indexOf('=');
        if (idx < 0) throw new Error(`--cookie must look like k=v, got ${JSON.stringify(raw)}`);
        const name = raw.slice(0, idx);
        const value = raw.slice(idx + 1);
        await cdp.send('Network.setCookie', { name, value, url: args.url }, sessionId);
      }
      if (args.headers.length) {
        const headers = {};
        for (const raw of args.headers) {
          const idx = raw.indexOf(':');
          if (idx < 0) throw new Error(`--header must look like 'K: V', got ${JSON.stringify(raw)}`);
          headers[raw.slice(0, idx).trim()] = raw.slice(idx + 1).trim();
        }
        await cdp.send('Network.setExtraHTTPHeaders', { headers }, sessionId);
      }

      await cdp.send('Page.enable', {}, sessionId);
      const loaded = waitForEvent(cdp, 'Page.loadEventFired', LOAD_TIMEOUT_MS);
      await cdp.send('Page.navigate', { url: args.url }, sessionId);
      await loaded;
      await sleep(SETTLE_MS);

      const evaluated = await cdp.send(
        'Runtime.evaluate',
        { expression: EXTRACTOR, returnByValue: true },
        sessionId
      );
      if (evaluated.exceptionDetails) {
        throw new Error(`in-page extractor threw: ${JSON.stringify(evaluated.exceptionDetails)}`);
      }
      const raw = JSON.parse(evaluated.result.value);
      const elements = buildElements(raw);

      const manifest = {
        schema: SCHEMA,
        screen: args.screen,
        source: {
          kind: 'web',
          ref: args.url,
          extractedAt: new Date().toISOString(),
          viewport: { width: args.width, height: args.height },
          unit: 'px',
        },
        elements,
        rollup: buildRollup(elements),
      };

      const shot = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);

      const jsonPath = path.join(args.out, `${args.screen}.json`);
      const pngPath = path.join(args.out, `${args.screen}-${args.width}x${args.height}.png`);
      fs.writeFileSync(jsonPath, JSON.stringify(manifest, null, 2) + '\n');
      fs.writeFileSync(pngPath, Buffer.from(shot.data, 'base64'));
    } finally {
      cdp.close();
    }
  } finally {
    try { proc.kill(); } catch (_err) { /* already dead */ }
  }
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    fail(err.message);
    return;
  }
  try {
    await run(args);
  } catch (err) {
    fail(err && err.message ? err.message : String(err));
  }
}

if (require.main === module) {
  main();
}

module.exports = { parseArgs, buildElements, buildRollup, kebabCase, slugFor, round1 };
