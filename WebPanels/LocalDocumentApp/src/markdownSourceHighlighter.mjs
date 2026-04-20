import {createStarryNight} from "@wooorm/starry-night";
import sourceCss from "@wooorm/starry-night/source.css";
import sourceIni from "@wooorm/starry-night/source.ini";
import sourceJs from "@wooorm/starry-night/source.js";
import sourceJson from "@wooorm/starry-night/source.json";
import sourcePython from "@wooorm/starry-night/source.python";
import sourceShell from "@wooorm/starry-night/source.shell";
import sourceTs from "@wooorm/starry-night/source.ts";
import sourceToml from "@wooorm/starry-night/source.toml";
import sourceYaml from "@wooorm/starry-night/source.yaml";
import textHtmlBasic from "@wooorm/starry-night/text.html.basic";
import textMd from "@wooorm/starry-night/text.md";
import textXml from "@wooorm/starry-night/text.xml";
import {toHtml} from "hast-util-to-html";

// Markdown itself plus the code-fence languages we expect most often in local docs.
const MARKDOWN_GRAMMARS = [
  textMd,
  sourceCss,
  sourceIni,
  sourceJs,
  sourceJson,
  sourcePython,
  sourceShell,
  sourceToml,
  sourceTs,
  sourceYaml,
  textHtmlBasic,
  textXml
];

// WKWebView can load the panel from file URLs but still reject fetches for sibling
// local assets. Embed the WASM in the browser bundle so the markdown path does not
// depend on a file-URL fetch succeeding at runtime.
const EMBEDDED_ONIG_WASM_DATA_URL =
  typeof __TOASTTY_ONIG_WASM_DATA_URL__ === "string"
    ? __TOASTTY_ONIG_WASM_DATA_URL__
    : null;

/** @type {Promise<unknown> | undefined} */
let highlighterPromise;
let didWarnMissingEmbeddedOnigurumaData = false;

export function resolveBrowserOnigurumaUrl(
  locationHref,
  inlineDataUrl = EMBEDDED_ONIG_WASM_DATA_URL
) {
  if (typeof inlineDataUrl === "string" && inlineDataUrl.length > 0) {
    return new URL(inlineDataUrl);
  }

  if (
    didWarnMissingEmbeddedOnigurumaData === false &&
    typeof console !== "undefined" &&
    typeof console.warn === "function"
  ) {
    didWarnMissingEmbeddedOnigurumaData = true;
    console.warn(
      "[ToasttyLocalDocumentPanel] Falling back to file-based onig.wasm loading because the embedded browser WASM URL is unavailable."
    );
  }

  return new URL("./onig.wasm", locationHref);
}

function createMarkdownHighlighter() {
  if (typeof window === "undefined") {
    return createStarryNight(MARKDOWN_GRAMMARS);
  }

  return createStarryNight(MARKDOWN_GRAMMARS, {
    getOnigurumaUrlFetch() {
      return resolveBrowserOnigurumaUrl(window.location.href);
    }
  });
}

function loadMarkdownHighlighter() {
  if (!highlighterPromise) {
    highlighterPromise = createMarkdownHighlighter();
  }

  return highlighterPromise;
}

function classList(node) {
  const className = node?.properties?.className;
  if (Array.isArray(className)) {
    return className;
  }

  return typeof className === "string" ? [className] : [];
}

function hasClass(node, className) {
  return node?.type === "element" && classList(node).includes(className);
}

function textValue(node) {
  if (node?.type === "text") {
    return node.value;
  }

  if (node?.type !== "element" || !Array.isArray(node.children) || node.children.length !== 1) {
    return null;
  }

  return node.children[0]?.type === "text" ? node.children[0].value : null;
}

function createSpan(className, valueOrChildren) {
  return {
    type: "element",
    tagName: "span",
    properties: { className: [className] },
    children: Array.isArray(valueOrChildren)
      ? valueOrChildren
      : [{ type: "text", value: valueOrChildren }]
  };
}

function isLineBoundary(children, index) {
  if (index === 0) {
    return true;
  }

  const previous = children[index - 1];
  return previous?.type === "text" && previous.value.includes("\n");
}

function findClosingMarker(children, startIndex, marker) {
  for (let index = startIndex + 1; index < children.length; index += 1) {
    const candidate = children[index];
    if (candidate?.type === "text" && candidate.value.includes("\n")) {
      return -1;
    }
    if (hasClass(candidate, "pl-s") && textValue(candidate) === marker) {
      return index;
    }
  }

  return -1;
}

function normalizeMarkdownChildren(children) {
  const normalized = [];

  for (let index = 0; index < children.length; index += 1) {
    const current = children[index];
    const currentText = textValue(current);
    const next = children[index + 1];
    const nextText = textValue(next);

    if (
      isLineBoundary(children, index) &&
      hasClass(current, "pl-s") &&
      /^\d+$/.test(currentText ?? "") &&
      hasClass(next, "pl-v") &&
      nextText === "."
    ) {
      normalized.push(createSpan("pl-ml", `${currentText}.`));
      index += 1;
      continue;
    }

    if (
      isLineBoundary(children, index) &&
      hasClass(current, "pl-v") &&
      /^[-+*]$/.test(currentText ?? "")
    ) {
      normalized.push(createSpan("pl-ml", currentText));
      continue;
    }

    if (
      hasClass(current, "pl-s") &&
      (currentText === "**" || currentText === "__" || currentText === "*" || currentText === "_")
    ) {
      const closingIndex = findClosingMarker(children, index, currentText);
      if (closingIndex > index + 1) {
        const emphasisClass = currentText.length === 2 ? "pl-mb" : "pl-mi";
        normalized.push(current);
        normalized.push(
          createSpan(emphasisClass, children.slice(index + 1, closingIndex))
        );
        normalized.push(children[closingIndex]);
        index = closingIndex;
        continue;
      }
    }

    normalized.push(current);
  }

  return normalized;
}

function normalizeMarkdownTree(node) {
  if (!node || !Array.isArray(node.children)) {
    return node;
  }

  node.children = normalizeMarkdownChildren(
    node.children.map((child) => normalizeMarkdownTree(child))
  );
  return node;
}

export async function highlightMarkdownSourceToHtml(content) {
  const starryNight = await loadMarkdownHighlighter();
  const scope = starryNight.flagToScope("markdown");

  if (!scope) {
    return null;
  }

  return toHtml(normalizeMarkdownTree(starryNight.highlight(String(content), scope)));
}
