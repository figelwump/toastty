export type ScratchpadDiagnosticSource = "panel" | "generated-content";

export type ScratchpadPanelEvent =
  | { type: "bridgeReady" }
  | {
      type: "consoleMessage";
      level: "info" | "warn" | "error";
      message: string;
      diagnosticSource: ScratchpadDiagnosticSource;
    }
  | {
      type: "javascriptError";
      message: string;
      source: string | null;
      line: number | null;
      column: number | null;
      stack: string | null;
      diagnosticSource: ScratchpadDiagnosticSource;
    }
  | {
      type: "unhandledRejection";
      reason: string;
      stack: string | null;
      diagnosticSource: ScratchpadDiagnosticSource;
    }
  | {
      type: "cspViolation";
      violatedDirective: string;
      effectiveDirective: string;
      blockedURI: string | null;
      sourceFile: string | null;
      line: number | null;
      column: number | null;
      disposition: string | null;
      diagnosticSource: ScratchpadDiagnosticSource;
    }
  | { type: "renderReady"; displayName: string; revision: number | null };

interface WebKitMessageHandler {
  postMessage: (event: ScratchpadPanelEvent) => void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, WebKitMessageHandler | undefined>;
    };
  }
}

const handlerName = "toasttyScratchpadPanel";

function postEvent(event: ScratchpadPanelEvent) {
  window.webkit?.messageHandlers?.[handlerName]?.postMessage(event);
}

export const scratchpadNativeBridge = {
  bridgeReady() {
    postEvent({ type: "bridgeReady" });
  },
  consoleMessage(
    level: "info" | "warn" | "error",
    message: string,
    diagnosticSource: ScratchpadDiagnosticSource = "panel"
  ) {
    postEvent({ type: "consoleMessage", level, message, diagnosticSource });
  },
  javascriptError(
    message: string,
    source: string | null,
    line: number | null,
    column: number | null,
    stack: string | null,
    diagnosticSource: ScratchpadDiagnosticSource = "panel"
  ) {
    postEvent({
      type: "javascriptError",
      message,
      source,
      line,
      column,
      stack,
      diagnosticSource
    });
  },
  unhandledRejection(
    reason: string,
    stack: string | null,
    diagnosticSource: ScratchpadDiagnosticSource = "panel"
  ) {
    postEvent({ type: "unhandledRejection", reason, stack, diagnosticSource });
  },
  cspViolation(
    violatedDirective: string,
    effectiveDirective: string,
    blockedURI: string | null,
    sourceFile: string | null,
    line: number | null,
    column: number | null,
    disposition: string | null,
    diagnosticSource: ScratchpadDiagnosticSource = "panel"
  ) {
    postEvent({
      type: "cspViolation",
      violatedDirective,
      effectiveDirective,
      blockedURI,
      sourceFile,
      line,
      column,
      disposition,
      diagnosticSource
    });
  },
  renderReady(displayName: string, revision: number | null) {
    postEvent({ type: "renderReady", displayName, revision });
  }
};
