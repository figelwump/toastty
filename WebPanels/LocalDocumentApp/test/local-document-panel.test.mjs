import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("edit mode uses a non-wrapping code textarea for all supported formats", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(
    source,
    /className="local-document-editor"[\s\S]*?wrap="off"/
  );
});

test("plain-code formats guard null highlight languages before touching highlight.js", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(
    source,
    /language === null \|\| !hljs\.getLanguage\(language\)/
  );
});

test("jsonc files opt out of json highlighting and keep a JSONC label", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /filePath\?\.toLowerCase\(\)\.endsWith\("\.jsonc"\)/);
  assert.match(source, /return "JSONC"/);
});

test("line reveal helpers clamp requests and choose reduced-motion-safe scroll behavior", async () => {
  const {
    REVEAL_HIGHLIGHT_DURATION_MS,
    clampRevealLineNumber,
    clampScrollTop,
    revealScrollBehavior
  } = await import(
    new URL("../src/lineReveal.mjs", import.meta.url).href
  );

  assert.equal(REVEAL_HIGHLIGHT_DURATION_MS, 1800);
  assert.equal(clampRevealLineNumber(42, 12), 12);
  assert.equal(clampRevealLineNumber(0, 12), 1);
  assert.equal(clampRevealLineNumber(3, 0), 1);
  assert.equal(clampScrollTop(-40, 200), 0);
  assert.equal(clampScrollTop(400, 200), 200);
  assert.equal(revealScrollBehavior(true), "auto");
  assert.equal(revealScrollBehavior(false), "smooth");
});

test("bootstrap bridge exposes one-shot line reveal registration and consumption", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/bootstrap.ts"),
    "utf8"
  );

  assert.match(source, /revealLine: \(lineNumber: number\) => void/);
  assert.match(source, /getCurrentRevealRequest: \(\) => LocalDocumentLineRevealRequest \| null/);
  assert.match(source, /consumeRevealRequest: \(requestID: number\) => void/);
  assert.match(source, /subscribeReveal: \(listener: RevealListener\) => \(\) => void/);
});

test("code view consumes reveal requests, clamps the target line, and clears the highlight after a timeout", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /window\.ToasttyLocalDocumentPanel\?\.consumeRevealRequest\(revealRequest\.requestID\)/);
  assert.match(source, /const targetLineNumber = clampRevealLineNumber\(revealRequest\.lineNumber, lines\.length\)/);
  assert.match(source, /className="local-document-code-line-reveal"/);
  assert.match(source, /window\.setTimeout\(\(\) => \{/);
  assert.match(source, /REVEAL_HIGHLIGHT_DURATION_MS/);
});

test("build script copies onig.wasm into the panel output bundle", async () => {
  const source = await readFile(
    resolve(packageRoot, "scripts/build.mjs"),
    "utf8"
  );

  assert.match(source, /vscode-oniguruma\/release\/onig\.wasm/);
  assert.match(source, /copyFileSync\(onigurumaWasmPath, join\(outputDir, "onig\.wasm"\)\)/);
  assert.match(source, /__TOASTTY_ONIG_WASM_DATA_URL__/);
  assert.match(source, /data:application\/wasm;base64/);
});

test("build script supports overriding the output directory for bundle sync checks", async () => {
  const source = await readFile(
    resolve(packageRoot, "scripts/build.mjs"),
    "utf8"
  );

  assert.match(source, /TOASTTY_LOCAL_DOCUMENT_PANEL_OUTPUT_DIR/);
});

test("bundle sync check rebuilds into a temporary output directory and compares the shipped assets", async () => {
  const source = await readFile(
    resolve(packageRoot, "scripts/check-bundle-sync.mjs"),
    "utf8"
  );

  assert.match(source, /TOASTTY_LOCAL_DOCUMENT_PANEL_OUTPUT_DIR/);
  assert.match(source, /local-document-panel\.js/);
  assert.match(source, /local-document-panel\.css/);
  assert.match(source, /onig\.wasm/);
  assert.match(source, /Checked-in local document panel assets are out of sync\./);
});
