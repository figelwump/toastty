import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const checkedInOutputDir = resolve(
  packageRoot,
  "../../Sources/App/Resources/WebPanels/scratchpad-panel"
);
const generatedOutputDir = mkdtempSync(join(tmpdir(), "toastty-scratchpad-panel-"));
const expectedFiles = [
  "index.html",
  "scratchpad-panel.css",
  "scratchpad-panel.js"
];

try {
  const build = spawnSync(process.execPath, [resolve(packageRoot, "scripts/build.mjs")], {
    cwd: packageRoot,
    env: {
      ...process.env,
      TOASTTY_SCRATCHPAD_PANEL_OUTPUT_DIR: generatedOutputDir
    },
    encoding: "utf8"
  });

  if (build.status !== 0) {
    if (build.stdout) {
      process.stdout.write(build.stdout);
    }
    if (build.stderr) {
      process.stderr.write(build.stderr);
    }
    process.exit(build.status ?? 1);
  }

  const mismatchedFiles = expectedFiles.filter((file) => {
    const checkedIn = readFileSync(join(checkedInOutputDir, file));
    const generated = readFileSync(join(generatedOutputDir, file));
    return checkedIn.equals(generated) === false;
  });

  if (mismatchedFiles.length > 0) {
    process.stderr.write(
      [
        "Checked-in Scratchpad panel assets are out of sync.",
        "Run `npm run build` in WebPanels/ScratchpadApp and commit the updated bundle.",
        `Mismatched files: ${mismatchedFiles.join(", ")}`
      ].join("\n") + "\n"
    );
    process.exit(1);
  }
} finally {
  rmSync(generatedOutputDir, { recursive: true, force: true });
}
