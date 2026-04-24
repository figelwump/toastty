export type ScratchpadPanelEvent =
  | { type: "bridgeReady" }
  | { type: "consoleMessage"; level: "info" | "warn" | "error"; message: string }
  | {
      type: "javascriptError";
      message: string;
      source: string | null;
      line: number | null;
      column: number | null;
      stack: string | null;
    }
  | { type: "unhandledRejection"; reason: string; stack: string | null }
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
  consoleMessage(level: "info" | "warn" | "error", message: string) {
    postEvent({ type: "consoleMessage", level, message });
  },
  javascriptError(
    message: string,
    source: string | null,
    line: number | null,
    column: number | null,
    stack: string | null
  ) {
    postEvent({ type: "javascriptError", message, source, line, column, stack });
  },
  unhandledRejection(reason: string, stack: string | null) {
    postEvent({ type: "unhandledRejection", reason, stack });
  },
  renderReady(displayName: string, revision: number | null) {
    postEvent({ type: "renderReady", displayName, revision });
  }
};
