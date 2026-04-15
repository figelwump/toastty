export type MarkdownPanelTheme = "light" | "dark";

export interface MarkdownPanelBootstrap {
  contractVersion: 3;
  filePath: string | null;
  displayName: string;
  content: string;
  contentRevision: number;
  isEditing: boolean;
  isDirty: boolean;
  hasExternalConflict: boolean;
  isSaving: boolean;
  saveErrorMessage: string | null;
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
  if (bootstrap.contractVersion !== 3) {
    console.warn(
      `[ToasttyMarkdownPanel] Expected bootstrap contractVersion 3 but received ${bootstrap.contractVersion}.`
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
