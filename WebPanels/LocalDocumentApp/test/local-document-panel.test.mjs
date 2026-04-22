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

test("editor mount focuses the textarea and moves the caret to the file start", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /React\.useLayoutEffect\(\(\) => \{/);
  assert.match(source, /props\.textareaRef\.current/);
  assert.match(source, /textarea\.focus\(\)/);
  assert.match(source, /textarea\.setSelectionRange\(0, 0\)/);
  assert.match(source, /ref=\{props\.textareaRef\}/);
});

test("markdown read-only code view uses a dedicated wrapped source layout", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /if \(props\.bootstrap\.format === "markdown"\)/);
  assert.match(source, /className="local-document-code-frame local-document-code-frame-markdown"/);
  assert.match(source, /renderPlainMarkdownSourceHtml\(props\.content\)/);
  assert.match(source, /useMarkdownLogicalLineLayout\(/);
  assert.match(source, /className="local-document-code-markdown-gutter"/);
  assert.match(source, /className="local-document-code-markdown-gutter-inner"/);
  assert.match(source, /className="local-document-code-markdown-surface"/);
  assert.match(source, /--local-document-code-gutter-digit-width/);
  assert.match(source, /Math\.max\(String\(props\.lines\.length\)\.length, 2\)\}ch/);
  assert.match(source, /\? "starry-night local-document-code-markdown"/);
  assert.match(source, /: "local-document-code-plain local-document-code-plain-markdown"/);
  assert.match(source, /MARKDOWN_LINE_START_SELECTOR/);
  assert.match(source, /style=\{\{\s*top: `\$\{lineLayout\.lineOffsets\[index\]/);
  assert.doesNotMatch(source, /splitHighlightedMarkdownIntoLogicalLines/);
});

test("markdown gutter stays non-selectable while wrapped content stays continuous", async () => {
  const styles = await readFile(
    resolve(packageRoot, "src/styles.css"),
    "utf8"
  );

  assert.match(styles, /\.local-document-code-gutter-cell[\s\S]*user-select: none/);
  assert.match(styles, /\.local-document-code-frame\s*\{[^}]*--local-document-code-gutter-padding-left: 18px/);
  assert.match(styles, /\.local-document-code-frame\s*\{[^}]*--local-document-code-gutter-padding-right: 10px/);
  assert.match(styles, /\.local-document-code-gutter\s*\{[^}]*padding: 20px var\(--local-document-code-gutter-padding-right\) 28px var\(--local-document-code-gutter-padding-left\)/);
  assert.match(styles, /\.local-document-code-markdown-gutter\s*\{[^}]*min-width: calc\(/);
  assert.match(styles, /\.local-document-code-markdown-gutter\s*\{[^}]*var\(--local-document-code-gutter-digit-width\)/);
  assert.match(styles, /\.local-document-code-markdown-gutter-inner\s*\{[^}]*position: relative/);
  assert.match(
    styles,
    /\.local-document-code-gutter-cell-markdown\s*\{[^}]*position: absolute/
  );
  assert.doesNotMatch(
    styles,
    /\.local-document-code-markdown-gutter\s*\{[^}]*display: flex/
  );
  assert.match(styles, /\.local-document-code-markdown-surface/);
  assert.match(styles, /\.local-document-code-markdown-surface\s*\{[^}]*position: relative/);
  assert.match(
    styles,
    /\.local-document-code-plain,\s*\.local-document-code-markdown\s*\{[^}]*font-size: calc\(13px \* var\(--toastty-markdown-text-scale\)\)/
  );
  assert.match(
    styles,
    /\.local-document-code-plain,\s*\.local-document-code-markdown\s*\{[^}]*line-height: var\(--local-document-code-line-height\)/
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

test("native bridge forwards local-document diagnostics and render lifecycle events", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/nativeBridge.ts"),
    "utf8"
  );

  assert.match(source, /type: "consoleMessage"/);
  assert.match(source, /type: "javascriptError"/);
  assert.match(source, /type: "unhandledRejection"/);
  assert.match(source, /type: "renderReady"/);
  assert.match(source, /consoleMessage\(level: "warn" \| "error", message: string\)/);
  assert.match(source, /javascriptError\(/);
  assert.match(source, /unhandledRejection\(reason: string, stack: string \| null\)/);
  assert.match(source, /renderReady\(displayName: string, contentRevision: number, isEditing: boolean\)/);
});

test("bootstrap installs diagnostic forwarding for console and unhandled page failures", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/bootstrap.ts"),
    "utf8"
  );

  assert.match(source, /window\.__toasttyLocalDocumentDiagnosticsInstalled/);
  assert.match(source, /console\.warn = \(...args: unknown\[\]\) => \{/);
  assert.match(source, /console\.error = \(...args: unknown\[\]\) => \{/);
  assert.match(source, /window\.addEventListener\("error",/);
  assert.match(source, /window\.addEventListener\("unhandledrejection",/);
  assert.match(source, /localDocumentNativeBridge\.consoleMessage\("warn"/);
  assert.match(source, /localDocumentNativeBridge\.consoleMessage\("error"/);
  assert.match(source, /localDocumentNativeBridge\.javascriptError\(/);
  assert.match(source, /localDocumentNativeBridge\.unhandledRejection\(/);
});

test("panel app reports render readiness once bootstrap-backed content is mounted", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /React\.useEffect\(\(\) => \{/);
  assert.match(source, /if \(!bootstrap\) \{/);
  assert.match(source, /localDocumentNativeBridge\.renderReady\(/);
  assert.match(source, /bootstrap\.displayName/);
  assert.match(source, /bootstrap\.contentRevision/);
  assert.match(source, /bootstrap\.isEditing/);
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
  const {
    clampRevealLineNumber,
    clampScrollTop,
    computeOffsetRevealLayout,
    computeRevealLayout
  } = lineRevealModule;

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
  assert.deepEqual(
    computeOffsetRevealLayout({
      lineNumber: 47,
      lineCount: 80,
      lineOffsets: Array.from({ length: 80 }, (_, index) => index * 22).map((offset, index) => (
        index === 46 ? 1240 : index === 47 ? 1286 : offset
      )),
      contentTopInset: 20,
      gutterTopInset: 0,
      scrollContentOffsetTop: 0,
      lineHeight: 22,
      scrollViewportHeight: 400,
      scrollContentHeight: 2200
    }),
    {
      lineNumber: 47,
      contentTop: 1260,
      gutterTop: 1240,
      contentHeight: 46,
      gutterHeight: 46,
      targetScrollTop: 1131
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
  // Reveal positioning directly measures line N's glyph rect and centers
  // a line-height-tall band around that glyph. First-line geometry is
  // retained as an empty-line fallback.
  assert.match(source, /measureDirectLineGlyph\(/);
  assert.match(source, /createTreeWalker\(element, NodeFilter\.SHOW_TEXT\)/);
  assert.match(source, /measureFirstRenderedLineGlyph\(/);
  assert.match(source, /range\.selectNodeContents\(element\)/);
  assert.match(source, /range\.getClientRects\(\)/);
  assert.match(source, /args\.lineHeight - direct\.height/);
  assert.match(source, /args\.lineHeight - firstGlyph\.height/);
  // Empty-line fallback extrapolates from the nearest non-empty neighbor so
  // we don't depend on rects[0] from selectNodeContents being line 1 (a long,
  // decorated WKWebView code block has been seen to return a first rect that
  // sits many lines below actual line 1).
  assert.match(source, /args\.lineHeight - candidate\.height/);
  assert.match(source, /args\.lineNumber \+ offset/);
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

test("markdown code view measures reveal layout from logical line offsets and renders the same reveal bands", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /function useMarkdownRevealLayout\(args: \{/);
  assert.match(source, /computeOffsetRevealLayout\(\{/);
  assert.match(source, /contentTopInset: contentElement\.offsetTop/);
  assert.match(source, /scrollContentOffsetTop: contentSurfaceElement\.offsetTop/);
  assert.match(source, /activeReveal: ActiveReveal \| null;/);
  assert.match(source, /const revealLayout = useMarkdownRevealLayout\(\{/);
  assert.match(source, /activeReveal: props\.activeReveal/);
  assert.match(source, /activeReveal=\{activeReveal\}/);
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
  assert.match(source, /\.local-document-code-gutter-frame \{[^}]*background: var\(--pre-bg\);/);
  assert.match(source, /\.local-document-code-gutter-reveal \{/);
  assert.match(source, /\.local-document-code-gutter-reveal \{[^}]*linear-gradient\(var\(--pre-bg\), var\(--pre-bg\)\)/);
  assert.match(source, /\.local-document-code-gutter-reveal \{[^}]*background-size: 100% 100%, var\(--local-document-code-gutter-divider-width\) 100%/);
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
