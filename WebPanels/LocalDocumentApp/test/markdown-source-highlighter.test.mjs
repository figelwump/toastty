import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  highlightMarkdownSourceToHtml,
  resolveBrowserOnigurumaUrl
} from "../src/markdownSourceHighlighter.mjs";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("markdown source highlighting colors inline emphasis and code spans", async () => {
  const html = await highlightMarkdownSourceToHtml("**bold** *italic* `inline`");

  assert.match(html, /class="pl-s">\*\*<\/span>bold<span class="pl-s">\*\*<\/span>/);
  assert.match(html, /class="pl-s">\*<\/span>italic<span class="pl-s">\*<\/span>/);
  assert.match(html, /class="pl-s">`<\/span><span class="pl-c1">inline<\/span><span class="pl-s">`<\/span>/);
});

test("markdown source highlighting colors fenced code using the declared language", async () => {
  const html = await highlightMarkdownSourceToHtml("```js\nconst answer = 42\n```");

  assert.match(html, /class="pl-s">```<\/span><span class="pl-en">js<\/span>/);
  assert.match(html, /class="pl-k">const<\/span>/);
  assert.match(html, /class="pl-c1">42<\/span>/);
});

test("browser wasm URL resolution prefers the bundled data URL", () => {
  const url = resolveBrowserOnigurumaUrl(
    "file:///tmp/local-document-panel/index.html",
    "data:application/wasm;base64,AAAA"
  );

  assert.equal(url.href, "data:application/wasm;base64,AAAA");
});

test("browser wasm URL resolution falls back to the sibling asset path", () => {
  const url = resolveBrowserOnigurumaUrl(
    "file:///tmp/local-document-panel/index.html",
    null
  );

  assert.equal(url.href, "file:///tmp/local-document-panel/onig.wasm");
});

test("styles include starry-night token classes for markdown punctuation and emphasis", async () => {
  const styles = await readFile(resolve(packageRoot, "src/styles.css"), "utf8");

  assert.match(styles, /\.pl-s[\s\S]*color: var\(--color-prettylights-syntax-string\)/);
  assert.match(styles, /\.pl-mi[\s\S]*font-style: italic/);
  assert.match(styles, /\.pl-mb[\s\S]*font-weight: 700/);
  assert.match(styles, /\.pl-k[\s\S]*color: var\(--color-prettylights-syntax-keyword\)/);
});
