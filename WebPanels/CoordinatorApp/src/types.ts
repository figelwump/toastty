// The chat's state as the app sends it. Swift builds it from the
// coordinator's transcript, its cards in events.jsonl and each task's live
// state, already in time order; the page only renders it.

export type Tone = "blue" | "amber" | "green" | "violet" | "red" | "plain";

export interface ChatCheck {
  name: string;
  ok: boolean;
  log: string | null;
}

export interface ChatScreenshot {
  name: string;
  pair: "before" | "after" | null;
  width: number | null;
  url: string;
}

export interface ChatPacket {
  version: number;
  latestVersion: number;
  summary: string;
  lookAt: string;
  checks: ChatCheck[];
  notVerified: string[];
  screenshots: ChatScreenshot[];
}

export interface ChatTask {
  id: string;
  title: string;
  slug: string;
  project: string | null;
  stageLabel: string;
  stageTone: Tone;
  needsUser: boolean;
  hasTaskSpace: boolean;
  pullRequestURL: string | null;
  pullRequestLabel: string | null;
  packetVersion: number | null;
  stale: boolean;
  /// What Merge does in this project, from tasks.toml.
  mergePolicy: string;
  canMerge: boolean;
  canReply: boolean;
}

export type CardKind = "packet" | "task-started" | "question" | "note";

export type ChatItem =
  | { type: "message"; id: string; at: string; role: "user" | "assistant"; text: string }
  | { type: "tool"; id: string; at: string; name: string; detail: string | null; outcome: "running" | "succeeded" | "failed" | "unknown" }
  | { type: "status"; id: string; at: string; text: string }
  | {
      type: "card";
      id: string;
      at: string;
      kind: CardKind;
      text: string | null;
      superseded: boolean;
      isNew: boolean;
      task: ChatTask | null;
      packet: ChatPacket | null;
    };

export interface ChatState {
  coordinator: {
    title: string;
    detail: string;
    canSend: boolean;
    sendHint: string | null;
    hasTerminal: boolean;
  };
  items: ChatItem[];
  /// Set by `coordinator.chat.show --task`: the card to open and scroll to.
  /// A new token asks again for the same task.
  focus: { taskID: string; token: number } | null;
  /// A short line after an action, such as a failed send.
  notice: { text: string; isError: boolean; token: number } | null;
  /// Whether the send, reply or ask with `token` was taken.
  ack?: { token: number; ok: boolean } | null;
}

export type ChatEvent =
  | { type: "ready" }
  | { type: "rendered"; expanded: string[] }
  | { type: "send"; text: string; token: number }
  | { type: "reply"; taskID: string; version: number; text: string; token: number }
  | { type: "ask"; taskID: string; version: number | null; text: string; token: number }
  | { type: "merge"; taskID: string }
  | { type: "openTaskSpace"; taskID: string }
  | { type: "openURL"; url: string }
  | { type: "openReport"; taskID: string; version: number; screenshot: string | null }
  | { type: "openRouting" }
  | { type: "openTerminal" };

/// The page's own state: which cards are open, what is being typed.
export interface ChatUIState {
  expanded: Set<string>;
  /// Cards seen superseded, so each folds only once.
  superseded: Set<string>;
  /// What is typed in each card's reply box, kept while the card is closed.
  drafts: Map<string, string>;
  replyTarget: Map<string, "task" | "coordinator">;
  confirmingMerge: string | null;
}

export interface ReportPacket {
  taskID: string;
  title: string;
  version: number;
  latestVersion: number;
  summary: string;
  lookAt: string;
  checks: ChatCheck[];
  notVerified: string[];
  screenshots: ChatScreenshot[];
  headCommit: string | null;
  createdAt: string | null;
}
