import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

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
  assert.match(source, /MutationObserver/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerReady\(\)/);
  assert.match(source, /localDocumentNativeBridge\.searchControllerUnavailable\(\)/);
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
