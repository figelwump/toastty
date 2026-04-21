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

/**
 * Normalize measured marker offsets into logical line top positions relative to
 * the markdown code surface. Missing or invalid entries fall back to a simple
 * line-height-based progression so the gutter still renders before remeasure.
 */
export function normalizeMarkdownLineTopOffsets(
  markerOffsets,
  fallbackLineHeight,
  lineCount
) {
  const safeLineCount = Number.isFinite(lineCount) && lineCount > 0
    ? Math.trunc(lineCount)
    : 0;
  const safeFallbackLineHeight = Number.isFinite(fallbackLineHeight) && fallbackLineHeight > 0
    ? fallbackLineHeight
    : 1;
  const offsets = Array.from(
    { length: safeLineCount },
    (_, index) => index * safeFallbackLineHeight
  );

  if (
    safeLineCount === 0 ||
    !Array.isArray(markerOffsets) ||
    markerOffsets.length === 0
  ) {
    return offsets;
  }

  const measuredLineCount = Math.min(safeLineCount, markerOffsets.length);

  for (let index = 0; index < measuredLineCount; index += 1) {
    const currentOffset = markerOffsets[index];
    if (Number.isFinite(currentOffset) && currentOffset >= 0) {
      offsets[index] = currentOffset;
    }
  }

  return offsets;
}
