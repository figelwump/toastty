import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { build } from "esbuild";

async function panelBootstrap() {
  const result = await build({ entryPoints: [new URL("../src/bootstrap.ts", import.meta.url).pathname],
    bundle: true, write: false, format: "iife", platform: "browser" });
  const events = [];
  const window = { addEventListener() {}, webkit: { messageHandlers: {
    toasttyLocalDocumentPanel: { postMessage(event) { events.push(event); } }
  } } };
  const document = { documentElement: { dataset: {}, style: { setProperty() {} } } };
  vm.runInNewContext(result.outputFiles[0].text, { window, document, console: { ...console } });
  return { panel: window.ToasttyLocalDocumentPanel, events };
}

test("mobile read-only presentation cannot bootstrap an editor; desktop remains editable", async () => {
  const { panel } = await panelBootstrap();
  const bootstrap = { contractVersion: 7, presentation: "mobileReadOnly", isEditing: true,
    isDirty: true, isSaving: true, content: "saved disk text", theme: "dark", textScale: 1 };
  panel.receiveBootstrap(bootstrap);
  assert.equal(panel.getCurrentBootstrap().isEditing, false);
  assert.equal(panel.getCurrentBootstrap().isDirty, false);
  assert.equal(panel.getCurrentBootstrap().isSaving, false);
  panel.receiveBootstrap({ ...bootstrap, presentation: undefined });
  assert.equal(panel.getCurrentBootstrap().isEditing, true);
});

test("line reveal requested before mobile bootstrap remains queued until consumed", async () => {
  const { panel } = await panelBootstrap();
  panel.revealLine(12);
  panel.receiveBootstrap({ contractVersion: 7, presentation: "mobileReadOnly", content: "line", theme: "dark" });
  assert.equal(panel.getCurrentRevealRequest().lineNumber, 12);
  const id = panel.getCurrentRevealRequest().requestID;
  panel.consumeRevealRequest(id + 1);
  assert.equal(panel.getCurrentRevealRequest().requestID, id);
  panel.consumeRevealRequest(id);
  assert.equal(panel.getCurrentRevealRequest(), null);
});
