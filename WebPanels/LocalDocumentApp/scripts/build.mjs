import { mkdirSync, copyFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";

const packageRoot = resolve(import.meta.dirname, "..");
const outputDir = resolve(packageRoot, "../../Sources/App/Resources/WebPanels/local-document-panel");

const require = createRequire(import.meta.url);
const reactRoot = dirname(require.resolve("react/package.json", { paths: [packageRoot] }));
const reactDomRoot = dirname(require.resolve("react-dom/package.json", { paths: [packageRoot] }));

mkdirSync(outputDir, { recursive: true });

copyFileSync(join(packageRoot, "index.html"), join(outputDir, "index.html"));
copyFileSync(join(packageRoot, "src", "styles.css"), join(outputDir, "local-document-panel.css"));

await build({
  entryPoints: [join(packageRoot, "src", "main.tsx")],
  bundle: true,
  format: "iife",
  jsx: "automatic",
  platform: "browser",
  target: ["safari17"],
  outfile: join(outputDir, "local-document-panel.js"),
  sourcemap: false,
  minify: true,
  alias: {
    react: join(reactRoot, "index.js"),
    "react/jsx-runtime": join(reactRoot, "jsx-runtime.js"),
    "react/jsx-dev-runtime": join(reactRoot, "jsx-dev-runtime.js"),
    "react-dom": join(reactDomRoot, "index.js"),
    "react-dom/client": join(reactDomRoot, "client.js")
  },
  define: {
    "process.env.NODE_ENV": "\"production\""
  },
  logLevel: "info"
});
