import assert from "node:assert/strict";
import test from "node:test";
import {
  MARKDOWN_LINE_START_CLASS,
  createMarkdownLineStartMarker,
  trimMarkdownLineBoundaryNewlines
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

test("markdown soft-wrap trimming removes only boundary newlines", () => {
  assert.equal(
    trimMarkdownLineBoundaryNewlines("\n<span class=\"pl-ml\">-</span> item\n"),
    "<span class=\"pl-ml\">-</span> item"
  );
  assert.equal(
    trimMarkdownLineBoundaryNewlines("\nalpha\nbeta\n"),
    "alpha\nbeta"
  );
  assert.equal(
    trimMarkdownLineBoundaryNewlines(""),
    ""
  );
});
