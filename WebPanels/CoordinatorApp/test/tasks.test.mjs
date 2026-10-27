import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildSync } from "esbuild";

// Bundle the real module once, so the tests run what the page runs.
const directory = mkdtempSync(join(tmpdir(), "toastty-coordinator-tasks-"));
const outfile = join(directory, "tasks.mjs");
buildSync({
  entryPoints: [resolve(import.meta.dirname, "../src/tasks.ts")],
  bundle: true,
  format: "esm",
  platform: "neutral",
  outfile,
  logLevel: "silent",
});
const tasks = await import(outfile);
rmSync(directory, { recursive: true, force: true });

const groups = [
  { id: "needsYou", title: "Needs you", total: 0 }, { id: "running", title: "Running", total: 0 },
  { id: "toShip", title: "To ship", total: 0 }, { id: "done", title: "Done", total: 0 }, { id: "archived", title: "Archived", total: 0 },
];

function row(id, group, overrides = {}) {
  return {
    id, taskID: id, title: `Task ${id}`, project: "lumen", group, stageLabel: group, stageTone: "plain",
    status: "running", activityAt: "2026-10-25T07:00:00Z", hasCard: true,
    primary: { id: "open", title: "Open", isDestructive: false }, confirm: null,
    menu: [[{ id: "openTaskSpace", title: "Open Task Space", isDestructive: false }]],
    ...overrides,
  };
}

function state(rows) {
  return { coordinator: {}, items: [], focus: null, notice: null, taskGroups: groups, tasks: rows };
}

test("Done and Archived start closed; a click opens them, and the arrow keys skip closed groups", () => {
  const ui = tasks.newTasksUIState();
  const s = state([row("A", "needsYou"), row("B", "done"), row("C", "running")]);
  assert.equal(tasks.isGroupOpen("running", ui), true);
  assert.equal(tasks.isGroupOpen("done", ui), false);
  // Group order, not row order: Needs you, then Running.
  assert.deepEqual(tasks.navigableRows(s, ui).map((r) => r.id), ["A", "C"]);
  ui.toggledGroups.add("done");
  assert.equal(tasks.isGroupOpen("done", ui), true);
  assert.deepEqual(tasks.navigableRows(s, ui).map((r) => r.id), ["A", "C", "B"]);
  ui.toggledGroups.add("running");
  assert.deepEqual(tasks.navigableRows(s, ui).map((r) => r.id), ["A", "B"]);
});

test("the selection moves within bounds, and starts at the first row", () => {
  const ui = tasks.newTasksUIState();
  const s = state([row("A", "needsYou"), row("B", "running"), row("C", "running")]);
  assert.equal(tasks.moveSelection(s, ui, 1), "A");
  ui.selected = "A";
  assert.equal(tasks.moveSelection(s, ui, -1), "A");
  ui.selected = "B";
  assert.equal(tasks.moveSelection(s, ui, 1), "C");
  ui.selected = "C";
  assert.equal(tasks.moveSelection(s, ui, 1), "C");
  // A row that went away starts the selection over.
  ui.selected = "gone";
  assert.equal(tasks.moveSelection(s, ui, 1), "A");
  assert.equal(tasks.moveSelection(state([]), ui, 1), null);
});

test("the project filter narrows the rows, and a project that has no tasks now shows all", () => {
  const ui = tasks.newTasksUIState();
  const s = state([row("A", "running"), row("B", "running", { project: "infra" }), row("C", "running", { project: null })]);
  ui.project = "infra";
  assert.deepEqual(tasks.navigableRows(s, ui).map((r) => r.id), ["B"]);
  assert.match(tasks.renderTasks(s, ui, new Date()), />infra<\/span>/);
  ui.project = "gone";
  assert.deepEqual(tasks.navigableRows(s, ui).map((r) => r.id), ["A", "B", "C"]);
});

