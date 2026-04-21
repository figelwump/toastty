export type LocalDocumentPanelTheme = "light" | "dark";
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
  | "shell";

export interface LocalDocumentPanelBootstrap {
  contractVersion: 4;
  filePath: string | null;
  displayName: string;
  format: LocalDocumentFormat;
  shouldHighlight: boolean;
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
export interface LocalDocumentLineRevealRequest {
  requestID: number;
  lineNumber: number;
}
type RevealListener = (request: LocalDocumentLineRevealRequest | null) => void;

declare global {
  interface Window {
    ToasttyLocalDocumentPanel?: {
      receiveBootstrap: (bootstrap: LocalDocumentPanelBootstrap) => void;
      setTextScale: (textScale: number) => void;
      revealLine: (lineNumber: number) => void;
      getCurrentBootstrap: () => LocalDocumentPanelBootstrap | null;
      getCurrentRevealRequest: () => LocalDocumentLineRevealRequest | null;
      consumeRevealRequest: (requestID: number) => void;
      subscribe: (listener: BootstrapListener) => () => void;
      subscribeReveal: (listener: RevealListener) => () => void;
    };
  }
}

const listeners = new Set<BootstrapListener>();
const revealListeners = new Set<RevealListener>();
let currentBootstrap: LocalDocumentPanelBootstrap | null = null;
let currentRevealRequest: LocalDocumentLineRevealRequest | null = null;
let revealRequestID = 0;

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
  if (bootstrap.contractVersion !== 4) {
    console.warn(
      `[ToasttyLocalDocumentPanel] Expected bootstrap contractVersion 4 but received ${bootstrap.contractVersion}.`
    );
  }
}

function notifyListeners() {
  for (const listener of listeners) {
    listener(currentBootstrap);
  }
}

function normalizedRevealLineNumber(lineNumber: number): number | null {
  const normalized = Number.isFinite(lineNumber) ? Math.floor(lineNumber) : Number.NaN;
  if (!Number.isFinite(normalized) || normalized < 1) {
    return null;
  }
  return normalized;
}

function notifyRevealListeners() {
  for (const listener of revealListeners) {
    listener(currentRevealRequest);
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
  revealLine(lineNumber) {
    const normalizedLineNumber = normalizedRevealLineNumber(lineNumber);
    if (normalizedLineNumber == null) {
      return;
    }

    currentRevealRequest = {
      requestID: ++revealRequestID,
      lineNumber: normalizedLineNumber
    };
    notifyRevealListeners();
  },
  getCurrentBootstrap() {
    return currentBootstrap;
  },
  getCurrentRevealRequest() {
    return currentRevealRequest;
  },
  consumeRevealRequest(requestID) {
    if (currentRevealRequest?.requestID !== requestID) {
      return;
    }
    currentRevealRequest = null;
    notifyRevealListeners();
  },
  subscribe(listener) {
    listeners.add(listener);
    listener(currentBootstrap);
    return () => {
      listeners.delete(listener);
    };
  },
  subscribeReveal(listener) {
    revealListeners.add(listener);
    listener(currentRevealRequest);
    return () => {
      revealListeners.delete(listener);
    };
  }
};
