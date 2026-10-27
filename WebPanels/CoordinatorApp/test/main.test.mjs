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
  const listeners = new Map();
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
    querySelectorAll: () => [],
    setAttribute() {}, removeAttribute() {},
    addEventListener(name, handler) { listeners.set(name, handler); },
    emit(name, event) { listeners.get(name)?.(event); },
    focus() { this.focusCount++; }, blur() {}, scrollIntoView() { this.scrollCount++; },
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
  } } }, addEventListener: (name, handler) => events.set(`window:${name}`, handler) };
  nodes.set("composer-input", input);
  const getElement = (id) => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); };
  const document = { body: { dataset: {} }, focused: true, hasFocus() { return this.focused; }, activeElement: null, getElementById: getElement,
    addEventListener: (name, handler) => events.set(name, handler) };
  vm.runInNewContext(source, { window, document, TextEncoder, CSS: { escape: (value) => value }, setTimeout: () => 0, setInterval: () => 0 });
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
    typeComposer(text) {
      input.value = text;
      input.emit("input", { target: input });
    },
    pickAddress(index) {
      const target = element({ dataset: { address: String(index) } });
      target.closest = () => target;
      nodes.get("address-options").emit("click", { target });
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
    submitComposer(text) {
      input.value = text;
      events.get("submit")({ target: composer, preventDefault() {} });
    },
    sends: () => posted.filter((event) => event.type === "reply" || event.type === "ask"),
    routeAnswers: () => posted.filter((event) => event.type === "answerRoute"),
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
        stale: false, mergePolicy: "Ask before merging.", canMerge: false, canReply: true, ...task },
      ...card }],
    focus: { taskID: "T1", cardID: "q1", token: 1 }, notice: null,
  };
}

