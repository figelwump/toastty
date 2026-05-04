export type LocalDocumentPanelEvent =
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
  | {
      type: "unhandledRejection";
      reason: string;
      stack: string | null;
    }
  | {
      type: "renderReady";
      displayName: string;
      contentRevision: number;
      isEditing: boolean;
    }
  | { type: "searchControllerReady" }
  | { type: "searchControllerUnavailable" }
  | { type: "enterEdit" }
  | { type: "openInDefaultApp" }
  | { type: "draftDidChange"; content: string; baseContentRevision: number }
  | { type: "save"; baseContentRevision: number }
  | { type: "cancelEdit"; baseContentRevision: number }
  | { type: "overwriteAfterConflict"; baseContentRevision: number };

interface WebKitMessageHandler {
  postMessage: (event: LocalDocumentPanelEvent) => void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, WebKitMessageHandler | undefined>;
    };
  }
}

const handlerName = "toasttyLocalDocumentPanel";

function postEvent(event: LocalDocumentPanelEvent) {
  window.webkit?.messageHandlers?.[handlerName]?.postMessage(event);
}

export const localDocumentNativeBridge = {
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
  renderReady(displayName: string, contentRevision: number, isEditing: boolean) {
    postEvent({ type: "renderReady", displayName, contentRevision, isEditing });
  },
  searchControllerReady() {
    postEvent({ type: "searchControllerReady" });
  },
  searchControllerUnavailable() {
    postEvent({ type: "searchControllerUnavailable" });
  },
  enterEdit() {
    postEvent({ type: "enterEdit" });
  },
  openInDefaultApp() {
    postEvent({ type: "openInDefaultApp" });
  },
  draftDidChange(content: string, baseContentRevision: number) {
    postEvent({ type: "draftDidChange", content, baseContentRevision });
  },
  save(baseContentRevision: number) {
    postEvent({ type: "save", baseContentRevision });
  },
  cancelEdit(baseContentRevision: number) {
    postEvent({ type: "cancelEdit", baseContentRevision });
  },
  overwriteAfterConflict(baseContentRevision: number) {
    postEvent({ type: "overwriteAfterConflict", baseContentRevision });
  },
};
