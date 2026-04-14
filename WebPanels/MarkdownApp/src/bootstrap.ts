export type MarkdownPanelMode = "view";
export type MarkdownPanelTheme = "light" | "dark";

export interface MarkdownPanelBootstrap {
  contractVersion: 2;
  mode: MarkdownPanelMode;
  filePath: string;
  displayName: string;
  content: string;
  theme: MarkdownPanelTheme;
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

function applyTheme(bootstrap: MarkdownPanelBootstrap | null) {
  if (!bootstrap) {
    return;
  }
  document.documentElement.dataset.theme = bootstrap.theme;
}

function warnOnContractMismatch(bootstrap: MarkdownPanelBootstrap) {
  if (bootstrap.contractVersion !== 2) {
    console.warn(
      `[ToasttyMarkdownPanel] Expected bootstrap contractVersion 2 but received ${bootstrap.contractVersion}.`
    );
  }
}

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

window.ToasttyMarkdownPanel = {
  receiveBootstrap(bootstrap) {
    currentBootstrap = bootstrap;
    warnOnContractMismatch(bootstrap);
    applyTheme(bootstrap);
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
