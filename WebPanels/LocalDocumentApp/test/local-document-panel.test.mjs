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

test("code highlighting uses bootstrap syntax metadata instead of file-path parsing", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /bootstrap\.syntaxLanguage/);
  assert.doesNotMatch(source, /toLowerCase\(\)\.endsWith\("\.jsonc"\)/);
});

test("header uses bootstrap-provided format labels", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /bootstrap\.formatLabel/);
});

test("highlight status copy distinguishes large files from unsupported formats", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /case "disabledForLargeFile":/);
  assert.match(source, /case "unsupportedFormat":/);
  assert.match(source, /formatLabel === "JSONC"/);
  assert.match(source, /JSONC files yet/);
  assert.match(source, /this format yet/);
});

test("read mode exposes an Open in Default App action through the native bridge", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );
  const stylesSource = await readFile(
    resolve(packageRoot, "src/styles.css"),
    "utf8"
  );
  const bridgeSource = await readFile(
    resolve(packageRoot, "src/nativeBridge.ts"),
    "utf8"
  );

  assert.match(source, /aria-label="Open in Default App"/);
  assert.match(source, /title="Open in Default App"/);
  assert.match(source, /local-document-action-button-icon/);
  assert.match(source, /<ExternalOpenIcon \/>/);
  assert.match(stylesSource, /\.local-document-action-button-icon/);
  assert.match(bridgeSource, /type: "openInDefaultApp"/);
  assert.match(bridgeSource, /openInDefaultApp\(\)/);
});

test("highlight.js registers the first-slice source-code grammars", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /highlight\.js\/lib\/languages\/swift/);
  assert.match(source, /highlight\.js\/lib\/languages\/javascript/);
  assert.match(source, /highlight\.js\/lib\/languages\/typescript/);
  assert.match(source, /highlight\.js\/lib\/languages\/python/);
  assert.match(source, /highlight\.js\/lib\/languages\/go/);
  assert.match(source, /highlight\.js\/lib\/languages\/rust/);
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
