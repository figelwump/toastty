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
import type {
  LocalDocumentHighlightState,
  LocalDocumentPanelBootstrap,
  LocalDocumentSyntaxLanguage
} from "./bootstrap";
import { highlightMarkdownSourceToHtml } from "./markdownSourceHighlighter.mjs";

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

export function highlightedCodeHTML(
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

export function highlightStatusMessage(
  highlightState: LocalDocumentHighlightState,
  formatLabel: string
): string | null {
  switch (highlightState) {
    case "enabled":
    case "plainText":
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

export function useDocumentHighlightHTML(
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
