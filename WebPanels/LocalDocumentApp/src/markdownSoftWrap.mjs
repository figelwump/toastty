export const MARKDOWN_LINE_START_CLASS = "toastty-markdown-line-start";
export const MARKDOWN_LINE_START_SELECTOR = `.${MARKDOWN_LINE_START_CLASS}`;

export function createMarkdownLineStartMarker(lineNumber) {
  return {
    type: "element",
    tagName: "span",
    properties: {
      className: [MARKDOWN_LINE_START_CLASS],
      ariaHidden: "true",
      dataSourceLine: String(lineNumber)
    },
    children: []
  };
}

export function trimMarkdownLineBoundaryNewlines(fragmentHtml) {
  return String(fragmentHtml)
    .replace(/^\n+/, "")
    .replace(/\n+$/, "");
}
