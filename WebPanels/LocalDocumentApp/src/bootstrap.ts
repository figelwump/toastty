import { localDocumentNativeBridge } from "./nativeBridge";

export type LocalDocumentPanelTheme = "light" | "dark";
export type LocalDocumentHighlightState =
  | "enabled"
  | "disabledForLargeFile"
  | "unsupportedFormat"
  | "unavailable";
export type LocalDocumentSyntaxLanguage =
  | "yaml"
  | "toml"
  | "json"
  | "xml"
  | "bash"
  | "swift"
  | "javascript"
  | "typescript"
  | "python"
  | "go"
  | "rust";
export type LocalDocumentFormat =
  | "markdown"
  | "yaml"
  | "toml"
  | "json"
  | "jsonl"
  | "config"
  | "csv"
  | "tsv"
  | "xml"
  | "shell"
  | "code";

export interface LocalDocumentPanelBootstrap {
  contractVersion: 6;
  filePath: string | null;
  displayName: string;
  format: LocalDocumentFormat;
  syntaxLanguage: LocalDocumentSyntaxLanguage | null;
  formatLabel: string;
  shouldHighlight: boolean;
  highlightState: LocalDocumentHighlightState;
  content: string;
  contentRevision: number;
  isEditing: boolean;
  isDirty: boolean;
  hasExternalConflict: boolean;
  isSaving: boolean;
  saveErrorMessage: string | null;
  theme: LocalDocumentPanelTheme;
  textScale: number;
}

type BootstrapListener = (bootstrap: LocalDocumentPanelBootstrap | null) => void;
export interface LocalDocumentLineRevealRequest {
  requestID: number;
  lineNumber: number;
}
type RevealListener = (request: LocalDocumentLineRevealRequest | null) => void;

export interface LocalDocumentPanelSearchState {
  query: string;
  matchCount: number;
  activeMatchIndex: number | null;
  matchFound: boolean;
}

export type LocalDocumentPanelSearchCommand =
  | { type: "setQuery"; query: string }
  | { type: "next"; query: string }
  | { type: "previous"; query: string }
  | { type: "clear" };

interface LocalDocumentPanelSearchController {
  perform: (command: LocalDocumentPanelSearchCommand) => LocalDocumentPanelSearchState;
}

