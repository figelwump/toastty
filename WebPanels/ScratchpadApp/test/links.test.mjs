import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { readFileSync } from "node:fs";

// Exercise the actual isolated-world script installed by the native Scratchpad runtime.
const source = readFileSync(new URL("../../../Sources/App/WebPanels/ScratchpadPanelRuntime.swift", import.meta.url), "utf8");
const script = source.match(/static let externalLinkJavaScript = """([\s\S]*?)"""/)[1];

function fixture() {
  const listeners = new Map();
  const posted = [];
  class Element {
    constructor(href, target) { this.href = href; this.target = target; }
    matches(selector) { return selector === "a[href]"; }
    getAttribute() { return this.href; }
  }
  const window = { addEventListener(name, handler) { listeners.set(name, handler); },
    webkit: { messageHandlers: { toasttyScratchpadExternalLink: { postMessage(url) { posted.push(url); } } } } };
  vm.runInNewContext(script, { window, document: { baseURI: "file:///panel/index.html" },
    console: { ...console }, URL, Element });
  return { posted, click(href, target, overrides = {}) {
    let prevented = false;
    listeners.get("click")({ isTrusted: true, button: 0, defaultPrevented: false,
      composedPath: () => [{}, new Element(href, target)],
      preventDefault() { prevented = true; }, ...overrides });
    return prevented;
  } };
}

test("normal and blank-target web links forward once without navigating the Scratchpad", () => {
  for (const target of [null, "_blank"]) {
    const f = fixture();
    assert.equal(f.click("https://example.com/path#section", target), true);
    assert.equal(f.posted.length, 1);
    assert.equal(f.posted[0], "https://example.com/path#section");
  }
});

test("anchors and unsupported schemes keep existing behavior", () => {
  const f = fixture();
  for (const href of ["#section", "", "relative", "file:///tmp/a", "javascript:alert(1)", "mailto:a@example.com"]) {
    assert.equal(f.click(href), false);
  }
  assert.equal(f.posted.length, 0);
});

test("synthetic, handled, and non-primary clicks do not open tabs", () => {
  const f = fixture();
  for (const overrides of [{ isTrusted: false }, { defaultPrevented: true }, { button: 2 }]) {
    assert.equal(f.click("https://example.com", null, overrides), false);
  }
  assert.equal(f.posted.length, 0);
});
