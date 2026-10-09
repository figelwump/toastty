#!/usr/bin/env node
// Renders the landing page's hero video (website/hero.js) or the Toastty Mobile video
// (website/mobile.js) to an MP4, a poster PNG, named stills, and a social preview card.
// Frames are captured one at a time through the page's window.toasttyHero.renderFrame(t)
// (or window.toasttyMobile) API, so the output does not depend on how fast this machine
// renders. Requires Google Chrome (or CHROME_PATH) and ffmpeg with libx264.
//
// Usage:
//   node scripts/website/render-hero-video.mjs [--target hero|mobile] [--out-dir DIR] [--fps 30]
//        [--width PX] [--stills name=seconds[@selector],...] [--no-video] [--social]
//        [--social-image PNG --social-crop x,y,w,h]
//
// Outputs (default DIR: artifacts/website-hero), for --target hero (the default):
//   toastty-tour.mp4   the full loop, H.264, width --width (default 1600)
//   poster.png         the reduced-motion poster frame
//   <name>.png         one PNG per --stills entry: the padded stage at that time, or only the
//                      element matching @selector (e.g. sidebar=0@.sbdemo, annotate=11.7@.rp)
//   social-preview.png 1200x630 card, with --social. Its close-up defaults to the poster's
//                      sidebar; --social-image and --social-crop (pixels) use another image,
//                      such as sidebar.png from capture-demo-screenshots.sh.
// For --target mobile the same files are toastty-mobile.mp4 (portrait, width --width, default
// 1080), mobile-poster.png, mobile-<name>.png, and mobile-social.png (the phone poster beside
// the Toastty Mobile tagline; --social-image replaces the poster).

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = parseArgs(process.argv.slice(2));
const TARGETS = {
  // The hero stage is designed at 1200x740 CSS px; the phone stage at 440x900.
  hero: {
    api: 'toasttyHero', wrap: 'wrap', stageWidth: 1200, viewportHeight: 1000, defaultWidth: 1600,
    video: 'toastty-tour.mp4', poster: 'poster.png', still: (n) => `${n}.png`,
    social: 'social-card.html', socialOut: 'social-preview.png',
    // The caption under the stage would otherwise show inside the bottom padding.
    prepare: `document.querySelector('section.video').style.width = '1200px';
      document.querySelector('.example-cap').style.visibility = 'hidden';`,
  },
  mobile: {
    api: 'toasttyMobile', wrap: 'mwrap', stageWidth: 440, viewportHeight: 1100, defaultWidth: 1080,
    video: 'toastty-mobile.mp4', poster: 'mobile-poster.png', still: (n) => `mobile-${n}.png`,
    social: 'social-card-mobile.html', socialOut: 'mobile-social.png',
    // Chrome mis-clips captures far down a page, so everything above the phone is hidden.
    prepare: `document.querySelectorAll('header.nav, main > section:not(#mobile), #mobile > :not(.mobile-grid), .mobile-grid > :not(.mstage-col), footer')
      .forEach((el) => { el.style.display = 'none'; });
      document.getElementById('mobile').style.paddingTop = '0';`,
  },
};
const target = TARGETS[args.target ?? 'hero'];
if (!target) throw new Error(`unknown --target ${args.target}; use hero or mobile`);
const outDir = resolve(args['out-dir'] ?? join(repoRoot, 'artifacts/website-hero'));
const fps = Number(args.fps ?? 30);
const videoWidth = Number(args.width ?? target.defaultWidth);
const stills = parseStills(args.stills ?? '');

// Capture at 2x and pad the stage with page background.
const STAGE_WIDTH = target.stageWidth;
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
      width: Math.max(STAGE_WIDTH + 2 * PAD + 100, 1300), height: target.viewportHeight, deviceScaleFactor: SCALE, mobile: false,
    });
    await page.evaluate(`document.fonts.ready.then(() => true)`);
    const clip = await page.evaluate(`(() => {
      ${target.prepare}
      window.${target.api}.startRendering();
      window.scrollTo(0, 0);
      const r = document.getElementById('${target.wrap}').getBoundingClientRect();
      return { x: r.left - ${PAD}, y: r.top + window.scrollY - ${PAD}, width: r.width + ${2 * PAD}, height: r.height + ${2 * PAD} };
    })()`);
    // Stills jump straight to their time, so they settle new transitions; video frames run in order.
    const capture = async (t, settle = false, selector = null) => {
      await page.evaluate(`${target.api}.renderFrame(${t}, ${settle})`);
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
  const hero = await page.evaluate(`({ duration: ${target.api}.duration, poster: ${target.api}.poster })`);

  writeFileSync(join(outDir, target.poster), await capture(hero.poster, true));
  // Sidebar region of the hero poster (in poster pixels) for the social card's close-up.
  const sidebarCrop = target !== TARGETS.hero ? null : await page.evaluate(`(() => {
    const sb = document.querySelector('.sb').getBoundingClientRect();
    const docs = document.getElementById('card-docs').getBoundingClientRect();
    // Start a few pixels inside the window so its rounded corner and the page background stay out.
    const x = sb.left - ${clip.x} + 6, y = sb.top + window.scrollY - ${clip.y} + 6;
    return [x, y, sb.width + 34, docs.bottom + window.scrollY - ${clip.y} - y + 12].map((v) => Math.round(v * ${SCALE}));
  })()`);
  for (const { name, t, selector } of stills) {
    writeFileSync(join(outDir, target.still(name)), await capture(t, true, selector));
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
        join(outDir, target.video),
      ]);
    } finally {
      rmSync(frameDir, { recursive: true, force: true });
      await video.page.close();
    }
  }

  if (args.social) {
    const image = args['social-image'] ? resolve(args['social-image']) : join(outDir, target.poster);
    const crop = args['social-crop'] ?? (sidebarCrop ? sidebarCrop.join(',') : '');
    const card = await chrome.openPage(
      pathToFileURL(join(repoRoot, 'scripts/website', target.social)).href
        + `?poster=${encodeURIComponent(pathToFileURL(image).href)}&crop=${crop}`,
    );
    await card.send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 630, deviceScaleFactor: 1, mobile: false });
    await card.evaluate(`Promise.all([document.fonts.ready, document.querySelector('img').decode()]).then(() => true)`);
    const shot = await card.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(outDir, target.socialOut), Buffer.from(shot.data, 'base64'));
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
