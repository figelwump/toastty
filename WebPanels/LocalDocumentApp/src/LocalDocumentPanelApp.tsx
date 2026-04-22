import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import React from "react";
import {
  LocalDocumentHighlightState,
  LocalDocumentLineRevealRequest,
  LocalDocumentPanelBootstrap,
  LocalDocumentSyntaxLanguage
} from "./bootstrap";
import {
  clampRevealLineNumber,
  computeOffsetRevealLayout,
  computeRevealLayout
} from "./lineReveal.mjs";
import { highlightMarkdownSourceToHtml } from "./markdownSourceHighlighter.mjs";
import {
  MARKDOWN_LINE_START_SELECTOR,
  normalizeMarkdownLineTopOffsets,
  renderPlainMarkdownSourceHtml,
} from "./markdownSoftWrap.mjs";
import { useLocalDocumentSearchController } from "./localDocumentSearch";
import { localDocumentNativeBridge } from "./nativeBridge";

if (!hljs.getLanguage("yaml")) {
  hljs.registerLanguage("yaml", yaml);
}
if (!hljs.getLanguage("toml")) {
  // The installed highlight.js bundle exposes TOML through the INI grammar.
  hljs.registerLanguage("toml", ini);
}
if (!hljs.getLanguage("json")) {
  hljs.registerLanguage("json", json);
}
if (!hljs.getLanguage("xml")) {
  hljs.registerLanguage("xml", xml);
}
if (!hljs.getLanguage("bash")) {
  hljs.registerLanguage("bash", bash);
}
if (!hljs.getLanguage("swift")) {
  hljs.registerLanguage("swift", swift);
}
if (!hljs.getLanguage("javascript")) {
  hljs.registerLanguage("javascript", javascript);
}
if (!hljs.getLanguage("typescript")) {
  hljs.registerLanguage("typescript", typescript);
}
if (!hljs.getLanguage("python")) {
  hljs.registerLanguage("python", python);
}
if (!hljs.getLanguage("go")) {
  hljs.registerLanguage("go", go);
}
if (!hljs.getLanguage("rust")) {
  hljs.registerLanguage("rust", rust);
}

function normalizeLineEndings(content: string): string {
  return content.replace(/\r\n?/g, "\n");
}

function contentLines(content: string): string[] {
  const normalized = normalizeLineEndings(content);
  if (normalized.length === 0) {
    return [""];
  }

  const lines = normalized.split("\n");
  if (normalized.endsWith("\n")) {
    lines.pop();
  }

  return lines.length > 0 ? lines : [""];
}

function shortenPath(filePath: string | null, displayName: string): string {
  if (!filePath) {
    return "No backing file";
  }
  const dir = filePath.endsWith(displayName)
    ? filePath.slice(0, -displayName.length).replace(/\/$/, "")
    : filePath;
  const segments = dir.split("/").filter(Boolean);
  if (segments.length <= 2) return segments.join("/");
  return "\u2026/" + segments.slice(-2).join("/");
}

function computeLineCount(content: string): string {
  return contentLines(content).length.toLocaleString();
}

function assignObjectRef<T>(ref: React.RefObject<T | null>, value: T | null) {
  ref.current = value;
}

function useBootstrap(): LocalDocumentPanelBootstrap | null {
  const [bootstrap, setBootstrap] = React.useState<LocalDocumentPanelBootstrap | null>(
    () => window.ToasttyLocalDocumentPanel?.getCurrentBootstrap() ?? null
  );

  React.useEffect(() => {
    return window.ToasttyLocalDocumentPanel?.subscribe(setBootstrap);
  }, []);

  React.useEffect(() => {
    document.title = bootstrap?.displayName ?? "Local Document";
  }, [bootstrap]);

  return bootstrap;
}

function useRevealRequest(): LocalDocumentLineRevealRequest | null {
  const [revealRequest, setRevealRequest] = React.useState<LocalDocumentLineRevealRequest | null>(
    () => window.ToasttyLocalDocumentPanel?.getCurrentRevealRequest() ?? null
  );

  React.useEffect(() => {
    return window.ToasttyLocalDocumentPanel?.subscribeReveal(setRevealRequest);
  }, []);

  return revealRequest;
}

type ActiveReveal = {
  lineNumber: number;
  requestID: number;
  filePath: string | null;
  contentRevision: number;
};

