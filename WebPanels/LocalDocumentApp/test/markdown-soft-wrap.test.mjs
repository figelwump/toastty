import assert from "node:assert/strict";
import test from "node:test";
import {
  MARKDOWN_LINE_START_CLASS,
  createMarkdownLineStartMarker
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
