import React from "react";
import ReactMarkdown from "react-markdown";
import rehypeHighlight from "rehype-highlight";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import { MarkdownPanelBootstrap } from "./bootstrap";
import { markdownNativeBridge } from "./nativeBridge";

// --- Sanitize schema: extend default to allow highlight.js class names on spans ---

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

// --- Heading helpers ---

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

// --- Content helpers ---

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

interface TocEntry {
  level: number;
  text: string;
  id: string;
}

/** Strip markdown inline syntax so raw heading text slugifies the same as
 *  the plain-text extraction from the rendered React tree. */
function stripMarkdownInline(text: string): string {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1") // links & images -> link text / alt
    .replace(/[*_~`]/g, "");                     // bold, italic, strikethrough, code
}

function parseToc(content: string): TocEntry[] {
  // Strip frontmatter so YAML comments (# ...) aren't mistaken for headings
  const body = content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");

  const entries: TocEntry[] = [];
  let fenceChar = "";
  let fenceLen = 0;

  for (const line of body.split("\n")) {
    // Track code fences with proper open/close matching (CommonMark: closing
    // fence must use the same character and be at least as long as the opener)
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

// --- Scroll helper that accounts for rehype-sanitize clobber prefix ---

function scrollToHeading(id: string) {
  const el = document.getElementById("user-content-" + id) ?? document.getElementById(id);
  if (el) {
    el.scrollIntoView({ behavior: "smooth", block: "start" });
  }
}

// --- Bootstrap hook ---

function useBootstrap(): MarkdownPanelBootstrap | null {
  const [bootstrap, setBootstrap] = React.useState<MarkdownPanelBootstrap | null>(
    () => window.ToasttyMarkdownPanel?.getCurrentBootstrap() ?? null
  );

  React.useEffect(() => {
    return window.ToasttyMarkdownPanel?.subscribe(setBootstrap);
  }, []);

  React.useEffect(() => {
    document.title = bootstrap?.displayName ?? "Markdown";
  }, [bootstrap]);

  return bootstrap;
}

function useMarkdownPanelState(): {
  bootstrap: MarkdownPanelBootstrap | null;
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

    markdownNativeBridge.enterEdit();
  }, [bootstrap?.filePath]);

  const saveEdit = React.useCallback(() => {
    if (!bootstrap?.isEditing || bootstrap.isSaving || bootstrap.hasExternalConflict) {
      return;
    }

    markdownNativeBridge.save(bootstrap.contentRevision);
  }, [bootstrap]);

  const overwriteAfterConflict = React.useCallback(() => {
    if (!bootstrap?.isEditing || bootstrap.isSaving || !bootstrap.hasExternalConflict) {
      return;
    }

    markdownNativeBridge.overwriteAfterConflict(bootstrap.contentRevision);
  }, [bootstrap]);

  const cancelEdit = React.useCallback(() => {
    if (!bootstrap || bootstrap.isSaving) {
      return;
    }

    markdownNativeBridge.cancelEdit(bootstrap.contentRevision);
  }, [bootstrap]);

  const updateDraftContent = React.useCallback((nextContent: string) => {
    setDraftContent(nextContent);

    if (!bootstrap?.isEditing || bootstrap.isSaving) {
      return;
    }

    markdownNativeBridge.draftDidChange(nextContent, bootstrap.contentRevision);
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

// --- Components ---

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
  bootstrap: MarkdownPanelBootstrap;
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
    () => (bootstrap.isEditing ? [] : parseToc(content)),
    [bootstrap.isEditing, content]
  );
  const wordCount = React.useMemo(() => computeWordCount(content), [content]);

  // Close TOC when clicking outside
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

  return (
    <header className="markdown-panel-header">
      <div className="markdown-panel-stats">
        <span className="markdown-panel-stat">{wordCount} words</span>
      </div>
      <div className="markdown-panel-title-wrap">
        <div className="markdown-panel-title">{bootstrap.displayName}</div>
        <div className="markdown-panel-path" title={bootstrap.filePath}>{shortPath}</div>
      </div>
      <div className="markdown-panel-actions">
        {bootstrap.isEditing ? (
          <>
            <span className={`markdown-session-badge${isDirty ? " markdown-session-badge-dirty" : ""}`}>
              {bootstrap.isSaving ? "Saving" : isDirty ? "Unsaved draft" : "Editing"}
            </span>
            <button
              className="markdown-action-button"
              onClick={bootstrap.hasExternalConflict ? overwriteAfterConflict : saveEdit}
              disabled={bootstrap.hasExternalConflict ? !canOverwrite : !canSave}
            >
              {bootstrap.hasExternalConflict ? "Overwrite" : "Save"}
            </button>
            <button
              className="markdown-action-button markdown-action-button-secondary"
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
              className="markdown-action-button"
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

function MarkdownEditor(props: {
  bootstrap: MarkdownPanelBootstrap;
  draftContent: string;
  updateDraftContent: (nextContent: string) => void;
}) {
  return (
    <section className="markdown-editor-shell">
      {(props.bootstrap.hasExternalConflict || props.bootstrap.saveErrorMessage) && (
        <div className="markdown-editor-status-strip">
          {props.bootstrap.hasExternalConflict && (
            <p className="markdown-editor-status markdown-editor-status-conflict">
              The file changed on disk. Save will stay disabled until you overwrite the file or revert your draft.
            </p>
          )}
          {props.bootstrap.saveErrorMessage && (
            <p className="markdown-editor-status markdown-editor-status-error">
              {props.bootstrap.saveErrorMessage}
            </p>
          )}
        </div>
      )}
      <textarea
        className="markdown-editor"
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

export function MarkdownPanelApp() {
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
  } = useMarkdownPanelState();

  if (!bootstrap) {
    return (
      <main className="markdown-shell markdown-shell-loading">
        <div className="markdown-empty-state">
          <p className="markdown-empty-title">Waiting for content…</p>
          <p className="markdown-empty-copy">Toastty will load a local markdown file into this panel.</p>
        </div>
      </main>
    );
  }

  const renderedContent = bootstrap.isEditing ? draftContent : bootstrap.content;
  const frontmatter = bootstrap.isEditing ? null : extractFrontmatter(renderedContent);

  return (
    <main className="markdown-shell">
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
        <MarkdownEditor
          bootstrap={bootstrap}
          draftContent={draftContent}
          updateDraftContent={updateDraftContent}
        />
      ) : (
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
            {renderedContent}
          </ReactMarkdown>
        </article>
      )}
    </main>
  );
}
