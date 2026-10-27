import assert from "node:assert/strict";
import test from "node:test";
import { buildSync } from "esbuild";
import { resolve } from "node:path";
import vm from "node:vm";

// Run the actual page entry point against a small DOM adapter. Native WebKit
// owns these elements; the checks below cover the page's bridge messages.
const source = buildSync({
  entryPoints: [resolve(import.meta.dirname, "../src/main.ts")],
  bundle: true, format: "iife", platform: "neutral", write: false, logLevel: "silent",
}).outputFiles[0].text;

function element(overrides = {}) {
  const classes = new Set();
  return {
    focusCount: 0, scrollCount: 0,
    innerHTML: "", textContent: "", className: "", value: "", disabled: false,
    scrollHeight: 500, scrollTop: 0, clientHeight: 500,
    dataset: {}, tagName: "BUTTON",
    classList: {
      contains: (name) => classes.has(name),
      add: (name) => classes.add(name), remove: (name) => classes.delete(name),
      toggle: (name, on) => on ? classes.add(name) : classes.delete(name),
    },
    querySelector: () => null, closest: () => null,
    setAttribute() {}, removeAttribute() {},
    addEventListener() {}, focus() { this.focusCount++; }, blur() {}, scrollIntoView() { this.scrollCount++; },
    getBoundingClientRect: () => ({ x: 30, y: 40, width: 24, height: 28 }),
    ...overrides,
  };
}

function page() {
  const events = new Map();
  const posted = [];
  const input = element({ tagName: "TEXTAREA" });
  const composer = element({ tagName: "FORM", querySelector: () => input });
  const nodes = new Map([
    ["header", element()], ["scroll", element()], ["tasks", element()],
    ["composer", composer], ["composer-hint-text", element()],
    ["composer-open-terminal", element()], ["notice", element()],
    ["suggestions", element()], ["address-options", element()],
  ]);
  const window = { webkit: { messageHandlers: { toasttyCoordinatorChat: {
    postMessage: (event) => posted.push(JSON.parse(JSON.stringify(event))),
  } } } };
  nodes.set("composer-input", input);
  const getElement = (id) => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); };
  const document = { body: { dataset: {} }, focused: true, hasFocus() { return this.focused; }, activeElement: null, getElementById: getElement,
    addEventListener: (name, handler) => events.set(name, handler) };
  vm.runInNewContext(source, { window, document, TextEncoder, CSS: { escape: (value) => value }, setTimeout: () => 0 });
  return {
    posted, nodes, events: posted, document, element: getElement,
    focusEvent() { events.get("focusin")?.({}); },
    focusProject(project) {
      const button = element({ dataset: { act: "project-filter", project } });
      document.activeElement = button;
      nodes.get("header").contains = (node) => node === button;
      nodes.get("header").querySelectorAll = () => [button];
      return button;
    },
    compose(text) {
      input.value = text;
      events.get("submit")({ target: composer, preventDefault() {} });
    },
    receive: (state) => window.toasttyCoordinatorChat.receive(state),
    click(dataset, bounds) {
      const target = element({ dataset, ...(bounds ? { getBoundingClientRect: () => bounds } : {}) });
      target.closest = () => target;
      events.get("click")({ target });
    },
    draft(text, id = "q1") {
      const form = element({ dataset: { id } });
      const input = element({ value: text, closest: () => form });
      events.get("input")({ target: input });
    },
    submit(text, id = "q1") {
      const form = element({ tagName: "FORM", dataset: { id }, querySelector: () => ({ value: text }) });
      form.classList.add("replybox");
      events.get("submit")({ target: form, preventDefault() {} });
    },
    sends: () => posted.filter((event) => event.type === "reply" || event.type === "ask"),
  };
}

function state(card = {}, task = {}, coordinator = {}) {
  return {
    hasUserRequests: false, addresses: [],
    coordinator: { title: "Coordinator", detail: "Codex", canSend: true, sendHint: null, hasTerminal: true, ...coordinator },
    items: [{ type: "card", id: "q1", at: "", kind: "question", text: "Rotate prod keys?",
      options: ["Staging only", "Prepare prod"], answer: null, thread: [], isCurrent: true,
      isNew: true, superseded: false, packet: null,
      task: { id: "T1", title: "Rotate keys", slug: "rotate-keys", project: "infra", stageLabel: "question", stageTone: "amber",
        needsUser: true, hasTaskSpace: true, pullRequestURL: null, pullRequestLabel: null, packetVersion: null,
        stale: false, mergePolicy: "Ask before merging.", canMerge: false, canReply: true, defaultReplyTarget: "task", ...task },
      ...card }],
    focus: { taskID: "T1", cardID: "q1", token: 1 }, notice: null,
  };
}

