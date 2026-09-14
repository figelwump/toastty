import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { build } from "esbuild";

const bundle = await build({
  entryPoints: [new URL("../src/main.ts", import.meta.url).pathname],
  bundle: true, write: false, format: "iife", platform: "browser"
});

function panelHarness() {
  const handlers = new Map();
  const timers = new Map();
  const requests = [];
  const replies = [];
  const nativeEvents = [];
  let sequence = 0;
  const window = { addEventListener(type, handler) { handlers.set(type, handler); } };
  window.webkit = { messageHandlers: { toasttyScratchpadPanel: {
    postMessage(event) { nativeEvents.push(event); }
  } } };
  class Element {
    children = [];
    handlers = new Map();
    sandbox = { add() {} };
    append(...children) { this.children.push(...children); }
    replaceChildren() { this.children = []; }
    addEventListener(type, handler) { this.handlers.set(type, handler); }
    setAttribute() {}
  }
  const root = new Element();
  const document = {
    documentElement: { dataset: {} },
    getElementById() { return root; },
    createElement(tag) {
      const element = new Element();
      if (tag === "iframe") {
        const childHandlers = new Map();
        const child = {
          scrollX: 0, scrollY: 0,
          parent: window,
          addEventListener(type, handler) { childHandlers.set(type, handler); },
          postMessage(data) { requests.push({ child, data }); }
        };
        element.contentWindow = child;
        element.start = () => {
          const script = [...element.srcdoc.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
          vm.runInNewContext(script, { window: child, console: { ...console } });
          element.handlers.get("load")();
        };
        element.receive = (data, source = window) => childHandlers.get("message")({ data, source });
      }
      return element;
    }
  };
  window.postMessage = (data) => replies.push(data);
  vm.runInNewContext(bundle.outputFiles[0].text, {
    window, document, HTMLElement: Element, console: { ...console },
    setTimeout(callback, delay) {
      const id = ++sequence;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); }
  });
  const api = window.ToasttyScratchpadPanel;
  const bootstrap = { contractVersion: 1, documentID: "doc", displayName: "Diagram",
    revision: 1, contentHTML: "<main>Diagram</main>", missingDocument: false, message: null, theme: "dark" };
  return {
    api, timers, requests, replies, nativeEvents,
    render(overrides = {}) {
      api.receiveBootstrap({ ...bootstrap, ...overrides });
      return root.children[0];
    },
    deliver(frame, data = replies.at(-1)) { handlers.get("message")({ source: frame.contentWindow, data }); }
  };
}

test("viewport is unavailable before a document loads, and each request reads current scroll", async () => {
  const h = panelHarness();
  assert.equal(await h.api.getAnnotationViewport(), null);
  const frame = h.render();
  assert.equal(await h.api.getAnnotationViewport(), null);
  frame.start();
  for (const [x, y] of [[12.5, 200], [-4, 870]]) {
    const pending = h.api.getAnnotationViewport();
    frame.contentWindow.scrollX = x;
    frame.contentWindow.scrollY = y;
    frame.receive(h.requests.at(-1).data);
    h.deliver(frame);
    assert.deepEqual(JSON.parse(JSON.stringify(await pending)), { x, y });
    assert.equal(h.timers.size, 0);
  }
  assert.notEqual(h.requests[0].data.requestID, h.requests[1].data.requestID);
});

test("ready events report the exact bootstrap render ID and ignore replaced frame loads", () => {
  const h = panelHarness();
  const oldFrame = h.render({ annotationRenderID: "old-render" });
  const currentFrame = h.render({ annotationRenderID: "current-render" });
  oldFrame.start();
  assert.equal(h.nativeEvents.filter(event => event.type === "renderReady").length, 0);
  currentFrame.start();
  assert.equal(h.nativeEvents.at(-1).annotationRenderID, "current-render");
  h.render({ missingDocument: true, annotationRenderID: "missing-render" });
  assert.equal(h.nativeEvents.at(-1).annotationRenderID, "missing-render");
  h.render({ contentHTML: "", annotationRenderID: "empty-render" });
  assert.equal(h.nativeEvents.at(-1).annotationRenderID, "empty-render");
  h.render().start();
  assert.equal(h.nativeEvents.at(-1).annotationRenderID, null);
});

test("child accepts only a viewport request from its parent with the current token", async () => {
  const h = panelHarness();
  const frame = h.render();
  frame.start();
  const pending = h.api.getAnnotationViewport();
  const request = h.requests.at(-1).data;
  frame.receive(request, {});
  frame.receive({ ...request, sessionToken: "wrong" });
  frame.receive({ ...request, type: "other" });
  frame.receive({ ...request, requestID: 1 });
  assert.equal(h.replies.length, 0);
  frame.receive(request);
  h.deliver(frame);
  assert.ok(await pending);
});

test("parent rejects wrong sources, tokens, request IDs, and invalid coordinates", async () => {
  const h = panelHarness();
  const frame = h.render();
  frame.start();
  const pending = h.api.getAnnotationViewport();
  frame.receive(h.requests.at(-1).data);
  const reply = h.replies.at(-1);
  h.deliver({ contentWindow: {} }, reply);
  h.deliver(frame, { ...reply, sessionToken: "wrong" });
  h.deliver(frame, { ...reply, event: { ...reply.event, requestID: "unknown" } });
  h.deliver(frame, { ...reply, event: { ...reply.event, x: NaN } });
  h.deliver(frame, { ...reply, event: { ...reply.event, y: Infinity } });
  assert.equal(h.timers.size, 1);
  h.deliver(frame, reply);
  assert.ok(await pending);
  assert.equal(h.timers.size, 0);
});

test("rerender cancels pending reads and stale frame loads and replies cannot affect new reads", async () => {
  const h = panelHarness();
  const oldFrame = h.render();
  oldFrame.start();
  const oldPending = h.api.getAnnotationViewport();
  oldFrame.receive(h.requests.at(-1).data);
  const oldReply = h.replies.at(-1);
  const newFrame = h.render({ revision: 2 });
  assert.equal(await oldPending, null);
  assert.equal(h.timers.size, 0);
  oldFrame.handlers.get("load")();
  assert.equal(await h.api.getAnnotationViewport(), null);
  newFrame.start();
  const newPending = h.api.getAnnotationViewport();
  h.deliver(oldFrame, oldReply);
  h.deliver(newFrame, oldReply);
  assert.equal(h.timers.size, 1);
  newFrame.receive(h.requests.at(-1).data);
  h.deliver(newFrame);
  assert.ok(await newPending);
});

test("missing documents and blank guidance cancel reads without leaving timers", async () => {
  for (const overrides of [{ missingDocument: true }, { contentHTML: "" }]) {
    const h = panelHarness();
    h.render().start();
    const pending = h.api.getAnnotationViewport();
    h.render(overrides);
    assert.equal(await pending, null);
    assert.equal(await h.api.getAnnotationViewport(), null);
    assert.equal(h.timers.size, 0);
  }
});

test("timeout and posting failure resolve null and remove pending state", async () => {
  const h = panelHarness();
  const frame = h.render();
  frame.start();
  const pending = h.api.getAnnotationViewport();
  const timer = [...h.timers.values()][0];
  assert.equal(timer.delay, 500);
  timer.callback();
  assert.equal(await pending, null);
  assert.equal(h.timers.size, 0);
  frame.receive(h.requests.at(-1).data);
  h.deliver(frame);
  assert.equal(h.timers.size, 0);
  frame.contentWindow.postMessage = () => { throw new Error("Detached frame"); };
  assert.equal(await h.api.getAnnotationViewport(), null);
  assert.equal(h.timers.size, 0);
});
