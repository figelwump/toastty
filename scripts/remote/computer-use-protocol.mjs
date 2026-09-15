function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function isComputerUseServer(name) {
  return name === "computer-use" || name === "cua_repl";
}

export function shouldAutoAcceptMcpElicitation(params) {
  if (params?.serverName === "cua_repl") {
    const meta = params._meta;
    const schema = params.requestedSchema;
    // The new runtime identifies app access with structured metadata. Accept
    // only the observed Toastty request; never fill a broader permission form.
    return params.mode === "form" &&
      meta?.connector_id === "computer-use" &&
      meta?.codex_approval_kind === "mcp_tool_call" &&
      meta?.tool_name === "get_app_state" &&
      meta?.tool_params?.app === "com.GiantThings.toastty" &&
      schema?.type === "object" &&
      isRecord(schema.properties) &&
      Object.keys(schema.properties).length === 0 &&
      (schema.required === undefined ||
        (Array.isArray(schema.required) && schema.required.length === 0));
  }

  if (params?.serverName !== "computer-use" || params?.mode !== "form") {
    return false;
  }

  // Keep unattended approvals narrow: only accept the known app-access prompt
  // shape, or an explicit MCP tool-call approval marker from the server.
  const properties = isRecord(params?.requestedSchema?.properties)
    ? params.requestedSchema.properties
    : {};
  if (
    Object.keys(properties).length === 0 &&
    typeof params?.message === "string" &&
    /^Allow Codex to use /i.test(params.message)
  ) {
    return true;
  }

  const meta = isRecord(params?._meta) ? params._meta : {};
  return meta.codex_approval_kind === "mcp_tool_call";
}

