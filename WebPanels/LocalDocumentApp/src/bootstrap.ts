export type LocalDocumentPanelTheme = "light" | "dark";

export interface LocalDocumentPanelBootstrap {
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
  theme: LocalDocumentPanelTheme;
}

type BootstrapListener = (bootstrap: LocalDocumentPanelBootstrap | null) => void;

declare global {
  interface Window {
    ToasttyLocalDocumentPanel?: {
      receiveBootstrap: (bootstrap: LocalDocumentPanelBootstrap) => void;
      getCurrentBootstrap: () => LocalDocumentPanelBootstrap | null;
      subscribe: (listener: BootstrapListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
let currentBootstrap: LocalDocumentPanelBootstrap | null = null;

function applyTheme(bootstrap: LocalDocumentPanelBootstrap | null) {
  if (!bootstrap) {
    return;
  }
  document.documentElement.dataset.theme = bootstrap.theme;
}

function warnOnContractMismatch(bootstrap: LocalDocumentPanelBootstrap) {
  if (bootstrap.contractVersion !== 3) {
    console.warn(
      `[ToasttyLocalDocumentPanel] Expected bootstrap contractVersion 3 but received ${bootstrap.contractVersion}.`
    );
  }
}

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

window.ToasttyLocalDocumentPanel = {
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
