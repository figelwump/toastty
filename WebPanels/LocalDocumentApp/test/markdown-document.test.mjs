import assert from "node:assert/strict";
import test from "node:test";

const {
  classifyMarkdownLinkHref,
  renderMarkdownDocumentHtml,
  revealBlockIndexForLine
} = await import(new URL("../src/markdownDocument.mjs", import.meta.url).href);

function sourceLines(html, tagName) {
  const pattern = new RegExp(
    `<${tagName}\\b[^>]*data-source-start="(\\d+)" data-source-end="(\\d+)"`,
    "g"
  );
  return Array.from(html.matchAll(pattern), (match) => [Number(match[1]), Number(match[2])]);
}

test("formatted markdown renders GitHub-flavored blocks", () => {
  const html = renderMarkdownDocumentHtml([
    "# Plan",
    "",
    "- [ ] open task",
    "- [x] done task",
    "",
    "| Step | Owner |",
    "| --- | --- |",
    "| Build | Agent |",
    "",
    "~~old~~ and https://example.com",
    ""
  ].join("\n"));

  assert.match(html, /<h1[^>]*>Plan<\/h1>/);
  assert.match(html, /<input type="checkbox" disabled> open task/);
  assert.match(html, /<input type="checkbox" checked disabled> done task/);
  assert.match(html, /<div class="markdown-table-scroll"><table[^>]*>[\s\S]*<td>Build<\/td>/);
  assert.match(html, /<del>old<\/del>/);
  assert.match(html, /<a href="https:\/\/example.com" title="https:\/\/example.com">https:\/\/example.com<\/a>/);
});

test("file links keep their href so the app can open them", () => {
  const html = renderMarkdownDocumentHtml("[notes](file:///tmp/notes.md#L3)\n");
  assert.match(html, /<a href="file:\/\/\/tmp\/notes.md#L3"/);
});

test("raw HTML keeps the safe GitHub subset and drops active content", () => {
  const html = renderMarkdownDocumentHtml([
    "<details><summary>More</summary>",
    "",
    "Press <kbd>Cmd</kbd>+<kbd>E</kbd><br>H<sub>2</sub>O",
    "",
    "</details>",
    "",
    "<script>alert(1)</script>",
    "<style>body { display: none }</style>",
    "<iframe src=\"https://example.com\"></iframe>",
    "<p onclick=\"alert(1)\" style=\"color: red\">styled</p>",
    "",
    "[bad](javascript:alert(1)) <a href=\"javascript:alert(2)\">raw bad</a>",
    ""
  ].join("\n"));

  assert.match(html, /<details[^>]*><summary[^>]*>More<\/summary>/);
  assert.match(html, /<kbd>Cmd<\/kbd>\+<kbd>E<\/kbd><br>H<sub>2<\/sub>O/);
  for (const forbidden of ["<script", "alert(1)</script", "<style", "<iframe", "onclick", "style=", "javascript:"]) {
    assert.equal(html.includes(forbidden), false, `${forbidden} should not survive sanitizing`);
  }
  assert.match(html, /<p[^>]*>styled<\/p>/);
});

test("images never load and become labeled placeholders", () => {
  const html = renderMarkdownDocumentHtml([
    "![Architecture diagram](docs/arch.png)",
    "",
    "![](assets/screen%20shot.png?raw=1)",
    "",
    "<img src=\"https://example.com/x.png\" alt=\"Remote\" onerror=\"alert(1)\">",
    ""
  ].join("\n"));

  assert.equal(html.includes("<img"), false);
  assert.match(
    html,
    /<span class="markdown-image-placeholder" role="img" aria-label="Image: Architecture diagram" title="docs\/arch.png">Architecture diagram<\/span>/
  );
  assert.match(html, /aria-label="Image: screen shot.png"[^>]*>screen shot.png<\/span>/);
  assert.match(html, /aria-label="Image: Remote" title="https:\/\/example.com\/x.png">Remote<\/span>/);
  assert.equal(html.includes("onerror"), false);
});

test("block elements record the source lines they came from", () => {
  const html = renderMarkdownDocumentHtml([
    "---",
    "title: Plan",
    "---",
    "# Heading",
    "",
    "A paragraph that",
    "spans two lines.",
    "",
    "<div>raw block</div>",
    "",
    "- first",
    "- second",
    "",
    "| a |",
    "| - |",
    "| 1 |",
    "",
    "```swift",
    "let x = 1",
    "```",
    ""
  ].join("\n"));

  assert.deepEqual(sourceLines(html, "pre")[0], [1, 3], "front matter");
  assert.deepEqual(sourceLines(html, "h1"), [[4, 4]]);
  assert.deepEqual(sourceLines(html, "p"), [[6, 7]]);
  assert.deepEqual(sourceLines(html, "div").filter(([start]) => start === 9), [[9, 9]]);
  assert.deepEqual(sourceLines(html, "li"), [[11, 11], [12, 12]]);
  assert.deepEqual(sourceLines(html, "tr"), [[14, 14], [16, 16]]);
  assert.deepEqual(sourceLines(html, "pre")[1], [18, 20], "fenced code");
  assert.equal(/<(em|strong|a|code)\b[^>]*data-source-start/.test(html), false, "inline elements stay unannotated");
});

