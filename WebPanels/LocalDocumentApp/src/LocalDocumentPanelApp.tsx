import hljs from "highlight.js/lib/core";
import ini from "highlight.js/lib/languages/ini";
import yaml from "highlight.js/lib/languages/yaml";
import React from "react";
import ReactMarkdown from "react-markdown";
import rehypeHighlight from "rehype-highlight";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import { LocalDocumentFormat, LocalDocumentPanelBootstrap } from "./bootstrap";
import { localDocumentNativeBridge } from "./nativeBridge";

if (!hljs.getLanguage("yaml")) {
  hljs.registerLanguage("yaml", yaml);
}
if (!hljs.getLanguage("toml")) {
  // The installed highlight.js bundle exposes TOML through the INI grammar.
  hljs.registerLanguage("toml", ini);
}

const sanitizeSchema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    span: [
      ...(defaultSchema.attributes?.span ?? []),
      ["className", /^hljs-/],
    ],
  },
};

function isMarkdownFormat(format: LocalDocumentFormat): boolean {
  return format === "markdown";
}

function syntaxLanguage(format: LocalDocumentFormat): "yaml" | "toml" | null {
  switch (format) {
    case "yaml":
      return "yaml";
    case "toml":
      return "toml";
    case "markdown":
      return null;
  }
}

function formatLabel(format: LocalDocumentFormat): string {
  switch (format) {
    case "markdown":
      return "Markdown";
    case "yaml":
      return "YAML";
    case "toml":
      return "TOML";
  }
}

function slugifyHeading(text: string): string {
  const collapsed = text
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return collapsed.length > 0 ? collapsed : "section";
}

function plainText(node: React.ReactNode): string {
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map(plainText).join("");
  }
  if (React.isValidElement(node)) {
    return plainText(node.props.children);
  }
  return "";
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

function computeWordCount(content: string): string {
  const body = content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");
  const cleaned = body
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`]+`/g, "")
    .replace(/!?\[.*?\]\(.*?\)/g, "")
    .replace(/#+\s/g, "")
    .replace(/[*_~`>|-]/g, "");
  const words = cleaned.split(/\s+/).filter((w) => w.length > 0);
  return words.length.toLocaleString();
}

function computeLineCount(content: string): string {
  return contentLines(content).length.toLocaleString();
}

interface TocEntry {
  level: number;
  text: string;
  id: string;
}

function stripMarkdownInline(text: string): string {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_~`]/g, "");
}