test("an option answers through the coordinator, accepts no packet, and blocks repeated clicks until ack", () => {
  const app = page();
  app.receive(state());
  app.draft("Keep this draft");
  app.click({ act: "answer", id: "q1", index: "0" });
  app.click({ act: "answer", id: "q1", index: "1" });
  assert.deepEqual(app.sends(), [{ type: "ask", taskID: "T1", version: null, text: "Staging only", token: 1, cardID: "q1", questionID: "q1" }]);
  app.receive({ ...state(), ack: { token: 1, ok: false } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Keep this draft"'));
  app.click({ act: "answer", id: "q1", index: "1" });
  assert.equal(app.sends().length, 2);
  app.receive({ ...state({ answer: "Prepare prod" }), ack: { token: 2, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Keep this draft"'), "an option does not erase the typed draft");
  app.click({ act: "answer", id: "q1", index: "0" });
  assert.equal(app.sends().length, 2, "an answered question rejects a stale option click");
});

test("a compact question answers from its options without opening the card", () => {
  const app = page();
  app.receive({ ...state(), focus: null });
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes("Rotate prod keys?") && html.includes('id="option-q1-0"'), "the question and its answers show while the card is folded");
  assert.ok(!html.includes("replybox"), "the folded card has no reply box");
  app.click({ act: "answer", id: "q1", index: "1" });
  assert.deepEqual(app.sends().map(({ type, text, questionID }) => ({ type, text, questionID })),
    [{ type: "ask", text: "Prepare prod", questionID: "q1" }]);
});

test("a typed answer goes to the coordinator and keeps its draft after a failed send", () => {
  const app = page();
  app.receive(state());
  app.draft("Staging first");
  app.submit("Staging first");
  assert.equal(app.sends()[0].type, "ask");
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
  assert.ok(app.sends().every((send) => send.type === "ask"));
});

test("a packet note goes to the coordinator with its packet version", () => {
  const app = page();
  const packet = { version: 2, latestVersion: 2, summary: "Updated", lookAt: "Review it", checks: [], notVerified: [], screenshots: [] };
  app.receive(state({ kind: "packet", packet }));
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('aria-label="Review note for rotate-keys, through the coordinator…"'));
  assert.ok(!html.includes('data-act="reply-to"'), "the card has no recipient switch");
  app.submit("Adjust the plan");
  assert.deepEqual(app.sends().map(({ type, version, questionID }) => ({ type, version, questionID })),
    [{ type: "ask", version: 2, questionID: null }]);
});

test("an unavailable task, coordinator or pending answer preserves the draft", () => {
  for (const [card, task, coordinator] of [[{}, { canReply: false }, {}], [{}, {}, { canSend: false }], [{ answerPending: true }, {}, {}]]) {
    const app = page();
    app.receive(state());
    app.draft("Do staging");
    app.receive(state(card, task, coordinator));
    app.submit("Do staging");
    app.click({ act: "answer", id: "q1", index: "0" });
    assert.equal(app.sends().length, 0);
    assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Do staging"'));
    assert.ok(app.nodes.get("notice").textContent.includes("Your draft is kept"));
    assert.match(app.nodes.get("scroll").innerHTML, /<button[^>]*data-act="answer"[^>]*disabled/);
    app.receive(state());
    app.submit("Do staging");
    assert.equal(app.sends()[0].type, "ask");
  }
});

test("a card menu sends only its task and viewport bounds to the native app", () => {
  const app = page();
  app.receive(state());
  app.click({ act: "card-menu", task: "T1" }, { x: 120, y: 250, width: 28, height: 30 });
  assert.deepEqual(app.posted.find((event) => event.type === "taskMenu"), {
    type: "taskMenu", taskID: "T1", x: 120, y: 250, width: 28, height: 30,
  });
});

test("route choices send only the question and option index and block duplicate, invalid and answered choices", () => {
  const app = page();
  const route = state({ task: null, text: "Which project?\nThis request names no project." });
  app.receive(route);
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('class="grow ctitle">Which project?</span>'));
  assert.ok(html.includes("This request names no project."));
  assert.ok(!html.includes("replybox") && !html.includes('data-act="expand"'));
  for (const index of [undefined, "", " ", "-1", "2", "0.5", "NaN"]) app.click({ act: "answer-route", id: "q1", index });
  app.submit("Arbitrary typed answer");
  assert.deepEqual(app.routeAnswers(), []);
  assert.deepEqual(app.sends(), []);
  app.click({ act: "answer-route", id: "q1", index: "1" });
  app.click({ act: "answer-route", id: "q1", index: "0" });
  assert.deepEqual(app.routeAnswers(), [{ type: "answerRoute", questionID: "q1", optionIndex: 1, token: 1 }]);
  app.receive({ ...route, ack: { token: 1, ok: false } });
  app.click({ act: "answer-route", id: "q1", index: "0" });
  assert.equal(app.routeAnswers().length, 2, "a rejected answer can be retried");
  app.receive({ ...state({ task: null, answer: "Staging only" }), ack: { token: 2, ok: true } });
  app.click({ act: "answer-route", id: "q1", index: "1" });
  assert.equal(app.routeAnswers().length, 2);
  assert.ok(app.nodes.get("scroll").innerHTML.includes(">answered<"));
});

test("route choices stay disabled when the coordinator is unavailable or delivery is unresolved", () => {
  for (const next of [state({ task: null }, {}, { canSend: false }), state({ task: null, answerPending: true })]) {
    const app = page();
    app.receive(next);
    app.click({ act: "answer-route", id: "q1", index: "0" });
    assert.deepEqual(app.routeAnswers(), []);
    assert.match(app.nodes.get("scroll").innerHTML, /<button[^>]*data-act="answer-route"[^>]*disabled/);
  }
});

test("route project titles use exact native identities while the choice payload keeps its saved option index", () => {
  const app = page();
  const options = ["project-billing", "/private/tmp/coordinator-docs", "/recent/tools", "Ask me later"];
  const current = { ...state({ task: null, options }),
    projects: [{ id: "project-billing", rootPath: "/repos/billing", title: "Billing app" }, { id: "/tmp/coordinator-docs", rootPath: "/tmp/coordinator-docs", title: "Documentation" }],
    routeProjects: [{ value: "/private/tmp/coordinator-docs", project: { id: "/tmp/coordinator-docs", rootPath: "/tmp/coordinator-docs", title: "Documentation" } }],
    addresses: [
      { kind: "project", id: "/tmp/coordinator-docs", title: "An older documentation title", token: "docs", version: null },
      { kind: "project", id: "/recent/tools", title: "Recent tools", token: "tools", version: null },
    ],
  };
  app.receive(current);
  const html = app.nodes.get("scroll").innerHTML;
  assert.match(html, /id="option-q1-0"[^>]*>Billing app<\/button>/);
  assert.match(html, /id="option-q1-1"[^>]*>Documentation<\/button>/);
  assert.match(html, /id="option-q1-2"[^>]*>Recent tools<\/button>/);
  assert.match(html, /id="option-q1-3"[^>]*>Ask me later<\/button>/);
  assert.ok(!html.includes("An older documentation title"), "the canonical project's title takes precedence over the address alias");
  assert.ok(!html.includes('title="/repos/billing"') && !html.includes('title="/tmp/coordinator-docs"'), "unique project titles do not show path tooltips");
  app.click({ act: "answer-route", id: "q1", index: "0" });
  app.receive({ ...current, ack: { token: 1, ok: false } });
  app.click({ act: "answer-route", id: "q1", index: "1" });
  assert.deepEqual(app.routeAnswers(), [
    { type: "answerRoute", questionID: "q1", optionIndex: 0, token: 1 },
    { type: "answerRoute", questionID: "q1", optionIndex: 1, token: 2 },
  ]);
  assert.deepEqual(current.items[0].options, options, "labels never replace persisted route options");
});

test("a replacement card retains expansion and draft while a pending send remains protected", () => {
  const app = page();
  app.receive(state());
  app.draft("Keep this note");
  app.submit("Keep this note");
  const replacement = state({ id: "packet-2", kind: "task-started", options: [] });
  app.receive(replacement);
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('id="collapse-packet-2"'));
  assert.match(html, /<input[^>]*value="Keep this note"[^>]*disabled/);
  assert.deepEqual(app.posted.at(-1).expanded, ["packet-2"]);
  app.draft("Newer edit", "packet-2");
  app.submit("Duplicate", "packet-2");
  assert.equal(app.sends().length, 1);
  app.receive({ ...replacement, ack: { token: 1, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Newer edit"'), "a later edit is not cleared by the earlier acknowledgement");
  app.submit("Newer edit", "packet-2");
  assert.equal(app.sends().at(-1).type, "ask");
  app.receive({ ...replacement, ack: { token: 2, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value=""'), "the matching draft clears after acceptance");
  app.click({ act: "expand", id: "packet-2" });
  app.receive(state({ id: "packet-3", kind: "task-started", options: [] }));
  assert.ok(!app.nodes.get("scroll").innerHTML.includes('id="collapse-packet-3"'), "a closed task stays closed");
});

test("a retained question draft answers its original question after a new question replaces it", () => {
  const app = page();
  app.receive(state({ text: "Use staging or production?" }));
  app.draft("Staging first");
  app.receive(state({ id: "q2", text: "Deploy now or tomorrow?" }));
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes("Draft for earlier question: Use staging or production?"));
  app.submit("Staging first", "q2");
  assert.deepEqual(app.sends(), [{ type: "ask", taskID: "T1", version: null, text: "Staging first", token: 1, cardID: "q1", questionID: "q1" }]);
  app.receive({ ...state({ id: "q2" }), ack: { token: 1, ok: false } });
  app.click({ act: "answer", id: "q2", index: "1" });
  assert.equal(app.sends().at(-1).cardID, "q2", "an option answers the current question");
  assert.equal(app.sends().at(-1).questionID, "q2");
});

test("a retained packet draft keeps its original report version until it is cleared", () => {
  const app = page();
  const packet = (version) => ({ version, latestVersion: version, summary: "Updated", lookAt: "Review it", checks: [], notVerified: [], screenshots: [] });
  app.receive(state({ id: "p1", kind: "packet", packet: packet(1) }));
  app.draft("The first report needs a check", "p1");
  app.receive(state({ id: "p2", kind: "packet", packet: packet(2) }));
  assert.ok(app.nodes.get("scroll").innerHTML.includes("Draft for packet v1"));
  app.submit("The first report needs a check", "p2");
  assert.equal(app.sends()[0].version, 1);
  assert.equal(app.sends()[0].cardID, "p1");
  assert.equal(app.sends()[0].questionID, null);
  app.receive({ ...state({ id: "p2", kind: "packet", packet: packet(2) }), ack: { token: 1, ok: true } });
  app.submit("The latest looks right", "p2");
  assert.equal(app.sends()[1].version, 2);
  assert.equal(app.sends()[1].cardID, "p2");
});

test("an accepted question answer keeps newer text as a follow-up to the original card and report", () => {
  const app = page();
  const packet = { version: 1, latestVersion: 1, summary: "First", lookAt: "Review", checks: [], notVerified: [], screenshots: [] };
  app.receive(state({ packet }));
  app.draft("First answer");
  app.submit("First answer");
  app.draft("A new note before acknowledgement");
  app.receive({ ...state({ id: "q2", text: "The next question?", packet: { ...packet, version: 2, latestVersion: 2 } }), ack: { token: 1, ok: true } });
  app.submit("A new note before acknowledgement", "q2");
  assert.deepEqual(app.sends()[1], { type: "ask", taskID: "T1", version: 1, text: "A new note before acknowledgement", token: 2, cardID: "q1", questionID: null });
});

test("an earlier question answered elsewhere releases a retained draft after the current card changes", () => {
  const app = page();
  const packet = { version: 1, latestVersion: 1, summary: "First", lookAt: "Review", checks: [], notVerified: [], screenshots: [] };
  app.receive(state({ packet }));
  app.draft("Keep this note about the first report");
  const replacement = state({ id: "q2", text: "The next question?", packet: { ...packet, version: 2, latestVersion: 2 }, answeredQuestionIDs: ["other-question", "q1"] });
  app.receive(replacement);
  app.submit("Keep this note about the first report", "q2");
  assert.deepEqual(app.sends()[0], { type: "ask", taskID: "T1", version: 1, text: "Keep this note about the first report", token: 1, cardID: "q1", questionID: null });
  app.receive({ ...replacement, ack: { token: 1, ok: true } });
  app.click({ act: "answer", id: "q2", index: "0" });
  assert.equal(app.sends()[1].questionID, "q2", "the current unanswered question keeps its own identity");
});

test("an option answer or persisted answer releases only the matching retained question reference", () => {
  const option = page();
  option.receive(state());
  option.draft("An unsent follow-up");
  option.click({ act: "answer", id: "q1", index: "0" });
  option.receive({ ...state({ id: "q2", text: "A later question?" }), ack: { token: 1, ok: true } });
  option.submit("An unsent follow-up", "q2");
  assert.equal(option.sends()[1].cardID, "q1");
  assert.equal(option.sends()[1].questionID, null);

  const persisted = page();
  persisted.receive(state());
  persisted.draft("Question follow-up");
  persisted.receive(state({ answer: "Answered elsewhere" }));
  persisted.submit("Question follow-up");
  assert.equal(persisted.sends()[0].questionID, null);
  assert.equal(persisted.sends()[0].cardID, "q1");

  const different = page();
  different.receive(state());
  different.draft("Still answering the first question");
  different.receive(state({ id: "q2", answer: "A different question was answered" }));
  different.submit("Still answering the first question", "q2");
  assert.equal(different.sends()[0].questionID, "q1");
});

test("a replacement card keeps reply focus, selection and the visible reading anchor", () => {
  const app = page();
  app.receive(state());
  app.draft("Keep reading here");
  const oldForm = element({ dataset: { id: "q1", task: "T1" } });
  app.document.activeElement = element({ closest: () => oldForm, selectionStart: 5, selectionEnd: 12, selectionDirection: "forward" });
  const oldAnchor = element({ dataset: { item: "q1", task: "T1" }, getBoundingClientRect: () => ({ top: -40, bottom: 200 }) });
  const newAnchor = element({ getBoundingClientRect: () => ({ top: -10, bottom: 230 }) });
  let focusOptions;
  let selection;
  const input = element({ focus: (options) => { focusOptions = options; }, setSelectionRange: (...args) => { selection = args; } });
  const scroll = app.nodes.get("scroll");
  scroll.scrollHeight = 2000;
  scroll.scrollTop = 400;
  scroll.clientHeight = 500;
  scroll.getBoundingClientRect = () => ({ top: 0 });
  scroll.querySelectorAll = () => [oldAnchor];
  scroll.querySelector = (selector) => selector.includes("form.replybox") ? element({ querySelector: () => input }) : newAnchor;
  app.receive(state({ id: "q2" }));
  assert.equal(focusOptions?.preventScroll, true);
  assert.deepEqual(selection, [5, 12, "forward"]);
  assert.equal(scroll.scrollTop, 430, "the same visible card content keeps its offset");
});

test("reading history stays on surviving visible messages when an unfocused task moves", () => {
  const app = page();
  app.receive(state());
  const scroll = app.nodes.get("scroll");
  scroll.scrollHeight = 2000;
  scroll.scrollTop = 400;
  scroll.clientHeight = 500;
  scroll.getBoundingClientRect = () => ({ top: 0 });
  scroll.querySelectorAll = () => [
    element({ dataset: { item: "q1", task: "T1" }, getBoundingClientRect: () => ({ top: -40, bottom: 80 }) }),
    element({ dataset: { item: "message-1" }, getBoundingClientRect: () => ({ top: 100, bottom: 170 }) }),
    element({ dataset: { item: "message-2" }, getBoundingClientRect: () => ({ top: 190, bottom: 260 }) }),
  ];
  scroll.querySelector = (selector) => {
    if (selector.includes('"message-1"')) return element({ getBoundingClientRect: () => ({ top: 70, bottom: 140 }) });
    if (selector.includes('"q2"')) return element({ getBoundingClientRect: () => ({ top: 1500, bottom: 1800 }) });
    return null;
  };
  const next = state({ id: "q2" });
  next.items.unshift({ type: "message", id: "message-1", at: "", role: "assistant", text: "Still reading this message" });
  app.receive(next);
  assert.equal(scroll.scrollTop, 370, "the surviving message keeps its visible offset instead of following the task to the bottom");
});

test("history links open their report versions and stuck actions use native task actions", () => {
  const app = page();
  app.receive(state({ kind: "task-started", packetVersions: [1, 3, 2] }, { packetVersion: 3, stageLabel: "stuck", failureText: "The real check failed.", canArchive: true }));
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes("The real check failed.") && html.includes("Open the task space") && html.includes("Archive it"));
  assert.ok(html.includes('data-version="3">Full report</button>'));
  assert.ok(html.includes('data-version="1">v1</button>') && html.includes('data-version="2">v2</button>'));
  app.click({ act: "open-report", task: "T1", version: "1" });
  app.click({ act: "open-task", task: "T1" });
  app.click({ act: "archive-task", task: "T1" });
  assert.deepEqual(app.posted.filter((event) => ["openReport", "openTaskSpace", "archiveTask"].includes(event.type)), [
    { type: "openReport", taskID: "T1", version: 1, screenshot: null },
    { type: "openTaskSpace", taskID: "T1" }, { type: "archiveTask", taskID: "T1" },
  ]);
  app.receive(state({}, { canArchive: false }));
  app.click({ act: "archive-task", task: "T1" });
  assert.equal(app.posted.filter((event) => event.type === "archiveTask").length, 1);
});

test("a composer acknowledgement keeps text written after the send", () => {
  const app = page();
  app.receive(state());
  const composer = app.nodes.get("composer");
  app.submitComposer("First request");
  const input = composer.querySelector();
  input.value = "Second request";
  app.receive({ ...state(), ack: { token: 1, ok: true } });
  assert.equal(input.value, "Second request");
  app.submitComposer("Second request");
  app.receive({ ...state(), ack: { token: 2, ok: true } });
  assert.equal(input.value, "");
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

test("a composer acknowledgement keeps a selected address for newer text and clears it with the matching text", () => {
  const app = page();
  const current = { ...state(), addresses: [
    { kind: "task", id: "T1", token: "rotate-keys", title: "Rotate keys", version: 2 },
    { kind: "project", id: "/repos/infra", token: "rotate-keys", title: "Infrastructure", version: null },
  ] };
  app.receive(current);
  app.typeComposer("@rotate");
  app.pickAddress(0);
  app.typeComposer("@rotate-keys First note");
  app.submitComposer("@rotate-keys First note");
  app.typeComposer("@rotate-keys Later note");
  app.receive({ ...current, ack: { token: 1, ok: true } });
  assert.equal(app.nodes.get("composer").querySelector().value, "@rotate-keys Later note");
  app.submitComposer("@rotate-keys Later note");
  assert.deepEqual(app.sends(), [
    { type: "ask", taskID: "T1", version: 2, text: "First note", token: 1 },
    { type: "ask", taskID: "T1", version: 2, text: "Later note", token: 2 },
  ]);
  app.receive({ ...current, ack: { token: 2, ok: true } });
  assert.equal(app.nodes.get("composer").querySelector().value, "");
  app.typeComposer("@rotate-keys A fresh request");
  app.submitComposer("@rotate-keys A fresh request");
  assert.deepEqual(app.posted.filter((event) => event.type === "send"), [{ type: "send", text: "@rotate-keys A fresh request", token: 3 }], "a fresh ambiguous address requires a new pick");
});

test("a composer acknowledgement keeps identical text addressed to a different selected target", () => {
  const app = page();
  const current = { ...state(), addresses: [
    { kind: "task", id: "T1", token: "rotate-keys", title: "First rotation task", version: 2 },
    { kind: "task", id: "T2", token: "rotate-keys", title: "Second rotation task", version: 1 },
  ] };
  app.receive(current);
  app.typeComposer("@rotate");
  app.pickAddress(0);
  app.typeComposer("@rotate-keys Same note");
  app.submitComposer("@rotate-keys Same note");
  app.typeComposer("@rotate");
  app.pickAddress(1);
  app.typeComposer("@rotate-keys Same note");
  app.receive({ ...current, ack: { token: 1, ok: true } });
  assert.equal(app.nodes.get("composer").querySelector().value, "@rotate-keys Same note", "the accepted T1 send must not clear the new T2 draft");
  app.submitComposer("@rotate-keys Same note");
  assert.equal(app.sends()[1].taskID, "T2");
  app.receive({ ...current, ack: { token: 2, ok: true } });
  assert.equal(app.nodes.get("composer").querySelector().value, "", "the matching T2 acknowledgement clears its draft");
});

test("composer and task-card acknowledgements clear only their own pending drafts", () => {
  const app = page();
  const current = { ...state(), addresses: [{ kind: "task", id: "T1", token: "rotate-keys", title: "Rotate keys", version: null }] };
  app.receive(current);
  app.draft("Answer from the card");
  app.submit("Answer from the card");
  app.submitComposer("@rotate-keys Separate coordinator question");
  assert.equal(app.sends().length, 2);
  app.receive({ ...current, ack: { token: 2, ok: true } });
  assert.equal(app.nodes.get("composer").querySelector().value, "");
  assert.match(app.nodes.get("scroll").innerHTML, /<input[^>]*value="Answer from the card"[^>]*disabled/);
  app.submit("Duplicate from the card");
  assert.equal(app.sends().length, 2);
  app.receive({ ...state({ id: "q2" }), ack: { token: 1, ok: true } });
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value=""'));
  assert.ok(!/<input[^>]*disabled/.test(app.nodes.get("scroll").innerHTML));
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

test("a project filter preserves a hidden replacement card's pending draft and original question context", () => {
  const app = page();
  const projects = [{ id: "one", title: "same" }, { id: "two", title: "same" }];
  const packet = (version) => ({ version, latestVersion: version, summary: "Updated", lookAt: "Review", checks: [], notVerified: [], screenshots: [] });
  const original = { ...state({ packet: packet(1) }, { projectID: "one" }), projects, projectFilter: "one" };
  app.receive(original);
  app.draft("Keep the first report note");
  app.submit("Keep the first report note");
  app.click({ act: "project-filter", project: "two" });
  assert.ok(!app.nodes.get("scroll").innerHTML.includes('data-item="q1"'));
  assert.deepEqual(app.posted.filter((event) => event.type === "rendered").at(-1).expanded, []);

  const replacement = { ...state({ id: "q2", packet: packet(2), answeredQuestionIDs: ["q1"] }, { projectID: "one" }), projects, projectFilter: "two" };
  app.receive(replacement);
  app.receive({ ...replacement, view: { view: "tasks", token: 2 } });
  assert.ok(!app.nodes.get("scroll").innerHTML.includes('data-item="q2"'));
  app.click({ act: "project-filter", project: "one" });
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('id="collapse-q2"'));
  assert.match(html, /<input[^>]*value="Keep the first report note"[^>]*disabled/);
  assert.deepEqual(app.posted.filter((event) => event.type === "rendered").at(-1).expanded, ["q2"]);
  app.submit("Duplicate", "q2");
  assert.equal(app.sends().length, 1);
  app.receive({ ...replacement, projectFilter: "one", ack: { token: 1, ok: false } });
  app.submit("Keep the first report note", "q2");
  assert.deepEqual(app.sends()[1], { type: "ask", taskID: "T1", version: 1, text: "Keep the first report note", token: 2, cardID: "q1", questionID: null });
});

test("a task opened from the dashboard reveals its current replacement card under the shared filter", () => {
  const app = page();
  const projects = [{ id: "one", title: "same" }, { id: "two", title: "same" }];
  const original = { ...state({}, { projectID: "one" }), projects, projectFilter: "one" };
  app.receive(original);
  app.draft("Retain this draft");
  app.receive({ ...original, projectFilter: "two", view: { view: "tasks", token: 2 } });
  const replacement = { ...state({ id: "q2", packetVersions: [1, 2] }, { projectID: "one", packetVersion: 2 }), projects, projectFilter: "one",
    focus: { taskID: "T1", token: 4 }, view: { view: "chat", token: 3 } };
  app.receive(replacement);
  assert.equal(app.element("card-q2").scrollCount, 1);
  assert.equal(app.element("card-q1").scrollCount, 1, "only the initial request scrolled the old card");
  assert.deepEqual(app.posted.filter((event) => event.type === "rendered").at(-1).expanded, ["q2"]);
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('value="Retain this draft"') && html.includes('id="report-q2-1"'));
  assert.ok(!html.includes('data-item="q1"'));
});

test("dashboard navigation and background updates do not restore a retained reply field's keyboard focus", () => {
  const app = page();
  const current = state();
  app.receive(current);
  app.draft("Keep this note");
  const form = element({ dataset: { id: "q1", task: "T1" } });
  app.document.activeElement = element({ closest: () => form });
  const input = element();
  app.nodes.get("scroll").querySelector = () => element({ querySelector: () => input });
  app.receive({ ...current, view: { view: "tasks", token: 2 } });
  assert.equal(input.focusCount, 0, "the native handoff wins even before document.hasFocus updates");
  app.document.focused = false;
  app.receive({ ...current, view: { view: "tasks", token: 2 } });
  assert.equal(input.focusCount, 0, "a background refresh does not reclaim keyboard focus");
  assert.ok(app.nodes.get("scroll").innerHTML.includes('value="Keep this note"'));
});

test("a sent message shows the coordinator working until the app reports the turn or a reply", () => {
  const working = () => app.nodes.get("scroll").innerHTML.includes('id="coordinator-activity"');
  const reply = { type: "message", id: "r1", at: "2026-10-27T17:00:05.000Z", role: "assistant", text: "Done.", phase: "final" };
  let app = page();
  app.receive(state());
  app.submitComposer("cleanup worktrees");
  assert.ok(working(), "the working row shows at once, before any acknowledgement");
  app.receive({ ...state(), ack: { token: 1, ok: true } });
  assert.ok(working(), "an accepted send keeps the row until the turn starts");
  app.receive(state({}, {}, { working: true }));
  assert.ok(working());
  app.receive(state());
  assert.ok(!working(), "the row goes once the reported turn ends");

  // A fast reply can arrive before the app ever reports the turn.
  app = page();
  app.receive(state());
  app.submitComposer("status");
  const withReply = state();
  withReply.items = [...withReply.items, reply];
  app.receive(withReply);
  assert.ok(!working(), "a new reply ends the wait");

  // A message sent during a turn waits for it; that turn's end and reply
  // do not end the wait for the queued message.
  app = page();
  app.receive(state({}, {}, { working: true }));
  app.submitComposer("and the release notes");
  app.receive({ ...withReply, coordinator: { ...withReply.coordinator, working: true }, ack: { token: 1, ok: true } });
  app.receive(withReply);
  assert.ok(working(), "the queued message still shows the coordinator working");
  app.receive({ ...withReply, coordinator: { ...withReply.coordinator, working: true } });
  app.receive(withReply);
  assert.ok(!working(), "the queued message's own turn ends the wait");

  // A refused send never started a turn.
  app = page();
  app.receive(state());
  app.submitComposer("status");
  app.receive({ ...state(), ack: { token: 1, ok: false } });
  assert.ok(!working());
});
