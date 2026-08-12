import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const appSource = await readFile(
  new URL("../../Sources/App/Resources/RemoteWebClient/app.js", import.meta.url),
  "utf8"
);

const conversation = {
  conversationID: "conversation-1",
  inputAvailability: { kind: "unavailable", reason: "working" },
  placement: { workspaceTitle: "Workspace" },
  provider: "codex",
  state: "working",
  title: "Reconnect test",
};

function event(sequence, text) {
  return {
    conversationID: conversation.conversationID,
    eventID: `event-${sequence}`,
    kind: "assistant_message",
    payload: { phase: "final", text },
    provider: "codex",
    schemaVersion: 1,
    sequence,
    timestamp: "2026-08-11T00:00:00.000Z",
  };
}

function eventsPage(events, latestSequence = events.at(-1)?.sequence ?? 0) {
  return {
    outcome: "page",
    page: {
      conversationID: conversation.conversationID,
      events,
      firstAvailableSequence: 1,
      historyTruncated: false,
      latestSequence,
      projectionGeneration: 1,
      projectionRunID: "run-1",
    },
    protocolVersion: "1.0",
  };
}

function sessionsResponse() {
  return {
    snapshot: {
      conversations: [conversation],
      generatedAt: "2026-08-11T00:00:00.000Z",
      projectionRunID: "run-1",
    },
    type: "session_list",
  };
}

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((completion) => {
    resolve = completion;
  });
  return { promise, resolve };
}

class ElementStub {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.disabled = false;
    this.hidden = false;
    this.listeners = new Map();
    this.style = {};
    this.textContent = "";
    this.value = "";
  }

  get lastElementChild() {
    return this.children.at(-1) ?? null;
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  removeAttribute(name) {
    if (name === "data-kind") delete this.dataset.kind;
  }

  replaceChildren(...children) {
    this.children = children;
  }

  requestSubmit() {
    return this.listeners.get("submit")?.({ preventDefault() {} });
  }

  scrollIntoView() {}
}

