import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import React from "react";
import ReactDOMServer from "react-dom/server";
import ReactMarkdown from "react-markdown";
import remarkBreaks from "remark-breaks";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("single newlines render as visible line breaks", () => {
  const html = ReactDOMServer.renderToStaticMarkup(
    React.createElement(
      ReactMarkdown,
      {
        remarkPlugins: [remarkGfm, remarkFrontmatter, remarkBreaks],
      },
      "first line\nsecond line"
    )
  );

  assert.match(html, /<p>first line<br\/>\s*second line<\/p>/);
});

test("editor styles force a text cursor across the textarea surface", async () => {
  const styles = await readFile(resolve(packageRoot, "src/styles.css"), "utf8");

  assert.match(styles, /\.markdown-editor\s*\{[\s\S]*?cursor:\s*text;/);
});
