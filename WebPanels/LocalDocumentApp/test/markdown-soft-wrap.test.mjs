import assert from "node:assert/strict";
import test from "node:test";
import {
  MARKDOWN_LINE_START_CLASS,
  computeMarkdownLineBlockHeights,
  createMarkdownLineStartMarker,
  renderPlainMarkdownSourceHtml
} from "../src/markdownSoftWrap.mjs";

test("markdown soft-wrap markers use a stable hidden span", () => {
  assert.deepEqual(createMarkdownLineStartMarker(4), {
    type: "element",
    tagName: "span",
    properties: {
      className: [MARKDOWN_LINE_START_CLASS],
      ariaHidden: "true",
      dataSourceLine: "4"
    },
    children: []
  });
});

test("plain markdown source HTML keeps line-start markers in one continuous surface", () => {
  assert.equal(
    renderPlainMarkdownSourceHtml("- alpha\n\nbeta <tag> & more"),
    `<span class="${MARKDOWN_LINE_START_CLASS}" aria-hidden="true" data-source-line="1"></span>- alpha\n` +
      `<span class="${MARKDOWN_LINE_START_CLASS}" aria-hidden="true" data-source-line="2"></span>\n` +
      `<span class="${MARKDOWN_LINE_START_CLASS}" aria-hidden="true" data-source-line="3"></span>beta &lt;tag&gt; &amp; more`
  );
  assert.equal(
    renderPlainMarkdownSourceHtml(""),
    ""
  );
});

test("markdown soft-wrap line heights expand wrapped rows without inventing extra gaps", () => {
  const heights = computeMarkdownLineBlockHeights([0, 42.9, 64.35, 107.25], 128.7, 21.45, 4);

  assert.deepEqual(
    heights.map((value) => Number(value.toFixed(2))),
    [42.9, 21.45, 42.9, 21.45]
  );
  assert.deepEqual(
    computeMarkdownLineBlockHeights([], 0, 21.45, 3),
    [21.45, 21.45, 21.45]
  );
});
