#!/usr/bin/env node
// Renders the landing page's hero video (website/hero.js) to an MP4, a poster PNG, named
// stills, and the social preview card. Frames are captured one at a time through the
// page's window.toasttyHero.renderFrame(t) API, so the output does not depend on how fast
// this machine renders. Requires Google Chrome (or CHROME_PATH) and ffmpeg with libx264.
//
// Usage:
//   node scripts/website/render-hero-video.mjs [--out-dir DIR] [--fps 30] [--width 1600]
//        [--stills name=seconds[@selector],...] [--no-video] [--social]
//
// Outputs (default DIR: artifacts/website-hero):
//   toastty-tour.mp4   the full loop, H.264, width --width
//   poster.png         the reduced-motion poster frame
//   <name>.png         one PNG per --stills entry: the padded stage at that time, or only the
//                      element matching @selector (e.g. sidebar=0@.sbdemo, annotate=11.7@.rp)
//   social-preview.png 1200x630 card, with --social

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = parseArgs(process.argv.slice(2));
const outDir = resolve(args['out-dir'] ?? join(repoRoot, 'artifacts/website-hero'));
const fps = Number(args.fps ?? 30);
const videoWidth = Number(args.width ?? 1600);
const stills = parseStills(args.stills ?? '');

// The stage is designed at 1200x740 CSS px; capture at 2x and pad it with page background.
const STAGE_WIDTH = 1200;
const PAD = 32;
const SCALE = 2;

mkdirSync(outDir, { recursive: true });
const chrome = await launchChrome();
try {
  // Each pass gets a freshly loaded page: video frames must run forward from t=0, and stills
  // jump around the timeline, which would leave the video's animation clocks out of phase.
  const openHero = async () => {
    const page = await chrome.openPage(pathToFileURL(join(repoRoot, 'website/index.html')).href);
    await page.send('Emulation.setDeviceMetricsOverride', {
      width: STAGE_WIDTH + 2 * PAD + 100, height: 1000, deviceScaleFactor: SCALE, mobile: false,
    });
    await page.evaluate(`document.fonts.ready.then(() => true)`);
    const clip = await page.evaluate(`(() => {
      document.querySelector('section.video').style.width = '${STAGE_WIDTH}px';
      // The caption under the stage would otherwise show inside the bottom padding.
      document.querySelector('.example-cap').style.visibility = 'hidden';
      window.toasttyHero.startRendering();
      window.scrollTo(0, 0);
      const r = document.getElementById('wrap').getBoundingClientRect();
      return { x: r.left - ${PAD}, y: r.top + window.scrollY - ${PAD}, width: r.width + ${2 * PAD}, height: r.height + ${2 * PAD} };
    })()`);
    // Stills jump straight to their time, so they settle new transitions; video frames run in order.
    const capture = async (t, settle = false, selector = null) => {
      await page.evaluate(`toasttyHero.renderFrame(${t}, ${settle})`);
      const region = selector ? await page.evaluate(`(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        if (!el) throw new Error('no element for ${selector}');
        el.scrollIntoView({ block: 'center' });
        const r = el.getBoundingClientRect();
        return { x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height };
      })()`) : clip;
      const shot = await page.send('Page.captureScreenshot', {
        format: 'png', clip: { ...region, scale: 1 }, captureBeyondViewport: true,
      });
      return Buffer.from(shot.data, 'base64');
    };
    return { page, clip, capture };
  };

  const { page, clip, capture } = await openHero();
  const hero = await page.evaluate(`({ duration: toasttyHero.duration, poster: toasttyHero.poster })`);

  writeFileSync(join(outDir, 'poster.png'), await capture(hero.poster, true));
  // Sidebar region of the poster (in poster pixels) for the social card's close-up.
  const sidebarCrop = await page.evaluate(`(() => {
    const sb = document.querySelector('.sb').getBoundingClientRect();
    const docs = document.getElementById('card-docs').getBoundingClientRect();
    // Start a few pixels inside the window so its rounded corner and the page background stay out.
    const x = sb.left - ${clip.x} + 6, y = sb.top + window.scrollY - ${clip.y} + 6;
    return [x, y, sb.width + 34, docs.bottom + window.scrollY - ${clip.y} - y + 12].map((v) => Math.round(v * ${SCALE}));
  })()`);
  for (const { name, t, selector } of stills) {
    writeFileSync(join(outDir, `${name}.png`), await capture(t, true, selector));
  }
  await page.close();

  if (!args['no-video']) {
    const video = await openHero();
    const frameDir = mkdtempSync(join(tmpdir(), 'toastty-hero-frames-'));
    try {
      const frames = Math.round(hero.duration * fps);
      for (let i = 0; i < frames; i += 1) {
        writeFileSync(join(frameDir, `f${String(i).padStart(5, '0')}.png`), await video.capture(i / fps));
        if (i % fps === 0) process.stdout.write(`\rframes ${i}/${frames}`);
      }
      process.stdout.write(`\rframes ${frames}/${frames}\n`);
      await run('ffmpeg', [
        '-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(frameDir, 'f%05d.png'),
        '-vf', `scale=${videoWidth}:-2:flags=lanczos`, '-c:v', 'libx264', '-preset', 'slow',
        '-crf', '22', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
        join(outDir, 'toastty-tour.mp4'),
      ]);
    } finally {
      rmSync(frameDir, { recursive: true, force: true });
      await video.page.close();
    }
  }

  if (args.social) {
    const card = await chrome.openPage(
      pathToFileURL(join(repoRoot, 'scripts/website/social-card.html')).href
        + `?poster=${encodeURIComponent(pathToFileURL(join(outDir, 'poster.png')).href)}&crop=${sidebarCrop.join(',')}`,
    );
    await card.send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 630, deviceScaleFactor: 1, mobile: false });
    await card.evaluate(`Promise.all([document.fonts.ready, document.querySelector('img').decode()]).then(() => true)`);
    const shot = await card.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(outDir, 'social-preview.png'), Buffer.from(shot.data, 'base64'));
  }
  console.log(`wrote ${outDir}`);
} finally {
  await chrome.close();
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].replace(/^--/, '');
    if (argv[i + 1] === undefined || argv[i + 1].startsWith('--')) out[key] = true;
    else out[key] = argv[++i];
  }
  return out;
}

