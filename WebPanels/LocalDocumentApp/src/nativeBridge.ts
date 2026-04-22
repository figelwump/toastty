export type LocalDocumentPanelEvent =
  | { type: "bridgeReady" }
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
