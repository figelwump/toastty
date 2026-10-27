import assert from "node:assert/strict";
import test from "node:test";
import { resolve } from "node:path";
import vm from "node:vm";
import { buildSync } from "esbuild";

// Drive the bundled page through its real receiver and event bridge. The
// DOM shell models child replacement and focus; remote UI checks cover
// layout and native WKWebView focus ownership.
const source = buildSync({ entryPoints: [resolve(import.meta.dirname, "../src/dashboard.ts")], bundle: true, format: "iife", platform: "browser", write: false, logLevel: "silent" }).outputFiles[0].text;

function page(pathname = "/tasks") {
  const events = [];
  const handlers = new Map();
  const windowHandlers = new Map();
  const elements = new Map();
  function element(id, owner = null) {
    let html = "";
    const node = {
      id, owner, textContent: "", className: "", focusCount: 0, classList: { toggle() {} }, scrollIntoView() {},
      contains(child) { return child === this || child?.owner === this; },
      focus(options) {
        this.focusCount++;
        this.focusOptions = options;
        document.activeElement = this;
        for (const handler of handlers.get("focusin") ?? []) handler({ target: this });
      },
      get innerHTML() { return html; },
      set innerHTML(value) {
        html = value;
        for (const [childID, child] of elements) if (child.owner === this) elements.delete(childID);
        if (document.activeElement?.owner === this) document.activeElement = null;
        for (const match of value.matchAll(/\sid="([^"]+)"/g)) element(match[1], this);
      },
    };
    elements.set(id, node);
    return node;
  }
  const root = element("dashboard");
  element("dashboard-tabs");
  element("notice");
  const document = {
    body: { dataset: {} }, activeElement: null, title: "", focused: true, hasFocus() { return this.focused; }, getElementById: (id) => elements.get(id) ?? null,
    addEventListener(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
  };
  const window = {
    webkit: { messageHandlers: { toasttyCoordinatorChat: { postMessage(event) { events.push(JSON.parse(JSON.stringify(event))); } } } },
    addEventListener(name, handler) { windowHandlers.set(name, [...(windowHandlers.get(name) ?? []), handler]); },
  };
  vm.runInNewContext(source, { document, window, location: { pathname }, setTimeout() {}, TextEncoder });
  function dispatch(name, data = {}, key = "") {
    const target = { dataset: data, closest(selector) { return selector === "[data-act]" ? this : null; } };
    for (const handler of handlers.get(name) ?? []) handler({ target, key, preventDefault() {} });
  }
  return {
    events, document, receive: window.toasttyCoordinatorChat.receive,
    click: (data) => dispatch("click", data), key: (key) => dispatch("keydown", {}, key),
    pointer: () => dispatch("pointerdown"), html: () => root.innerHTML, focusCount: () => root.focusCount,
    focus: (id) => document.getElementById(id)?.focus(),
    show(persisted) { for (const handler of windowHandlers.get("pageshow") ?? []) handler({ persisted }); },
  };
}

function row(id, group, extra = {}) {
  return { id, taskID: id, title: id, project: "Project", projectID: "P", group, stageLabel: group, stageTone: "blue", status: "Working", activityAt: "2026-10-25T10:00:00Z", hasCard: true, primary: { id: "open", title: "Open", isDestructive: false }, confirm: null, menu: [[{ id: "openTaskSpace", title: "Open Task Space", isDestructive: false }]], ...extra };
}

function state() {
  return {
    coordinator: {}, items: [], projects: [{ id: "P", title: "Project" }], projectFilter: null,
    tasks: [row("A", "needsYou", { primary: { id: "action:merge", title: "Merge", isDestructive: false }, confirm: "Merge PR #9 now?" }), row("B", "running")],
    taskGroups: [{ id: "needsYou", title: "Needs you", total: 1 }, { id: "running", title: "Running", total: 1 }],
    focus: null, view: null, notice: null, today: { completed: [] },
  };
}

test("the dashboard preserves task confirmation, menu dispatch and keyboard opening", () => {
  const p = page();
  assert.deepEqual(p.events, [{ type: "ready" }]);
  p.receive(state());
  assert.equal(p.document.body.dataset.view, "tasks");
  p.click({ act: "task-primary", id: "A" });
  assert.match(p.html(), /Merge PR #9 now/);
  assert.equal(p.events.filter((event) => event.type === "taskAction").length, 0);
  p.key("Escape");
  assert.ok(!p.html().includes("task-confirm-A"));
  p.click({ act: "task-primary", id: "A" });
  p.click({ act: "task-action", id: "A", action: "action:merge" });
  assert.deepEqual(p.events.filter((event) => event.type === "taskAction").at(-1), { type: "taskAction", rowID: "A", actionID: "action:merge" });
  p.click({ act: "task-menu", id: "A" });
  assert.match(p.html(), /id="task-action-A-openTaskSpace"/);
  p.click({ act: "task-action", id: "A", action: "openTaskSpace" });
  assert.deepEqual(p.events.filter((event) => event.type === "taskAction").at(-1), { type: "taskAction", rowID: "A", actionID: "openTaskSpace" });
  p.key("ArrowDown");
  p.key("Enter");
  assert.deepEqual(p.events.filter((event) => event.type === "taskAction").at(-1), { type: "taskAction", rowID: "B", actionID: "open" });
});

test("Today opens rows through the existing action and tab events; chat requests leave it mounted", () => {
  const p = page("/today");
  p.receive(state());
  assert.equal(p.document.body.dataset.view, "today");
  p.pointer();
  assert.deepEqual(p.events.at(-1), { type: "activate", view: "today", selected: null });
  p.click({ act: "today-open", id: "A" });
  assert.deepEqual(p.events.filter((event) => event.type === "taskAction").at(-1), { type: "taskAction", rowID: "A", actionID: "open" });
  p.receive({ ...state(), view: { view: "chat", token: 1 } });
  assert.equal(p.document.body.dataset.view, "today");
  p.click({ act: "today-group", group: "running" });
  assert.equal(p.document.body.dataset.view, "tasks");
  assert.deepEqual(p.events.filter((event) => event.type === "showView").at(-1), { type: "showView", view: "tasks" });
  assert.equal(p.events.filter((event) => event.type === "rendered").at(-1).selected, "B");
});

test("live shared-filter updates keep a valid empty project empty", () => {
  const p = page();
  p.receive(state());
  p.receive({ ...state(), projects: [...state().projects, { id: "empty", title: "Empty" }], projectFilter: "empty" });
  assert.equal(p.document.body.dataset.projectFilter, "empty");
  assert.match(p.html(), /No tasks in this project/);
  assert.equal(p.events.filter((event) => event.type === "rendered").at(-1).selected, null);
  // Rendering a passive update must not change which page owns commands.
  assert.equal(p.events.filter((event) => event.type === "activate").length, 0);
});

test("only new programmatic task-page navigation focuses an already mounted dashboard", () => {
  const p = page();
  const request = { view: "tasks", token: 1 };
  p.receive({ ...state(), view: request });
  assert.equal(p.focusCount(), 0);
  p.receive({ ...state(), view: { ...request, token: 2 } });
  assert.equal(p.focusCount(), 1);
  p.receive({ ...state(), view: { ...request, token: 2 } });
  p.receive({ ...state(), view: { view: "chat", token: 3 } });
  assert.equal(p.focusCount(), 1);
});

test("background focus notifications do not claim the active command surface", () => {
  const p = page();
  p.receive(state());
  p.document.focused = false;
  p.pointer();
  assert.equal(p.events.filter((event) => event.type === "activate").length, 0);
});

test("live updates preserve the focused task control and tab, with a stable fallback when a control disappears", () => {
  const p = page();
  p.receive(state());
  p.focus("task-primary-A");
  const oldControl = p.document.activeElement;
  p.receive(state());
  assert.equal(p.document.activeElement.id, "task-primary-A");
  assert.notEqual(p.document.activeElement, oldControl);
  assert.equal(p.document.activeElement.focusOptions.preventScroll, true);
  p.focus("dashboard-tab-tasks");
  p.receive(state());
  assert.equal(p.document.activeElement.id, "dashboard-tab-tasks");
  p.focus("task-primary-A");
  p.receive({ ...state(), tasks: [row("B", "running")] });
  assert.equal(p.document.activeElement.id, "dashboard");
  assert.equal(p.document.activeElement.focusOptions.preventScroll, true);
});

test("a live update in a background page does not restore or activate its retained focused control", () => {
  const p = page();
  p.receive(state());
  p.focus("task-primary-A");
  p.document.focused = false;
  const activationCount = p.events.filter((event) => event.type === "activate").length;
  p.receive(state());
  assert.equal(p.document.activeElement, null);
  assert.equal(p.document.getElementById("task-primary-A").focusCount, 0);
  assert.equal(p.focusCount(), 0);
  assert.equal(p.events.filter((event) => event.type === "activate").length, activationCount);
});

test("shared project changes close menus and confirmations even when the same row remains visible", () => {
  const p = page();
  p.receive(state());
  p.click({ act: "task-primary", id: "A" });
  assert.match(p.html(), /task-confirm-A/);
  p.receive({ ...state(), projectFilter: "P" });
  assert.ok(!p.html().includes("task-confirm-A"));
  p.click({ act: "task-menu", id: "A" });
  p.receive({ ...state(), projectFilter: "P" });
  assert.match(p.html(), /id="task-action-A-openTaskSpace"/);
  p.receive(state());
  assert.ok(!p.html().includes('role="menu"'));
});

test("native page changes close confirmations and menus before returning to All tasks", () => {
  const p = page();
  p.receive(state());
  p.click({ act: "task-primary", id: "A" });
  p.receive({ ...state(), view: { view: "today", token: 1 } });
  p.receive({ ...state(), view: { view: "tasks", token: 2 } });
  assert.ok(!p.html().includes("task-confirm-A"));
  p.click({ act: "task-menu", id: "A" });
  p.receive({ ...state(), view: { view: "chat", token: 3 } });
  assert.ok(!p.html().includes('role="menu"'));
});

test("a page restored from the back-forward cache renews its ready handshake", () => {
  const p = page("/today");
  p.receive(state());
  p.show(false);
  assert.equal(p.events.filter((event) => event.type === "ready").length, 1);
  p.show(true);
  assert.equal(p.events.filter((event) => event.type === "ready").length, 2);
  assert.deepEqual(p.events.at(-1), { type: "ready" });
  assert.equal(p.document.body.dataset.view, "today");
});
