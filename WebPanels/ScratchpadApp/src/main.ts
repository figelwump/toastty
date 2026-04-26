import { scratchpadNativeBridge } from "./nativeBridge";
import { generatedDiagnosticsMessageType, sandboxedSrcdoc } from "./sandbox";

type ScratchpadPanelTheme = "light" | "dark";

interface ScratchpadPanelBootstrap {
  contractVersion: 1;
  documentID: string | null;
  displayName: string;
  revision: number | null;
  contentHTML: string | null;
  missingDocument: boolean;
  message: string | null;
  theme: ScratchpadPanelTheme;
}

type BootstrapListener = (bootstrap: ScratchpadPanelBootstrap | null) => void;

declare global {
  interface Window {
    __toasttyScratchpadDiagnosticsInstalled?: boolean;
    ToasttyScratchpadPanel?: {
      receiveBootstrap: (bootstrap: ScratchpadPanelBootstrap) => void;
      getCurrentBootstrap: () => ScratchpadPanelBootstrap | null;
      subscribe: (listener: BootstrapListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
let currentBootstrap: ScratchpadPanelBootstrap | null = null;
let currentGeneratedContentWindow: Window | null = null;
let currentGeneratedContentDiagnosticsToken: string | null = null;
const diagnosticStringLimit = 2_000;

function truncateDiagnosticString(value: string, limit = diagnosticStringLimit): string {
  if (value.length <= limit) {
    return value;
  }
  return `${value.slice(0, limit - 1)}...`;
}

function describeDiagnosticValue(
  value: unknown,
  seen = new WeakSet<object>()
): { message: string; stack: string | null } {
  if (value instanceof Error) {
    return {
      message: value.message || value.name || "Error",
      stack: value.stack ? truncateDiagnosticString(value.stack) : null
    };
  }

  if (typeof value === "string") {
    return { message: truncateDiagnosticString(value), stack: null };
  }

  if (
    typeof value === "number" ||
    typeof value === "boolean" ||
    typeof value === "bigint" ||
    typeof value === "symbol"
  ) {
    return { message: String(value), stack: null };
  }

  if (value == null) {
    return { message: String(value), stack: null };
  }

  if (typeof value === "object") {
    if (seen.has(value)) {
      return { message: "[Circular]", stack: null };
    }
    seen.add(value);

    const stack = "stack" in value && typeof value.stack === "string"
      ? truncateDiagnosticString(value.stack)
      : null;

    try {
      return {
        message: truncateDiagnosticString(JSON.stringify(value)),
        stack
      };
    } catch {
      return {
        message: truncateDiagnosticString(Object.prototype.toString.call(value)),
        stack
      };
    }
  }

  return { message: truncateDiagnosticString(String(value)), stack: null };
}

function describeConsoleArguments(args: unknown[]): string {
  if (args.length === 0) {
    return "";
  }

  return args.map((value) => describeDiagnosticValue(value).message).join(" ");
}

function installDiagnostics() {
  if (window.__toasttyScratchpadDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadDiagnosticsInstalled = true;

  for (const level of ["info", "warn", "error"] as const) {
    const original = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      original(...args);
      scratchpadNativeBridge.consoleMessage(level, describeConsoleArguments(args));
    };
  }

  window.addEventListener("error", (event) => {
    scratchpadNativeBridge.javascriptError(
      event.message || "JavaScript error",
      event.filename || null,
      Number.isFinite(event.lineno) ? event.lineno : null,
      Number.isFinite(event.colno) ? event.colno : null,
      event.error instanceof Error && event.error.stack
        ? truncateDiagnosticString(event.error.stack)
        : null
    );
  });

  window.addEventListener("unhandledrejection", (event) => {
    const diagnostic = describeDiagnosticValue(event.reason);
    scratchpadNativeBridge.unhandledRejection(diagnostic.message, diagnostic.stack);
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function optionalDiagnosticString(value: unknown, limit = diagnosticStringLimit): string | null {
  return typeof value === "string" && value.length > 0
    ? truncateDiagnosticString(value, limit)
    : null;
}

function requiredDiagnosticString(
  value: unknown,
  fallback: string,
  limit = diagnosticStringLimit
): string {
  return typeof value === "string" && value.length > 0
    ? truncateDiagnosticString(value, limit)
    : fallback;
}

function optionalDiagnosticNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  const normalized = Math.trunc(value);
  return normalized >= 0 && normalized <= 1_000_000 ? normalized : null;
}

function generatedConsoleLevel(value: unknown): "info" | "warn" | "error" | null {
  switch (value) {
    case "info":
    case "warn":
    case "error":
      return value;
    default:
      return null;
  }
}

function forwardGeneratedContentDiagnostic(event: Record<string, unknown>) {
  switch (event.type) {
    case "consoleMessage": {
      const level = generatedConsoleLevel(event.level);
      const message = optionalDiagnosticString(event.message);
      if (!level || !message) {
        return;
      }
      scratchpadNativeBridge.consoleMessage(level, message, "generated-content");
      return;
    }
    case "javascriptError": {
      scratchpadNativeBridge.javascriptError(
        requiredDiagnosticString(event.message, "JavaScript error"),
        optionalDiagnosticString(event.source),
        optionalDiagnosticNumber(event.line),
        optionalDiagnosticNumber(event.column),
        optionalDiagnosticString(event.stack),
        "generated-content"
      );
      return;
    }
    case "unhandledRejection": {
      scratchpadNativeBridge.unhandledRejection(
        requiredDiagnosticString(event.reason, "Unhandled promise rejection"),
        optionalDiagnosticString(event.stack),
        "generated-content"
      );
      return;
    }
    case "cspViolation": {
      scratchpadNativeBridge.cspViolation(
        requiredDiagnosticString(event.violatedDirective, "<unknown>", 128),
        requiredDiagnosticString(event.effectiveDirective, "<unknown>", 128),
        optionalDiagnosticString(event.blockedURI, 512),
        optionalDiagnosticString(event.sourceFile, 512),
        optionalDiagnosticNumber(event.line),
        optionalDiagnosticNumber(event.column),
        optionalDiagnosticString(event.disposition, 32),
        "generated-content"
      );
      return;
    }
  }
}

function installGeneratedContentDiagnosticsBridge() {
  window.addEventListener("message", (event: MessageEvent<unknown>) => {
    if (!currentGeneratedContentWindow || event.source !== currentGeneratedContentWindow) {
      return;
    }

    if (!isRecord(event.data) || event.data.type !== generatedDiagnosticsMessageType) {
      return;
    }
    if (
      typeof event.data.sessionToken !== "string" ||
      event.data.sessionToken !== currentGeneratedContentDiagnosticsToken
    ) {
      return;
    }

    const diagnosticEvent = event.data.event;
    if (!isRecord(diagnosticEvent)) {
      return;
    }

    forwardGeneratedContentDiagnostic(diagnosticEvent);
  });
}

function createDiagnosticsSessionToken(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
}

function applyTheme(bootstrap: ScratchpadPanelBootstrap | null) {
  document.documentElement.dataset.theme = bootstrap?.theme ?? "dark";
}

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

function receiveBootstrap(bootstrap: ScratchpadPanelBootstrap) {
  if (bootstrap.contractVersion !== 1) {
    console.warn(
      `[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${bootstrap.contractVersion}.`
    );
  }
  currentBootstrap = bootstrap;
  applyTheme(bootstrap);
  notifyListeners();
}

window.ToasttyScratchpadPanel = {
  receiveBootstrap,
  getCurrentBootstrap() {
    return currentBootstrap;
  },
  subscribe(listener: BootstrapListener) {
    listeners.add(listener);
    listener(currentBootstrap);
    return () => {
      listeners.delete(listener);
    };
  }
};

function renderMissing(root: HTMLElement, bootstrap: ScratchpadPanelBootstrap) {
  currentGeneratedContentWindow = null;
  currentGeneratedContentDiagnosticsToken = null;
  root.replaceChildren();
  const section = document.createElement("section");
  section.className = "scratchpad-empty";
  const title = document.createElement("h1");
  title.textContent = bootstrap.displayName || "Scratchpad";
  const message = document.createElement("p");
  message.textContent = bootstrap.message || "This Scratchpad document is unavailable.";
  section.append(title, message);
  root.append(section);
  scratchpadNativeBridge.renderReady(bootstrap.displayName, bootstrap.revision);
}

function renderDocument(root: HTMLElement, bootstrap: ScratchpadPanelBootstrap) {
  currentGeneratedContentWindow = null;
  currentGeneratedContentDiagnosticsToken = createDiagnosticsSessionToken();
  root.replaceChildren();

  const iframe = document.createElement("iframe");
  iframe.className = "scratchpad-frame";
  iframe.title = bootstrap.displayName || "Scratchpad";
  // Keep generated content in an opaque origin; scripts are allowed only inside that boundary.
  iframe.sandbox.add("allow-scripts");
  iframe.referrerPolicy = "no-referrer";
  iframe.srcdoc = sandboxedSrcdoc(
    bootstrap.contentHTML ?? "",
    bootstrap.theme,
    currentGeneratedContentDiagnosticsToken
  );
  iframe.addEventListener("load", () => {
    scratchpadNativeBridge.renderReady(bootstrap.displayName, bootstrap.revision);
  }, { once: true });

  currentGeneratedContentWindow = iframe.contentWindow;
  root.append(iframe);
  currentGeneratedContentWindow = iframe.contentWindow;
}

function render(root: HTMLElement, bootstrap: ScratchpadPanelBootstrap | null) {
  if (!bootstrap) {
    return;
  }
  if (bootstrap.missingDocument) {
    renderMissing(root, bootstrap);
    return;
  }
  renderDocument(root, bootstrap);
}

installDiagnostics();
installGeneratedContentDiagnosticsBridge();

const root = document.getElementById("root");
if (!(root instanceof HTMLElement)) {
  scratchpadNativeBridge.javascriptError(
    "Missing Scratchpad panel root container",
    "main.ts",
    null,
    null,
    null
  );
  throw new Error("Missing Scratchpad panel root container");
}

applyTheme(currentBootstrap);
window.ToasttyScratchpadPanel.subscribe((bootstrap) => render(root, bootstrap));
scratchpadNativeBridge.bridgeReady();
