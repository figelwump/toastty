import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const helpers = await import(new URL("../src/formattedMarkdown.mjs", import.meta.url).href);

async function renderFormatted(content, { filePath = "/Users/me/notes/plan.md", opensLocalFiles = true } = {}) {
  const result = await build({
    stdin: {
      contents: `
        import React from "react";
        import { renderToStaticMarkup } from "react-dom/server";
        import { FormattedMarkdownView } from "./src/FormattedMarkdownView";
        export function render(props) {
          return renderToStaticMarkup(React.createElement(FormattedMarkdownView, {
            ...props,
            previewRootRef: { current: null },
            previewContentRef: { current: null },
            onOpenLink() {}
          }));
        }
      `,
      resolveDir: new URL("..", import.meta.url).pathname,
      loader: "tsx"
    },
    bundle: true,
    write: false,
    format: "cjs",
    platform: "node",
    jsx: "automatic",
    define: { __TOASTTY_ONIG_WASM_DATA_URL__: "null" },
    logLevel: "silent"
  });
  const directory = mkdtempSync(join(tmpdir(), "formatted-markdown-test-"));
  try {
    const bundlePath = join(directory, "render.cjs");
    writeFileSync(bundlePath, result.outputFiles[0].text);
    const { render } = createRequire(import.meta.url)(bundlePath);
    return render({ content, filePath, opensLocalFiles });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("markdown links scroll fragments, open web and sibling files, and drop unsafe schemes", () => {
  const filePath = "/Users/me/my notes/plan.md";
  assert.deepEqual(helpers.classifyMarkdownLink("#rollout", filePath), { kind: "fragment", id: "rollout" });
  assert.deepEqual(helpers.classifyMarkdownLink("https://example.com/a?b=1#c", filePath),
    { kind: "open", url: "https://example.com/a?b=1#c" });
  assert.deepEqual(helpers.classifyMarkdownLink("mailto:me@example.com", filePath),
    { kind: "open", url: "mailto:me@example.com" });
  assert.deepEqual(helpers.classifyMarkdownLink("../docs/other plan.md#later", filePath),
    { kind: "open", url: "file:///Users/me/docs/other%20plan.md" });
  assert.deepEqual(helpers.classifyMarkdownLink("javascript:alert(1)", filePath), { kind: "inert" });
  assert.deepEqual(helpers.classifyMarkdownLink("./other.md", null), { kind: "inert" });
  assert.deepEqual(helpers.classifyMarkdownLink("", filePath), { kind: "inert" });
});

test("frontmatter entries keep simple scalar values and skip nested or block values", () => {
  const content = "---\nname: toastty-open-markdown\ndescription: \"Opens: markdown\"\ntags:\n  - a\nnotes: |\n  long\n---\n# Body\n";
  assert.deepEqual(helpers.frontmatterEntries(content), [
    ["name", "toastty-open-markdown"],
    ["description", "Opens: markdown"]
  ]);
  assert.deepEqual(helpers.frontmatterEntries("# No frontmatter\n---\nkey: value\n---\n"), []);
});

test("formatted view renders GFM, skips raw HTML, and replaces images with placeholders", async () => {
  const html = await renderFormatted([
    "---",
    "status: draft",
    "---",
    "",
    "# Plan",
    "",
    "<script>window.injected = true</script>",
    "",
    "Text with <b>inline tag</b> and a [bad](javascript:alert(1)) link.",
    "",
    "- [x] done",
    "- [ ] later",
    "",
    "| A | B |",
    "| - | - |",
    "| 1 | 2 |",
    "",
    "```swift",
    "func reveal() {}",
    "```",
    "",
    "![Sketch](./sketch.png)",
    "",
    "## Plan"
  ].join("\n"));

  assert.doesNotMatch(html, /<script|injected|&lt;b&gt;|<b>/);
  assert.match(html, /Text with inline tag and a <span class="markdown-link-inert"[^>]*>bad<\/span> link/);
  assert.match(html, /<h1 id="plan">Plan<\/h1>/);
  assert.match(html, /<h2 id="plan-1">Plan<\/h2>/);
  assert.equal((html.match(/type="checkbox"/g) ?? []).length, 2);
  assert.match(html, /<div class="markdown-table-scroll"><table>/);
  assert.match(html, /<code class="hljs language-swift"><span class="hljs-keyword">func<\/span>/);
  assert.match(html, /Image not shown: <em>Sketch<\/em>.*\.\/sketch\.png/);
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /markdown-frontmatter-key">status<.*markdown-frontmatter-value">draft</);
  assert.doesNotMatch(html, /<hr/);
});

test("formatted view marks web links external and keeps file links inert where files cannot open", async () => {
  const content = "[site](https://example.com) and [sibling](./other.md)";
  const desktop = await renderFormatted(content);
  assert.match(desktop, /href="https:\/\/example.com"[^>]*>site<span class="markdown-link-external"/);
  assert.match(desktop, /<a href="\.\/other\.md" title="file:\/\/\/Users\/me\/notes\/other\.md">sibling<\/a>/);

  const phone = await renderFormatted(content, { opensLocalFiles: false });
  assert.match(phone, /<span class="markdown-link-inert" title="\.\/other\.md">sibling<\/span>/);
});
