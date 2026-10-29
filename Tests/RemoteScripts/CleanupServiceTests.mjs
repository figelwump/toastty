import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("cleanup service integration scenarios", { timeout: 120_000 }, () => {
  const suite = fileURLToPath(new URL("./CleanupServiceTests.py", import.meta.url));
  const result = spawnSync("python3", ["-B", suite, "-v"], {
    encoding: "utf8",
    timeout: 110_000,
    env: { PATH: process.env.PATH, PYTHONDONTWRITEBYTECODE: "1" },
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});
