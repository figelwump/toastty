import React from "react";
import {
  LocalDocumentLineRevealRequest,
  LocalDocumentMarkdownViewMode,
  LocalDocumentPanelBootstrap
} from "./bootstrap";
import {
  clampRevealLineNumber,
  computeOffsetRevealLayout
} from "./lineReveal.mjs";
import { applyEditorIndentation } from "./editorIndentation.mjs";
import {
  highlightStatusMessage,
  useDocumentHighlightHTML
} from "./DocumentHighlighting";
import {
  measureRevealLayout,
  resolveComputedLineHeight,
  type RevealLayout
} from "./LineRevealMeasurement";
import {
  MARKDOWN_LINE_START_SELECTOR,
  normalizeMarkdownLineTopOffsets,
  renderPlainMarkdownSourceHtml,
} from "./markdownSoftWrap.mjs";
import {
  SOURCE_LINE_SELECTOR,
  classifyMarkdownLinkHref,
  renderMarkdownDocumentHtml,
  revealBlockIndexForLine
} from "./markdownDocument.mjs";
import { useLocalDocumentSearchController } from "./localDocumentSearch";
import { localDocumentNativeBridge } from "./nativeBridge";

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

/**
 * The view a Markdown document uses when it is not being edited, or null for
 * other formats. Files too large to highlight are also too large to format,
 * so they always use the source view.
 */
function effectiveMarkdownViewMode(
  bootstrap: LocalDocumentPanelBootstrap
): LocalDocumentMarkdownViewMode | null {
  if (bootstrap.format !== "markdown") {
    return null;
  }
  if (bootstrap.highlightState === "disabledForLargeFile") {
    return "source";
  }
  return bootstrap.markdownViewMode ?? "formatted";
}