declare global {
  interface Window {
    __toasttyLocalDocumentDiagnosticsInstalled?: boolean;
    ToasttyLocalDocumentPanel?: {
      receiveBootstrap: (bootstrap: LocalDocumentPanelBootstrap) => void;
      setTextScale: (textScale: number) => void;
      revealLine: (lineNumber: number) => void;
      getCurrentBootstrap: () => LocalDocumentPanelBootstrap | null;
      getCurrentRevealRequest: () => LocalDocumentLineRevealRequest | null;
      consumeRevealRequest: (requestID: number) => void;
      subscribe: (listener: BootstrapListener) => () => void;
      getCurrentSearchState: () => LocalDocumentPanelSearchState;
      setCurrentSearchState: (searchState: LocalDocumentPanelSearchState) => void;
      resetSearchState: () => void;
      registerSearchController: (controller: LocalDocumentPanelSearchController | null) => void;
      performSearchCommand: (
        command: LocalDocumentPanelSearchCommand
      ) => LocalDocumentPanelSearchState | null;
      subscribeReveal: (listener: RevealListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
const revealListeners = new Set<RevealListener>();
let currentBootstrap: LocalDocumentPanelBootstrap | null = null;
let currentRevealRequest: LocalDocumentLineRevealRequest | null = null;
let revealRequestID = 0;
let currentSearchState: LocalDocumentPanelSearchState = emptySearchState();
let currentSearchController: LocalDocumentPanelSearchController | null = null;
const diagnosticStringLimit = 2_000;

function emptySearchState(query = ""): LocalDocumentPanelSearchState {
  return {
    query,
    matchCount: 0,
    activeMatchIndex: null,
    matchFound: false
  };
}

function applyTheme(bootstrap: LocalDocumentPanelBootstrap | null) {
  if (!bootstrap) {
    return;
  }
  document.documentElement.dataset.theme = bootstrap.theme;
}

function applyTextScale(bootstrap: LocalDocumentPanelBootstrap | null) {
  document.documentElement.style.setProperty(
    "--toastty-markdown-text-scale",
    String(bootstrap?.textScale ?? 1)
  );
}

function warnOnContractMismatch(bootstrap: LocalDocumentPanelBootstrap) {
  if (bootstrap.contractVersion !== 6) {
    console.warn(
      `[ToasttyLocalDocumentPanel] Expected bootstrap contractVersion 6 but received ${bootstrap.contractVersion}.`
    );
  }
}

function truncateDiagnosticString(value: string): string {
  if (value.length <= diagnosticStringLimit) {
    return value;
  }
  return `${value.slice(0, diagnosticStringLimit - 1)}…`;
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
    return {
      message: truncateDiagnosticString(value),
      stack: null
    };
  }

  if (
    typeof value === "number" ||
    typeof value === "boolean" ||
    typeof value === "bigint" ||
    typeof value === "symbol"
  ) {
    return {
      message: String(value),
      stack: null
    };
  }

  if (value == null) {
    return {
      message: String(value),
      stack: null
    };
  }

  if (typeof value === "object") {
    if (seen.has(value)) {
      return {
        message: "[Circular]",
        stack: null
      };
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

  return {
    message: truncateDiagnosticString(String(value)),
    stack: null
  };
}

function describeConsoleArguments(args: unknown[]): string {
  if (args.length === 0) {
    return "";
  }

  return truncateDiagnosticString(
    args
      .map((value) => describeDiagnosticValue(value).message)
      .join(" ")
  );
}

function installDiagnosticsBridge() {
  if (window.__toasttyLocalDocumentDiagnosticsInstalled) {
    return;
  }
  window.__toasttyLocalDocumentDiagnosticsInstalled = true;

  const originalWarn = console.warn.bind(console);
  const originalError = console.error.bind(console);

  console.warn = (...args: unknown[]) => {
    localDocumentNativeBridge.consoleMessage("warn", describeConsoleArguments(args));
    originalWarn(...args);
  };

  console.error = (...args: unknown[]) => {
    localDocumentNativeBridge.consoleMessage("error", describeConsoleArguments(args));
    originalError(...args);
  };

  window.addEventListener("error", (event) => {
    const diagnostic = describeDiagnosticValue(event.error ?? event.message ?? "Unknown error");
    localDocumentNativeBridge.javascriptError(
      truncateDiagnosticString(event.message || diagnostic.message),
      event.filename || null,
      Number.isFinite(event.lineno) ? event.lineno : null,
      Number.isFinite(event.colno) ? event.colno : null,
      diagnostic.stack
    );
  });

  window.addEventListener("unhandledrejection", (event) => {
    const diagnostic = describeDiagnosticValue(event.reason);
    localDocumentNativeBridge.unhandledRejection(diagnostic.message, diagnostic.stack);
  });
}

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

function normalizedRevealLineNumber(lineNumber: number): number | null {
  const normalized = Number.isFinite(lineNumber) ? Math.floor(lineNumber) : Number.NaN;
  if (!Number.isFinite(normalized) || normalized < 1) {
    return null;
  }
  return normalized;
}

function notifyRevealListeners() {
  for (const listener of revealListeners) {
    listener(currentRevealRequest);
  }
}

installDiagnosticsBridge();

window.ToasttyLocalDocumentPanel = {
  receiveBootstrap(bootstrap) {
    currentBootstrap = bootstrap;
    warnOnContractMismatch(bootstrap);
    applyTheme(bootstrap);
    applyTextScale(bootstrap);
    notifyListeners();
  },
  setTextScale(textScale) {
    if (!currentBootstrap) {
      return;
    }
    currentBootstrap = { ...currentBootstrap, textScale };
    applyTextScale(currentBootstrap);
    notifyListeners();
  },
  revealLine(lineNumber) {
    const normalizedLineNumber = normalizedRevealLineNumber(lineNumber);
    if (normalizedLineNumber == null) {
      return;
    }

    currentRevealRequest = {
      requestID: ++revealRequestID,
      lineNumber: normalizedLineNumber
    };
    notifyRevealListeners();
  },
  getCurrentBootstrap() {
    return currentBootstrap;
  },
  getCurrentRevealRequest() {
    return currentRevealRequest;
  },
  consumeRevealRequest(requestID) {
    if (currentRevealRequest?.requestID !== requestID) {
      return;
    }
    currentRevealRequest = null;
    notifyRevealListeners();
  },
  getCurrentSearchState() {
    return currentSearchState;
  },
  setCurrentSearchState(searchState) {
    currentSearchState = searchState;
  },
  resetSearchState() {
    if (currentSearchController) {
      currentSearchState = currentSearchController.perform({ type: "clear" });
      return;
    }

    currentSearchState = emptySearchState();
  },
  registerSearchController(controller) {
    currentSearchController = controller;

    if (controller && currentSearchState.query.length > 0) {
      currentSearchState = controller.perform({
        type: "setQuery",
        query: currentSearchState.query
      });
    }
  },
  performSearchCommand(command) {
    if (!currentSearchController) {
      return null;
    }

    const nextState = currentSearchController.perform(command);
    currentSearchState = nextState;
    return nextState;
  },
  subscribe(listener) {
    listeners.add(listener);
    listener(currentBootstrap);
    return () => {
      listeners.delete(listener);
    };
  },
  subscribeReveal(listener) {
    revealListeners.add(listener);
    listener(currentRevealRequest);
    return () => {
      revealListeners.delete(listener);
    };
  }
};

localDocumentNativeBridge.bridgeReady();
