export const REVEAL_HIGHLIGHT_DURATION_MS = 1800;

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

export function revealScrollBehavior(prefersReducedMotion) {
  return prefersReducedMotion ? "auto" : "smooth";
}
