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

test("generated iframe forwards diagnostics through the parent frame", () => {
  assert.match(sandboxSource, /toastty:scratchpad-generated-diagnostic:v1/);
  assert.match(sandboxSource, /window\.parent\?\.postMessage\(\{ type: messageType, sessionToken, event \}/);
  assert.match(sandboxSource, /securitypolicyviolation/);
  assert.match(sandboxSource, /truncate\(event\.blockedURI, 512\)/);
  assert.match(mainSource, /window\.addEventListener\("message"/);
  assert.match(mainSource, /event\.source !== currentGeneratedContentWindow/);
  assert.match(mainSource, /event\.data\.sessionToken !== currentGeneratedContentDiagnosticsToken/);
  assert.match(mainSource, /optionalDiagnosticString\(event\.blockedURI, 512\)/);
  assert.match(mainSource, /"generated-content"/);
});
