export type MarkdownPanelTheme = "light" | "dark";

export interface MarkdownPanelBootstrap {
  contractVersion: 4;
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
  textScale: number;
}

type BootstrapListener = (bootstrap: MarkdownPanelBootstrap | null) => void;

declare global {
  interface Window {
    ToasttyMarkdownPanel?: {
      receiveBootstrap: (bootstrap: MarkdownPanelBootstrap) => void;
      setTextScale: (textScale: number) => void;
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

function applyTextScale(bootstrap: MarkdownPanelBootstrap | null) {
  document.documentElement.style.setProperty(
    "--toastty-markdown-text-scale",
    String(bootstrap?.textScale ?? 1)
  );
}

function warnOnContractMismatch(bootstrap: MarkdownPanelBootstrap) {
  if (bootstrap.contractVersion !== 4) {
    console.warn(
      `[ToasttyMarkdownPanel] Expected bootstrap contractVersion 4 but received ${bootstrap.contractVersion}.`
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
    applyTextScale(bootstrap);
    notifyListeners();
  },
  setTextScale(textScale) {
    if (!currentBootstrap) {
      return;
    }
    currentBootstrap = { ...currentBootstrap, textScale };
    applyTextScale(currentBootstrap);
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
