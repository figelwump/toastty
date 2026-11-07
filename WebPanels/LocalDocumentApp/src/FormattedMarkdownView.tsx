import React from "react";
import Markdown, { type Components } from "react-markdown";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import { highlightedCodeHTML } from "./DocumentHighlighting";
import {
  classifyMarkdownLink,
  createHeadingSlugger,
  frontmatterEntries
} from "./formattedMarkdown.mjs";

type HastNode = {
  type: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

function hastText(node: HastNode | undefined): string {
  if (!node) {
    return "";
  }
  if (node.type === "text") {
    return node.value ?? "";
  }
  return (node.children ?? []).map(hastText).join("");
}

const HEADING_TAGS = new Set(["h1", "h2", "h3", "h4", "h5", "h6"]);

// Assigns GitHub-style ids to headings once per parse, so in-document
// `#fragment` links resolve and repeated headings get stable suffixes.
function rehypeHeadingIds() {
  return (tree: HastNode) => {
    const slug = createHeadingSlugger();
    const visit = (node: HastNode) => {
      if (node.type === "element" && node.tagName && HEADING_TAGS.has(node.tagName)) {
        node.properties = { ...node.properties, id: slug(hastText(node)) };
      }
      node.children?.forEach(visit);
    };
    visit(tree);
  };
}

const remarkPlugins = [remarkGfm, remarkFrontmatter];
const rehypePlugins = [rehypeHeadingIds];

// Raw HTML in the source is skipped (never rendered or shown as tag text), and
// react-markdown's default URL transform drops unsafe schemes such as `javascript:`.
export function FormattedMarkdownView(props: {
  content: string;
  filePath: string | null;
  // The iPhone preview can only open web links; local file links stay inert there.
  opensLocalFiles: boolean;
  previewRootRef: React.RefObject<HTMLElement | null>;
  previewContentRef: React.RefObject<HTMLElement | null>;
  onOpenLink: (url: string) => void;
}) {
  const { content, filePath, opensLocalFiles, onOpenLink, previewRootRef, previewContentRef } = props;
  const frontmatter = React.useMemo(() => frontmatterEntries(content), [content]);
  const handleScrollRef = React.useCallback((node: HTMLDivElement | null) => {
    previewRootRef.current = node;
  }, [previewRootRef]);
  const handleContentRef = React.useCallback((node: HTMLElement | null) => {
    previewContentRef.current = node;
  }, [previewContentRef]);

  const components = React.useMemo<Components>(() => ({
      a({ href, children, title }) {
        const classified = classifyMarkdownLink(href, filePath);
        const target = classified.kind === "open" && classified.url.startsWith("file:") && !opensLocalFiles
          ? { kind: "inert" as const }
          : classified;
        if (target.kind === "inert") {
          return <span className="markdown-link-inert" title={href ?? undefined}>{children}</span>;
        }
        const isExternal = target.kind === "open" && !target.url.startsWith("file:");
        return (
          <a
            href={href}
            title={title ?? (target.kind === "open" ? target.url : undefined)}
            onClick={(event) => {
              event.preventDefault();
              if (target.kind === "fragment") {
                document.getElementById(target.id)?.scrollIntoView({ block: "start" });
              } else {
                onOpenLink(target.url);
              }
            }}
          >
            {children}
            {isExternal && <span className="markdown-link-external" aria-hidden="true">↗</span>}
          </a>
        );
      },
      img({ alt, src }) {
        return (
          <span className="markdown-image-placeholder">
            <span className="markdown-image-placeholder-label">
              Image not shown{alt ? <>: <em>{alt}</em></> : null}
            </span>
            {src && <span className="markdown-image-placeholder-path">{src}</span>}
          </span>
        );
      },
      table({ children }) {
        return (
          <div className="markdown-table-scroll">
            <table>{children}</table>
          </div>
        );
      },
      code({ className, children }) {
        const language = /\blanguage-([\w+#.-]+)/.exec(className ?? "")?.[1] ?? null;
        const html = language
          ? highlightedCodeHTML(language, String(children).replace(/\n$/, ""), true)
          : null;
        if (html !== null) {
          return <code className={`hljs ${className}`} dangerouslySetInnerHTML={{ __html: html }} />;
        }
        return <code className={className}>{children}</code>;
      }
  }), [filePath, onOpenLink, opensLocalFiles]);
  // Parsing is the expensive part; only redo it when the text or link rules change.
  const rendered = React.useMemo(() => (
    <Markdown remarkPlugins={remarkPlugins} rehypePlugins={rehypePlugins} components={components} skipHtml>
      {content}
    </Markdown>
  ), [components, content]);

  return (
    <div className="markdown-prose-scroll" ref={handleScrollRef}>
      <article className="markdown-prose" ref={handleContentRef}>
        {frontmatter.length > 0 && (
          <div className="markdown-frontmatter">
            {frontmatter.map(([key, value]) => (
              <span key={key} className="markdown-frontmatter-item">
                <span className="markdown-frontmatter-key">{key}</span>
                <span className="markdown-frontmatter-value">{value}</span>
              </span>
            ))}
          </div>
        )}
        {rendered}
      </article>
    </div>
  );
}
