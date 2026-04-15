export type MarkdownPanelEvent =
  | { type: "enterEdit" }
  | { type: "draftDidChange"; content: string; baseContentRevision: number }
  | { type: "cancelEdit"; baseContentRevision: number };

interface WebKitMessageHandler {
  postMessage: (event: MarkdownPanelEvent) => void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, WebKitMessageHandler | undefined>;
    };
  }
}

const handlerName = "toasttyMarkdownPanel";

function postEvent(event: MarkdownPanelEvent) {
  window.webkit?.messageHandlers?.[handlerName]?.postMessage(event);
}

export const markdownNativeBridge = {
  enterEdit() {
    postEvent({ type: "enterEdit" });
  },
  draftDidChange(content: string, baseContentRevision: number) {
    postEvent({ type: "draftDidChange", content, baseContentRevision });
  },
  cancelEdit(baseContentRevision: number) {
    postEvent({ type: "cancelEdit", baseContentRevision });
  },
};
