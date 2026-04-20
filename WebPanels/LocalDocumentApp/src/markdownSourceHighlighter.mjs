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

/** @type {Promise<unknown> | undefined} */
let highlighterPromise;

function createMarkdownHighlighter() {
  if (typeof window === "undefined") {
    return createStarryNight(MARKDOWN_GRAMMARS);
  }

  return createStarryNight(MARKDOWN_GRAMMARS, {
    getOnigurumaUrlFetch() {
      return new URL("./onig.wasm", window.location.href);
    }
  });
}

function loadMarkdownHighlighter() {
  if (!highlighterPromise) {
    highlighterPromise = createMarkdownHighlighter();
  }

  return highlighterPromise;
}

export async function highlightMarkdownSourceToHtml(content) {
  const starryNight = await loadMarkdownHighlighter();
  const scope = starryNight.flagToScope("markdown");

  if (!scope) {
    return null;
  }

  return toHtml(starryNight.highlight(String(content), scope));
}
