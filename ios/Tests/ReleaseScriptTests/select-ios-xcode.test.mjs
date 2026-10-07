import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

const root = new URL('../../../', import.meta.url).pathname;
const script = path.join(root, 'scripts/ci/select-ios-xcode.sh');
for (const valid of [true, false, 'unavailable']) {
  test(`Xcode selection ${valid === true ? 'exports the exact pinned build' : `rejects ${valid === false ? 'a different build' : 'an unavailable app'}`}`, () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'toastty-xcode-pin-'));
    try {
      writeFileSync(path.join(dir, 'xcodebuild'), `#!/bin/sh
${valid === 'unavailable' ? 'exit 1' : ''}
[ "$DEVELOPER_DIR" = /Applications/Xcode_26.6.app/Contents/Developer ] || exit 2
printf 'Xcode 26.6\\nBuild version ${valid ? '17F113' : 'different'}\\n'
`, { mode: 0o755 });
      const output = path.join(dir, 'output');
      const result = spawnSync('bash', [script], { cwd: root, encoding: 'utf8',
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, GITHUB_ENV: output } });
      if (valid === true) {
        assert.equal(result.status, 0, result.stderr);
        assert.equal(readFileSync(output, 'utf8'), 'DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer\n');
      } else {
        assert.notEqual(result.status, 0);
        assert.equal(existsSync(output), false);
        if (valid === false) assert.match(result.stderr, /Xcode does not match/);
        else assert.match(result.stderr, /Pinned Xcode 26.6 is unavailable/);
      }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
