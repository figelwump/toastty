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
    clampRevealLineNumber,
    clampScrollTop
  } = await import(
    new URL("../src/lineReveal.mjs", import.meta.url).href
  );

  assert.equal(clampRevealLineNumber(42, 12), 12);
  assert.equal(clampRevealLineNumber(0, 12), 1);
  assert.equal(clampRevealLineNumber(3, 0), 1);
  assert.equal(clampScrollTop(-40, 200), 0);
  assert.equal(clampScrollTop(400, 200), 200);
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

test("code view keeps reveal state sticky, clears it on escape, and scrolls with a direct layout-synchronized scrollTop assignment", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /window\.ToasttyLocalDocumentPanel\?\.consumeRevealRequest\(revealRequest\.requestID\)/);
  assert.match(source, /const targetLineNumber = clampRevealLineNumber\(revealRequest\.lineNumber, lines\.length\)/);
  assert.match(source, /targetScrollTop,/);
  assert.match(source, /revealScrollSequenceRef/);
  assert.match(source, /window\.requestAnimationFrame\(\(\) => \{/);
  assert.match(source, /revealScrollSequence !== revealScrollSequenceRef\.current/);
  assert.match(source, /scrollElement\.scrollTop = activeReveal\.targetScrollTop/);
  assert.match(source, /event\.key !== "Escape"/);
  assert.doesNotMatch(source, /document\.hasFocus/);
  assert.match(source, /props\.bootstrap\.contentRevision !== activeReveal\.contentRevision/);
  assert.match(source, /props\.bootstrap\.filePath !== activeReveal\.filePath/);
  assert.match(source, /setActiveReveal\(null\)/);
  assert.match(source, /className="local-document-code-line-reveal"/);
  assert.match(source, /className="local-document-code-gutter-reveal"/);
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

test("styles keep the gutter sticky and use flat reveal highlights for both the gutter and content rows", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/styles.css"),
    "utf8"
  );

  assert.match(source, /\.local-document-code-gutter-frame \{\s*position: sticky;/);
  assert.match(source, /\.local-document-code-gutter-reveal \{/);
  assert.match(source, /\.local-document-code-line-reveal,\s*\.local-document-code-gutter-reveal \{/);
  assert.doesNotMatch(source, /animation: local-document-line-reveal/);
  assert.doesNotMatch(source, /border-radius: 8px/);
});
