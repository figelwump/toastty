import type { ChatEvent, ChatState } from "./types";

interface WebKitMessageHandler {
  postMessage: (event: ChatEvent) => void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: Record<string, WebKitMessageHandler | undefined> };
    toasttyCoordinatorChat?: { receive: (state: ChatState) => void };
  }
}

export function post(event: ChatEvent) {
  window.webkit?.messageHandlers?.toasttyCoordinatorChat?.postMessage(event);
}
