import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildSync } from 'esbuild';
const dir = mkdtempSync(join(tmpdir(), 'coordinator-marks-'));
buildSync({ entryPoints: [resolve(import.meta.dirname, '../src/marks.ts')], bundle: true, format: 'esm', platform: 'neutral', outfile: join(dir, 'marks.mjs'), logLevel: 'silent' });
const { marksMessage, validMarks } = await import(join(dir, 'marks.mjs'));
rmSync(dir, { recursive: true, force: true });
const mark = { shot: 'after-390', note: 'Move this up', x: .25, y: .5 };
test('marks keep screenshot names and order in one review message', () => {
  assert.equal(marksMessage([mark, { ...mark, shot: 'before-390', note: 'Keep the\n old label' }]), '2 marks on the screenshots:\n1. Move this up [after-390]\n2. Keep the old label [before-390]');
  assert.equal(marksMessage([mark]), '1 mark on the screenshots:\n1. Move this up [after-390]');
});
test('send requires notes, available screenshots, bounded pins and message size', () => {
  assert.equal(validMarks([], ['after-390']), false);
  assert.equal(validMarks([mark], ['after-390']), true);
  for (const change of [{ note: '  ' }, { note: '\u001b[201~' }, { x: NaN }, { y: -1 }, { x: 1.1 }, { shot: 'missing' }, { note: 'a'.repeat(17000) }]) {
    assert.equal(validMarks([{ ...mark, ...change }], ['after-390']), false);
  }
  assert.equal(validMarks(Array(101).fill(mark), ['after-390']), false);
});
