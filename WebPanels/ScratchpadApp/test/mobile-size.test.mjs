import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { build } from "esbuild";

async function generatedScript() {
  const result = await build({ entryPoints: [new URL("../src/sandbox.ts", import.meta.url).pathname],
    bundle: true, write: false, format: "cjs", platform: "node" });
  const module = { exports: {} };
  vm.runInNewContext(result.outputFiles[0].text, { module, exports: module.exports });
  return module.exports.sandboxedSrcdoc;
}

test("mobile sizing keeps CSP and reports bounded changed dimensions through the existing token", async () => {
  const sandboxedSrcdoc = await generatedScript();
  const html = sandboxedSrcdoc("<main>Diagram</main>", "dark", "token", true);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /base-uri 'none'/);
  const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
  const listeners = new Map();
  const posted = [];
  let resize;
  const doc = { documentElement: { scrollWidth: 1200, scrollHeight: 1000 }, body: { scrollWidth: 1200, scrollHeight: 1000 } };
  const window = { addEventListener(name, handler) { listeners.set(name, handler); },
    parent: { postMessage(message) { posted.push(message); } } };
  vm.runInNewContext(script, { window, document: doc, console: { ...console },
    requestAnimationFrame(callback) { callback(); }, ResizeObserver: class { constructor(callback) { resize = callback; } observe() {} } });
  listeners.get("load")();
  assert.equal(posted[0].sessionToken, "token");
  assert.equal(posted[0].event.type, "contentSize");
  assert.equal(posted[0].event.width, 1200);
  resize();
  assert.equal(posted.length, 1);
  doc.body.scrollHeight = 20000;
  resize();
  assert.equal(posted.length, 1);
});

test("desktop sandbox does not install mobile size observer", async () => {
  const html = (await generatedScript())("<main>Diagram</main>", "dark", "token");
  assert.match(html, /if \(false\)/);
});