test("an option uses the selected target, accepts no packet, and blocks repeated clicks until ack", () => {
  const app = page();
  app.receive(state({}, { defaultReplyTarget: "coordinator" }));
  app.draft("Keep this draft");
  app.click({ act: "reply-to", id: "q1", to: "task" });
  app.click({ act: "answer", id: "q1", index: "0" });
  app.click({ act: "answer", id: "q1", index: "1" });
  assert.deepEqual(app.sends(), [{ type: "reply", taskID: "T1", version: null, text: "Staging only", token: 1, cardID: "q1", questionID: "q1" }]);
  app.receive({ ...state({}, { defaultReplyTarget: "coordinator" }), ack: { token: 1, ok: false } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Keep this draft"'));
  app.click({ act: "answer", id: "q1", index: "1" });
  assert.equal(app.sends().length, 2);
  app.receive({ ...state({ answer: "Prepare prod" }), ack: { token: 2, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Keep this draft"'), "an option does not erase the typed draft");
  app.click({ act: "answer", id: "q1", index: "0" });
  assert.equal(app.sends().length, 2, "an answered question rejects a stale option click");
  const coordinator = page();
  coordinator.receive(state({}, { defaultReplyTarget: "coordinator" }));
  coordinator.click({ act: "answer", id: "q1", index: "0" });
  assert.equal(coordinator.sends()[0].type, "ask");
  assert.equal(coordinator.sends()[0].questionID, "q1");
});

test("a typed answer keeps its recipient across updates and keeps its draft after a failed send", () => {
  const app = page();
  app.receive(state());
  app.draft("Staging first");
  app.receive(state({}, { defaultReplyTarget: "coordinator" }));
  assert.match(app.nodes.get("scroll").innerHTML, /<form[^>]*data-to="task"/);
  app.submit("Staging first");
  assert.equal(app.sends()[0].type, "reply");
  assert.equal(app.sends()[0].version, null);
  assert.equal(app.sends()[0].questionID, "q1");
  app.submit("Duplicate");
  assert.equal(app.sends().length, 1);
  app.receive({ ...state(), ack: { token: 1, ok: false } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Staging first"'));
  app.submit("Staging first");
  app.receive({ ...state({ answer: "Staging first" }), ack: { token: 2, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value=""'));
  app.submit("What changed?");
  assert.equal(app.sends().at(-1).questionID, null, "a followup is not another answer");
});

test("a packet snapshots its task target even when the question default is coordinator", () => {
  const app = page();
  const packet = { version: 2, latestVersion: 2, summary: "Updated", lookAt: "Review it", checks: [], notVerified: [], screenshots: [] };
  app.receive(state({ kind: "packet", packet }, { defaultReplyTarget: "coordinator" }));
  assert.match(app.nodes.get("scroll").innerHTML, /<form[^>]*data-to="task"/);
  assert.ok(app.nodes.get("scroll").innerHTML.includes('aria-label="Review note for rotate-keys…"'));
  app.submit("Adjust the plan");
  assert.equal(app.sends()[0].type, "reply");
  assert.equal(app.sends()[0].version, 2);
  assert.equal(app.sends()[0].questionID, null);
});

test("unavailable recipients preserve the draft and never reroute it", () => {
  const app = page();
  app.receive(state());
  app.draft("Do staging");
  app.receive(state({}, { canReply: false, defaultReplyTarget: "coordinator" }));
  app.submit("Do staging");
  app.click({ act: "answer", id: "q1", index: "0" });
  assert.equal(app.sends().length, 0);
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Do staging"'));
  assert.ok(app.nodes.get("notice").textContent.includes("Your draft is kept"));
  app.click({ act: "reply-to", id: "q1", to: "coordinator" });
  app.receive(state({}, { canReply: false }, { canSend: false }));
  app.submit("Do staging");
  assert.equal(app.sends().length, 0);
  app.receive(state({}, { canReply: false }));
  app.submit("Do staging");
  assert.equal(app.sends()[0].type, "ask");
});

test("a card menu sends only its task and viewport bounds to the native app", () => {
  const app = page();
  app.receive(state());
  app.click({ act: "card-menu", task: "T1" }, { x: 120, y: 250, width: 28, height: 30 });
  assert.deepEqual(app.posted.find((event) => event.type === "taskMenu"), {
    type: "taskMenu", taskID: "T1", x: 120, y: 250, width: 28, height: 30,
  });
});


test("composer task addressing keeps card sends independent and retains a draft edited while awaiting acknowledgement", () => {
  const app = page();
  const current = { ...state(), addresses: [{ kind: "task", id: "T1", token: "rotate-keys", title: "Rotate keys", version: null }] };
  app.receive(current);
  app.compose("@rotate-keys What changed?");
  assert.deepEqual(app.sends(), [{ type: "ask", taskID: "T1", version: null, text: "What changed?", token: 1 }]);
  app.compose("A different draft");
  assert.equal(app.sends().length, 1, "pending composer sends block repeats");
  app.receive({ ...current, ack: { token: 1, ok: true } });
  app.compose("@rotate-keys Follow up");
  assert.equal(app.sends().at(-1).text, "Follow up");
  app.receive({ ...current, ack: { token: 2, ok: false } });
  app.draft("Staging only");
  app.submit("Staging only");
  assert.equal(app.sends().at(-1).cardID, "q1");
  app.receive({ ...current, ack: { token: 3, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value=""'));
});

function filteredState() {
  return {
    coordinator: { title: "Coordinator", detail: "Codex", canSend: true, sendHint: null, hasTerminal: true },
    projects: [{ id: "one", title: "same" }, { id: "two", title: "same" }], projectFilter: "one",
    items: [{ type: "card", id: "other", kind: "task-started", thread: [], answer: null, options: [], isCurrent: true, task: { id: "T2", title: "Task 2", projectID: "two", project: "same", stageLabel: "running", stageTone: "blue", canReply: false }, packet: null }],
    notice: null, focus: null, view: null,
  };
}

test("a retained old focus cannot override a newer dashboard request or change the shared filter", () => {
  const p = page();
  p.receive({ ...filteredState(), focus: { taskID: "T2", token: 1 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.view, "chat");
  assert.equal(p.document.body.dataset.projectFilter, "one");
  assert.equal(p.element("card-other").scrollCount, 0);
  assert.equal(p.events.filter((event) => event.type === "projectFilter").length, 0);
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, []);
  p.receive({ ...filteredState(), focus: { taskID: "T2", token: 3 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.projectFilter, "one");
  assert.equal(p.element("card-other").scrollCount, 0);
  assert.equal(p.events.filter((event) => event.type === "projectFilter").length, 0);
  p.receive({ ...filteredState(), projectFilter: "two", focus: { taskID: "T2", token: 4 }, view: { view: "tasks", token: 2 } });
  assert.equal(p.document.body.dataset.projectFilter, "two");
  assert.equal(p.element("card-other").scrollCount, 1);
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, ["other"]);
});

test("an explicit local About click reveals a hidden task card", () => {
  const p = page();
  p.receive(filteredState());
  p.click({ act: "focus-task", task: "T2" });
  assert.equal(p.document.body.dataset.projectFilter, "two");
  assert.equal(p.element("card-other").scrollCount, 1);
  assert.deepEqual(p.events.filter((event) => event.type === "projectFilter").at(-1), { type: "projectFilter", project: "two" });
  assert.deepEqual(p.events.filter((event) => event.type === "rendered").at(-1).expanded, ["other"]);
});

test("only a chat request focuses the composer and background focus restoration does not activate chat", () => {
  const p = page();
  p.receive({ ...filteredState(), view: { view: "today", token: 1 } });
  assert.equal(p.element("composer-input").focusCount, 0);
  p.receive({ ...filteredState(), view: { view: "chat", token: 2 } });
  assert.equal(p.element("composer-input").focusCount, 1);
  p.document.focused = false;
  p.focusEvent();
  assert.equal(p.events.filter((event) => event.type === "activate").length, 0);
  p.document.focused = true;
  p.focusEvent();
  assert.deepEqual(p.events.at(-1), { type: "activate", view: "chat", selected: null });
});


test("a live header push preserves project focus but a new dashboard request does not take it back", () => {
  const app = page();
  const current = { ...filteredState(), focus: null };
  app.receive(current);
  const button = app.focusProject("one");
  app.receive(current);
  assert.equal(button.focusCount, 1);
  // The native handoff can precede WebKit's hasFocus update.
  app.receive({ ...current, view: { view: "tasks", token: 10 } });
  assert.equal(button.focusCount, 1);
  app.document.focused = false;
  app.receive({ ...current, view: { view: "tasks", token: 10 } });
  assert.equal(button.focusCount, 1);
});