test("ages read as the sidebar's", () => {
  const now = new Date("2026-10-25T10:00:00Z");
  assert.equal(tasks.taskAge("2026-10-25T09:59:30Z", now), "now");
  assert.equal(tasks.taskAge("2026-10-25T09:55:00Z", now), "5m");
  assert.equal(tasks.taskAge("2026-10-25T07:00:00Z", now), "3h");
  assert.equal(tasks.taskAge("2026-10-23T10:00:00Z", now), "2d");
  assert.equal(tasks.taskAge("2026-10-25T11:00:00Z", now), "now");
});

test("rows escape what agents wrote, and a confirm question replaces the buttons", () => {
  const ui = tasks.newTasksUIState();
  const merge = row("A", "needsYou", {
    title: "<img src=x onerror=alert(1)>",
    primary: { id: "action:merge", title: "Merge", isDestructive: false },
    confirm: "Merge PR #9? Merge merges right away (merge = \"direct\").",
    menu: [[{ id: "openPullRequest", title: "Open PR #9", isDestructive: false }], [{ id: "delete", title: "Delete Task", isDestructive: true }]],
  });
  let html = tasks.renderTaskRow(merge, ui, new Date());
  assert.ok(!html.includes("<img"));
  assert.match(html, /id="task-primary-A"/);
  assert.match(html, /id="task-menu-A"/);
  assert.ok(!html.includes('role="menu"'));

  ui.menuOpen = "A";
  html = tasks.renderTaskRow(merge, ui, new Date());
  assert.match(html, /id="task-action-A-openPullRequest"/);
  assert.match(html, /class="destructive"[^>]*data-action="delete"/);
  assert.match(html, /<hr>/);

  ui.menuOpen = null;
  ui.confirming = { rowID: "A", actionID: "action:merge" };
  html = tasks.renderTaskRow(merge, ui, new Date());
  assert.ok(!html.includes('id="task-primary-A"'));
  assert.match(html, /merge = &quot;direct&quot;/);
  assert.match(html, /id="task-confirm-A"[^>]*data-action="action:merge"/);

  // A refresh that changes the row's action closes the question: it never
  // becomes a button for the new action.
  const cleanUp = { ...merge, primary: { id: "action:cleanUp", title: "Clean Up", isDestructive: false }, confirm: null };
  html = tasks.renderTaskRow(cleanUp, ui, new Date());
  assert.ok(!html.includes("task-confirm-A"));
  tasks.normalize(state([cleanUp]), ui);
  assert.equal(ui.confirming, null);
});

test("the selection stays on a row the user can see", () => {
  const ui = tasks.newTasksUIState();
  const s = state([row("A", "running"), row("B", "running", { project: "infra" }), row("C", "done")]);
  ui.selected = "A";
  ui.menuOpen = "A";
  ui.project = "infra";
  tasks.normalize(s, ui);
  assert.equal(ui.selected, "B");
  assert.equal(ui.menuOpen, null);
  // A row in a closed group gives way too.
  ui.project = null;
  ui.selected = "C";
  tasks.normalize(s, ui);
  assert.equal(ui.selected, "A");
  tasks.normalize(state([]), ui);
  assert.equal(ui.selected, null);
});

test("tasks without projects remain visible when all projects are selected", () => {
  const unassigned = row("B", "running");
  delete unassigned.project;
  const s = state([row("A", "running"), unassigned]);
  assert.deepEqual(tasks.navigableRows(s, tasks.newTasksUIState()).map((row) => row.id), ["A", "B"]);
  assert.ok(!tasks.renderTasks(s, tasks.newTasksUIState(), new Date()).includes("task-filter"));
});