test("heading and footnote ids use one user-content prefix that in-document links can find", () => {
  const html = renderMarkdownDocumentHtml([
    "# Testing",
    "## Testing",
    "## User content guide",
    "",
    "See [tests](#testing), [the guide](#user-content-guide), and a note.[^n]",
    "",
    "[^n]: The note.",
    ""
  ].join("\n"));

  const ids = new Set(Array.from(html.matchAll(/ id="([^"]+)"/g), (match) => match[1]));
  assert.ok(ids.has("user-content-testing"));
  assert.ok(ids.has("user-content-testing-1"));
  assert.ok(ids.has("user-content-user-content-guide"));

  for (const [, href] of html.matchAll(/<a href="(#[^"]+)"/g)) {
    const link = classifyMarkdownLinkHref(href);
    assert.equal(link.kind, "fragment");
    assert.ok(link.elementIDs.some((id) => ids.has(id)), `${href} should resolve to a rendered id`);
  }
});

test("front matter renders as a code block instead of a rule and heading", () => {
  const yamlHTML = renderMarkdownDocumentHtml("---\ntitle: Plan\n---\nBody\n");
  assert.match(yamlHTML, /^<pre class="markdown-frontmatter"[^>]*><code class="language-yaml hljs">/);
  assert.equal(yamlHTML.includes("<hr"), false);
  assert.equal(/<h2/.test(yamlHTML), false);

  const tomlHTML = renderMarkdownDocumentHtml("+++\ntitle = \"Plan\"\n+++\nBody\n");
  assert.match(tomlHTML, /^<pre class="markdown-frontmatter"[^>]*><code class="language-toml hljs">/);
});

test("fenced code highlights known languages and aliases and leaves others plain", () => {
  const html = renderMarkdownDocumentHtml([
    "```sh",
    "echo hi",
    "```",
    "",
    "```ts",
    "const x: number = 1",
    "```",
    "",
    "```made-up",
    "<b>not html</b>",
    "```",
    ""
  ].join("\n"));

  assert.match(html, /<code class="language-sh hljs"><span class="hljs-built_in">echo<\/span>/);
  assert.match(html, /<code class="language-ts hljs"><span class="hljs-keyword">const<\/span>/);
  assert.match(html, /<code class="language-made-up">&#x3C;b>not html&#x3C;\/b>\n<\/code>/);
});

test("reveal picks the smallest block that holds the line", () => {
  const blocks = [
    { start: 1, end: 1 },
    { start: 3, end: 8 },
    { start: 3, end: 4 },
    { start: 3, end: 4 },
    { start: 6, end: 8 },
    { start: 11, end: 12 }
  ];

  assert.equal(revealBlockIndexForLine(blocks, 1), 0);
  assert.equal(revealBlockIndexForLine(blocks, 4), 3, "ties prefer the nested block");
  assert.equal(revealBlockIndexForLine(blocks, 5), 1, "a gap inside a list reveals the list");
  assert.equal(revealBlockIndexForLine(blocks, 9), 5, "a gap between blocks reveals the next block");
  assert.equal(revealBlockIndexForLine(blocks, 40), 5, "a line past the end reveals the last block");
  assert.equal(revealBlockIndexForLine([], 3), -1);
});

test("link classification separates in-document links from links the app opens", () => {
  assert.deepEqual(classifyMarkdownLinkHref("#testing"), {
    kind: "fragment",
    elementIDs: ["user-content-testing", "testing"],
    lineNumber: null
  });
  assert.deepEqual(classifyMarkdownLinkHref("#user-content-fn-1"), {
    kind: "fragment",
    elementIDs: ["user-content-user-content-fn-1", "user-content-fn-1"],
    lineNumber: null
  });
  assert.deepEqual(classifyMarkdownLinkHref("#L42-L50"), {
    kind: "fragment",
    elementIDs: ["user-content-L42-L50", "L42-L50"],
    lineNumber: 42
  });
  assert.deepEqual(classifyMarkdownLinkHref("#caf%C3%A9").elementIDs, ["user-content-café", "café"]);
  assert.equal(classifyMarkdownLinkHref("#L0").lineNumber, null);
  assert.deepEqual(classifyMarkdownLinkHref(" docs/plan.md#L3 "), { kind: "open", href: "docs/plan.md#L3" });
  assert.deepEqual(classifyMarkdownLinkHref("https://example.com"), { kind: "open", href: "https://example.com" });
  assert.deepEqual(classifyMarkdownLinkHref("#"), { kind: "none" });
  assert.deepEqual(classifyMarkdownLinkHref(""), { kind: "none" });
  assert.deepEqual(classifyMarkdownLinkHref(null), { kind: "none" });
});
