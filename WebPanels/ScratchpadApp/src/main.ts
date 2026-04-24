import { scratchpadNativeBridge } from "./nativeBridge";
import { sandboxedSrcdoc } from "./sandbox";

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
const diagnosticStringLimit = 2_000;

function truncateDiagnosticString(value: string): string {
  if (value.length <= diagnosticStringLimit) {
    return value;
  }
  return `${value.slice(0, diagnosticStringLimit - 1)}...`;
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
  root.replaceChildren();

  const iframe = document.createElement("iframe");
  iframe.className = "scratchpad-frame";
  iframe.title = bootstrap.displayName || "Scratchpad";
  iframe.sandbox.add("allow-scripts");
  iframe.referrerPolicy = "no-referrer";
  iframe.srcdoc = sandboxedSrcdoc(bootstrap.contentHTML ?? "", bootstrap.theme);
  iframe.addEventListener("load", () => {
    scratchpadNativeBridge.renderReady(bootstrap.displayName, bootstrap.revision);
  }, { once: true });

  root.append(iframe);
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
