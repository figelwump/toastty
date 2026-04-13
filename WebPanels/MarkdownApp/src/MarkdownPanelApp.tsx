import React from "react";
import ReactMarkdown from "react-markdown";
import rehypeSanitize from "rehype-sanitize";
import remarkGfm from "remark-gfm";
import { MarkdownPanelBootstrap } from "./bootstrap";

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

function Header(props: { bootstrap: MarkdownPanelBootstrap }) {
  const { bootstrap } = props;

  return (
    <header className="markdown-panel-header">
      <div className="markdown-panel-badge">Markdown</div>
      <div className="markdown-panel-title-wrap">
        <div className="markdown-panel-title">{bootstrap.displayName}</div>
        <div className="markdown-panel-path" title={bootstrap.filePath}>{bootstrap.filePath}</div>
      </div>
    </header>
  );
}

export function MarkdownPanelApp() {
  const bootstrap = useBootstrap();

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

  return (
    <main className="markdown-shell">
      <Header bootstrap={bootstrap} />
      <article className="markdown-prose">
        <ReactMarkdown
          remarkPlugins={[remarkGfm]}
          rehypePlugins={[rehypeSanitize]}
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
          {bootstrap.content}
        </ReactMarkdown>
      </article>
    </main>
  );
}
