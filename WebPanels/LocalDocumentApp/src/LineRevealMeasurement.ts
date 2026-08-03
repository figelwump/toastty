import { computeRevealLayout } from "./lineReveal.mjs";

export type RevealLayout = {
  contentTop: number;
  gutterTop: number;
  contentHeight: number;
  gutterHeight: number;
  targetScrollTop: number;
};

// Measure the rendered glyph box of the first line of `element` (top + height)
// relative to viewport. Used as the anchor for empty-line fallback so the
// content reveal (which often can't do a direct-range measurement on an empty
// line) still lines up with the gutter reveal (which always can, because the
// gutter always has a line number to measure).
function measureFirstRenderedLineGlyph(element: HTMLElement): { top: number; height: number } | null {
  const range = document.createRange();
  range.selectNodeContents(element);
  const rects = range.getClientRects();
  if (rects.length === 0) {
    return null;
  }
  const rect = rects[0];
  if (!Number.isFinite(rect.top) || rect.height <= 0) {
    return null;
  }
  return { top: rect.top, height: rect.height };
}

// Directly measure the rendered top + glyph height of line `lineNumber` by
// walking text nodes to the matching character offset and reading back a Range
// over a character on that line. Returns `null` on empty lines or when the
// element is not laid out yet. Two WebKit quirks drive the precise slice we
// select:
//
//   1. When `localOffset` falls immediately after a `\n` (which always happens
//      for the first char of every line), the range's start caret can be
//      interpreted as "end of the previous visual line". Over an empty
//      preceding line that makes the bounding rect span both lines, and
//      `rect.top` lands on the previous line. Skipping one character forward
//      so the range sits mid-line sidesteps the ambiguity.
//   2. Even with the mid-line start, we prefer the last entry from
//      `getClientRects()` over the bounding rect because `getBoundingClientRect`
//      still unions any phantom zero-width start rect that WebKit emits.
function measureDirectLineGlyph(element: HTMLElement, lineNumber: number): { top: number; height: number } | null {
  const textContent = element.textContent;
  if (textContent === null || textContent.length === 0) {
    return null;
  }
  const lines = textContent.split("\n");
  if (lineNumber < 1 || lineNumber > lines.length) {
    return null;
  }
  const targetLineLength = lines[lineNumber - 1].length;
  if (targetLineLength === 0) {
    return null;
  }

  let charOffset = 0;
  for (let i = 0; i < lineNumber - 1; i++) {
    charOffset += lines[i].length + 1;
  }

  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let accumulated = 0;
  let node = walker.nextNode();
  while (node !== null) {
    const nodeLength = node.textContent?.length ?? 0;
    if (accumulated + nodeLength > charOffset) {
      const localOffset = charOffset - accumulated;
      // Default to the first char of the line.
      let startOffset = localOffset;
      let endOffset = Math.min(localOffset + 1, nodeLength);
      // Prefer the second char when both it and its neighbor live in the same
      // text node — that moves the start caret away from the post-newline
      // boundary where WebKit is ambiguous.
      if (targetLineLength >= 2 && localOffset + 2 <= nodeLength) {
        startOffset = localOffset + 1;
        endOffset = localOffset + 2;
      }
      if (endOffset <= startOffset) {
        return null;
      }

      const range = document.createRange();
      range.setStart(node, startOffset);
      range.setEnd(node, endOffset);
      const rects = range.getClientRects();
      if (rects.length === 0) {
        return null;
      }
      // Take the last rect: it's always on line N. `rects[0]` can belong to a
      // zero-width phantom at the previous line-box boundary when the start
      // caret is post-newline.
      const rect = rects[rects.length - 1];
      if (!Number.isFinite(rect.top) || rect.height <= 0) {
        return null;
      }
      return { top: rect.top, height: rect.height };
    }
    accumulated += nodeLength;
    node = walker.nextNode();
  }
  return null;
}

export function resolveComputedLineHeight(element: HTMLElement): number | null {
  const parsed = Number.parseFloat(window.getComputedStyle(element).lineHeight);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }
  return parsed;
}

