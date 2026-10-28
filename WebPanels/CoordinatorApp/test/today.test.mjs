import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildSync } from "esbuild";

const directory = mkdtempSync(join(tmpdir(), "toastty-coordinator-today-"));
const outfile = join(directory, "today.mjs");
buildSync({ entryPoints: [resolve(import.meta.dirname, "../src/today.ts")], bundle: true, format: "esm", platform: "neutral", outfile, logLevel: "silent" });
const { renderToday } = await import(outfile);
rmSync(directory, { recursive: true, force: true });

function row(id, group, projectID = "one") {
  return { id, title: `Task ${id}`, project: "same", projectID, group, stageLabel: group, stageTone: "blue", status: "Working", activityAt: "2026-10-25T10:00:00Z" };
}

const state = {
  projects: [{ id: "one", title: "same" }, { id: "two", title: "same" }, { id: "empty", title: "Empty" }],
  tasks: [row("A", "needsYou"), row("B", "running"), row("C", "toShip"), row("D", "done"), row("E", "done"), row("F", "needsYou", "two"), row("G", "idle"), row("H", "idle", "two")],
  // D has new activity today but did not merge or release today. Only
  // native completion metadata makes E appear in the completion section.
  today: { completed: [{ rowID: "E", kind: "released", at: "2026-10-25T09:50:00Z" }] },
};
const now = new Date("2026-10-25T10:00:00Z");

test("Today shows filtered stats, Needs you, Running and actual completions, with empty Intake absent", () => {
  const html = renderToday({ ...state, projectFilter: "one" }, now);
  for (const id of ["needsYou", "running", "toShip"]) assert.match(html, new RegExp(`id="today-stat-${id}"[^>]*><span class="n">1<`));
  for (const id of ["A", "B", "G"]) assert.ok(html.includes(`id="today-row-${id}"`));
  assert.ok(html.includes('id="today-completed-row-E"'));
  for (const id of ["C", "D", "F", "H"]) assert.ok(!html.includes(`id="today-row-${id}"`));
  assert.ok(html.indexOf('id="today-running"') < html.indexOf('id="today-idle"'));
  assert.match(html, /id="today-idle"[^]*?<span>Idle<\/span><span>1<\/span>/);
  assert.match(html, /Merged or released today/);
  assert.match(html, /class="badge b-green">released/);
  assert.match(html, /data-act="today-open" data-id="E"/);
  assert.ok(!/Intake|intake/.test(html));
});

test("a valid empty project has zero stats and no other-project rows", () => {
  const html = renderToday({ ...state, projectFilter: "empty" }, now);
  for (const id of ["needsYou", "running", "toShip"]) assert.match(html, new RegExp(`id="today-stat-${id}"[^>]*><span class="n">0<`));
  assert.ok(!html.includes('id="today-row-'));
  assert.match(html, /Nothing needs you/);
  assert.match(html, /No tasks running/);
  assert.match(html, /No idle tasks/);
  assert.match(html, /Nothing merged or released today/);
});

test("Today escapes task and project text", () => {
  const html = renderToday({ ...state, tasks: [{ ...row("A", "running"), title: "<script>x</script>", project: "<img>" }] }, now);
  assert.ok(!html.includes("<script>") && !html.includes("<img>"));
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&lt;img&gt;/);
});

test("a task that needs cleanup and completed today has unique IDs with the same task action target", () => {
  const html = renderToday({
    ...state,
    tasks: [row("A", "needsYou")],
    today: { completed: [{ rowID: "A", kind: "merged", at: "2026-10-25T09:50:00Z" }] },
  }, now);
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of ["today-row-A", "today-completed-row-A"]) {
    assert.match(html, new RegExp(`id="${id}" data-act="today-open" data-id="A" data-row-id="A"`));
  }
});
