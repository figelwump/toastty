import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("markdown edit mode uses a wrapping textarea while code formats stay preformatted", async () => {
  const source = await readFile(
    resolve(packageRoot, "src/LocalDocumentPanelApp.tsx"),
    "utf8"
  );
  const styles = await readFile(resolve(packageRoot, "src/styles.css"), "utf8");

  assert.match(source, /const wrapsMarkdown = isMarkdownFormat\(props\.bootstrap\.format\);/);
  assert.match(
    source,
    /className=\{editorClassName\}[\s\S]*?wrap=\{wrapsMarkdown \? "soft" : "off"\}/
  );
  assert.match(
    styles,
    /\.local-document-editor-markdown\s*\{[\s\S]*?white-space:\s*pre-wrap;[\s\S]*?overflow-wrap:\s*anywhere;/
  );
});