// Compute the top of line N's highlight band relative to `frameElement`. The
// band is `lineHeight` tall and we want the rendered glyph for that line
// visually centered in it.
//
// Empty-line targets can't be measured directly (no glyph to put a Range
// over), so we scan outward for the nearest non-empty line and extrapolate
// by the line delta. Extrapolating off the target's own neighbor dodges an
// observed WKWebView quirk where `rects[0]` from
// `selectNodeContents(element).getClientRects()` on a very large decorated
// code block doesn't correspond to line 1 — the first-line anchor produced
// off-by-many-lines reveals in long files whose requested line happened to
// be blank. Using a neighbor keeps the base measurement close to the real
// target and makes the formula robust to whatever rects[0] is doing.
function measureHighlightTopRelativeToFrame(args: {
  element: HTMLElement;
  frameElement: HTMLElement;
  lineNumber: number;
  lineHeight: number;
}): number | null {
  const frameTop = args.frameElement.getBoundingClientRect().top;

  const direct = measureDirectLineGlyph(args.element, args.lineNumber);
  if (direct !== null) {
    const verticalPadding = Math.max(0, (args.lineHeight - direct.height) / 2);
    return (direct.top - frameTop) - verticalPadding;
  }

  const textContent = args.element.textContent ?? "";
  const lines = textContent.split("\n");
  // Scan outward ±N lines for the closest non-empty neighbor and extrapolate.
  for (let distance = 1; distance <= 32; distance++) {
    for (const offset of [distance, -distance]) {
      const candidateLineNumber = args.lineNumber + offset;
      if (candidateLineNumber < 1 || candidateLineNumber > lines.length) {
        continue;
      }
      if (lines[candidateLineNumber - 1].length === 0) {
        continue;
      }
      const candidate = measureDirectLineGlyph(args.element, candidateLineNumber);
      if (candidate === null) {
        continue;
      }
      const verticalPadding = Math.max(0, (args.lineHeight - candidate.height) / 2);
      return (candidate.top - frameTop) - offset * args.lineHeight - verticalPadding;
    }
  }

  // Last resort: first-line anchor. This path is only reached when the entire
  // file is blank within ±32 lines of the target, which should be rare enough
  // that the remaining WKWebView rects[0] drift doesn't matter in practice.
  const firstGlyph = measureFirstRenderedLineGlyph(args.element);
  if (firstGlyph === null) {
    return null;
  }
  const verticalPadding = Math.max(0, (args.lineHeight - firstGlyph.height) / 2);
  return (firstGlyph.top - frameTop) + (args.lineNumber - 1) * args.lineHeight - verticalPadding;
}

export function measureRevealLayout(args: {
  lineNumber: number;
  lineCount: number;
  scrollElement: HTMLDivElement;
  contentFrameElement: HTMLDivElement;
  gutterFrameElement: HTMLDivElement;
  contentElement: HTMLElement;
  gutterElement: HTMLElement;
}): RevealLayout | null {
  const contentLineHeight = resolveComputedLineHeight(args.contentElement);
  const gutterLineHeight = resolveComputedLineHeight(args.gutterElement);
  if (contentLineHeight === null || gutterLineHeight === null) {
    return null;
  }

  const contentTopBase = measureHighlightTopRelativeToFrame({
    element: args.contentElement,
    frameElement: args.contentFrameElement,
    lineNumber: args.lineNumber,
    lineHeight: contentLineHeight
  });
  const gutterTopBase = measureHighlightTopRelativeToFrame({
    element: args.gutterElement,
    frameElement: args.gutterFrameElement,
    lineNumber: args.lineNumber,
    lineHeight: gutterLineHeight
  });
  if (contentTopBase === null || gutterTopBase === null) {
    return null;
  }

  // `computeRevealLayout` still takes a `contentTopBase`/`gutterTopBase` + a
  // `(lineNumber - 1) * line-height` step, so to reuse it we pass the
  // already-measured line-N top as the base and force `lineNumber: 1`. That
  // keeps the pure helper and its test unchanged.
  return computeRevealLayout({
    lineNumber: 1,
    lineCount: args.lineCount,
    contentTopBase,
    gutterTopBase,
    contentLineHeight,
    gutterLineHeight,
    contentFrameOffsetTop: args.contentFrameElement.offsetTop,
    scrollViewportHeight: args.scrollElement.clientHeight,
    scrollContentHeight: args.scrollElement.scrollHeight
  });
}
