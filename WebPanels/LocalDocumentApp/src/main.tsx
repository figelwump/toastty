import React from "react";
import { createRoot } from "react-dom/client";
import { LocalDocumentPanelApp } from "./LocalDocumentPanelApp";
import { localDocumentNativeBridge } from "./nativeBridge";
import "./bootstrap";

function describeRootError(error: unknown): { message: string; stack: string | null } {
  if (error instanceof Error) {
    return {
      message: error.message || error.name || "Error",
      stack: error.stack ?? null
    };
  }

  if (typeof error === "string") {
    return {
      message: error,
      stack: null
    };
  }

  return {
    message: String(error),
    stack: null
  };
}

function reportRootError(
  phase: "caught" | "uncaught" | "recoverable",
  error: unknown,
  info?: { componentStack?: string }
) {
  const diagnostic = describeRootError(error);
  const componentStack = info?.componentStack?.trim();
  const combinedStack = [diagnostic.stack, componentStack]
    .filter((value): value is string => Boolean(value && value.length > 0))
    .join("\n\n");

  localDocumentNativeBridge.javascriptError(
    `[react-root:${phase}] ${diagnostic.message}`,
    "react-root",
    null,
    null,
    combinedStack.length > 0 ? combinedStack : null
  );
}

localDocumentNativeBridge.consoleMessage("info", "[main] local-document module executing");

const container = document.getElementById("root");

if (!container) {
  localDocumentNativeBridge.javascriptError(
    "Missing local document panel root container",
    "main.tsx",
    null,
    null,
    null
  );
  throw new Error("Missing local document panel root container");
}

localDocumentNativeBridge.consoleMessage("info", "[main] createRoot render starting");

createRoot(container, {
  onCaughtError(error, info) {
    reportRootError("caught", error, info);
  },
  onUncaughtError(error, info) {
    reportRootError("uncaught", error, info);
  },
  onRecoverableError(error, info) {
    reportRootError("recoverable", error, info);
  }
}).render(
  <React.StrictMode>
    <LocalDocumentPanelApp />
  </React.StrictMode>
);
