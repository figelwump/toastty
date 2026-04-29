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
  sessionLinked?: boolean;
  message: string | null;
  theme: ScratchpadPanelTheme;
}

type BootstrapListener = (bootstrap: ScratchpadPanelBootstrap | null) => void;

declare global {
  interface Window {
    __toasttyScratchpadDiagnosticsInstalled?: boolean;
    ToasttyScratchpadPanel?: {
      receiveBootstrap: (bootstrap: ScratchpadPanelBootstrap) => void;
      focusActiveContent: () => boolean;
      getCurrentBootstrap: () => ScratchpadPanelBootstrap | null;
      subscribe: (listener: BootstrapListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
let currentBootstrap: ScratchpadPanelBootstrap | null = null;
let currentGeneratedContentFrame: HTMLIFrameElement | null = null;
let currentGeneratedContentWindow: Window | null = null;
let currentGeneratedContentDiagnosticsToken: string | null = null;
let currentGeneratedContentReady = false;
const diagnosticStringLimit = 2_000;
const scratchpadSkillInstallSnippet = `Download the Toastty Scratchpad skill from
https://github.com/figelwump/toastty/tree/main/.agents/skills/toastty-scratchpad

Install it globally. Check which of these directories already exist
and copy the toastty-scratchpad folder into the matching ones:

  • ~/.claude/skills        (Claude Code)
  • ~/.codex/skills         (Codex)
  • ~/.agents/skills        (generic / Codex)

If none of these exist for the agent I'm currently using, create the
appropriate one and install there.`;

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

function resetGeneratedContentState() {
  currentGeneratedContentFrame = null;
  currentGeneratedContentWindow = null;
  currentGeneratedContentDiagnosticsToken = null;
  currentGeneratedContentReady = false;
}

function isBlankUnboundScratchpadDocument(bootstrap: ScratchpadPanelBootstrap): boolean {
  return (
    !bootstrap.missingDocument &&
    bootstrap.sessionLinked !== true &&
    (bootstrap.contentHTML ?? "").trim().length === 0
  );
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

function focusActiveContent(): boolean {
  if (currentGeneratedContentFrame) {
    if (!currentGeneratedContentReady) {
      return false;
    }

    try {
      currentGeneratedContentFrame.focus({ preventScroll: true });
      currentGeneratedContentWindow?.focus();
      return true;
    } catch {
      return false;
    }
  }

  if (!currentBootstrap || (!currentBootstrap.missingDocument && !isBlankUnboundScratchpadDocument(currentBootstrap))) {
    return false;
  }

  const emptyState = document.querySelector(".scratchpad-empty");
  if (emptyState instanceof HTMLElement) {
    emptyState.tabIndex = -1;
    emptyState.focus({ preventScroll: true });
    return document.activeElement === emptyState;
  }

  return false;
}

window.ToasttyScratchpadPanel = {
  receiveBootstrap,
  focusActiveContent,
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
  resetGeneratedContentState();
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

function renderEmptyGuidance(root: HTMLElement, bootstrap: ScratchpadPanelBootstrap) {
  resetGeneratedContentState();
  root.replaceChildren();

  const section = document.createElement("section");
  section.className = "scratchpad-empty scratchpad-empty--guide";
  section.tabIndex = -1;

  const header = document.createElement("div");
  header.className = "scratchpad-guide-header";
  const title = document.createElement("h1");
  title.textContent = "Scratchpad is ready";
  const intro = document.createElement("p");
  intro.textContent = "You’re on the manual path: you created an empty Scratchpad, so you’ll need to bind it to an agent and install the Scratchpad skill before the agent can publish to it.";
  const introAlt = document.createElement("p");
  introAlt.textContent = "The shorter path is to install the skill once and skip this screen entirely — agents create and bind their own Scratchpads on demand. See “Skip this next time” below.";
  header.append(title, intro, introAlt);

  const steps = document.createElement("ol");
  steps.className = "scratchpad-guide-steps";

  const bindStep = document.createElement("li");
  bindStep.className = "scratchpad-guide-step";
  const bindTitle = document.createElement("h2");
  bindTitle.textContent = "Bind this Scratchpad to an agent";
  const bindText = document.createElement("p");
  bindText.textContent = "Click the “Unbound” chip in this panel’s header and pick an agent session running in the current tab. Only Toastty-managed sessions show up.";
  bindStep.append(bindTitle, bindText);

  const installStep = document.createElement("li");
  installStep.className = "scratchpad-guide-step scratchpad-guide-step--snippet";
  const installHeader = document.createElement("div");
  installHeader.className = "scratchpad-snippet-header";
  const installTitle = document.createElement("h2");
  installTitle.textContent = "Install the Scratchpad skill";
  const copyButton = document.createElement("button");
  copyButton.type = "button";
  copyButton.className = "scratchpad-copy-button";
  copyButton.textContent = "Copy";
  installHeader.append(installTitle, copyButton);
  const installText = document.createElement("p");
  installText.textContent = "Paste this into your agent’s chat (Claude Code, Codex, or any compatible agent). It tells the agent to download the skill and install it globally for whichever runtime you’re using.";
  const snippet = document.createElement("textarea");
  snippet.className = "scratchpad-snippet";
  snippet.readOnly = true;
  snippet.spellcheck = false;
  snippet.value = scratchpadSkillInstallSnippet;
  snippet.setAttribute("aria-label", "Toastty Scratchpad skill install snippet");
  copyButton.addEventListener("click", async () => {
    try {
      if (!navigator.clipboard) {
        throw new Error("Clipboard unavailable");
      }
      await navigator.clipboard.writeText(scratchpadSkillInstallSnippet);
      copyButton.textContent = "Copied";
      setTimeout(() => {
        copyButton.textContent = "Copy";
      }, 1_600);
    } catch {
      snippet.focus();
      snippet.select();
      copyButton.textContent = "Selected";
      setTimeout(() => {
        copyButton.textContent = "Copy";
      }, 1_600);
    }
  });
  installStep.append(installHeader, installText, snippet);

  const exampleStep = document.createElement("li");
  exampleStep.className = "scratchpad-guide-step";
  const exampleTitle = document.createElement("h2");
  exampleTitle.textContent = "Ask the agent for a visual";
  const exampleText = document.createElement("p");
  exampleText.textContent = "Ask for a diagram, mock-up, wireframe, architecture map, or data viz, or invoke the skill explicitly. The result will publish into this Scratchpad.";
  exampleStep.append(exampleTitle, exampleText);

  steps.append(bindStep, installStep, exampleStep);

  const footer = document.createElement("aside");
  footer.className = "scratchpad-guide-footer";
  const footerTitle = document.createElement("h2");
  footerTitle.textContent = "Skip this next time";
  const footerSkill = document.createElement("p");
  footerSkill.textContent = "Once the skill is installed for an agent, you don’t need New Scratchpad at all — just ask the agent for a visual and it’ll create and bind a fresh Scratchpad on the fly.";
  const footerRebind = document.createElement("p");
  footerRebind.textContent = "Rebinding is still useful, though: you might want one agent to create a Scratchpad and another to read it. Use the binding chip to switch which agent has access. Only one agent session can read or write a Scratchpad at a time.";
  footer.append(footerTitle, footerSkill, footerRebind);

  section.append(header, steps, footer);
  root.append(section);
  scratchpadNativeBridge.renderReady(bootstrap.displayName, bootstrap.revision);
}

function renderDocument(root: HTMLElement, bootstrap: ScratchpadPanelBootstrap) {
  resetGeneratedContentState();
  currentGeneratedContentDiagnosticsToken = createDiagnosticsSessionToken();
  root.replaceChildren();

  const iframe = document.createElement("iframe");
  iframe.className = "scratchpad-frame";
  iframe.title = bootstrap.displayName || "Scratchpad";
  iframe.tabIndex = -1;
  // Keep generated content in an opaque origin; scripts are allowed only inside that boundary.
  iframe.sandbox.add("allow-scripts");
  iframe.referrerPolicy = "no-referrer";
  iframe.srcdoc = sandboxedSrcdoc(
    bootstrap.contentHTML ?? "",
    bootstrap.theme,
    currentGeneratedContentDiagnosticsToken
  );
  iframe.addEventListener("load", () => {
    currentGeneratedContentReady = true;
    currentGeneratedContentWindow = iframe.contentWindow;
    scratchpadNativeBridge.renderReady(bootstrap.displayName, bootstrap.revision);
  }, { once: true });

  currentGeneratedContentFrame = iframe;
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
  if (isBlankUnboundScratchpadDocument(bootstrap)) {
    renderEmptyGuidance(root, bootstrap);
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
