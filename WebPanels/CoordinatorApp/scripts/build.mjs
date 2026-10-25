import { copyFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { build } from "esbuild";

const packageRoot = resolve(import.meta.dirname, "..");
const outputDir = process.env.TOASTTY_COORDINATOR_PANEL_OUTPUT_DIR
  ? resolve(packageRoot, process.env.TOASTTY_COORDINATOR_PANEL_OUTPUT_DIR)
  : resolve(packageRoot, "../../Sources/App/Resources/WebPanels/coordinator-panel");

mkdirSync(outputDir, { recursive: true });

copyFileSync(join(packageRoot, "index.html"), join(outputDir, "index.html"));
copyFileSync(join(packageRoot, "report.html"), join(outputDir, "report.html"));
copyFileSync(join(packageRoot, "src", "styles.css"), join(outputDir, "coordinator-panel.css"));

for (const [entry, output] of [["main.ts", "coordinator-panel.js"], ["report.ts", "coordinator-report.js"]]) {
  await build({
    entryPoints: [join(packageRoot, "src", entry)],
    bundle: true,
    format: "iife",
    platform: "browser",
    target: ["safari17"],
    outfile: join(outputDir, output),
    sourcemap: false,
    minify: true,
    logLevel: "info"
  });
}
