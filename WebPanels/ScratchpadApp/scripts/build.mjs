import { copyFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { build } from "esbuild";

const packageRoot = resolve(import.meta.dirname, "..");
const outputDir = process.env.TOASTTY_SCRATCHPAD_PANEL_OUTPUT_DIR
  ? resolve(packageRoot, process.env.TOASTTY_SCRATCHPAD_PANEL_OUTPUT_DIR)
  : resolve(packageRoot, "../../Sources/App/Resources/WebPanels/scratchpad-panel");

mkdirSync(outputDir, { recursive: true });

copyFileSync(join(packageRoot, "index.html"), join(outputDir, "index.html"));
copyFileSync(join(packageRoot, "src", "styles.css"), join(outputDir, "scratchpad-panel.css"));

await build({
  entryPoints: [join(packageRoot, "src", "main.ts")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari17"],
  outfile: join(outputDir, "scratchpad-panel.js"),
  sourcemap: false,
  minify: true,
  logLevel: "info"
});
