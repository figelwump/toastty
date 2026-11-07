// Pure helpers for the formatted markdown view. Kept framework-free so the
// link and frontmatter rules can be tested without a DOM.

const OPENABLE_SCHEMES = new Set(["http:", "https:", "mailto:", "file:"]);

function fileURLForPath(filePath) {
  return `file://${filePath.split("/").map(encodeURIComponent).join("/")}`;
}

/**
 * Decides what a click on a rendered markdown link does.
 * - `fragment`: scroll to a heading or footnote in this document.
 * - `open`: ask the native host to route the URL. Relative links resolve
 *   against the document's own file; the host decides whether it can open it.
 * - `inert`: render the link text without navigation.
 */
export function classifyMarkdownLink(href, filePath) {
  if (typeof href !== "string" || href.trim().length === 0) {
    return { kind: "inert" };
  }

  const trimmed = href.trim();
  if (trimmed.startsWith("#")) {
    const id = safeDecode(trimmed.slice(1));
    return id.length > 0 ? { kind: "fragment", id } : { kind: "inert" };
  }

  let absolute = null;
  try {
    absolute = new URL(trimmed);
  } catch {
    absolute = null;
  }

  if (absolute) {
    return OPENABLE_SCHEMES.has(absolute.protocol)
      ? { kind: "open", url: absolute.href }
      : { kind: "inert" };
  }

  if (!filePath || !filePath.startsWith("/")) {
    return { kind: "inert" };
  }

  try {
    const resolved = new URL(trimmed, fileURLForPath(filePath));
    resolved.hash = "";
    resolved.search = "";
    return { kind: "open", url: resolved.href };
  } catch {
    return { kind: "inert" };
  }
}

function safeDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/**
 * Returns `[key, value]` pairs for simple `key: value` lines in a leading
 * YAML frontmatter block, or an empty array when there is none. Nested and
 * multi-line values are skipped; the Source view still shows them.
 */
export function frontmatterEntries(content) {
  const normalized = content.replace(/\r\n?/g, "\n");
  const match = /^---\n([\s\S]*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)/.exec(normalized);
  if (!match) {
    return [];
  }

  const entries = [];
  for (const line of match[1].split("\n")) {
    const pair = /^([A-Za-z0-9_][\w.-]*)[ \t]*:[ \t]*(.*)$/.exec(line);
    if (!pair) {
      continue;
    }
    const value = unquote(pair[2].trim());
    if (value.length === 0 || value === "|" || value === ">") {
      continue;
    }
    entries.push([pair[1], value]);
  }
  return entries;
}

function unquote(value) {
  if (value.length >= 2 &&
      ((value.startsWith("\"") && value.endsWith("\"")) ||
       (value.startsWith("'") && value.endsWith("'")))) {
    return value.slice(1, -1);
  }
  return value;
}

/**
 * GitHub-style heading anchors: lowercase, punctuation dropped, spaces to
 * hyphens, and `-1`, `-2` suffixes for repeated headings in one document.
 */
export function createHeadingSlugger() {
  const counts = new Map();
  return (text) => {
    const base = text
      .toLowerCase()
      .trim()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s/g, "-");
    const seen = counts.get(base) ?? 0;
    counts.set(base, seen + 1);
    return seen === 0 ? base : `${base}-${seen}`;
  };
}
