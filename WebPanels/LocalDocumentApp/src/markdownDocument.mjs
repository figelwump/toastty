import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkFrontmatter from "remark-frontmatter";
import remarkRehype from "remark-rehype";
import rehypeRaw from "rehype-raw";
import rehypeSlug from "rehype-slug";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import { createLowlight } from "lowlight";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { toHtml } from "hast-util-to-html";
import { visit } from "unist-util-visit";

// The formatted view renders Markdown the way GitHub renders a file: GFM,
// a sanitized subset of raw HTML, and `user-content-` prefixed ids. Every
// block element records the source lines it came from so line reveals and
// `#L42` links can find the block that holds a line.

export const SOURCE_START_ATTRIBUTE = "data-source-start";
export const SOURCE_END_ATTRIBUTE = "data-source-end";
export const SOURCE_LINE_SELECTOR = `[${SOURCE_START_ATTRIBUTE}]`;
const USER_CONTENT_ID_PREFIX = "user-content-";

const SOURCE_LINE_TAGS = new Set([
  "blockquote",
  "dd",
  "details",
  "div",
  "dt",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "li",
  "ol",
  "p",
  "pre",
  "summary",
  "table",
  "tr",
  "ul"
]);

// Images never load in this view. `picture` and `source` can name image URLs
// through `srcset`, so they are dropped; an `img` inside becomes a placeholder.
const IMAGE_SOURCE_TAGS = new Set(["picture", "source"]);

const sanitizeSchema = {
  ...defaultSchema,
  tagNames: (defaultSchema.tagNames ?? []).filter((tagName) => !IMAGE_SOURCE_TAGS.has(tagName)),
  // The app opens `file:` links the same way as absolute paths.
  protocols: {
    ...defaultSchema.protocols,
    href: [...(defaultSchema.protocols?.href ?? []), "file"]
  },
  attributes: {
    ...defaultSchema.attributes,
    "*": [
      ...(defaultSchema.attributes?.["*"] ?? []),
      "dataSourceStart",
      "dataSourceEnd"
    ]
  }
};

// `toml` is an alias of the INI grammar, as in DocumentHighlighting.ts.
const lowlight = createLowlight({
  bash,
  css,
  diff,
  go,
  ini,
  javascript,
  json,
  python,
  rust,
  sql,
  swift,
  typescript,
  xml,
  yaml
});

function remarkCaptureFrontmatter() {
  return (tree, file) => {
    const first = tree.children[0];
    if (first?.type !== "yaml" && first?.type !== "toml") {
      return;
    }

    file.data.toasttyFrontmatter = {
      language: first.type,
      value: first.value,
      start: first.position?.start.line ?? null,
      end: first.position?.end.line ?? null
    };
  };
}

function rehypeAnnotateSourceLines() {
  return (tree) => {
    visit(tree, "element", (node) => {
      if (!SOURCE_LINE_TAGS.has(node.tagName) || !node.position) {
        return;
      }

      node.properties.dataSourceStart = node.position.start.line;
      node.properties.dataSourceEnd = node.position.end.line;
    });
  };
}

function rehypeInsertFrontmatter() {
  return (tree, file) => {
    const frontmatter = file.data.toasttyFrontmatter;
    if (!frontmatter) {
      return;
    }

    const properties = { className: ["markdown-frontmatter"] };
    if (frontmatter.start !== null && frontmatter.end !== null) {
      properties.dataSourceStart = frontmatter.start;
      properties.dataSourceEnd = frontmatter.end;
    }

    tree.children.unshift({
      type: "element",
      tagName: "pre",
      properties,
      children: [{
        type: "element",
        tagName: "code",
        properties: { className: [`language-${frontmatter.language}`] },
        children: [{ type: "text", value: frontmatter.value }]
      }]
    });
  };
}

function classNames(node) {
  const className = node.properties?.className;
  if (Array.isArray(className)) {
    return className.map(String);
  }
  return typeof className === "string" ? className.split(/\s+/) : [];
}

function textContent(node) {
  if (node.type === "text") {
    return node.value;
  }
  return Array.isArray(node.children) ? node.children.map(textContent).join("") : "";
}

function rehypeHighlightCodeBlocks() {
  return (tree) => {
    visit(tree, "element", (node, _index, parent) => {
      if (node.tagName !== "code" || parent?.type !== "element" || parent.tagName !== "pre") {
        return;
      }

      const classes = classNames(node);
      const language = classes
        .find((className) => className.startsWith("language-"))
        ?.slice("language-".length)
        .toLowerCase();
      if (!language || !lowlight.registered(language)) {
        return;
      }

      const highlighted = lowlight.highlight(language, textContent(node));
      node.children = highlighted.children;
      node.properties.className = [...classes, "hljs"];
    });
  };
}

