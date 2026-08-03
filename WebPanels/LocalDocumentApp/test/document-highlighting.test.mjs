import assert from "node:assert/strict";
import test from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { outputFiles } = await build({
  stdin: {
    contents: `
      export {
        highlightedCodeHTML,
        highlightStatusMessage
      } from "./src/DocumentHighlighting.ts";
    `,
    resolveDir: packageRoot,
    sourcefile: "document-highlighting-test-entry.mjs"
  },
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
  logLevel: "silent"
});

const {
  highlightedCodeHTML,
  highlightStatusMessage
} = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].contents).toString("base64")}`);

test("plain-code highlighting honors syntax metadata and highlighting availability", () => {
  assert.equal(highlightedCodeHTML("yaml", "enabled: true", false), null);
  assert.equal(highlightedCodeHTML(null, "enabled: true", true), null);
  assert.match(
    highlightedCodeHTML("yaml", "enabled: true", true),
    /hljs-attr/
  );
});

test("highlight status messages preserve format-specific guidance", () => {
  assert.equal(highlightStatusMessage("enabled", "YAML"), null);
  assert.equal(highlightStatusMessage("plainText", "Plain Text"), null);
  assert.equal(highlightStatusMessage("unavailable", "YAML"), null);
  assert.equal(
    highlightStatusMessage("disabledForLargeFile", "YAML"),
    "Syntax highlighting is disabled for large files. Editing remains available, but performance may still degrade on very large documents."
  );
  assert.equal(
    highlightStatusMessage("unsupportedFormat", "JSONC"),
    "Syntax highlighting is not available for JSONC files yet."
  );
  assert.equal(
    highlightStatusMessage("unsupportedFormat", "Unknown"),
    "Syntax highlighting is not available for this format yet."
  );
});
