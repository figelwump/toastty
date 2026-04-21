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
  LocalDocumentPanelBootstrap,
  LocalDocumentSyntaxLanguage
} from "./bootstrap";
import { highlightMarkdownSourceToHtml } from "./markdownSourceHighlighter.mjs";
import {
  MARKDOWN_LINE_START_SELECTOR,
  normalizeMarkdownLineTopOffsets,
  renderPlainMarkdownSourceHtml,
} from "./markdownSoftWrap.mjs";
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
  updateDraftContent: (nextContent: string) => void;
}) {
  const textareaRef = React.useRef<HTMLTextAreaElement | null>(null);

  React.useLayoutEffect(() => {
    const textarea = textareaRef.current;
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
        ref={textareaRef}
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

function MarkdownCodeDocumentView(props: {
  content: string;
  highlightedHTML: string | null;
  lines: string[];
}) {
  const sourceHTML = React.useMemo(
    () => props.highlightedHTML ?? renderPlainMarkdownSourceHtml(props.content),
    [props.content, props.highlightedHTML]
  );
  const { contentRef, scrollRef, lineLayout } = useMarkdownLogicalLineLayout(
    props.lines.length,
    sourceHTML
  );
  const codeClassName = props.highlightedHTML
    ? "starry-night local-document-code-markdown"
    : "local-document-code-plain local-document-code-plain-markdown";

  return (
    <div className="local-document-code-frame local-document-code-frame-markdown">
      <div className="local-document-code-scroll local-document-code-scroll-markdown" ref={scrollRef}>
        <div className="local-document-code-markdown-grid">
          <div className="local-document-code-markdown-gutter" aria-hidden="true">
            <div
              className="local-document-code-markdown-gutter-inner"
              style={{ height: `${lineLayout.contentHeight}px` }}
            >
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
          <pre className="local-document-code-markdown-surface">
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

function CodeDocumentView(props: { bootstrap: LocalDocumentPanelBootstrap; content: string }) {
  const lines = React.useMemo(() => contentLines(props.content), [props.content]);
  const highlightedHTML = useDocumentHighlightHTML(props.bootstrap, props.content);
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
        <pre className="local-document-code-gutter" aria-hidden="true">
          {lines.map((_, index) => String(index + 1)).join("\n")}
        </pre>
        <pre className="local-document-code-scroll">
          {highlightedHTML ? (
            <code className={codeClassName} dangerouslySetInnerHTML={{ __html: highlightedHTML }} />
          ) : (
            <code className="local-document-code-plain">{props.content}</code>
          )}
        </pre>
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
          updateDraftContent={updateDraftContent}
        />
      ) : (
        <CodeDocumentView bootstrap={bootstrap} content={renderedContent} />
      )}
    </main>
  );
}
