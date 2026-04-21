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

test("markdown read-only code view uses a dedicated wrapped source layout", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /if \(props\.bootstrap\.format === "markdown"\)/);
  assert.match(source, /className="local-document-code-frame local-document-code-frame-markdown"/);
  assert.match(source, /trimMarkdownLineBoundaryNewlines\(container\.innerHTML\)/);
  assert.match(source, /<div className="local-document-code-markdown-line">/);
  assert.match(source, /className="starry-night local-document-code-markdown"/);
  assert.match(source, /className="local-document-code-plain local-document-code-plain-markdown"/);
  assert.match(source, /MARKDOWN_LINE_START_SELECTOR/);
  assert.doesNotMatch(source, /<pre className="local-document-code-markdown-line">/);
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

test("jsonl files reuse the json grammar", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /case "jsonl":\s+return "json";/);
});

test("highlight status copy distinguishes large files from unsupported formats", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /case "disabledForLargeFile":/);
  assert.match(source, /case "unsupportedFormat":/);
  assert.match(source, /JSONC files yet/);
  assert.match(source, /this format yet/);
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
