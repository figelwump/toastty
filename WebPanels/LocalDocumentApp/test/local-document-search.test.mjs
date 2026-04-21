import assert from "node:assert/strict";
import test, { after } from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { build } from "esbuild";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let searchModulePromise;

async function loadLocalDocumentSearchModule() {
  if (!searchModulePromise) {
    searchModulePromise = (async () => {
      const tempDirectory = await mkdtemp(resolve(tmpdir(), "toastty-local-document-search-"));
      const outputPath = resolve(tempDirectory, "localDocumentSearch.mjs");

      await build({
        absWorkingDir: packageRoot,
        bundle: true,
        entryPoints: [resolve(packageRoot, "src/localDocumentSearch.ts")],
        format: "esm",
        outfile: outputPath,
        platform: "browser",
        target: "es2022"
      });

      const module = await import(pathToFileURL(outputPath).href);
      return {
        module,
        dispose: () => rm(tempDirectory, { recursive: true, force: true })
      };
    })();
  }

  return searchModulePromise;
}

after(async () => {
  if (!searchModulePromise) {
    return;
  }

  const { dispose } = await searchModulePromise;
  await dispose();
});

test("bootstrap exposes imperative search commands for the native runtime bridge", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/bootstrap.ts"),
    "utf8"
  );

  assert.match(source, /registerSearchController/);
  assert.match(source, /performSearchCommand/);
  assert.match(source, /setCurrentSearchState/);
  assert.match(source, /resetSearchState/);
  assert.match(source, /localDocumentNativeBridge\.bridgeReady\(\)/);
  assert.match(source, /return null;/);
  assert.match(source, /type: "setQuery"/);
  assert.match(source, /type: "next"/);
  assert.match(source, /type: "previous"/);
  assert.match(source, /type: "clear"/);
  assert.match(source, /currentSearchController\.perform\(\{ type: "clear" \}\)/);
});

test("local-document search keeps preview highlights in the DOM layer and editor matches in the textarea selection", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/localDocumentSearch.ts"),
    "utf8"
  );

  assert.match(source, /MATCH_HIGHLIGHT_NAME/);
  assert.match(source, /ACTIVE_HIGHLIGHT_NAME/);
  assert.match(source, /registry\.set\(MATCH_HIGHLIGHT_NAME/);
  assert.match(source, /registry\.set\(ACTIVE_HIGHLIGHT_NAME/);
  assert.match(source, /textarea\.setSelectionRange/);
  assert.match(source, /scrollEditorMatchIntoView/);
  assert.match(source, /previewLineIndexForOffset/);
  assert.match(source, /range\.getClientRects\(\)/);
  assert.match(source, /root\.scrollTop = centeredPreviewScrollTop/);
  assert.match(source, /root\.scrollLeft = previewNearestScrollOffset/);
  assert.match(source, /MutationObserver/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerReady\(\)/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerUnavailable\(\)/);
});

test("preview search uses the dedicated scroll container as the preview root", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /<pre ref=\{props\.previewRootRef\} className="local-document-code-scroll">/);
});

test("centered preview scroll clamps top matches to the container origin", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.centeredPreviewScrollTop({
      containerHeight: 480,
      targetTop: 18,
      targetHeight: 21.45
    }),
    0
  );
});

test("centered preview scroll moves lower matches into the viewport center", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.centeredPreviewScrollTop({
      containerHeight: 480,
      targetTop: 700,
      targetHeight: 21.45
    }),
    470.725
  );
});

test("preview line index tracks the top-to-bottom line ordering for match offsets", async () => {
  const { module } = await loadLocalDocumentSearchModule();
  const text = "alpha\nbeta\ngamma";

  assert.equal(module.previewLineIndexForOffset(text, 0), 0);
  assert.equal(module.previewLineIndexForOffset(text, 5), 0);
  assert.equal(module.previewLineIndexForOffset(text, 6), 1);
  assert.equal(module.previewLineIndexForOffset(text, text.length), 2);
});

test("preview scroll offset converts viewport rect coordinates into scroll-space coordinates", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.previewScrollOffsetInScrollSpace({
      currentScroll: 480,
      containerStart: 100,
      targetStart: 620
    }),
    1000
  );
});

test("preview nearest scroll offset keeps already visible matches stable", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.previewNearestScrollOffset({
      currentScroll: 80,
      containerSize: 320,
      targetStart: 120,
      targetSize: 90
    }),
    80
  );
});

test("preview nearest scroll offset reveals matches beyond the right edge", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.previewNearestScrollOffset({
      currentScroll: 40,
      containerSize: 300,
      targetStart: 390,
      targetSize: 60
    }),
    150
  );
});

test("preview nearest scroll offset reveals matches before the left edge", async () => {
  const { module } = await loadLocalDocumentSearchModule();

  assert.equal(
    module.previewNearestScrollOffset({
      currentScroll: 120,
      containerSize: 300,
      targetStart: 45,
      targetSize: 30
    }),
    45
  );
});

test("search styles define distinct preview match and active-match highlights", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/styles.css"),
    "utf8"
  );

  assert.match(source, /--find-match-bg/);
  assert.match(source, /--find-active-bg/);
  assert.match(source, /::highlight\(toastty-local-document-find-match\)/);
  assert.match(source, /::highlight\(toastty-local-document-find-active\)/);
});
