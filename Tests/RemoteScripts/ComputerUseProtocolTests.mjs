import assert from "node:assert/strict";
import test from "node:test";
import {
  isComputerUseServer,
  shouldAutoAcceptMcpElicitation,
} from "../../scripts/remote/computer-use-protocol.mjs";

// Matches the approval request emitted by the updated remote runtime.
function toasttyAccessRequest() {
  return {
    serverName: "cua_repl",
    mode: "form",
    message: 'Allow Computer Use to use "Toastty"?',
    requestedSchema: { type: "object", properties: {} },
    _meta: {
      connector_id: "computer-use",
      codex_approval_kind: "mcp_tool_call",
      tool_name: "get_app_state",
      tool_params: { app: "com.GiantThings.toastty" },
      persist: ["session", "always"],
    },
  };
}

test("recognizes the current Toastty app-access request without changing it", () => {
  const request = toasttyAccessRequest();
  const before = structuredClone(request);
  assert.equal(shouldAutoAcceptMcpElicitation(request), true);
  assert.deepEqual(request, before);
  request.message = "Localized app access prompt";
  assert.equal(shouldAutoAcceptMcpElicitation(request), true);
  for (const tool of ["get_app_state", "get_app_screenshot", "get_app_state_and_screenshot", "click", "drag", "press_key",
    "scroll", "paste", "type_text", "select_text", "set_value", "perform_secondary_action"]) {
    request._meta.tool_name = tool;
    assert.equal(shouldAutoAcceptMcpElicitation(request), true, tool);
  }
});

test("declines foreign, incomplete, or broader current-runtime requests", () => {
  const mutations = [
    r => { r.serverName = "unrelated"; },
    r => { r.mode = "url"; },
    r => { delete r._meta; },
    r => { r._meta.connector_id = "unrelated"; },
    r => { delete r._meta.connector_id; },
    r => { delete r._meta.codex_approval_kind; },
    r => { r._meta.codex_approval_kind = "other"; },
    r => { r._meta.tool_name = "run_command"; },
    r => { r._meta.tool_name = "unknown"; },
    r => { delete r._meta.tool_name; },
    r => { delete r._meta.tool_params; },
    r => { r._meta.tool_params.app = "com.apple.Terminal"; },
    r => { r._meta.tool_params.app = "com.GiantThings.toastty.other"; },
    r => { r.requestedSchema = null; },
    r => { r.requestedSchema = { type: "object" }; },
    r => { r.requestedSchema.type = "string"; },
    r => { r.requestedSchema.properties = []; },
    r => { r.requestedSchema.properties = { always: { type: "boolean" } }; },
    r => { r.requestedSchema.required = ["always"]; },
  ];
  for (const mutate of mutations) {
    const request = toasttyAccessRequest();
    mutate(request);
    assert.equal(shouldAutoAcceptMcpElicitation(request), false, JSON.stringify(request));
  }
  assert.equal(shouldAutoAcceptMcpElicitation(null), false);
});

test("retains recognized legacy Computer Use approval requests", () => {
  assert.equal(shouldAutoAcceptMcpElicitation({
    serverName: "computer-use", mode: "form",
    message: 'Allow Codex to use "Toastty"?',
    requestedSchema: { type: "object", properties: {} },
  }), true);
  assert.equal(shouldAutoAcceptMcpElicitation({
    serverName: "computer-use", mode: "form",
    _meta: { codex_approval_kind: "mcp_tool_call" },
  }), true);
  assert.equal(shouldAutoAcceptMcpElicitation({
    serverName: "computer-use", mode: "form", message: "Unrecognized request",
  }), false);
  assert.equal(shouldAutoAcceptMcpElicitation({
    serverName: "computer-use", mode: "url",
    _meta: { codex_approval_kind: "mcp_tool_call" },
  }), false);
});

test("tool reporting recognizes only exact current and legacy server names", () => {
  for (const name of ["computer-use", "cua_repl"]) {
    assert.equal(isComputerUseServer(name), true);
  }
  for (const name of [undefined, null, "", "other", "cua_repl_extra", "computer-use-other"]) {
    assert.equal(isComputerUseServer(name), false);
  }
});
