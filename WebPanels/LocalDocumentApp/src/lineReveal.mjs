export function clampRevealLineNumber(lineNumber, lineCount) {
  const normalizedLineCount = Number.isFinite(lineCount)
    ? Math.max(1, Math.floor(lineCount))
    : 1;
  const normalizedLineNumber = Number.isFinite(lineNumber)
    ? Math.floor(lineNumber)
    : 1;

  return Math.min(Math.max(normalizedLineNumber, 1), normalizedLineCount);
}

export function clampScrollTop(scrollTop, maxScrollTop) {
  if (!Number.isFinite(scrollTop)) {
    return 0;
  }

  const normalizedMaxScrollTop = Number.isFinite(maxScrollTop)
    ? Math.max(0, maxScrollTop)
    : 0;
  return Math.min(Math.max(scrollTop, 0), normalizedMaxScrollTop);
}

export function computeRevealLayout({
  lineNumber,
  lineCount,
  contentTopBase,
  gutterTopBase,
  contentLineHeight,
  gutterLineHeight,
  contentFrameOffsetTop,
  scrollViewportHeight,
  scrollContentHeight
}) {
  const normalizedLineNumber = clampRevealLineNumber(lineNumber, lineCount);
  const normalizedContentTopBase = Number.isFinite(contentTopBase) ? contentTopBase : 0;
  const normalizedGutterTopBase = Number.isFinite(gutterTopBase) ? gutterTopBase : 0;
  const normalizedContentFrameOffsetTop = Number.isFinite(contentFrameOffsetTop)
    ? contentFrameOffsetTop
    : 0;
  const contentTop = normalizedContentTopBase
    + (normalizedLineNumber - 1) * contentLineHeight;
  const gutterTop = normalizedGutterTopBase
    + (normalizedLineNumber - 1) * gutterLineHeight;
  const maxScrollTop = scrollContentHeight - scrollViewportHeight;
  const targetScrollTop = clampScrollTop(
    normalizedContentFrameOffsetTop
      + contentTop
      - scrollViewportHeight * 0.35
      + contentLineHeight * 0.5,
    maxScrollTop
  );

  return {
    lineNumber: normalizedLineNumber,
    contentTop,
    gutterTop,
    contentHeight: contentLineHeight,
    gutterHeight: gutterLineHeight,
    targetScrollTop
  };
}

export function revealScrollBehavior(prefersReducedMotion) {
  return prefersReducedMotion ? "auto" : "smooth";
}