class DocumentStub {
  constructor() {
    this.elements = new Map();
    this.listeners = new Map();
    this.visibilityState = "visible";
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  createElement(tagName) {
    return new ElementStub(tagName);
  }

  getElementById(id) {
    if (!this.elements.has(id)) this.elements.set(id, new ElementStub());
    return this.elements.get(id);
  }
}

function createHarness() {
  const document = new DocumentStub();
  const fetchCalls = [];
  const fetchQueues = new Map();
  const sockets = [];
  const timers = [];

  function enqueueFetch(path, result) {
    if (!fetchQueues.has(path)) fetchQueues.set(path, []);
    fetchQueues.get(path).push(result);
  }

  async function fetch(path, options = {}) {
    fetchCalls.push({ path, options });
    const queue = fetchQueues.get(path);
    assert.ok(queue?.length, `unexpected fetch: ${path}`);
    const result = queue.shift();
    return result instanceof Promise ? result : result;
  }

  class WebSocketStub {
    static OPEN = 1;

    constructor(url) {
      this.url = url;
      this.readyState = 0;
      sockets.push(this);
    }

    close() {
      this.readyState = 3;
    }

    disconnect() {
      this.readyState = 3;
      this.onclose?.();
    }

    message(message) {
      this.onmessage?.({ data: JSON.stringify(message) });
    }

    open() {
      this.readyState = WebSocketStub.OPEN;
      this.onopen?.();
    }
  }

  enqueueFetch("/api/sessions", jsonResponse(sessionsResponse()));
  const context = vm.createContext({
    console,
    document,
    fetch,
    location: { host: "toastty.test", protocol: "https:" },
    Math,
    setTimeout(callback) {
      timers.push(callback);
      return timers.length;
    },
    WebSocket: WebSocketStub,
    window: { crypto: { randomUUID: () => "request-id" } },
  });
  vm.runInContext(appSource, context, { filename: "app.js" });

  return { document, enqueueFetch, fetchCalls, sockets, timers };
}

async function settle() {
  for (let index = 0; index < 32; index += 1) await Promise.resolve();
}

async function openConversationWithFirstEvent(harness) {
  await settle();
  assert.equal(harness.sockets.length, 1);
  harness.sockets[0].open();

  harness.enqueueFetch(
    "/api/conversation.events.get",
    jsonResponse(eventsPage([event(1, "one")]))
  );
  const groups = harness.document.getElementById("session-groups");
  const sessionCard = groups.children[0].children[1];
  sessionCard.listeners.get("click")();
  await settle();

  const messages = harness.document.getElementById("chat-messages");
  assert.deepEqual(messages.children.map((node) => node.textContent), ["one"]);
}

async function reconnect(harness) {
  harness.enqueueFetch("/api/sessions", jsonResponse(sessionsResponse()));
  harness.sockets[0].disconnect();
  assert.equal(harness.timers.length, 1);
  await harness.timers.shift()();
  await settle();
  assert.equal(harness.sockets.length, 2);
  return harness.sockets[1];
}

test("an already-open conversation catches up through REST after reconnect", async () => {
  const harness = createHarness();
  await openConversationWithFirstEvent(harness);
  const reconnectedSocket = await reconnect(harness);

  harness.enqueueFetch(
    "/api/conversation.events.get",
    jsonResponse(eventsPage([event(2, "two")]))
  );
  reconnectedSocket.open();
  await settle();

  const eventRequests = harness.fetchCalls.filter(
    (call) => call.path === "/api/conversation.events.get"
  );
  assert.equal(eventRequests.length, 2);
  assert.deepEqual(JSON.parse(eventRequests[1].options.body).cursor, {
    afterSequence: 1,
    projectionGeneration: 1,
    projectionRunID: "run-1",
  });
  const messages = harness.document.getElementById("chat-messages");
  assert.deepEqual(messages.children.map((node) => node.textContent), ["one", "two"]);
});

test("live pages are preserved while reconnect REST catch-up is in flight", async () => {
  const harness = createHarness();
  await openConversationWithFirstEvent(harness);
  const reconnectedSocket = await reconnect(harness);
  const catchUp = deferred();

  harness.enqueueFetch("/api/conversation.events.get", catchUp.promise);
  reconnectedSocket.open();
  await settle();
  reconnectedSocket.message({
    page: eventsPage([event(3, "three")]).page,
    protocolVersion: "1.0",
    type: "conversation_events",
  });
  catchUp.resolve(jsonResponse(eventsPage([event(2, "two")])));
  await settle();

  const messages = harness.document.getElementById("chat-messages");
  assert.deepEqual(
    messages.children.map((node) => node.textContent),
    ["one", "two", "three"]
  );
});

test("a queued live gap stays single and makes progress across REST pages", async () => {
  const harness = createHarness();
  await openConversationWithFirstEvent(harness);
  const reconnectedSocket = await reconnect(harness);
  const firstCatchUpPage = deferred();

  harness.enqueueFetch("/api/conversation.events.get", firstCatchUpPage.promise);
  harness.enqueueFetch(
    "/api/conversation.events.get",
    jsonResponse(eventsPage([event(3, "three")]))
  );
  reconnectedSocket.open();
  await settle();
  reconnectedSocket.message({
    page: eventsPage([event(4, "four")]).page,
    protocolVersion: "1.0",
    type: "conversation_events",
  });
  firstCatchUpPage.resolve(jsonResponse(eventsPage([event(2, "two")])));
  await settle();

  const eventRequests = harness.fetchCalls.filter(
    (call) => call.path === "/api/conversation.events.get"
  );
  assert.deepEqual(
    eventRequests.slice(1).map((call) => JSON.parse(call.options.body).cursor.afterSequence),
    [1, 2]
  );
  const messages = harness.document.getElementById("chat-messages");
  assert.deepEqual(
    messages.children.map((node) => node.textContent),
    ["one", "two", "three", "four"]
  );
});