type RevealLayout = {
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

function resolveComputedLineHeight(element: HTMLElement): number | null {
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

function measureRevealLayout(args: {
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

function useLocalDocumentPanelState(): {
  bootstrap: LocalDocumentPanelBootstrap | null;
  draftContent: string;
  isDirty: boolean;
  canSave: boolean;
  canOverwrite: boolean;
  openInDefaultApp: () => void;
  enterEdit: () => void;
  saveEdit: () => void;
  overwriteAfterConflict: () => void;
  cancelEdit: () => void;
  updateDraftContent: (nextContent: string) => void;
} {
  const bootstrap = useBootstrap();
  const [draftContent, setDraftContent] = React.useState("");
  const lastSyncedContentRevision = React.useRef<number | null>(null);

  React.useEffect(() => {
    if (!bootstrap) {
      lastSyncedContentRevision.current = null;
      setDraftContent("");
      return;
    }

    if (lastSyncedContentRevision.current === bootstrap.contentRevision) {
      return;
    }

    lastSyncedContentRevision.current = bootstrap.contentRevision;
    setDraftContent(bootstrap.content);
  }, [bootstrap]);

  const openInDefaultApp = React.useCallback(() => {
    if (!bootstrap?.filePath || bootstrap.isEditing) {
      return;
    }

    localDocumentNativeBridge.openInDefaultApp();
  }, [bootstrap?.filePath, bootstrap?.isEditing]);

  const enterEdit = React.useCallback(() => {
    if (!bootstrap?.filePath) {
      return;
    }

    localDocumentNativeBridge.enterEdit();
  }, [bootstrap?.filePath]);

  const saveEdit = React.useCallback(() => {
    if (!bootstrap?.isEditing || bootstrap.isSaving || bootstrap.hasExternalConflict) {
      return;
    }

    localDocumentNativeBridge.save(bootstrap.contentRevision);
  }, [bootstrap]);

  const overwriteAfterConflict = React.useCallback(() => {
    if (!bootstrap?.isEditing || bootstrap.isSaving || !bootstrap.hasExternalConflict) {
      return;
    }

    localDocumentNativeBridge.overwriteAfterConflict(bootstrap.contentRevision);
  }, [bootstrap]);

  const cancelEdit = React.useCallback(() => {
    if (!bootstrap || bootstrap.isSaving) {
      return;
    }

    localDocumentNativeBridge.cancelEdit(bootstrap.contentRevision);
  }, [bootstrap]);

  const updateDraftContent = React.useCallback((nextContent: string) => {
    setDraftContent(nextContent);

    if (!bootstrap?.isEditing || bootstrap.isSaving) {
      return;
    }

    localDocumentNativeBridge.draftDidChange(nextContent, bootstrap.contentRevision);
  }, [bootstrap]);

  const isDirty = Boolean(
    bootstrap?.isEditing ? (bootstrap.isDirty || draftContent !== bootstrap.content) : bootstrap?.isDirty
  );
  const canSave = Boolean(bootstrap?.isEditing && !bootstrap.isSaving && !bootstrap.hasExternalConflict);
  const canOverwrite = Boolean(bootstrap?.isEditing && !bootstrap.isSaving && bootstrap.hasExternalConflict);

  return {
    bootstrap,
    draftContent,
    isDirty,
    canSave,
    canOverwrite,
    openInDefaultApp,
    enterEdit,
    saveEdit,
    overwriteAfterConflict,
    cancelEdit,
    updateDraftContent
  };
}

function Header(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  content: string;
  isDirty: boolean;
  canSave: boolean;
  canOverwrite: boolean;
  openInDefaultApp: () => void;
  enterEdit: () => void;
  saveEdit: () => void;
  overwriteAfterConflict: () => void;
  cancelEdit: () => void;
}) {
  const {
    bootstrap,
    content,
    isDirty,
    canSave,
    canOverwrite,
    openInDefaultApp,
    enterEdit,
    saveEdit,
    overwriteAfterConflict,
    cancelEdit
  } = props;
  const shortPath = shortenPath(bootstrap.filePath, bootstrap.displayName);
  const statsLabel = React.useMemo(
    () => `${computeLineCount(content)} lines`,
    [content]
  );

  return (
    <header className="local-document-panel-header">
      <div className="local-document-panel-stats">
        <span className="local-document-panel-stat">{statsLabel}</span>
        <span className="local-document-panel-stat-divider" />
        <span className="local-document-panel-stat">{bootstrap.formatLabel}</span>
      </div>
      <div className="local-document-panel-title-wrap">
        <div className="local-document-panel-title">{bootstrap.displayName}</div>
        <div className="local-document-panel-path" title={bootstrap.filePath}>{shortPath}</div>
      </div>
      <div className="local-document-panel-actions">
        {bootstrap.isEditing ? (
          <>
            <span className={`local-document-session-badge${isDirty ? " local-document-session-badge-dirty" : ""}`}>
              {bootstrap.isSaving ? "Saving" : isDirty ? "Unsaved draft" : "Editing"}
            </span>
            <button
              className="local-document-action-button"
              onClick={bootstrap.hasExternalConflict ? overwriteAfterConflict : saveEdit}
              disabled={bootstrap.hasExternalConflict ? !canOverwrite : !canSave}
            >
              {bootstrap.hasExternalConflict ? "Overwrite" : "Save"}
            </button>
            <button
              className="local-document-action-button local-document-action-button-secondary"
              onClick={cancelEdit}
              disabled={bootstrap.isSaving}
            >
              {bootstrap.hasExternalConflict ? "Revert" : "Cancel"}
            </button>
          </>
        ) : (
          <>
            {bootstrap.filePath && (
              <button
                className="local-document-action-button local-document-action-button-secondary local-document-action-button-icon"
                onClick={openInDefaultApp}
                aria-label="Open in Default App"
                title="Open in Default App"
              >
                <ExternalOpenIcon />
              </button>
            )}
            <button
              className="local-document-action-button"
              onClick={enterEdit}
              disabled={!bootstrap.filePath}
            >
              <span>Edit</span>
              <span className="local-document-action-button-shortcut" aria-hidden="true">⌘E</span>
            </button>
          </>
        )}
      </div>
    </header>
  );
}

function ExternalOpenIcon() {
  return (
    <svg
      aria-hidden="true"
      className="local-document-action-icon"
      viewBox="0 0 16 16"
      fill="none"
    >
      <path
        d="M9.5 2.5H13.5V6.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M7 9L13.5 2.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M13 9.5V11.5C13 12.6046 12.1046 13.5 11 13.5H4.5C3.39543 13.5 2.5 12.6046 2.5 11.5V5C2.5 3.89543 3.39543 3 4.5 3H6.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function LocalDocumentEditor(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  draftContent: string;
  textareaRef: React.RefObject<HTMLTextAreaElement | null>;
  updateDraftContent: (nextContent: string) => void;
}) {
  React.useLayoutEffect(() => {
    const textarea = props.textareaRef.current;
    if (!textarea) {
      return;
    }

    textarea.focus();
    textarea.setSelectionRange(0, 0);
  }, []);

  return (
    <section className="local-document-editor-shell">
      {(props.bootstrap.hasExternalConflict || props.bootstrap.saveErrorMessage) && (
        <div className="local-document-editor-status-strip">
          {props.bootstrap.hasExternalConflict && (
            <p className="local-document-editor-status local-document-editor-status-conflict">
              The file changed on disk. Save will stay disabled until you overwrite the file or revert your draft.
            </p>
          )}
          {props.bootstrap.saveErrorMessage && (
            <p className="local-document-editor-status local-document-editor-status-error">
              {props.bootstrap.saveErrorMessage}
            </p>
          )}
        </div>
      )}
      <textarea
        ref={props.textareaRef}
        className="local-document-editor"
        value={props.draftContent}
        onChange={(event) => props.updateDraftContent(event.target.value)}
        spellCheck={false}
        autoCorrect="off"
        autoCapitalize="off"
        wrap="off"
        readOnly={props.bootstrap.isSaving}
      />
    </section>
  );
}

function highlightedCodeHTML(
  language: LocalDocumentSyntaxLanguage | null,
  content: string,
  shouldHighlight: boolean
): string | null {
  if (!shouldHighlight || language === null || !hljs.getLanguage(language)) {
    return null;
  }

  try {
    return hljs.highlight(String(content), { language, ignoreIllegals: true }).value;
  } catch {
    return null;
  }
}

function highlightStatusMessage(
  highlightState: LocalDocumentHighlightState,
  formatLabel: string
): string | null {
  switch (highlightState) {
    case "enabled":
    case "unavailable":
      return null;
    case "disabledForLargeFile":
      return "Syntax highlighting is disabled for large files. Editing remains available, but performance may still degrade on very large documents.";
    case "unsupportedFormat":
      if (formatLabel === "JSONC") {
        return "Syntax highlighting is not available for JSONC files yet.";
      }
      return "Syntax highlighting is not available for this format yet.";
  }
}

function useDocumentHighlightHTML(
  bootstrap: LocalDocumentPanelBootstrap,
  content: string
): string | null {
  const syncHighlight = React.useMemo(() => {
    if (bootstrap.format === "markdown") {
      return null;
    }

    return highlightedCodeHTML(
      bootstrap.syntaxLanguage,
      content,
      bootstrap.shouldHighlight
    );
  }, [bootstrap.format, bootstrap.shouldHighlight, bootstrap.syntaxLanguage, content]);
  const [markdownHighlight, setMarkdownHighlight] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (bootstrap.format !== "markdown" || !bootstrap.shouldHighlight) {
      setMarkdownHighlight(null);
      return;
    }

    let isCurrent = true;
    setMarkdownHighlight(null);

    highlightMarkdownSourceToHtml(content)
      .then((highlightedHTML) => {
        if (isCurrent) {
          setMarkdownHighlight(highlightedHTML);
        }
      })
      .catch((error) => {
        console.warn("[ToasttyLocalDocumentPanel] Markdown highlighting failed.", error);
        if (isCurrent) {
          setMarkdownHighlight(null);
        }
      });

    return () => {
      isCurrent = false;
    };
  }, [bootstrap.format, bootstrap.shouldHighlight, content]);

  return bootstrap.format === "markdown" ? markdownHighlight : syncHighlight;
}

const DEFAULT_MARKDOWN_LINE_HEIGHT = 21.45;

type MarkdownLineLayout = {
  contentHeight: number;
  lineOffsets: number[];
};

function fallbackMarkdownLineOffsets(
  lineCount: number,
  lineHeight = DEFAULT_MARKDOWN_LINE_HEIGHT
): number[] {
  return Array.from({ length: lineCount }, (_, index) => index * lineHeight);
}

function fallbackMarkdownLineLayout(
  lineCount: number,
  lineHeight = DEFAULT_MARKDOWN_LINE_HEIGHT
): MarkdownLineLayout {
  return {
    contentHeight: Math.max(lineCount * lineHeight, lineHeight),
    lineOffsets: fallbackMarkdownLineOffsets(lineCount, lineHeight),
  };
}

function sameMarkdownLineLayout(previous: MarkdownLineLayout, next: MarkdownLineLayout): boolean {
  if (Math.abs(previous.contentHeight - next.contentHeight) > 0.25) {
    return false;
  }

  if (previous.lineOffsets.length !== next.lineOffsets.length) {
    return false;
  }

  for (let index = 0; index < previous.lineOffsets.length; index += 1) {
    if (Math.abs(previous.lineOffsets[index] - next.lineOffsets[index]) > 0.25) {
      return false;
    }
  }

  return true;
}

function useMarkdownLogicalLineLayout(
  lineCount: number,
  sourceHTML: string
): {
  contentRef: React.RefObject<HTMLElement | null>;
  scrollRef: React.RefObject<HTMLDivElement | null>;
  lineLayout: MarkdownLineLayout;
} {
  const contentRef = React.useRef<HTMLElement | null>(null);
  const scrollRef = React.useRef<HTMLDivElement | null>(null);
  const [lineLayout, setLineLayout] = React.useState<MarkdownLineLayout>(
    () => fallbackMarkdownLineLayout(lineCount)
  );

  React.useEffect(() => {
    setLineLayout((current) => (
      current.lineOffsets.length === lineCount ? current : fallbackMarkdownLineLayout(lineCount)
    ));
  }, [lineCount]);

  React.useLayoutEffect(() => {
    const contentNode = contentRef.current;
    if (!contentNode) {
      return;
    }

    let frameID = 0;
    const measure = () => {
      const currentContentNode = contentRef.current;
      if (!currentContentNode) {
        return;
      }

      const computedStyles = window.getComputedStyle(currentContentNode);
      const computedLineHeight = Number.parseFloat(computedStyles.lineHeight);
      const fallbackLineHeight = Number.isFinite(computedLineHeight) && computedLineHeight > 0
        ? computedLineHeight
        : DEFAULT_MARKDOWN_LINE_HEIGHT;
      const contentRect = currentContentNode.getBoundingClientRect();
      const markerOffsets = Array.from(
        currentContentNode.querySelectorAll<HTMLElement>(MARKDOWN_LINE_START_SELECTOR)
      ).map((marker) => marker.getBoundingClientRect().top - contentRect.top);
      const nextLineOffsets = normalizeMarkdownLineTopOffsets(
        markerOffsets,
        fallbackLineHeight,
        lineCount
      );
      const nextContentHeight = Math.max(
        contentRect.height,
        fallbackLineHeight,
        nextLineOffsets.length > 0
          ? nextLineOffsets[nextLineOffsets.length - 1] + fallbackLineHeight
          : fallbackLineHeight
      );
      const nextLineLayout = {
        contentHeight: nextContentHeight,
        lineOffsets: nextLineOffsets,
      };

      setLineLayout((current) => (
        sameMarkdownLineLayout(current, nextLineLayout) ? current : nextLineLayout
      ));
    };
    const scheduleMeasure = () => {
      window.cancelAnimationFrame(frameID);
      frameID = window.requestAnimationFrame(measure);
    };

    scheduleMeasure();

    const resizeObserver = typeof ResizeObserver === "function"
      ? new ResizeObserver(() => {
        scheduleMeasure();
      })
      : null;

    resizeObserver?.observe(contentNode);
    if (scrollRef.current) {
      resizeObserver?.observe(scrollRef.current);
    }

    return () => {
      window.cancelAnimationFrame(frameID);
      resizeObserver?.disconnect();
    };
  }, [lineCount, sourceHTML]);

  return { contentRef, scrollRef, lineLayout };
}

function useMarkdownRevealLayout(args: {
  activeReveal: ActiveReveal | null;
  lineCount: number;
  lineLayout: MarkdownLineLayout;
  scrollRef: React.RefObject<HTMLDivElement | null>;
  gutterInnerRef: React.RefObject<HTMLDivElement | null>;
  contentSurfaceRef: React.RefObject<HTMLPreElement | null>;
  contentRef: React.RefObject<HTMLElement | null>;
}): RevealLayout | null {
  const revealScrollFrameRef = React.useRef<{
    outer: number | null;
    inner: number | null;
  }>({ outer: null, inner: null });
  const revealScrollSequenceRef = React.useRef(0);
  const [revealLayout, setRevealLayout] = React.useState<RevealLayout | null>(null);

  const cancelScheduledRevealScroll = React.useCallback(() => {
    revealScrollSequenceRef.current += 1;
    if (revealScrollFrameRef.current.outer !== null) {
      window.cancelAnimationFrame(revealScrollFrameRef.current.outer);
      revealScrollFrameRef.current.outer = null;
    }
    if (revealScrollFrameRef.current.inner !== null) {
      window.cancelAnimationFrame(revealScrollFrameRef.current.inner);
      revealScrollFrameRef.current.inner = null;
    }
  }, []);

  React.useEffect(() => {
    return () => {
      cancelScheduledRevealScroll();
    };
  }, [cancelScheduledRevealScroll]);

  React.useLayoutEffect(() => {
    if (!args.activeReveal) {
      setRevealLayout(null);
      return;
    }

    const scrollElement = args.scrollRef.current;
    const contentSurfaceElement = args.contentSurfaceRef.current;
    const contentElement = args.contentRef.current;
    if (!scrollElement ||
        !contentSurfaceElement ||
        !contentElement ||
        !args.gutterInnerRef.current) {
      return;
    }

    const lineHeight = resolveComputedLineHeight(contentElement) ?? DEFAULT_MARKDOWN_LINE_HEIGHT;
    setRevealLayout(
      computeOffsetRevealLayout({
        lineNumber: args.activeReveal.lineNumber,
        lineCount: args.lineCount,
        lineOffsets: args.lineLayout.lineOffsets,
        contentTopInset: contentElement.offsetTop,
        gutterTopInset: 0,
        scrollContentOffsetTop: contentSurfaceElement.offsetTop,
        lineHeight,
        scrollViewportHeight: scrollElement.clientHeight,
        scrollContentHeight: scrollElement.scrollHeight
      })
    );
  }, [
    args.activeReveal?.lineNumber,
    args.activeReveal?.requestID,
    args.contentRef,
    args.contentSurfaceRef,
    args.gutterInnerRef,
    args.lineCount,
    args.lineLayout,
    args.scrollRef
  ]);

  React.useLayoutEffect(() => {
    if (!args.activeReveal || !revealLayout) {
      return;
    }

    cancelScheduledRevealScroll();
    const revealScrollSequence = revealScrollSequenceRef.current;
    revealScrollFrameRef.current.outer = window.requestAnimationFrame(() => {
      revealScrollFrameRef.current.outer = null;
      if (revealScrollSequence !== revealScrollSequenceRef.current) {
        return;
      }

      revealScrollFrameRef.current.inner = window.requestAnimationFrame(() => {
        revealScrollFrameRef.current.inner = null;
        if (revealScrollSequence !== revealScrollSequenceRef.current) {
          return;
        }

        const scrollElement = args.scrollRef.current;
        if (!scrollElement) {
          return;
        }
        scrollElement.scrollTop = revealLayout.targetScrollTop;
      });
    });

    return () => {
      cancelScheduledRevealScroll();
    };
  }, [args.activeReveal?.requestID, args.scrollRef, cancelScheduledRevealScroll, revealLayout?.targetScrollTop]);

  return revealLayout;
}

function MarkdownCodeDocumentView(props: {
  content: string;
  highlightedHTML: string | null;
  lines: string[];
  activeReveal: ActiveReveal | null;
  previewRootRef: React.RefObject<HTMLElement | null>;
  previewContentRef: React.RefObject<HTMLElement | null>;
}) {
  const contentSurfaceRef = React.useRef<HTMLPreElement | null>(null);
  const gutterInnerRef = React.useRef<HTMLDivElement | null>(null);
  const markdownGutterStyle = {
    "--local-document-code-gutter-digit-width": `${Math.max(String(props.lines.length).length, 2)}ch`
  } as React.CSSProperties;
  const sourceHTML = React.useMemo(
    () => props.highlightedHTML ?? renderPlainMarkdownSourceHtml(props.content),
    [props.content, props.highlightedHTML]
  );
  const { contentRef, scrollRef, lineLayout } = useMarkdownLogicalLineLayout(
    props.lines.length,
    sourceHTML
  );
  const handleScrollRef = React.useCallback((node: HTMLDivElement | null) => {
    assignObjectRef(scrollRef, node);
    assignObjectRef(props.previewRootRef, node);
  }, [props.previewRootRef, scrollRef]);
  const handlePreviewContentRef = React.useCallback((node: HTMLPreElement | null) => {
    assignObjectRef(contentSurfaceRef, node);
    assignObjectRef(props.previewContentRef, node);
  }, [contentSurfaceRef, props.previewContentRef]);
  const codeClassName = props.highlightedHTML
    ? "starry-night local-document-code-markdown"
    : "local-document-code-plain local-document-code-plain-markdown";
  const revealLayout = useMarkdownRevealLayout({
    activeReveal: props.activeReveal,
    lineCount: props.lines.length,
    lineLayout,
    scrollRef,
    gutterInnerRef,
    contentSurfaceRef,
    contentRef
  });

  return (
    <div className="local-document-code-frame local-document-code-frame-markdown">
      <div
        className="local-document-code-scroll local-document-code-scroll-markdown"
        ref={handleScrollRef}
      >
        <div className="local-document-code-markdown-grid">
          <div
            className="local-document-code-markdown-gutter"
            aria-hidden="true"
            style={markdownGutterStyle}
          >
            <div
              className="local-document-code-markdown-gutter-inner"
              ref={gutterInnerRef}
              style={{ height: `${lineLayout.contentHeight}px` }}
            >
              {revealLayout ? (
                <div
                  aria-hidden="true"
                  className="local-document-code-gutter-reveal"
                  style={{
                    top: `${revealLayout.gutterTop}px`,
                    height: `${revealLayout.gutterHeight}px`
                  }}
                />
              ) : null}
              {props.lines.map((_, index) => (
                <div
                  key={index}
                  className="local-document-code-gutter-cell local-document-code-gutter-cell-markdown"
                  style={{
                    top: `${lineLayout.lineOffsets[index] ?? (index * DEFAULT_MARKDOWN_LINE_HEIGHT)}px`
                  }}
                >
                  {index + 1}
                </div>
              ))}
            </div>
          </div>
          <pre className="local-document-code-markdown-surface" ref={handlePreviewContentRef}>
            {revealLayout ? (
              <div
                aria-hidden="true"
                className="local-document-code-line-reveal"
                style={{
                  top: `${revealLayout.contentTop}px`,
                  height: `${revealLayout.contentHeight}px`
                }}
              />
            ) : null}
            <code
              ref={contentRef}
              className={codeClassName}
              dangerouslySetInnerHTML={{ __html: sourceHTML }}
            />
          </pre>
        </div>
      </div>
    </div>
  );
}

function CodeDocumentView(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  content: string;
  previewRootRef: React.RefObject<HTMLElement | null>;
  previewContentRef: React.RefObject<HTMLElement | null>;
}) {
  const lines = React.useMemo(() => contentLines(props.content), [props.content]);
  const highlightedHTML = useDocumentHighlightHTML(props.bootstrap, props.content);
  const revealRequest = useRevealRequest();
  const scrollRef = React.useRef<HTMLDivElement | null>(null);
  const gutterFrameRef = React.useRef<HTMLDivElement | null>(null);
  const gutterPreRef = React.useRef<HTMLPreElement | null>(null);
  const contentFrameRef = React.useRef<HTMLDivElement | null>(null);
  const contentCodeRef = React.useRef<HTMLElement | null>(null);
  const revealScrollFrameRef = React.useRef<{
    outer: number | null;
    inner: number | null;
  }>({ outer: null, inner: null });
  const revealScrollSequenceRef = React.useRef(0);
  const [activeReveal, setActiveReveal] = React.useState<ActiveReveal | null>(null);
  const [revealLayout, setRevealLayout] = React.useState<RevealLayout | null>(null);
  const language = props.bootstrap.syntaxLanguage;
  const statusMessage = highlightStatusMessage(
    props.bootstrap.highlightState,
    props.bootstrap.formatLabel
  );
  const codeClassName = props.bootstrap.format === "markdown"
    ? "starry-night"
    : language
      ? `hljs language-${language}`
      : "hljs";
  const handleScrollRef = React.useCallback((node: HTMLDivElement | null) => {
    assignObjectRef(scrollRef, node);
    assignObjectRef(props.previewRootRef, node);
  }, [props.previewRootRef, scrollRef]);
  const handlePreviewContentRef = React.useCallback((node: HTMLPreElement | null) => {
    assignObjectRef(props.previewContentRef, node);
  }, [props.previewContentRef]);

  const cancelScheduledRevealScroll = React.useCallback(() => {
    revealScrollSequenceRef.current += 1;
    if (revealScrollFrameRef.current.outer !== null) {
      window.cancelAnimationFrame(revealScrollFrameRef.current.outer);
      revealScrollFrameRef.current.outer = null;
    }
    if (revealScrollFrameRef.current.inner !== null) {
      window.cancelAnimationFrame(revealScrollFrameRef.current.inner);
      revealScrollFrameRef.current.inner = null;
    }
  }, []);

  React.useEffect(() => {
    return () => {
      cancelScheduledRevealScroll();
    };
  }, [cancelScheduledRevealScroll]);

  React.useEffect(() => {
    if (!revealRequest) {
      return;
    }

    if (props.bootstrap.isEditing) {
      return;
    }

    const targetLineNumber = clampRevealLineNumber(revealRequest.lineNumber, lines.length);
    setRevealLayout(null);
    setActiveReveal({
      lineNumber: targetLineNumber,
      requestID: revealRequest.requestID,
      filePath: props.bootstrap.filePath,
      contentRevision: props.bootstrap.contentRevision
    });
    window.ToasttyLocalDocumentPanel?.consumeRevealRequest(revealRequest.requestID);
  }, [props.bootstrap.contentRevision, props.bootstrap.filePath, props.bootstrap.isEditing, revealRequest, lines.length]);

  React.useLayoutEffect(() => {
    if (!activeReveal || props.bootstrap.isEditing) {
      setRevealLayout(null);
      return;
    }

    const scrollElement = scrollRef.current;
    const gutterFrameElement = gutterFrameRef.current;
    const gutterPreElement = gutterPreRef.current;
    const contentFrameElement = contentFrameRef.current;
    const contentCodeElement = contentCodeRef.current;
    if (!scrollElement ||
        !gutterFrameElement ||
        !gutterPreElement ||
        !contentFrameElement ||
        !contentCodeElement) {
      return;
    }

    setRevealLayout(
      measureRevealLayout({
        lineNumber: activeReveal.lineNumber,
        lineCount: lines.length,
        scrollElement,
        gutterFrameElement,
        gutterElement: gutterPreElement,
        contentFrameElement,
        contentElement: contentCodeElement
      })
    );
  }, [
    activeReveal?.lineNumber,
    activeReveal?.requestID,
    // `highlightedHTML` stays in the dep list so the measurement re-runs once
    // the content code element is swapped out by the async markdown highlighter
    // — `contentCodeRef` gets re-attached and our Range-based anchor needs to
    // re-read geometry against the new node.
    highlightedHTML,
    lines.length,
    props.bootstrap.isEditing,
    props.bootstrap.textScale
  ]);

  React.useLayoutEffect(() => {
    if (!activeReveal || !revealLayout) {
      return;
    }

    cancelScheduledRevealScroll();
    const revealScrollSequence = revealScrollSequenceRef.current;
    revealScrollFrameRef.current.outer = window.requestAnimationFrame(() => {
      revealScrollFrameRef.current.outer = null;
      if (revealScrollSequence !== revealScrollSequenceRef.current) {
        return;
      }

      // WKWebView has been unreliable about applying immediate overflow
      // scroll jumps during the same layout pass, so defer once for the new
      // reveal render and once more for the settled layout before assigning.
      revealScrollFrameRef.current.inner = window.requestAnimationFrame(() => {
        revealScrollFrameRef.current.inner = null;
        if (revealScrollSequence !== revealScrollSequenceRef.current) {
          return;
        }

        const scrollElement = scrollRef.current;
        if (!scrollElement) {
          return;
        }
        scrollElement.scrollTop = revealLayout.targetScrollTop;
      });
    });

    return () => {
      cancelScheduledRevealScroll();
    };
  }, [activeReveal?.requestID, cancelScheduledRevealScroll, revealLayout?.targetScrollTop]);

  React.useEffect(() => {
    if (!activeReveal) {
      return;
    }

    if (props.bootstrap.isEditing ||
        props.bootstrap.filePath !== activeReveal.filePath ||
        props.bootstrap.contentRevision !== activeReveal.contentRevision) {
      cancelScheduledRevealScroll();
      setRevealLayout(null);
      setActiveReveal(null);
    }
  }, [
    activeReveal,
    cancelScheduledRevealScroll,
    props.bootstrap.contentRevision,
    props.bootstrap.filePath,
    props.bootstrap.isEditing
  ]);

  React.useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape" ||
          activeReveal == null ||
          props.bootstrap.isEditing) {
        return;
      }

      cancelScheduledRevealScroll();
      setRevealLayout(null);
      setActiveReveal(null);
      event.preventDefault();
      event.stopPropagation();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [activeReveal, cancelScheduledRevealScroll, props.bootstrap.isEditing]);

  // Markdown delegates to a soft-wrap-aware view with its own gutter layout.
  // The reveal hooks above stay declared unconditionally (React rules of
  // hooks); their refs just don't get attached on this branch so the
  // measurement effect is a no-op for markdown.
  if (props.bootstrap.format === "markdown") {
    return (
      <section className="local-document-code-shell">
        {statusMessage && (
          <div className="local-document-code-status-strip">
            <p className="local-document-code-status">
              {statusMessage}
            </p>
          </div>
        )}
        <MarkdownCodeDocumentView
          content={props.content}
          highlightedHTML={highlightedHTML}
          lines={lines}
          activeReveal={activeReveal}
          previewRootRef={props.previewRootRef}
          previewContentRef={props.previewContentRef}
        />
      </section>
    );
  }

  return (
    <section className="local-document-code-shell">
      {statusMessage && (
        <div className="local-document-code-status-strip">
          <p className="local-document-code-status">
            {statusMessage}
          </p>
        </div>
      )}
      <div className="local-document-code-frame">
        <div className="local-document-code-scroll" ref={handleScrollRef}>
          <div className="local-document-code-scroll-inner">
            <div className="local-document-code-gutter-frame" ref={gutterFrameRef}>
              {revealLayout ? (
                <div
                  aria-hidden="true"
                  className="local-document-code-gutter-reveal"
                  style={{
                    top: `${revealLayout.gutterTop}px`,
                    height: `${revealLayout.gutterHeight}px`
                  }}
                />
              ) : null}
              <pre className="local-document-code-gutter" aria-hidden="true" ref={gutterPreRef}>
                {lines.map((_, index) => String(index + 1)).join("\n")}
              </pre>
            </div>
            <div className="local-document-code-content-frame" ref={contentFrameRef}>
              {revealLayout ? (
                <div
                  aria-hidden="true"
                  className="local-document-code-line-reveal"
                  style={{
                    top: `${revealLayout.contentTop}px`,
                    height: `${revealLayout.contentHeight}px`
                  }}
                />
              ) : null}
              <pre className="local-document-code-content" ref={handlePreviewContentRef}>
                {highlightedHTML ? (
                  <code
                    ref={contentCodeRef}
                    className={codeClassName}
                    dangerouslySetInnerHTML={{ __html: highlightedHTML }}
                  />
                ) : (
                  <code ref={contentCodeRef} className="local-document-code-plain">{props.content}</code>
                )}
              </pre>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export function LocalDocumentPanelApp() {
  const {
    bootstrap,
    draftContent,
    isDirty,
    canSave,
    canOverwrite,
    openInDefaultApp,
    enterEdit,
    saveEdit,
    overwriteAfterConflict,
    cancelEdit,
    updateDraftContent
  } = useLocalDocumentPanelState();

  if (!bootstrap) {
    return (
      <main className="local-document-shell local-document-shell-loading">
        <div className="local-document-empty-state">
          <p className="local-document-empty-title">Waiting for content…</p>
          <p className="local-document-empty-copy">Toastty will load a local file into this panel.</p>
        </div>
      </main>
    );
  }

  const renderedContent = bootstrap.isEditing ? draftContent : bootstrap.content;
  const previewRootRef = React.useRef<HTMLElement | null>(null);
  const previewContentRef = React.useRef<HTMLElement | null>(null);
  const textareaRef = React.useRef<HTMLTextAreaElement | null>(null);

  useLocalDocumentSearchController({
    content: renderedContent,
    isEditing: bootstrap.isEditing,
    previewRootRef,
    previewContentRef,
    textareaRef
  });

  return (
    <main className="local-document-shell">
      <Header
        bootstrap={bootstrap}
        content={renderedContent}
        isDirty={isDirty}
        canSave={canSave}
        canOverwrite={canOverwrite}
        openInDefaultApp={openInDefaultApp}
        enterEdit={enterEdit}
        saveEdit={saveEdit}
        overwriteAfterConflict={overwriteAfterConflict}
        cancelEdit={cancelEdit}
      />
      {bootstrap.isEditing ? (
        <LocalDocumentEditor
          bootstrap={bootstrap}
          draftContent={draftContent}
          textareaRef={textareaRef}
          updateDraftContent={updateDraftContent}
        />
      ) : (
        <CodeDocumentView
          bootstrap={bootstrap}
          content={renderedContent}
          previewRootRef={previewRootRef}
          previewContentRef={previewContentRef}
        />
      )}
    </main>
  );
}
