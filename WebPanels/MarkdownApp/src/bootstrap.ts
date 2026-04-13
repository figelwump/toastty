export type MarkdownPanelMode = "view";

export interface MarkdownPanelBootstrap {
  contractVersion: 1;
  mode: MarkdownPanelMode;
  filePath: string;
  displayName: string;
  content: string;
}

type BootstrapListener = (bootstrap: MarkdownPanelBootstrap | null) => void;

declare global {
  interface Window {
    ToasttyMarkdownPanel?: {
      receiveBootstrap: (bootstrap: MarkdownPanelBootstrap) => void;
      getCurrentBootstrap: () => MarkdownPanelBootstrap | null;
      subscribe: (listener: BootstrapListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
let currentBootstrap: MarkdownPanelBootstrap | null = null;

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

window.ToasttyMarkdownPanel = {
  receiveBootstrap(bootstrap) {
    currentBootstrap = bootstrap;
    notifyListeners();
  },
  getCurrentBootstrap() {
    return currentBootstrap;
  },
  subscribe(listener) {
    listeners.add(listener);
    listener(currentBootstrap);
    return () => {
      listeners.delete(listener);
    };
  }
};
