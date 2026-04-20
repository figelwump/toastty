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

  assert.match(html, /class="pl-s">\*\*<\/span><span class="pl-mb">bold<\/span><span class="pl-s">\*\*<\/span>/);
  assert.match(html, /class="pl-s">\*<\/span><span class="pl-mi">italic<\/span><span class="pl-s">\*<\/span>/);
  assert.match(html, /class="pl-s">`<\/span><span class="pl-c1">inline<\/span><span class="pl-s">`<\/span>/);
});

test("markdown source highlighting colors fenced code using the declared language", async () => {
  const html = await highlightMarkdownSourceToHtml("```js\nconst answer = 42\n```");

  assert.match(html, /class="pl-s">```<\/span><span class="pl-en">js<\/span>/);
  assert.match(html, /class="pl-k">const<\/span>/);
  assert.match(html, /class="pl-c1">42<\/span>/);
});

test("ordered list markers render as a single markdown list token", async () => {
  const html = await highlightMarkdownSourceToHtml("1. Confirm\n2. Require");

  assert.match(html, /class="pl-ml">1\.<\/span> Confirm/);
  assert.match(html, /class="pl-ml">2\.<\/span> Require/);
  assert.doesNotMatch(html, /class="pl-s">1<\/span><span class="pl-v">\.<\/span>/);
});

test("ordered list normalization also covers multi-digit markers", async () => {
  const html = await highlightMarkdownSourceToHtml("10. Confirm\n100. Require");

  assert.match(html, /class="pl-ml">10\.<\/span> Confirm/);
  assert.match(html, /class="pl-ml">100\.<\/span> Require/);
});

test("escaped emphasis markers stay literal", async () => {
  const html = await highlightMarkdownSourceToHtml("\\*escaped\\*");

  assert.match(html, /class="pl-c1">\\\*<\/span>escaped<span class="pl-c1">\\\*<\/span>/);
  assert.doesNotMatch(html, /class="pl-mi">escaped<\/span>/);
});

test("ordered list normalization does not rewrite code-fence contents", async () => {
  const html = await highlightMarkdownSourceToHtml("```\n10. not a list\n```");

  assert.match(html, /class="pl-c1">10\. not a list<\/span>/);
  assert.doesNotMatch(html, /class="pl-ml">10\.<\/span>/);
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
