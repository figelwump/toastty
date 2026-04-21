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
  computeRevealLayout,
  resolveMeasuredLineHeight
} from "./lineReveal.mjs";
import { highlightMarkdownSourceToHtml } from "./markdownSourceHighlighter.mjs";
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

function measureRevealLayout(args: {
  lineNumber: number;
  lineCount: number;
  scrollElement: HTMLDivElement;
  contentFrameElement: HTMLDivElement;
  gutterFrameElement: HTMLDivElement;
  contentElement: HTMLElement;
  gutterElement: HTMLElement;
}): RevealLayout | null {
  const contentFrameRect = args.contentFrameElement.getBoundingClientRect();
  const gutterFrameRect = args.gutterFrameElement.getBoundingClientRect();
  const contentRect = args.contentElement.getBoundingClientRect();
  const gutterRect = args.gutterElement.getBoundingClientRect();
  const contentStyle = window.getComputedStyle(args.contentElement);
  const gutterStyle = window.getComputedStyle(args.gutterElement);
  const contentLineHeight = resolveMeasuredLineHeight(
    Number.parseFloat(contentStyle.lineHeight),
    contentRect.height,
    args.lineCount,
    Number.parseFloat(contentStyle.paddingTop) + Number.parseFloat(contentStyle.paddingBottom)
  );
  const gutterLineHeight = resolveMeasuredLineHeight(
    Number.parseFloat(gutterStyle.lineHeight),
    gutterRect.height,
    args.lineCount,
    Number.parseFloat(gutterStyle.paddingTop) + Number.parseFloat(gutterStyle.paddingBottom)
  );

  if (contentLineHeight <= 0 || gutterLineHeight <= 0) {
    return null;
  }

  return computeRevealLayout({
    lineNumber: args.lineNumber,
    lineCount: args.lineCount,
    contentTopBase: contentRect.top - contentFrameRect.top,
    gutterTopBase: gutterRect.top - gutterFrameRect.top,
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
  updateDraftContent: (nextContent: string) => void;
}) {
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

function CodeDocumentView(props: { bootstrap: LocalDocumentPanelBootstrap; content: string }) {
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
        <div className="local-document-code-scroll" ref={scrollRef}>
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
              <pre className="local-document-code-content">
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