function parseToc(content: string): TocEntry[] {
  const body = content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");

  const entries: TocEntry[] = [];
  let fenceChar = "";
  let fenceLen = 0;

  for (const line of body.split("\n")) {
    const fenceMatch = line.match(/^(`{3,}|~{3,})/);
    if (fenceMatch) {
      const char = fenceMatch[1][0];
      const len = fenceMatch[1].length;
      if (fenceLen === 0) {
        fenceChar = char;
        fenceLen = len;
      } else if (char === fenceChar && len >= fenceLen) {
        fenceChar = "";
        fenceLen = 0;
      }
      continue;
    }
    if (fenceLen > 0) continue;

    const match = line.match(/^(#{1,6})\s+(.+)$/);
    if (match) {
      const level = match[1].length;
      const raw = match[2].replace(/\s*#+\s*$/, "").trim();
      const text = stripMarkdownInline(raw);
      const id = slugifyHeading(text);
      entries.push({ level, text, id });
    }
  }
  return entries;
}

function extractFrontmatter(content: string): Record<string, string> | null {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return null;

  const meta: Record<string, string> = {};
  for (const line of match[1].split("\n")) {
    const colon = line.indexOf(":");
    if (colon > 0) {
      const key = line.slice(0, colon).trim();
      const value = line.slice(colon + 1).trim();
      if (key && value) meta[key] = value;
    }
  }
  return Object.keys(meta).length > 0 ? meta : null;
}

function scrollToHeading(id: string) {
  const el = document.getElementById("user-content-" + id) ?? document.getElementById(id);
  if (el) {
    el.scrollIntoView({ behavior: "smooth", block: "start" });
  }
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

const FRONTMATTER_DISPLAY_KEYS = ["date", "author", "tags", "category", "status", "description"];

function FrontmatterBar(props: { meta: Record<string, string> }) {
  const entries = Object.entries(props.meta).filter(
    ([key]) => FRONTMATTER_DISPLAY_KEYS.includes(key.toLowerCase())
  );
  if (entries.length === 0) return null;

  return (
    <div className="markdown-frontmatter">
      {entries.map(([key, value]) => (
        <span key={key} className="markdown-frontmatter-item">
          <span className="markdown-frontmatter-key">{key}</span>
          <span className="markdown-frontmatter-value">{value}</span>
        </span>
      ))}
    </div>
  );
}

function TableOfContents(props: { entries: TocEntry[]; onNavigate: () => void }) {
  const { entries, onNavigate } = props;
  if (entries.length === 0) return null;

  const minLevel = Math.min(...entries.map((e) => e.level));

  return (
    <nav className="markdown-toc" aria-label="Table of contents">
      <ul className="markdown-toc-list">
        {entries.map((entry, i) => (
          <li
            key={`${entry.id}-${i}`}
            className="markdown-toc-item"
            style={{ paddingLeft: `${(entry.level - minLevel) * 16}px` }}
          >
            <a
              href={`#${entry.id}`}
              className="markdown-toc-link"
              onClick={(e) => {
                e.preventDefault();
                scrollToHeading(entry.id);
                onNavigate();
              }}
            >
              {entry.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
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
  const [tocOpen, setTocOpen] = React.useState(false);
  const shortPath = shortenPath(bootstrap.filePath, bootstrap.displayName);
  const tocEntries = React.useMemo(
    () => (bootstrap.isEditing || !isMarkdownFormat(bootstrap.format) ? [] : parseToc(content)),
    [bootstrap.isEditing, bootstrap.format, content]
  );
  const statsLabel = React.useMemo(
    () => isMarkdownFormat(bootstrap.format)
      ? `${computeWordCount(content)} words`
      : `${computeLineCount(content)} lines`,
    [bootstrap.format, content]
  );

  React.useEffect(() => {
    if (!tocOpen) return;
    function handleClick(e: MouseEvent) {
      const target = e.target as HTMLElement;
      if (!target.closest(".markdown-toc") && !target.closest(".markdown-toc-toggle")) {
        setTocOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [tocOpen]);

  React.useEffect(() => {
    if (!isMarkdownFormat(bootstrap.format) && tocOpen) {
      setTocOpen(false);
    }
  }, [bootstrap.format, tocOpen]);

  return (
    <header className="local-document-panel-header">
      <div className="local-document-panel-stats">
        <span className="local-document-panel-stat">{statsLabel}</span>
        <span className="local-document-panel-stat-divider" />
        <span className="local-document-panel-stat">{formatLabel(bootstrap.format)}</span>
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
            {tocEntries.length > 0 && (
              <button
                className={`markdown-toc-toggle${tocOpen ? " markdown-toc-toggle-open" : ""}`}
                onClick={() => setTocOpen((prev) => !prev)}
                aria-expanded={tocOpen}
                aria-label="Table of contents"
                title="Table of contents"
              >
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                  <path d="M2 4h12M2 8h8M2 12h10" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
                </svg>
              </button>
            )}
            <button
              className="local-document-action-button"
              onClick={enterEdit}
              disabled={!bootstrap.filePath}
            >
              Edit
            </button>
          </>
        )}
        {tocOpen && (
          <TableOfContents entries={tocEntries} onNavigate={() => setTocOpen(false)} />
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
        readOnly={props.bootstrap.isSaving}
      />
    </section>
  );
}

function MarkdownDocumentView(props: { content: string }) {
  const frontmatter = React.useMemo(
    () => extractFrontmatter(props.content),
    [props.content]
  );

  return (
    <article className="markdown-prose">
      {frontmatter && <FrontmatterBar meta={frontmatter} />}
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkFrontmatter, remarkBreaks]}
        rehypePlugins={[rehypeHighlight, [rehypeSanitize, sanitizeSchema]]}
        components={{
          a({ href, children }) {
            if (href?.startsWith("#")) {
              return <a href={href}>{children}</a>;
            }
            return <span className="markdown-link-blocked">{children}</span>;
          },
          img({ alt }) {
            return <span className="markdown-image-blocked">Image blocked{alt ? `: ${alt}` : ""}</span>;
          },
          h1({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h1 id={id}>{children}</h1>;
          },
          h2({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h2 id={id}>{children}</h2>;
          },
          h3({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h3 id={id}>{children}</h3>;
          },
          h4({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h4 id={id}>{children}</h4>;
          },
          h5({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h5 id={id}>{children}</h5>;
          },
          h6({ children }) {
            const id = slugifyHeading(plainText(children));
            return <h6 id={id}>{children}</h6>;
          }
        }}
      >
        {props.content}
      </ReactMarkdown>
    </article>
  );
}

function highlightedCodeHTML(
  format: LocalDocumentFormat,
  content: string,
  shouldHighlight: boolean
): string | null {
  const language = syntaxLanguage(format);
  if (!shouldHighlight || !language || !hljs.getLanguage(language)) {
    return null;
  }

  try {
    return hljs.highlight(String(content), { language, ignoreIllegals: true }).value;
  } catch {
    return null;
  }
}

function CodeDocumentView(props: { bootstrap: LocalDocumentPanelBootstrap; content: string }) {
  const lines = React.useMemo(() => contentLines(props.content), [props.content]);
  const highlightedHTML = React.useMemo(
    () => highlightedCodeHTML(props.bootstrap.format, props.content, props.bootstrap.shouldHighlight),
    [props.bootstrap.format, props.bootstrap.shouldHighlight, props.content]
  );
  const language = syntaxLanguage(props.bootstrap.format);
  const codeClassName = language ? `hljs language-${language}` : "hljs";

  return (
    <section className="local-document-code-shell">
      {!props.bootstrap.shouldHighlight && (
        <div className="local-document-code-status-strip">
          <p className="local-document-code-status">
            Syntax highlighting is disabled for large files. Editing remains available, but performance may still degrade on very large documents.
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
      ) : isMarkdownFormat(bootstrap.format) ? (
        <MarkdownDocumentView content={renderedContent} />
      ) : (
        <CodeDocumentView bootstrap={bootstrap} content={renderedContent} />
      )}
    </main>
  );
}
