#!/usr/bin/env node
'use strict';

// Zero-dependency Chrome DevTools Protocol client (node:* builtins only).
// Task 1 of the port-fidelity tranche: this is the foundation Task 2's design
// extractor consumes (module.exports = { launchChrome, connect }). No npm
// package does the CDP handshake + minimal RFC6455 client framing here on
// purpose — no new dependency, no package.json anywhere in the repo.

const http = require('node:http');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const DEFAULT_CHROME_BIN =
  process.env.CHROME_BIN ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Spawns headless Chrome with an ephemeral profile and a kernel-assigned
// debugging port, then parses the actual port off the
// "DevTools listening on ws://127.0.0.1:<port>/" line Chrome prints to
// stderr (remote-debugging-port=0 means "pick a free port", so this line is
// the only source of truth for what it picked). Rejects after 15s if that
// line never appears, or immediately if the process errors/exits first.
function launchChrome({ chromeBin, userDataDir } = {}) {
  const bin = chromeBin || DEFAULT_CHROME_BIN;
  const dir = userDataDir || fs.mkdtempSync(path.join(os.tmpdir(), 'cdp-ws-'));
  return new Promise((resolve, reject) => {
    const proc = spawn(
      bin,
      ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${dir}`, 'about:blank'],
      { stdio: ['ignore', 'ignore', 'pipe'] }
    );

    let settled = false;
    let buffer = '';

    const timer = setTimeout(() => {
      finish(() => reject(new Error('launchChrome: timed out after 15s waiting for the DevTools listening line')));
      try { proc.kill(); } catch (_err) { /* already dead */ }
    }, 15000);

    function finish(fn) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      proc.stderr.removeListener('data', onStderr);
      proc.removeListener('error', onError);
      proc.removeListener('exit', onExit);
      fn();
    }

    function onStderr(chunk) {
      buffer += chunk.toString('utf8');
      const m = buffer.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//);
      if (m) finish(() => resolve({ port: Number(m[1]), proc }));
    }
    function onError(err) {
      finish(() => reject(err));
    }
    function onExit(code, signal) {
      finish(() => reject(new Error(`launchChrome: chrome exited early (code ${code}, signal ${signal}) before announcing a DevTools port`)));
    }

    proc.stderr.on('data', onStderr);
    proc.on('error', onError);
    proc.on('exit', onExit);
  });
}

function httpGetJson(port, urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: urlPath }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch (err) { reject(err); }
      });
    });
    req.on('error', reject);
    // Idle timeout: covers both "connection never established" and
    // "connected but Chrome never answers" — either way the request socket
    // sits silent, so 15s of inactivity is the signal to give up.
    req.setTimeout(15000, () => {
      req.destroy(new Error('httpGetJson: timed out after 15s waiting for a response'));
    });
  });
}

// Client->server text frame. Client frames MUST be masked (RFC6455 5.1).
// Verbatim per the port-fidelity Task 1 brief.
function encodeTextFrame(str) {
  const payload = Buffer.from(str, 'utf8');
  const mask = require('node:crypto').randomBytes(4);
  let header;
  if (payload.length < 126) header = Buffer.from([0x81, 0x80 | payload.length]);
  else if (payload.length < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0xfe; header.writeUInt16BE(payload.length, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 0xff; header.writeBigUInt64BE(BigInt(payload.length), 2); }
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
  return Buffer.concat([header, mask, masked]);
}

// Client->server pong frame (opcode 0xa). Control frames are capped at 125
// bytes by spec, so pings we must echo back never need the 126/65536 length
// branches encodeTextFrame has for data frames.
function encodePongFrame(payload) {
  const buf = payload || Buffer.alloc(0);
  const mask = crypto.randomBytes(4);
  const header = Buffer.from([0x8a, 0x80 | buf.length]);
  const masked = Buffer.from(buf);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
  return Buffer.concat([header, mask, masked]);
}

// Parses one frame off the front of `buf`. Server frames arrive unmasked.
// Returns null if `buf` does not yet hold a complete frame (caller waits for
// more data); otherwise {fin, opcode, payload, total} where `total` is the
// number of bytes consumed so the caller can slice the buffer forward.
function parseFrame(buf) {
  if (buf.length < 2) return null;
  const b0 = buf[0];
  const b1 = buf[1];
  const fin = (b0 & 0x80) !== 0;
  const opcode = b0 & 0x0f;
  const masked = (b1 & 0x80) !== 0;
  let len = b1 & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < offset + 2) return null;
    len = buf.readUInt16BE(offset);
    offset += 2;
  } else if (len === 127) {
    if (buf.length < offset + 8) return null;
    len = Number(buf.readBigUInt64BE(offset));
    offset += 8;
  }
  let maskKey = null;
  if (masked) {
    if (buf.length < offset + 4) return null;
    maskKey = buf.subarray(offset, offset + 4);
    offset += 4;
  }
  if (buf.length < offset + len) return null;
  let payload = buf.subarray(offset, offset + len);
  if (masked) {
    const unmasked = Buffer.from(payload);
    for (let i = 0; i < unmasked.length; i++) unmasked[i] ^= maskKey[i % 4];
    payload = unmasked;
  }
  return { fin, opcode, payload, total: offset + len };
}

// GETs /json/version for the browser target's webSocketDebuggerUrl, then
// performs a minimal RFC6455 client handshake + framing over it (no
// extensions/compression). Returns a Cdp handle:
//   send(method, params?, sessionId?) -> Promise<result>  (JSON-RPC by id)
//   on(event, fn)                                          (dispatch by .method)
//   close()
function connect(port) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let activeSocket = null;
    let activeReq = null;

    // Overall connect() timeout: covers the /json/version fetch AND the ws
    // upgrade handshake. If Chrome accepts the TCP connection but never
    // completes the upgrade (or never answers at all), this is what unblocks
    // the caller instead of hanging forever.
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (activeSocket) { try { activeSocket.destroy(); } catch (_err) { /* already gone */ } }
      else if (activeReq) { try { activeReq.destroy(); } catch (_err) { /* already gone */ } }
      reject(new Error('connect: timed out after 15s waiting for the CDP websocket handshake'));
    }, 15000);

    function settle(fn) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    }

    httpGetJson(port, '/json/version').then((info) => {
      const wsUrl = new URL(info.webSocketDebuggerUrl);
      const key = crypto.randomBytes(16).toString('base64');

      const req = http.request({
        host: wsUrl.hostname,
        port: wsUrl.port || port,
        path: wsUrl.pathname + wsUrl.search,
        headers: {
          Connection: 'Upgrade',
          Upgrade: 'websocket',
          'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': key,
        },
      });
      activeReq = req;

      req.on('error', (err) => settle(() => reject(err)));
      req.on('response', (res) => {
        // A non-101 response means no 'upgrade' event will fire.
        settle(() => reject(new Error(`connect: expected HTTP 101, got ${res.statusCode}`)));
      });
      // The request is never actually written to the socket until end() is
      // called — without this the handshake hangs forever waiting on an
      // 'upgrade' event that Chrome never gets a chance to trigger.
      req.end();

      req.on('upgrade', (res, socket, head) => {
        activeSocket = socket;
        socket.setNoDelay(true);

        const listeners = new Map(); // event name -> [fn, ...]
        const pending = new Map(); // id -> {resolve, reject}
        let nextId = 1;
        let recvBuffer = head && head.length ? Buffer.from(head) : Buffer.alloc(0);
        let fragments = [];
        let fragmentOpcode = null;
        let closed = false;

        function on(event, fn) {
          if (!listeners.has(event)) listeners.set(event, []);
          listeners.get(event).push(fn);
        }
        function emit(event, payload) {
          const fns = listeners.get(event);
          if (fns) for (const fn of fns) fn(payload);
        }

        function handleMessage(text) {
          let msg;
          try { msg = JSON.parse(text); } catch (_err) { return; }
          if (msg.id != null && pending.has(msg.id)) {
            const { resolve: res2, reject: rej2 } = pending.get(msg.id);
            pending.delete(msg.id);
            if (msg.error) rej2(new Error(msg.error.message || 'CDP error response'));
            else res2(msg.result);
          } else if (msg.method) {
            emit(msg.method, msg.params);
          }
        }

        function onFrame(frame) {
          switch (frame.opcode) {
            case 0x9: // ping -> pong
              socket.write(encodePongFrame(frame.payload));
              return;
            case 0xa: // pong: nothing to do
              return;
            case 0x8: // close
              closed = true;
              socket.end();
              return;
            case 0x1: // text (start of message, possibly fragmented)
            case 0x2: // binary: unused by CDP but handled the same way
              fragmentOpcode = frame.opcode;
              fragments = [frame.payload];
              break;
            case 0x0: // continuation
              fragments.push(frame.payload);
              break;
            default:
              return;
          }
          if (frame.fin) {
            const full = Buffer.concat(fragments);
            fragments = [];
            const opcode = fragmentOpcode;
            fragmentOpcode = null;
            if (opcode === 0x1) handleMessage(full.toString('utf8'));
          }
        }

        socket.on('data', (chunk) => {
          recvBuffer = recvBuffer.length ? Buffer.concat([recvBuffer, chunk]) : chunk;
          for (;;) {
            const frame = parseFrame(recvBuffer);
            if (!frame) break;
            recvBuffer = recvBuffer.subarray(frame.total);
            onFrame(frame);
          }
        });

        socket.on('error', (err) => {
          for (const { reject: rej2 } of pending.values()) rej2(err);
          pending.clear();
        });
        socket.on('close', () => {
          closed = true;
          for (const { reject: rej2 } of pending.values()) rej2(new Error('cdp: socket closed'));
          pending.clear();
        });

        function send(method, params, sessionId) {
          return new Promise((res2, rej2) => {
            if (closed) { rej2(new Error('cdp: send after close')); return; }
            const id = nextId++;
            const msg = { id, method, params: params || {} };
            if (sessionId) msg.sessionId = sessionId;
            pending.set(id, { resolve: res2, reject: rej2 });
            socket.write(encodeTextFrame(JSON.stringify(msg)));
          });
        }

        function close() {
          if (closed) return;
          closed = true;
          try { socket.end(); } catch (_err) { /* already gone */ }
        }

        settle(() => resolve({ send, on, close }));
      });
    }, (err) => settle(() => reject(err)));
  });
}

module.exports = { launchChrome, connect };

// Tracks the in-flight selftest's Chrome process so the wall-clock cap below
// can still kill it if something inside selftest() hangs past the per-call
// timeouts (e.g. a cdp.send() whose response never arrives).
let selftestChromeProc = null;

// --selftest: launches real headless Chrome, evaluates 1+1 over CDP, and
// exits 0/1. Chrome-presence gating lives in the bash fixture that invokes
// this (scripts/test/fixtures.sh, fixture_cdp_ws) so the deterministic suite
// never fails on a machine without Chrome; this entry point assumes the
// caller already confirmed a chrome binary exists.
async function selftest() {
  let proc;
  try {
    const launched = await launchChrome({});
    proc = launched.proc;
    selftestChromeProc = proc;
    const cdp = await connect(launched.port);
    try {
      const created = await cdp.send('Target.createTarget', { url: 'about:blank' });
      const attached = await cdp.send('Target.attachToTarget', { targetId: created.targetId, flatten: true });
      const evaluated = await cdp.send(
        'Runtime.evaluate',
        { expression: '1+1', returnByValue: true },
        attached.sessionId
      );
      const value = evaluated.result && evaluated.result.value;
      if (value !== 2) {
        console.error(`cdp-ws selftest: expected 1+1 === 2, got ${JSON.stringify(value)}`);
        return 1;
      }
      return 0;
    } finally {
      cdp.close();
    }
  } catch (err) {
    console.error(`cdp-ws selftest failed: ${err && err.stack ? err.stack : err}`);
    return 1;
  } finally {
    if (proc) { try { proc.kill(); } catch (_err) { /* already dead */ } }
    selftestChromeProc = null;
  }
}

if (require.main === module && process.argv.includes('--selftest')) {
  // Backstop only: connect()/httpGetJson() already time out well under this,
  // so this only fires if something else inside selftest() hangs (e.g. a
  // cdp.send() awaiting a response that never comes). unref() so it never
  // keeps the process alive past a normal, on-time exit.
  const t = setTimeout(() => {
    console.error('selftest timeout');
    if (selftestChromeProc) { try { selftestChromeProc.kill(); } catch (_err) { /* already dead */ } }
    process.exit(1);
  }, 30000);
  t.unref?.();
  selftest().then((code) => process.exit(code));
}
