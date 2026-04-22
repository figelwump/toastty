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

// `lineOffsets` stores the measured top of each 1-based logical source line at
// its 0-based array index. Wrapped markdown can span multiple visual rows, so
// the next logical-line offset also defines the current highlight band height.
export function computeOffsetRevealLayout({
  lineNumber,
  lineCount,
  lineOffsets,
  contentTopInset = 0,
  gutterTopInset = 0,
  scrollContentOffsetTop = 0,
  lineHeight,
  scrollViewportHeight,
  scrollContentHeight
}) {
  const normalizedLineNumber = clampRevealLineNumber(lineNumber, lineCount);
  const normalizedLineHeight = Number.isFinite(lineHeight) && lineHeight > 0
    ? lineHeight
    : 1;
  const lineIndex = normalizedLineNumber - 1;
  const fallbackOffset = lineIndex * normalizedLineHeight;
  const measuredOffset = Array.isArray(lineOffsets) && Number.isFinite(lineOffsets[lineIndex])
    ? lineOffsets[lineIndex]
    : fallbackOffset;
  const normalizedMeasuredOffset = measuredOffset >= 0 ? measuredOffset : fallbackOffset;
  const nextMeasuredOffset = Array.isArray(lineOffsets) && Number.isFinite(lineOffsets[lineIndex + 1])
    ? lineOffsets[lineIndex + 1]
    : normalizedMeasuredOffset + normalizedLineHeight;
  const normalizedMeasuredHeight = Math.max(
    normalizedLineHeight,
    nextMeasuredOffset - normalizedMeasuredOffset
  );
  const normalizedContentTopInset = Number.isFinite(contentTopInset) ? contentTopInset : 0;
  const normalizedGutterTopInset = Number.isFinite(gutterTopInset) ? gutterTopInset : 0;
  const normalizedScrollContentOffsetTop = Number.isFinite(scrollContentOffsetTop)
    ? scrollContentOffsetTop
    : 0;
  const contentTop = normalizedContentTopInset + normalizedMeasuredOffset;
  const gutterTop = normalizedGutterTopInset + normalizedMeasuredOffset;
  const maxScrollTop = scrollContentHeight - scrollViewportHeight;
  const targetScrollTop = clampScrollTop(
    normalizedScrollContentOffsetTop
      + contentTop
      - scrollViewportHeight * 0.35
      + normalizedLineHeight * 0.5,
    maxScrollTop
  );

  return {
    lineNumber: normalizedLineNumber,
    contentTop,
    gutterTop,
    contentHeight: normalizedMeasuredHeight,
    gutterHeight: normalizedMeasuredHeight,
    targetScrollTop
  };
}

export function revealScrollBehavior(prefersReducedMotion) {
  return prefersReducedMotion ? "auto" : "smooth";
}
