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

function normalizeLineEndings(content) {
  return String(content).replace(/\r\n?/g, "\n");
}

function visibleSourceLines(content) {
  const normalized = normalizeLineEndings(content);

  if (normalized.length === 0) {
    return [];
  }

  const lines = normalized.split("\n");
  if (normalized.endsWith("\n")) {
    lines.pop();
  }

  return lines;
}

function escapeHtmlText(content) {
  return String(content)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function createMarkdownLineStartMarkerHtml(lineNumber) {
  return `<span class="${MARKDOWN_LINE_START_CLASS}" aria-hidden="true" data-source-line="${String(lineNumber)}"></span>`;
}

export function renderPlainMarkdownSourceHtml(content) {
  const lines = visibleSourceLines(content);

  if (lines.length === 0) {
    return "";
  }

  return lines.map((line, index) => (
    `${index > 0 ? "\n" : ""}${createMarkdownLineStartMarkerHtml(index + 1)}${escapeHtmlText(line)}`
  )).join("");
}

export function computeMarkdownLineBlockHeights(
  markerOffsets,
  contentHeight,
  fallbackLineHeight,
  lineCount
) {
  const safeLineCount = Number.isFinite(lineCount) && lineCount > 0
    ? Math.trunc(lineCount)
    : 0;
  const safeFallbackLineHeight = Number.isFinite(fallbackLineHeight) && fallbackLineHeight > 0
    ? fallbackLineHeight
    : 1;
  const heights = Array.from({ length: safeLineCount }, () => safeFallbackLineHeight);

  if (
    safeLineCount === 0 ||
    !Array.isArray(markerOffsets) ||
    markerOffsets.length === 0 ||
    !Number.isFinite(contentHeight) ||
    contentHeight <= 0
  ) {
    return heights;
  }

  const measuredLineCount = Math.min(safeLineCount, markerOffsets.length);

  for (let index = 0; index < measuredLineCount; index += 1) {
    const currentOffset = markerOffsets[index];
    const nextOffset = index + 1 < measuredLineCount
      ? markerOffsets[index + 1]
      : contentHeight;

    if (
      !Number.isFinite(currentOffset) ||
      !Number.isFinite(nextOffset) ||
      nextOffset < currentOffset
    ) {
      continue;
    }

    heights[index] = Math.max(safeFallbackLineHeight, nextOffset - currentOffset);
  }

  return heights;
}
