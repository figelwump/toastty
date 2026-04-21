export type LocalDocumentPanelTheme = "light" | "dark";
export type LocalDocumentHighlightState =
  | "enabled"
  | "disabledForLargeFile"
  | "unsupportedFormat"
  | "unavailable";
export type LocalDocumentSyntaxLanguage =
  | "yaml"
  | "toml"
  | "json"
  | "xml"
  | "bash"
  | "swift"
  | "javascript"
  | "typescript"
  | "python"
  | "go"
  | "rust";
export type LocalDocumentFormat =
  | "markdown"
  | "yaml"
  | "toml"
  | "json"
  | "jsonl"
  | "config"
  | "csv"
  | "tsv"
  | "xml"
  | "shell"
  | "code";

export interface LocalDocumentPanelBootstrap {
  contractVersion: 6;
  filePath: string | null;
  displayName: string;
  format: LocalDocumentFormat;
  syntaxLanguage: LocalDocumentSyntaxLanguage | null;
  formatLabel: string;
  shouldHighlight: boolean;
  highlightState: LocalDocumentHighlightState;
  content: string;
  contentRevision: number;
  isEditing: boolean;
  isDirty: boolean;
  hasExternalConflict: boolean;
  isSaving: boolean;
  saveErrorMessage: string | null;
  theme: LocalDocumentPanelTheme;
  textScale: number;
}

type BootstrapListener = (bootstrap: LocalDocumentPanelBootstrap | null) => void;

declare global {
  interface Window {
    ToasttyLocalDocumentPanel?: {
      receiveBootstrap: (bootstrap: LocalDocumentPanelBootstrap) => void;
      setTextScale: (textScale: number) => void;
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

function applyTextScale(bootstrap: LocalDocumentPanelBootstrap | null) {
  document.documentElement.style.setProperty(
    "--toastty-markdown-text-scale",
    String(bootstrap?.textScale ?? 1)
  );
}

function warnOnContractMismatch(bootstrap: LocalDocumentPanelBootstrap) {
  if (bootstrap.contractVersion !== 6) {
    console.warn(
      `[ToasttyLocalDocumentPanel] Expected bootstrap contractVersion 6 but received ${bootstrap.contractVersion}.`
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