test("stable project IDs keep projects with the same title apart and keep an empty filter empty", () => {
  const ui = tasks.newTasksUIState();
  const s = state([
    row("A", "running", { project: "same", projectID: "/projects/a" }),
    row("B", "running", { project: "same", projectID: "/projects/b" }),
  ]);
  s.projects = [
    { id: "/projects/a", title: "same" }, { id: "/projects/b", title: "same" },
    { id: "/projects/empty", title: "Empty" },
  ];
  tasks.applyFilter(s, ui, { project: "/projects/b", group: "running" });
  assert.deepEqual(tasks.navigableRows(s, ui).map((row) => row.id), ["B"]);
  assert.equal(ui.selected, "B");
  tasks.applyFilter(s, ui, { project: "/projects/empty", group: "running" });
  tasks.normalize(s, ui);
  assert.deepEqual(tasks.navigableRows(s, ui), []);
  assert.equal(ui.selected, null);
  const html = tasks.renderTasks(s, ui, new Date());
  assert.match(html, /No tasks in this project/);
  assert.ok(!html.includes("task-row-A") && !html.includes("task-row-B"));
});

test("rows with IDs still filter by identity when the projects list is omitted", () => {
  const ui = tasks.newTasksUIState();
  const s = state([
    row("A", "running", { project: "same", projectID: "one" }),
    row("B", "running", { project: "same", projectID: "two" }),
    row("C", "running", { project: "same", projectID: "two" }),
  ]);
  ui.project = "two";
  assert.deepEqual(tasks.navigableRows(s, ui).map((row) => row.id), ["B", "C"]);
  const html = tasks.renderTasks(s, ui, new Date());
  assert.ok(!html.includes("task-row-A"));
  assert.match(html, />same<\/span>/);
});

test("a group the app cut short says how many there are", () => {
  const ui = tasks.newTasksUIState();
  ui.toggledGroups.add("done");
  const s = state([row("A", "done")]);
  s.taskGroups = groups.map((g) => g.id === "done" ? { ...g, total: 250 } : g);
  const html = tasks.renderTasks(s, ui, new Date());
  assert.match(html, /id="group-done"[^>]*>.*<span>250<\/span>/s);
  assert.match(html, /The newest 1 of 250/);
});

test("an empty list says how to start, and empty groups are left out", () => {
  const ui = tasks.newTasksUIState();
  assert.match(tasks.renderTasks(state([]), ui, new Date()), /No tasks yet/);
  const html = tasks.renderTasks(state([row("A", "archived")]), ui, new Date());
  assert.match(html, /id="group-archived" [^>]*aria-expanded="false"/);
  assert.ok(!html.includes('id="group-running"'));
  assert.ok(!html.includes('id="task-row-A"'));
});

test("a filter from the sidebar shows one project with its group open and its first row selected", () => {
  const ui = tasks.newTasksUIState();
  const s = state([
    row("A", "needsYou"),
    row("B", "done", { project: "docs" }),
    row("C", "done"),
    row("D", "done"),
  ]);
  ui.menuOpen = "A";
  tasks.applyFilter(s, ui, { project: "lumen", group: "done" });
  assert.equal(ui.project, "lumen");
  assert.equal(tasks.isGroupOpen("done", ui), true);
  // The docs task is hidden by the filter, so the first lumen row is chosen.
  assert.equal(ui.selected, "C");
  assert.equal(ui.menuOpen, null);
  // The selection survives the next render's normalize.
  tasks.normalize(s, ui);
  assert.equal(ui.selected, "C");

  // A group the user had closed opens again, and one already open stays open.
  ui.toggledGroups.add("running");
  tasks.applyFilter(s, ui, { project: null, group: "running" });
  assert.equal(tasks.isGroupOpen("running", ui), true);
  tasks.applyFilter(s, ui, { project: null, group: "done" });
  assert.equal(tasks.isGroupOpen("done", ui), true);
  assert.equal(ui.project, null);
  assert.equal(ui.selected, "B");

  // A project whose rows were not sent shows every project, but nothing of
  // another project is selected.
  tasks.applyFilter(s, ui, { project: "gone", group: "done" });
  assert.equal(ui.selected, null);
});
