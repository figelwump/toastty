import assert from "node:assert/strict";
import test from "node:test";
import { resolve } from "node:path";
import vm from "node:vm";
import { buildSync } from "esbuild";

const source = buildSync({ entryPoints: [resolve(import.meta.dirname, "../src/main.ts")], bundle: true, format: "iife", platform: "neutral", write: false, logLevel: "silent" }).outputFiles[0].text;

function page() {
  const events = [];
  const handlers = new Map();
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      dataset: {}, innerHTML: "", textContent: "", className: "", disabled: false, value: "", focusCount: 0, scrollCount: 0,
      scrollTop: 0, scrollHeight: 0, clientHeight: 0,
      classList: { toggle() {}, add() {}, remove() {}, contains() { return false; } },
      focus() { this.focusCount++; }, scrollIntoView() { this.scrollCount++; },
      querySelector(selector) { return id === "composer" && selector === "textarea" ? element("composer-input") : null; },
      addEventListener() {}, closest() { return null; },
    });
    return elements.get(id);
  }
  const document = {
    body: { dataset: {} }, activeElement: null, focused: true, hasFocus() { return this.focused; }, getElementById: element,
    addEventListener(name, handler) { handlers.set(name, [...(handlers.get(name) ?? []), handler]); },
  };
  const window = { webkit: { messageHandlers: { toasttyCoordinatorChat: { postMessage(event) { events.push(JSON.parse(JSON.stringify(event))); } } } } };
  vm.runInNewContext(source, { document, window, setTimeout() {}, TextEncoder });
  return {
    events, document, receive: window.toasttyCoordinatorChat.receive, element,
    focusEvent() { for (const handler of handlers.get("focusin") ?? []) handler({}); },
    click(data) {
      const target = { tagName: "BUTTON", dataset: data, closest(selector) { return selector === "[data-act]" ? this : null; } };
      for (const handler of handlers.get("click") ?? []) handler({ target });
    },
  };
}

function state() {
  return {
    coordinator: { title: "Coordinator", detail: "Codex", canSend: true, sendHint: null, hasTerminal: true },
    projects: [{ id: "one", title: "same" }, { id: "two", title: "same" }], projectFilter: "one",
    items: [{ type: "card", id: "other", kind: "task-started", task: { id: "T2", title: "Task 2", projectID: "two", project: "same", stageLabel: "running", stageTone: "blue", canReply: false }, packet: null }],
    notice: null, focus: null, view: null,
  };
}

test("a retained old focus cannot override a newer dashboard request or change the shared filter", () => {
  const p = page();
  p.receive({ ...state(), focus: { taskID: "T2", token: 1 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.view, "chat");
  assert.equal(p.document.body.dataset.projectFilter, "one");
  assert.equal(p.element("card-other").scrollCount, 0);
  assert.equal(p.events.filter((event) => event.type === "projectFilter").length, 0);
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, []);
  p.receive({ ...state(), focus: { taskID: "T2", token: 3 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.projectFilter, "one");
  assert.equal(p.element("card-other").scrollCount, 0);
  assert.equal(p.events.filter((event) => event.type === "projectFilter").length, 0);
  p.receive({ ...state(), projectFilter: "two", focus: { taskID: "T2", token: 4 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.projectFilter, "two");
  assert.equal(p.element("card-other").scrollCount, 1);
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, ["other"]);
});

test("an explicit local About click reveals a hidden task card", () => {
  const p = page();
  p.receive(state());
  p.click({ act: "focus-task", task: "T2" });
  assert.equal(p.document.body.dataset.projectFilter, "two");
  assert.equal(p.element("card-other").scrollCount, 1);
  assert.deepEqual(p.events.filter((event) => event.type === "projectFilter").at(-1), { type: "projectFilter", project: "two" });
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, ["other"]);
});

test("only a chat request focuses the composer and background focus restoration does not activate chat", () => {
  const p = page();
  p.receive({ ...state(), view: { view: "today", token: 1 } });
  assert.equal(p.element("composer-input").focusCount, 0);
  p.receive({ ...state(), view: { view: "chat", token: 2 } });
  assert.equal(p.element("composer-input").focusCount, 1);
  p.document.focused = false;
  p.focusEvent();
  assert.equal(p.events.filter((event) => event.type === "activate").length, 0);
  p.document.focused = true;
  p.focusEvent();
  assert.deepEqual(p.events.at(-1), { type: "activate", view: "chat", selected: null });
});