function parseStills(spec) {
  return spec.split(',').filter(Boolean).map((entry) => {
    const [name, rest = ''] = entry.split('=');
    const [t, selector = null] = rest.split('@');
    if (!name || Number.isNaN(Number(t))) throw new Error(`bad --stills entry: ${entry}`);
    return { name, t: Number(t), selector };
  });
}

function run(cmd, cmdArgs) {
  return new Promise((ok, fail) => {
    const child = spawn(cmd, cmdArgs, { stdio: 'inherit' });
    child.on('error', fail);
    child.on('exit', (code) => (code === 0 ? ok() : fail(new Error(`${cmd} exited ${code}`))));
  });
}

async function launchChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ].filter(Boolean);
  const bin = candidates.find((p) => existsSync(p));
  if (!bin) throw new Error('Chrome not found; set CHROME_PATH');
  const profile = mkdtempSync(join(tmpdir(), 'toastty-hero-chrome-'));
  const proc = spawn(bin, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  const port = await withTimeout(new Promise((ok, fail) => {
    let buf = '';
    proc.stderr.on('data', (d) => {
      buf += d;
      const m = buf.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
      if (m) ok(Number(m[1]));
    });
    proc.on('exit', (code) => fail(new Error(`Chrome exited ${code}: ${buf.slice(-400)}`)));
  }), 30000, 'Chrome startup').catch((error) => {
    proc.kill('SIGKILL');
    throw error;
  });
  return {
    async openPage(url) {
      const res = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' });
      const target = await res.json();
      const page = await connect(target.webSocketDebuggerUrl);
      await page.send('Page.enable');
      await page.send('Runtime.enable');
      const loaded = page.waitFor('Page.loadEventFired', 30000);
      await page.send('Page.navigate', { url });
      await loaded;
      return page;
    },
    async close() {
      if (proc.exitCode === null && proc.signalCode === null) {
        const exited = new Promise((ok) => proc.once('exit', ok));
        proc.kill();
        // Fall back to SIGKILL if Chrome ignores SIGTERM.
        const timer = setTimeout(() => proc.kill('SIGKILL'), 5000);
        await exited;
        clearTimeout(timer);
      }
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    },
  };
}

async function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
  let nextId = 1;
  const pending = new Map();
  const waiters = [];
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { ok, fail } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) fail(new Error(`${msg.error.message} ${msg.error.data ?? ''}`));
      else ok(msg.result);
    } else if (msg.method) {
      for (const w of waiters.filter((x) => x.method === msg.method)) w.ok();
    }
  };
  ws.onclose = () => {
    for (const { fail } of pending.values()) fail(new Error('DevTools connection closed'));
    pending.clear();
  };
  const send = (method, params = {}) => withTimeout(new Promise((ok, fail) => {
    const id = nextId++;
    pending.set(id, { ok, fail });
    ws.send(JSON.stringify({ id, method, params }));
  }), 60000, method);
  return {
    send,
    waitFor(method, timeout) {
      let waiter;
      const event = new Promise((ok) => { waiter = { method, ok }; waiters.push(waiter); });
      return withTimeout(event, timeout, `waiting for ${method}`)
        .finally(() => waiters.splice(waiters.indexOf(waiter), 1));
    },
    async close() {
      await send('Page.close').catch(() => {});
      ws.close();
    },
    async evaluate(expression) {
      const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(`page error: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },
  };
}

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, fail) => {
    timer = setTimeout(() => fail(new Error(`${what} timed out after ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