function useFormattedMarkdownHTML(content: string | null): string | null {
  return React.useMemo(() => {
    if (content === null) {
      return null;
    }

    try {
      return renderMarkdownDocumentHtml(content);
    } catch (error) {
      console.warn("[ToasttyLocalDocumentPanel] Markdown formatting failed; showing the source view.", error);
      return null;
    }
  }, [content]);
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

function useLocalDocumentPanelState(): {
  bootstrap: LocalDocumentPanelBootstrap | null;
  draftContent: string;
  isDirty: boolean;
  canSave: boolean;
  canOverwrite: boolean;
  copyFullPath: () => void;
  openInDefaultApp: () => void;
  enterEdit: () => void;
  saveEdit: () => void;
  overwriteAfterConflict: () => void;
  cancelEdit: () => void;
  updateDraftContent: (nextContent: string) => void;
  setMarkdownViewMode: (mode: LocalDocumentMarkdownViewMode) => void;
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

  const copyFullPath = React.useCallback(() => {
    if (!bootstrap?.filePath || bootstrap.isEditing) {
      return;
    }

    localDocumentNativeBridge.copyFullPath();
  }, [bootstrap?.filePath, bootstrap?.isEditing]);

  const enterEdit = React.useCallback(() => {
    if (!bootstrap?.filePath || bootstrap.presentation === "mobileReadOnly") {
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

  const setMarkdownViewMode = React.useCallback((mode: LocalDocumentMarkdownViewMode) => {
    if (!bootstrap || bootstrap.format !== "markdown" || bootstrap.isEditing) {
      return;
    }

    localDocumentNativeBridge.setMarkdownViewMode(mode);
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
    copyFullPath,
    openInDefaultApp,
    enterEdit,
    saveEdit,
    overwriteAfterConflict,
    cancelEdit,
    updateDraftContent,
    setMarkdownViewMode
  };
}

function Header(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  content: string;
  markdownViewMode: LocalDocumentMarkdownViewMode | null;
  setMarkdownViewMode: (mode: LocalDocumentMarkdownViewMode) => void;
  isDirty: boolean;
  canSave: boolean;
  canOverwrite: boolean;
  copyFullPath: () => void;
  openInDefaultApp: () => void;
  enterEdit: () => void;
  saveEdit: () => void;
  overwriteAfterConflict: () => void;
  cancelEdit: () => void;
}) {
  const {
    bootstrap,
    content,
    markdownViewMode,
    setMarkdownViewMode,
    isDirty,
    canSave,
    canOverwrite,
    copyFullPath,
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
  const [copyFeedback, setCopyFeedback] = React.useState<{
    filePath: string;
    requestID: number;
  } | null>(null);
  const didCopyFullPath = copyFeedback?.filePath === bootstrap.filePath;

  const handleCopyFullPath = React.useCallback(() => {
    const filePath = bootstrap.filePath;
    if (!filePath) {
      return;
    }

    copyFullPath();
    setCopyFeedback((current) => ({
      filePath,
      requestID: (current?.requestID ?? 0) + 1
    }));
  }, [bootstrap.filePath, copyFullPath]);

  React.useEffect(() => {
    if (!copyFeedback) {
      return;
    }

    const timer = window.setTimeout(() => setCopyFeedback(null), 1500);
    return () => window.clearTimeout(timer);
  }, [copyFeedback]);

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
            {markdownViewMode && bootstrap.highlightState !== "disabledForLargeFile" && (
              <MarkdownViewModeToggle mode={markdownViewMode} onChange={setMarkdownViewMode} />
            )}
            {bootstrap.filePath && (
              <>
                <button
                  className="local-document-action-button local-document-action-button-secondary local-document-action-button-icon"
                  onClick={handleCopyFullPath}
                  aria-label="Copy Full Path"
                  title={didCopyFullPath ? "Path Copied" : "Copy Full Path"}
                >
                  {didCopyFullPath ? <CheckIcon /> : <CopyIcon />}
                </button>
                {didCopyFullPath && copyFeedback && (
                  <span
                    key={copyFeedback.requestID}
                    className="local-document-visually-hidden"
                    role="status"
                    aria-live="polite"
                  >
                    Full path copied
                  </span>
                )}
                <button
                  className="local-document-action-button local-document-action-button-secondary local-document-action-button-icon"
                  onClick={openInDefaultApp}
                  aria-label="Open in Default App"
                  title="Open in Default App"
                >
                  <ExternalOpenIcon />
                </button>
              </>
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

const MARKDOWN_VIEW_MODE_OPTIONS: ReadonlyArray<{
  mode: LocalDocumentMarkdownViewMode;
  label: string;
}> = [
  { mode: "formatted", label: "Formatted" },
  { mode: "source", label: "Source" }
];

function MarkdownViewModeToggle(props: {
  mode: LocalDocumentMarkdownViewMode;
  onChange: (mode: LocalDocumentMarkdownViewMode) => void;
}) {
  return (
    <div className="local-document-view-mode-toggle" role="group" aria-label="Markdown view">
      {MARKDOWN_VIEW_MODE_OPTIONS.map(({ mode, label }) => {
        const isSelected = props.mode === mode;
        return (
          <button
            key={mode}
            type="button"
            className={`local-document-view-mode-option${isSelected ? " local-document-view-mode-option-selected" : ""}`}
            aria-pressed={isSelected}
            onClick={() => {
              if (!isSelected) {
                props.onChange(mode);
              }
            }}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}

function CopyIcon() {
  return (
    <svg
      aria-hidden="true"
      className="local-document-action-icon"
      viewBox="0 0 16 16"
      fill="none"
    >
      <rect
        x="5.5"
        y="5.5"
        width="8"
        height="8"
        rx="1.5"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <path
        d="M10.5 5.5V4C10.5 3.17157 9.82843 2.5 9 2.5H4C3.17157 2.5 2.5 3.17157 2.5 4V9C2.5 9.82843 3.17157 10.5 4 10.5H5.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
      />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      aria-hidden="true"
      className="local-document-action-icon"
      viewBox="0 0 16 16"
      fill="none"
    >
      <path
        d="M3 8.5L6.5 12L13 4.5"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
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

  function handleKeyDown(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key !== "Tab" ||
        event.metaKey ||
        event.ctrlKey ||
        event.altKey ||
        props.bootstrap.isSaving) {
      return;
    }

    const textarea = event.currentTarget;
    const result = applyEditorIndentation({
      value: textarea.value,
      selectionStart: textarea.selectionStart,
      selectionEnd: textarea.selectionEnd,
      direction: event.shiftKey ? "outdent" : "indent"
    });

    event.preventDefault();
    event.stopPropagation();

    if (result.value === textarea.value) {
      return;
    }

    textarea.setSelectionRange(result.replacementStart, result.replacementEnd, "none");
    let didApplyNativeReplacement = false;
    try {
      didApplyNativeReplacement = textarea.ownerDocument.execCommand(
        "insertText",
        false,
        result.replacementText
      );
    } catch {
      didApplyNativeReplacement = false;
    }

    if (!didApplyNativeReplacement) {
      textarea.setRangeText(
        result.replacementText,
        result.replacementStart,
        result.replacementEnd,
        "end"
      );
    }

    textarea.setSelectionRange(result.selectionStart, result.selectionEnd, "none");
    props.updateDraftContent(textarea.value);
  }

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
        onKeyDown={handleKeyDown}
        spellCheck={false}
        autoCorrect="off"
        autoCapitalize="off"
        wrap="off"
        readOnly={props.bootstrap.isSaving}
      />
    </section>
  );
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
    props.bootstrap.formatLabel,
    props.bootstrap.format
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

const MARKDOWN_REVEAL_TARGET_CLASS = "markdown-reveal-target";
// A revealed block sits this far down the viewport, like a source-view reveal.
const FORMATTED_REVEAL_VIEWPORT_FRACTION = 0.3;
const FORMATTED_SCROLL_TOP_INSET = 16;

// A target inside a closed <details> block has no layout until it opens.
function openEnclosingDetails(target: HTMLElement, root: HTMLElement) {
  for (let element = target.parentElement; element && element !== root; element = element.parentElement) {
    if (element instanceof HTMLDetailsElement && !element.open) {
      element.open = true;
    }
  }
}

function formattedScrollTopFor(
  scrollElement: HTMLElement,
  target: HTMLElement,
  topInset: number
): number {
  const scrollRect = scrollElement.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();
  const targetTop = scrollElement.scrollTop + (targetRect.top - scrollRect.top);
  const maxScrollTop = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
  return Math.min(maxScrollTop, Math.max(0, targetTop - topInset));
}

function FormattedMarkdownView(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  html: string;
  lineCount: number;
  previewRootRef: React.RefObject<HTMLElement | null>;
  previewContentRef: React.RefObject<HTMLElement | null>;
}) {
  const revealRequest = useRevealRequest();
  const scrollRef = React.useRef<HTMLDivElement | null>(null);
  const contentRef = React.useRef<HTMLElement | null>(null);
  const localRevealRequestIDRef = React.useRef(0);
  const scrollFrameRef = React.useRef<{
    outer: number | null;
    inner: number | null;
  }>({ outer: null, inner: null });
  const [activeReveal, setActiveReveal] = React.useState<ActiveReveal | null>(null);
  const { filePath, contentRevision, isEditing } = props.bootstrap;

  const handleScrollRef = React.useCallback((node: HTMLDivElement | null) => {
    assignObjectRef(scrollRef, node);
    assignObjectRef(props.previewRootRef, node);
  }, [props.previewRootRef]);
  const handleContentRef = React.useCallback((node: HTMLElement | null) => {
    assignObjectRef(contentRef, node);
    assignObjectRef(props.previewContentRef, node);
  }, [props.previewContentRef]);

  const cancelScheduledScroll = React.useCallback(() => {
    if (scrollFrameRef.current.outer !== null) {
      window.cancelAnimationFrame(scrollFrameRef.current.outer);
      scrollFrameRef.current.outer = null;
    }
    if (scrollFrameRef.current.inner !== null) {
      window.cancelAnimationFrame(scrollFrameRef.current.inner);
      scrollFrameRef.current.inner = null;
    }
  }, []);

  // WKWebView can drop a scrollTop assignment made in the same layout pass,
  // so wait one frame for the render and one more for settled layout, as the
  // source view does.
  const scheduleScroll = React.useCallback((target: HTMLElement, topInset: (scrollElement: HTMLElement) => number) => {
    cancelScheduledScroll();
    scrollFrameRef.current.outer = window.requestAnimationFrame(() => {
      scrollFrameRef.current.outer = null;
      scrollFrameRef.current.inner = window.requestAnimationFrame(() => {
        scrollFrameRef.current.inner = null;
        const scrollElement = scrollRef.current;
        if (!scrollElement || !target.isConnected) {
          return;
        }
        scrollElement.scrollTop = formattedScrollTopFor(scrollElement, target, topInset(scrollElement));
      });
    });
  }, [cancelScheduledScroll]);

  React.useEffect(() => cancelScheduledScroll, [cancelScheduledScroll]);

  React.useEffect(() => {
    if (!revealRequest || isEditing) {
      return;
    }

    setActiveReveal({
      lineNumber: clampRevealLineNumber(revealRequest.lineNumber, props.lineCount),
      requestID: revealRequest.requestID,
      filePath,
      contentRevision
    });
    window.ToasttyLocalDocumentPanel?.consumeRevealRequest(revealRequest.requestID);
  }, [contentRevision, filePath, isEditing, props.lineCount, revealRequest]);

  React.useEffect(() => {
    if (activeReveal &&
        (filePath !== activeReveal.filePath || contentRevision !== activeReveal.contentRevision)) {
      setActiveReveal(null);
    }
  }, [activeReveal, contentRevision, filePath]);

  React.useEffect(() => {
    if (!activeReveal) {
      return;
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape") {
        return;
      }
      cancelScheduledScroll();
      setActiveReveal(null);
      event.preventDefault();
      event.stopPropagation();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [activeReveal, cancelScheduledScroll]);

  React.useLayoutEffect(() => {
    const contentElement = contentRef.current;
    if (!contentElement) {
      return;
    }

    for (const element of Array.from(contentElement.querySelectorAll(`.${MARKDOWN_REVEAL_TARGET_CLASS}`))) {
      element.classList.remove(MARKDOWN_REVEAL_TARGET_CLASS);
    }
    // A reveal from an earlier file or revision is cleared by the effect
    // above; until then it must not mark or scroll the new content.
    if (!activeReveal ||
        activeReveal.filePath !== filePath ||
        activeReveal.contentRevision !== contentRevision) {
      cancelScheduledScroll();
      return;
    }

    const blockElements = Array.from(contentElement.querySelectorAll<HTMLElement>(SOURCE_LINE_SELECTOR));
    const targetIndex = revealBlockIndexForLine(
      blockElements.map((element) => ({
        start: Number(element.dataset.sourceStart),
        end: Number(element.dataset.sourceEnd)
      })),
      activeReveal.lineNumber
    );
    const target = blockElements[targetIndex];
    if (!target) {
      return;
    }

    openEnclosingDetails(target, contentElement);
    target.classList.add(MARKDOWN_REVEAL_TARGET_CLASS);
    scheduleScroll(target, (scrollElement) => {
      const targetHeight = target.getBoundingClientRect().height;
      const revealInset = scrollElement.clientHeight * FORMATTED_REVEAL_VIEWPORT_FRACTION;
      // A block taller than the space below the reveal position starts near the top instead.
      return targetHeight > scrollElement.clientHeight - revealInset
        ? FORMATTED_SCROLL_TOP_INSET
        : revealInset;
    });
  }, [activeReveal, cancelScheduledScroll, contentRevision, filePath, props.html, scheduleScroll]);

  const handleClick = React.useCallback((event: React.MouseEvent<HTMLElement>) => {
    const contentElement = contentRef.current;
    const anchor = event.target instanceof Element
      ? event.target.closest<HTMLAnchorElement>("a[href]")
      : null;
    if (!contentElement || !anchor || !contentElement.contains(anchor)) {
      return;
    }

    // Links never navigate the panel page itself.
    event.preventDefault();
    const link = classifyMarkdownLinkHref(anchor.getAttribute("href"));
    if (link.kind === "open") {
      localDocumentNativeBridge.openLink(link.href);
      return;
    }
    if (link.kind !== "fragment") {
      return;
    }

    const target = link.elementIDs
      .map((id) => document.getElementById(id))
      .find((element): element is HTMLElement => element !== null && contentElement.contains(element));
    if (target) {
      openEnclosingDetails(target, contentElement);
      scheduleScroll(target, () => FORMATTED_SCROLL_TOP_INSET);
      return;
    }

    if (link.lineNumber !== null) {
      localRevealRequestIDRef.current -= 1;
      setActiveReveal({
        lineNumber: clampRevealLineNumber(link.lineNumber, props.lineCount),
        requestID: localRevealRequestIDRef.current,
        filePath,
        contentRevision
      });
    }
  }, [contentRevision, filePath, props.lineCount, scheduleScroll]);

  return (
    <section className="local-document-formatted-shell">
      <div className="local-document-formatted-scroll" ref={handleScrollRef}>
        <article
          ref={handleContentRef}
          className="local-document-formatted markdown-prose"
          onClick={handleClick}
          dangerouslySetInnerHTML={{ __html: props.html }}
        />
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
    copyFullPath,
    openInDefaultApp,
    enterEdit,
    saveEdit,
    overwriteAfterConflict,
    cancelEdit,
    updateDraftContent,
    setMarkdownViewMode
  } = useLocalDocumentPanelState();

  React.useEffect(() => {
    if (!bootstrap) {
      return;
    }

    localDocumentNativeBridge.renderReady(
      bootstrap.displayName,
      bootstrap.contentRevision,
      bootstrap.isEditing
    );
  }, [bootstrap?.displayName, bootstrap?.contentRevision, bootstrap?.isEditing]);

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

  return (
    <LoadedLocalDocumentPanelApp
      bootstrap={bootstrap}
      draftContent={draftContent}
      isDirty={isDirty}
      canSave={canSave}
      canOverwrite={canOverwrite}
      copyFullPath={copyFullPath}
      openInDefaultApp={openInDefaultApp}
      enterEdit={enterEdit}
      saveEdit={saveEdit}
      overwriteAfterConflict={overwriteAfterConflict}
      cancelEdit={cancelEdit}
      updateDraftContent={updateDraftContent}
      setMarkdownViewMode={setMarkdownViewMode}
    />
  );
}

function LoadedLocalDocumentPanelApp(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  draftContent: string;
  isDirty: boolean;
  canSave: boolean;
  canOverwrite: boolean;
  copyFullPath: () => void;
  openInDefaultApp: () => void;
  enterEdit: () => void;
  saveEdit: () => void;
  overwriteAfterConflict: () => void;
  cancelEdit: () => void;
  updateDraftContent: (nextContent: string) => void;
  setMarkdownViewMode: (mode: LocalDocumentMarkdownViewMode) => void;
}) {
  const renderedContent = props.bootstrap.isEditing ? props.draftContent : props.bootstrap.content;
  const previewRootRef = React.useRef<HTMLElement | null>(null);
  const previewContentRef = React.useRef<HTMLElement | null>(null);
  const textareaRef = React.useRef<HTMLTextAreaElement | null>(null);
  const markdownViewMode = effectiveMarkdownViewMode(props.bootstrap);
  const formattedHTML = useFormattedMarkdownHTML(
    !props.bootstrap.isEditing && markdownViewMode === "formatted" ? renderedContent : null
  );
  const lineCount = React.useMemo(() => contentLines(renderedContent).length, [renderedContent]);

  useLocalDocumentSearchController({
    content: renderedContent,
    isEditing: props.bootstrap.isEditing,
    surfaceKey: formattedHTML === null ? "source" : "formatted",
    previewRootRef,
    previewContentRef,
    textareaRef
  });

  return (
    <main className="local-document-shell">
      {props.bootstrap.presentation !== "mobileReadOnly" && <Header
        bootstrap={props.bootstrap}
        content={renderedContent}
        markdownViewMode={markdownViewMode}
        setMarkdownViewMode={props.setMarkdownViewMode}
        isDirty={props.isDirty}
        canSave={props.canSave}
        canOverwrite={props.canOverwrite}
        copyFullPath={props.copyFullPath}
        openInDefaultApp={props.openInDefaultApp}
        enterEdit={props.enterEdit}
        saveEdit={props.saveEdit}
        overwriteAfterConflict={props.overwriteAfterConflict}
        cancelEdit={props.cancelEdit}
      />}
      {props.bootstrap.isEditing ? (
        <LocalDocumentEditor
          bootstrap={props.bootstrap}
          draftContent={props.draftContent}
          textareaRef={textareaRef}
          updateDraftContent={props.updateDraftContent}
        />
      ) : formattedHTML !== null ? (
        <FormattedMarkdownView
          bootstrap={props.bootstrap}
          html={formattedHTML}
          lineCount={lineCount}
          previewRootRef={previewRootRef}
          previewContentRef={previewContentRef}
        />
      ) : (
        <CodeDocumentView
          bootstrap={props.bootstrap}
          content={renderedContent}
          previewRootRef={previewRootRef}
          previewContentRef={previewContentRef}
        />
      )}
    </main>
  );
}