function fileNameFromSource(source) {
  const path = source.split(/[?#]/)[0];
  const name = path.split("/").filter(Boolean).pop() ?? "";
  try {
    return decodeURIComponent(name);
  } catch {
    return name;
  }
}

// Images do not load in this view. Each image becomes a labeled placeholder
// that keeps its alt text readable and searchable.
function rehypeImagePlaceholders() {
  return (tree) => {
    visit(tree, "element", (node, index, parent) => {
      if (node.tagName !== "img" || !parent || index === undefined) {
        return;
      }

      const source = typeof node.properties.src === "string" ? node.properties.src : "";
      const alt = typeof node.properties.alt === "string" ? node.properties.alt.trim() : "";
      const label = alt || fileNameFromSource(source) || "Image";
      const properties = {
        className: ["markdown-image-placeholder"],
        role: "img",
        ariaLabel: `Image: ${label}`
      };
      if (source) {
        properties.title = source;
      }

      parent.children[index] = {
        type: "element",
        tagName: "span",
        properties,
        children: [{ type: "text", value: label }]
      };
    });
  };
}

// The web view has no status bar, so a link's title shows where it goes.
// In-document links (footnotes, headings) need no such hint.
function rehypeLinkTitles() {
  return (tree) => {
    visit(tree, "element", (node) => {
      const href = node.properties.href;
      if (node.tagName !== "a" ||
          typeof href !== "string" ||
          href.startsWith("#") ||
          node.properties.title) {
        return;
      }
      node.properties.title = href;
    });
  };
}

function rehypeScrollableTables() {
  return (tree) => {
    visit(tree, "element", (node, index, parent) => {
      if (node.tagName !== "table" || !parent || index === undefined) {
        return;
      }

      parent.children[index] = {
        type: "element",
        tagName: "div",
        properties: { className: ["markdown-table-scroll"] },
        children: [node]
      };
      return index + 1;
    });
  };
}

const processor = unified()
  .use(remarkParse)
  .use(remarkFrontmatter, ["yaml", "toml"])
  .use(remarkCaptureFrontmatter)
  .use(remarkGfm)
  // Sanitize adds the `user-content-` prefix once; footnotes must not add another.
  .use(remarkRehype, { allowDangerousHtml: true, clobberPrefix: "" })
  .use(rehypeRaw)
  .use(rehypeAnnotateSourceLines)
  .use(rehypeSlug)
  .use(rehypeSanitize, sanitizeSchema)
  .use(rehypeInsertFrontmatter)
  .use(rehypeHighlightCodeBlocks)
  .use(rehypeImagePlaceholders)
  .use(rehypeLinkTitles)
  .use(rehypeScrollableTables);

export function renderMarkdownDocumentHtml(markdown) {
  const file = { value: String(markdown), data: {} };
  const tree = processor.runSync(processor.parse(file.value), file);
  return toHtml(tree);
}

/**
 * Chooses the block to reveal for a 1-based source line.
 * `blocks` are `{ start, end }` line ranges in document order.
 * The smallest block that contains the line wins; on a tie, the later
 * (more deeply nested) block wins. A line between blocks reveals the next
 * block, and a line after the last block reveals the last block.
 */
export function revealBlockIndexForLine(blocks, lineNumber) {
  let bestIndex = -1;
  let bestSpan = Number.POSITIVE_INFINITY;
  let nextIndex = -1;

  blocks.forEach((block, index) => {
    if (!Number.isFinite(block.start) || !Number.isFinite(block.end)) {
      return;
    }

    if (block.start <= lineNumber && lineNumber <= block.end) {
      const span = block.end - block.start;
      if (span <= bestSpan) {
        bestSpan = span;
        bestIndex = index;
      }
      return;
    }

    if (block.start > lineNumber && nextIndex === -1) {
      nextIndex = index;
    }
  });

  if (bestIndex !== -1) {
    return bestIndex;
  }
  if (nextIndex !== -1) {
    return nextIndex;
  }
  return blocks.length - 1;
}

function decodedFragment(fragment) {
  try {
    return decodeURIComponent(fragment);
  } catch {
    return fragment;
  }
}

/**
 * Decides what a click on a rendered link does.
 * - `fragment`: an in-document link. Try `elementIDs` in order; when none
 *   exists and the fragment is a GitHub line anchor (`#L42`, `#L42-L50`),
 *   reveal `lineNumber` instead.
 * - `open`: any other link. The app resolves it against the document.
 * - `none`: nothing to follow.
 */
export function classifyMarkdownLinkHref(href) {
  if (typeof href !== "string") {
    return { kind: "none" };
  }

  const trimmed = href.trim();
  if (trimmed.length === 0) {
    return { kind: "none" };
  }

  if (!trimmed.startsWith("#")) {
    return { kind: "open", href: trimmed };
  }

  const fragment = decodedFragment(trimmed.slice(1));
  if (fragment.length === 0) {
    return { kind: "none" };
  }

  const lineMatch = /^L(\d+)(?:-L?\d+)?$/.exec(fragment);
  const lineNumber = lineMatch ? Number.parseInt(lineMatch[1], 10) : null;
  // Sanitizing prefixes every id once, so a link to `#user-content-guide`
  // can mean the heading "User content guide" or an already prefixed id.
  const elementIDs = [`${USER_CONTENT_ID_PREFIX}${fragment}`, fragment];

  return {
    kind: "fragment",
    elementIDs,
    lineNumber: lineNumber !== null && lineNumber > 0 ? lineNumber : null
  };
}
