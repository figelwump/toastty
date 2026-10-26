import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildSync } from 'esbuild';
const dir = mkdtempSync(join(tmpdir(), 'coordinator-composer-'));
buildSync({ entryPoints: [resolve(import.meta.dirname, '../src/composer.ts')], bundle: true, format: 'esm', platform: 'neutral', outfile: join(dir, 'composer.mjs'), logLevel: 'silent' });
const { addressFor, addressMatches, pickedAddress } = await import(join(dir, 'composer.mjs'));
rmSync(dir, { recursive: true, force: true });
const task = { kind: 'task', id: 't1', token: 'fix-totals', title: 'Fix rounding totals', version: 2 };
const project = { kind: 'project', id: '/repos/billing', token: 'billing', title: 'Billing app', version: null };
const choices = [task, project];
test('only a leading complete unique known token addresses a message', () => {
  assert.equal(addressFor('@fix-total hello', choices, null), null);
  assert.equal(addressFor('ask @fix-totals hello', choices, null), null);
  assert.equal(addressFor('@fix-totals! hello', choices, null), null);
  assert.equal(addressFor('@Fix-totals hello', choices, null), null);
  assert.equal(addressFor('@fix-totals', choices, null), null);
  assert.deepEqual(addressFor('@fix-totals hello\nthere', choices, null), { address: task, text: 'hello\nthere' });
  assert.deepEqual(addressFor('@billing ship it', choices, null), { address: project, text: 'ship it' });
});
test('ambiguous tokens require a current explicit pick', () => {
  const duplicate = { ...project, token: task.token };
  assert.equal(addressFor('@fix-totals hello', [task, duplicate], null), null);
  const pick = pickedAddress(task);
  assert.equal(addressFor('@fix-totals hello', [task, duplicate], pick).address.kind, 'task');
  assert.equal(addressFor('@fix-totals hello', [duplicate], pick), null);
  assert.equal(addressFor('@billing hello', choices, pick).address.kind, 'project');
});
test('picker searches slug and title, only for the leading address', () => {
  assert.deepEqual(addressMatches('@round', choices), [task]);
  assert.deepEqual(addressMatches('@bill', choices), [project]);
  assert.deepEqual(addressMatches('@', choices), choices);
  assert.deepEqual(addressMatches('hi @bill', choices), []);
  assert.deepEqual(addressMatches('@billing hello', choices), []);
});
