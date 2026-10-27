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
    addEventListener() {}, focus() {}, blur() {}, scrollIntoView() {},
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
  ]);
  const window = { webkit: { messageHandlers: { toasttyCoordinatorChat: {
    postMessage: (event) => posted.push(JSON.parse(JSON.stringify(event))),
  } } } };
  const document = { activeElement: null, getElementById: (id) => nodes.get(id) ?? null,
    addEventListener: (name, handler) => events.set(name, handler) };
  vm.runInNewContext(source, { window, document, TextEncoder, CSS: { escape: (value) => value }, setTimeout: () => 0 });
  return {
    posted, nodes, document,
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

test("opening a card does not pin a fresh draft to an unavailable task", () => {
  const app = page();
  app.receive(state({ kind: "task-started" }));
  app.receive(state({ kind: "task-started" }, { canReply: false, stageLabel: "stuck" }));
  assert.match(app.nodes.get("scroll").innerHTML, /<form[^>]*data-to="coordinator"/);
  app.draft("Please inspect the failure");
  app.submit("Please inspect the failure");
  assert.equal(app.sends()[0].type, "ask");
});

test("a cleared or accepted draft releases its default recipient while explicit choices survive", () => {
  const cleared = page();
  cleared.receive(state());
  cleared.draft("Old question draft");
  cleared.receive(state({}, { defaultReplyTarget: "coordinator" }));
  assert.match(cleared.nodes.get("scroll").innerHTML, /<form[^>]*data-to="task"/);
  cleared.draft("");
  assert.match(cleared.nodes.get("scroll").innerHTML, /<form[^>]*data-to="coordinator"/, "clearing the input also refreshes the visible recipient");
  cleared.draft("Fresh question draft");
  cleared.submit("Fresh question draft");
  assert.equal(cleared.sends()[0].type, "ask");

  const accepted = page();
  accepted.receive(state());
  accepted.submit("First answer");
  accepted.receive({ ...state({ answer: "First answer" }, { defaultReplyTarget: "coordinator" }), ack: { token: 1, ok: true } });
  accepted.submit("Fresh follow-up");
  assert.equal(accepted.sends()[1].type, "ask");

  const explicit = page();
  explicit.receive(state());
  explicit.click({ act: "reply-to", id: "q1", to: "coordinator" });
  explicit.draft("Discarded");
  explicit.draft("");
  explicit.receive(state());
  explicit.submit("Keep my explicit recipient");
  assert.equal(explicit.sends()[0].type, "ask");
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

test("a replacement card retains expansion, draft and recipient while a pending send remains protected", () => {
  const app = page();
  app.receive(state());
  app.draft("Keep this note");
  app.click({ act: "reply-to", id: "q1", to: "coordinator" });
  app.submit("Keep this note");
  const replacement = state({ id: "packet-2", kind: "task-started", options: [] }, { defaultReplyTarget: "task" });
  app.receive(replacement);
  const html = app.nodes.get("scroll").innerHTML;
  assert.ok(html.includes('id="collapse-packet-2"'));
  assert.match(html, /<form[^>]*data-to="coordinator"/);
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
  assert.deepEqual(app.sends(), [{ type: "reply", taskID: "T1", version: null, text: "Staging first", token: 1, cardID: "q1", questionID: "q1" }]);
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
  assert.deepEqual(app.sends()[1], { type: "reply", taskID: "T1", version: 1, text: "A new note before acknowledgement", token: 2, cardID: "q1", questionID: null });
});

test("an earlier question answered elsewhere releases a retained draft after the current card changes", () => {
  const app = page();
  const packet = { version: 1, latestVersion: 1, summary: "First", lookAt: "Review", checks: [], notVerified: [], screenshots: [] };
  app.receive(state({ packet }));
  app.draft("Keep this note about the first report");
  const replacement = state({ id: "q2", text: "The next question?", packet: { ...packet, version: 2, latestVersion: 2 }, answeredQuestionIDs: ["other-question", "q1"] });
  app.receive(replacement);
  app.submit("Keep this note about the first report", "q2");
  assert.deepEqual(app.sends()[0], { type: "reply", taskID: "T1", version: 1, text: "Keep this note about the first report", token: 1, cardID: "q1", questionID: null });
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
