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

test("preview edit button shows the Cmd+E shortcut hint", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /local-document-action-button-shortcut/);
  assert.match(source, />⌘E<\/span>/);
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

test("line reveal helpers clamp requests and compute layout from measured base offsets", async () => {
  const lineRevealModule = await import(
    new URL("../src/lineReveal.mjs", import.meta.url).href
  );
  const { clampRevealLineNumber, clampScrollTop, computeRevealLayout } = lineRevealModule;

  assert.equal(clampRevealLineNumber(42, 12), 12);
  assert.equal(clampRevealLineNumber(0, 12), 1);
  assert.equal(clampRevealLineNumber(3, 0), 1);
  assert.equal(clampScrollTop(-40, 200), 0);
  assert.equal(clampScrollTop(400, 200), 200);
  // Measurement-driven helpers replaced the previous fallback-from-block-height
  // line-height resolver — keep it removed so callers cannot accidentally rely
  // on that brittle path again.
  assert.equal(lineRevealModule.resolveMeasuredLineHeight, undefined);
  assert.deepEqual(
    computeRevealLayout({
      lineNumber: 120,
      lineCount: 134,
      contentTopBase: 20,
      gutterTopBase: 20,
      contentLineHeight: 22,
      gutterLineHeight: 22,
      contentFrameOffsetTop: 0,
      scrollViewportHeight: 400,
      scrollContentHeight: 3200
    }),
    {
      lineNumber: 120,
      contentTop: 2638,
      gutterTop: 2638,
      contentHeight: 22,
      gutterHeight: 22,
      targetScrollTop: 2509
    }
  );
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
  assert.match(source, /measureRevealLayout\(\{/);
  // Reveal positioning anchors on the actual rendered first-line geometry so
  // the gutter and content highlights line up regardless of pre/code padding.
  assert.match(source, /measureFirstRenderedLineTop\(/);
  assert.match(source, /range\.selectNodeContents\(element\)/);
  assert.match(source, /range\.getClientRects\(\)/);
  assert.match(source, /setRevealLayout\(null\);/);
  assert.match(source, /revealScrollSequenceRef/);
  assert.match(source, /window\.requestAnimationFrame\(\(\) => \{/);
  assert.match(source, /revealScrollSequence !== revealScrollSequenceRef\.current/);
  assert.match(source, /scrollElement\.scrollTop = revealLayout\.targetScrollTop/);
  assert.match(source, /event\.key !== "Escape"/);
  assert.doesNotMatch(source, /document\.hasFocus/);
  assert.doesNotMatch(source, /getPropertyValue\("--local-document-code-line-height"\)/);
  assert.doesNotMatch(source, /resolvedLineHeight\(/);
  assert.doesNotMatch(source, /resolveMeasuredLineHeight\(/);
  assert.match(source, /props\.bootstrap\.contentRevision !== activeReveal\.contentRevision/);
  assert.match(source, /props\.bootstrap\.filePath !== activeReveal\.filePath/);
  assert.match(source, /setActiveReveal\(null\)/);
  assert.match(source, /top: `\$\{revealLayout\.contentTop}px`/);
  assert.match(source, /height: `\$\{revealLayout\.contentHeight}px`/);
  assert.match(source, /top: `\$\{revealLayout\.gutterTop}px`/);
  assert.match(source, /height: `\$\{revealLayout\.gutterHeight}px`/);
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

test("styles bound the panel to the viewport so .local-document-code-scroll is the actual reveal scroller", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/styles.css"),
    "utf8"
  );

  // The reveal handler assigns scrollTop on .local-document-code-scroll. That
  // only scrolls when the document chain is bounded — otherwise the page
  // itself becomes the scroller and the reveal jump is a no-op.
  assert.match(source, /html,\s*body \{\s*height: 100%;/);
  assert.match(source, /body \{[^}]*overflow: hidden;/);
  assert.match(source, /#root \{\s*height: 100%;/);
  assert.match(source, /\.local-document-shell \{\s*height: 100%;/);
  assert.doesNotMatch(source, /\.local-document-shell \{\s*min-height: 100vh;/);
});
