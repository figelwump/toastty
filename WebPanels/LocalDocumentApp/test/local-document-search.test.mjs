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

function makeTextarea({
  value,
  selectionStart = 0,
  selectionEnd = selectionStart,
  clientHeight = 120,
  scrollTop = 0
}) {
  return {
    value,
    selectionStart,
    selectionEnd,
    clientHeight,
    scrollTop,
    setSelectionRangeCalls: [],
    setSelectionRange(start, end, direction) {
      this.selectionStart = start;
      this.selectionEnd = end;
      this.setSelectionRangeCalls.push({ start, end, direction });
    }
  };
}

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
  assert.match(source, /FALLBACK_MATCH_CLASS/);
  assert.match(source, /FALLBACK_ACTIVE_CLASS/);
  assert.match(source, /registry\.set\(MATCH_HIGHLIGHT_NAME/);
  assert.match(source, /registry\.set\(ACTIVE_HIGHLIGHT_NAME/);
  assert.match(source, /wrapRangeInHighlightSpan/);
  assert.match(source, /extractContents\(\)/);
  assert.match(source, /textarea\.setSelectionRange/);
  assert.match(source, /scrollEditorMatchIntoView/);
  assert.match(source, /previewLineIndexForOffset/);
  assert.match(source, /range\.getClientRects\(\)/);
  assert.match(source, /root\.scrollTop = centeredPreviewScrollTop/);
  assert.match(source, /root\.scrollLeft = previewNearestScrollOffset/);
  assert.match(source, /MutationObserver/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerReady\(\)/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerUnavailable\(\)/);
  assert.doesNotMatch(source, /addRange\(/);
});

test("preview search keeps separate scroll and content refs for the preview surface", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );

  assert.match(source, /previewRootRef/);
  assert.match(source, /previewContentRef/);
  assert.match(source, /className="local-document-code-scroll"/);
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
  assert.match(source, /\.toastty-local-document-find-match-fallback/);
  assert.match(source, /\.toastty-local-document-find-active-fallback/);
});

test("edit-mode content refresh uses passive editor search updates", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/localDocumentSearch.ts"),
    "utf8"
  );

  assert.match(source, /applyEditorSearchForTesting/);
  assert.match(source, /type EditorSearchMode = "interactive" \| "passive"/);
  assert.match(source, /if \(isEditing\) \{\s*return;\s*\}\s*\n\s*applyCommand\(\{ type: "setQuery", query: currentQuery \}\);/);
  assert.match(source, /applyEditorSearch\(\s*textareaRef\.current,[\s\S]*?"passive"/);
});

test("passive editor refresh clamps the active match without moving selection or scroll", async () => {
  const { module } = await loadLocalDocumentSearchModule();
  const textarea = makeTextarea({
    value: "alpha\nbeta\ngamma",
    selectionStart: 4,
    selectionEnd: 4,
    scrollTop: 160
  });
  const selectionSnapshotRef = {
    current: { start: 1, end: 3 }
  };

  const nextState = module.applyEditorSearchForTesting(
    textarea,
    { type: "setQuery", query: "alpha" },
    {
      query: "alpha",
      matchCount: 2,
      activeMatchIndex: 1,
      matchFound: true
    },
    selectionSnapshotRef,
    "passive"
  );

  assert.deepEqual(nextState, {
    query: "alpha",
    matchCount: 1,
    activeMatchIndex: 0,
    matchFound: true
  });
  assert.equal(textarea.setSelectionRangeCalls.length, 0);
  assert.equal(textarea.scrollTop, 160);
  assert.equal(selectionSnapshotRef.current, null);
});

test("interactive editor search still selects and scrolls to the active match", async () => {
  const { module } = await loadLocalDocumentSearchModule();
  const previousWindow = globalThis.window;
  globalThis.window = {
    ...(previousWindow ?? {}),
    getComputedStyle() {
      return {
        lineHeight: "20",
        fontSize: "12"
      };
    }
  };

  try {
    const value = `${"line\n".repeat(24)}needle\n${"line\n".repeat(10)}needle`;
    const firstMatchStart = value.indexOf("needle");
    const secondMatchStart = value.indexOf("needle", firstMatchStart + 1);
    const textarea = makeTextarea({
      value,
      selectionStart: 0,
      selectionEnd: 0,
      clientHeight: 100,
      scrollTop: 0
    });
    const selectionSnapshotRef = {
      current: { start: 0, end: 0 }
    };

    const nextState = module.applyEditorSearchForTesting(
      textarea,
      { type: "setQuery", query: "needle" },
      {
        query: "needle",
        matchCount: 2,
        activeMatchIndex: 1,
        matchFound: true
      },
      selectionSnapshotRef,
      "interactive"
    );

    assert.equal(textarea.setSelectionRangeCalls.length, 1);
    assert.deepEqual(textarea.setSelectionRangeCalls[0], {
      start: secondMatchStart,
      end: secondMatchStart + "needle".length,
      direction: "forward"
    });
    assert.ok(textarea.scrollTop > 0);
    assert.deepEqual(nextState, {
      query: "needle",
      matchCount: 2,
      activeMatchIndex: 1,
      matchFound: true
    });
    assert.deepEqual(selectionSnapshotRef.current, { start: 0, end: 0 });
  } finally {
    globalThis.window = previousWindow;
  }
});

test("clearing find after an edit keeps the current caret when the pre-find snapshot is invalidated", async () => {
  const { module } = await loadLocalDocumentSearchModule();
  const textarea = makeTextarea({
    value: "alpha\nbeta",
    selectionStart: 5,
    selectionEnd: 5,
    scrollTop: 90
  });
  const selectionSnapshotRef = {
    current: null
  };

  const nextState = module.applyEditorSearchForTesting(
    textarea,
    { type: "clear" },
    {
      query: "alpha",
      matchCount: 1,
      activeMatchIndex: 0,
      matchFound: true
    },
    selectionSnapshotRef,
    "interactive"
  );

  assert.deepEqual(nextState, {
    query: "",
    matchCount: 0,
    activeMatchIndex: null,
    matchFound: false
  });
  assert.deepEqual(textarea.setSelectionRangeCalls, [{
    start: 5,
    end: 5,
    direction: "none"
  }]);
  assert.equal(selectionSnapshotRef.current, null);
});
