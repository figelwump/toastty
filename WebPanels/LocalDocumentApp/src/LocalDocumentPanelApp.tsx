import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import ini from "highlight.js/lib/languages/ini";
import json from "highlight.js/lib/languages/json";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import React from "react";
import {
  LocalDocumentFormat,
  LocalDocumentHighlightState,
  LocalDocumentPanelBootstrap
} from "./bootstrap";
import { highlightMarkdownSourceToHtml } from "./markdownSourceHighlighter.mjs";
import {
  MARKDOWN_LINE_START_SELECTOR,
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

type HighlightLanguage = "yaml" | "toml" | "json" | "xml" | "bash";

function syntaxLanguage(
  format: LocalDocumentFormat,
  filePath: string | null = null
): HighlightLanguage | null {
  switch (format) {
    case "yaml":
      return "yaml";
    case "toml":
      return "toml";
    case "markdown":
      return null;
    case "json":
      if (filePath?.toLowerCase().endsWith(".jsonc")) {
        return null;
      }
      return "json";
    case "xml":
      return "xml";
    case "shell":
      return "bash";
    case "jsonl":
      return "json";
    case "config":
    case "csv":
    case "tsv":
      return null;
  }
}

function formatLabel(format: LocalDocumentFormat, filePath: string | null = null): string {
  switch (format) {
    case "markdown":
      return "Markdown";
    case "yaml":
      return "YAML";
    case "toml":
      return "TOML";
    case "json":
      if (filePath?.toLowerCase().endsWith(".jsonc")) {
        return "JSONC";
      }
      return "JSON";
    case "jsonl":
      return "JSON Lines";
    case "config":
      return "Config";
    case "csv":
      return "CSV";
    case "tsv":
      return "TSV";
    case "xml":
      return "XML";
    case "shell":
      return "Shell Script";
  }
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
        <span className="local-document-panel-stat">{formatLabel(bootstrap.format, bootstrap.filePath)}</span>
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
          <button
            className="local-document-action-button"
            onClick={enterEdit}
            disabled={!bootstrap.filePath}
          >
            Edit
          </button>
        )}
      </div>
    </header>
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
  format: LocalDocumentFormat,
  filePath: string | null,
  content: string,
  shouldHighlight: boolean
): string | null {
  const language = syntaxLanguage(format, filePath);
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
  format: LocalDocumentFormat,
  filePath: string | null
): string | null {
  switch (highlightState) {
    case "enabled":
    case "unavailable":
      return null;
    case "disabledForLargeFile":
      return "Syntax highlighting is disabled for large files. Editing remains available, but performance may still degrade on very large documents.";
    case "unsupportedFormat":
      if (format === "json" && filePath?.toLowerCase().endsWith(".jsonc")) {
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
      bootstrap.format,
      bootstrap.filePath,
      content,
      bootstrap.shouldHighlight
    );
  }, [bootstrap.filePath, bootstrap.format, bootstrap.shouldHighlight, content]);
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

function trimTrailingNewline(node: Node): boolean {
  if (node.nodeType === Node.TEXT_NODE) {
    const value = node.textContent ?? "";
    if (!value.endsWith("\n")) {
      return false;
    }

    const trimmedValue = value.slice(0, -1);
    if (trimmedValue.length > 0) {
      node.textContent = trimmedValue;
    } else {
      node.parentNode?.removeChild(node);
    }
    return true;
  }

  let child = node.lastChild;
  while (child) {
    if (trimTrailingNewline(child)) {
      if (child.nodeType === Node.ELEMENT_NODE && child.childNodes.length === 0) {
        child.parentNode?.removeChild(child);
      }
      return true;
    }

    if (child.nodeType === Node.ELEMENT_NODE && child.childNodes.length === 0) {
      const previousSibling = child.previousSibling;
      child.parentNode?.removeChild(child);
      child = previousSibling;
      continue;
    }

    child = child.previousSibling;
  }

  return false;
}

function splitHighlightedMarkdownIntoLogicalLines(
  highlightedHTML: string,
  lineCount: number
): string[] {
  const parsedDocument = new DOMParser().parseFromString(
    `<div>${highlightedHTML}</div>`,
    "text/html"
  );
  const root = parsedDocument.body.firstElementChild;

  if (!root) {
    return Array.from({ length: lineCount }, () => "");
  }

  const markers = Array.from(root.querySelectorAll<HTMLElement>(MARKDOWN_LINE_START_SELECTOR));
  const logicalLines = markers.map((marker, index) => {
    const range = parsedDocument.createRange();
    range.setStartAfter(marker);

    if (index + 1 < markers.length) {
      range.setEndBefore(markers[index + 1]);
    } else if (root.lastChild) {
      range.setEndAfter(root.lastChild);
    } else {
      range.setEndAfter(marker);
    }

    const container = parsedDocument.createElement("div");
    container.append(range.cloneContents());
    trimTrailingNewline(container);
    return container.innerHTML;
  });

  while (logicalLines.length < lineCount) {
    logicalLines.push("");
  }

  return logicalLines.slice(0, lineCount);
}

function MarkdownCodeDocumentView(props: {
  content: string;
  highlightedHTML: string | null;
  lines: string[];
}) {
  const highlightedLines = React.useMemo(
    () => (
      props.highlightedHTML
        ? splitHighlightedMarkdownIntoLogicalLines(props.highlightedHTML, props.lines.length)
        : null
    ),
    [props.highlightedHTML, props.lines.length]
  );

  return (
    <div className="local-document-code-frame local-document-code-frame-markdown">
      <div className="local-document-code-scroll local-document-code-scroll-markdown">
        <div className="local-document-code-markdown-grid">
          {props.lines.map((line, index) => (
            <React.Fragment key={index}>
              <div className="local-document-code-gutter-cell" aria-hidden="true">
                {index + 1}
              </div>
              <pre className="local-document-code-markdown-line">
                {highlightedLines ? (
                  <code
                    className="starry-night local-document-code-markdown"
                    dangerouslySetInnerHTML={{ __html: highlightedLines[index] ?? "" }}
                  />
                ) : (
                  <code className="local-document-code-plain local-document-code-plain-markdown">
                    {line}
                  </code>
                )}
              </pre>
            </React.Fragment>
          ))}
        </div>
      </div>
    </div>
  );
}

function CodeDocumentView(props: { bootstrap: LocalDocumentPanelBootstrap; content: string }) {
  const lines = React.useMemo(() => contentLines(props.content), [props.content]);
  const highlightedHTML = useDocumentHighlightHTML(props.bootstrap, props.content);
  const language = syntaxLanguage(props.bootstrap.format, props.bootstrap.filePath);
  const statusMessage = highlightStatusMessage(
    props.bootstrap.highlightState,
    props.bootstrap.format,
    props.bootstrap.filePath
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
