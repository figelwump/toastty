import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const sandboxSource = readFileSync(
  resolve(import.meta.dirname, "../src/sandbox.ts"),
  "utf8"
);
const mainSource = readFileSync(
  resolve(import.meta.dirname, "../src/main.ts"),
  "utf8"
);

test("generated content CSP blocks network and native-adjacent surfaces", () => {
  assert.match(sandboxSource, /default-src 'none'/);
  assert.match(sandboxSource, /connect-src 'none'/);
  assert.match(sandboxSource, /frame-src 'none'/);
  assert.match(sandboxSource, /script-src 'unsafe-inline'/);
  assert.match(sandboxSource, /worker-src 'none'/);
  assert.match(sandboxSource, /form-action 'none'/);
  assert.doesNotMatch(sandboxSource, /script-src 'unsafe-inline' data: blob:/);
  assert.doesNotMatch(sandboxSource, /worker-src blob:/);
});

test("generated iframe allows scripts without same-origin privileges", () => {
  assert.match(mainSource, /iframe\.sandbox\.add\("allow-scripts"\)/);
  assert.doesNotMatch(mainSource, /allow-same-origin/);
});
