// Folds the coordinator's work so the chat reads as requests, replies and
// cards. Work is its tool calls and the messages it writes between them,
// which Claude marks `commentary`; a turn's final message stays visible.
import type { ChatItem } from "./types";

type Message = Extract<ChatItem, { type: "message" }>;

/// One run of work: from a request, or from the reply before it, to the
/// next reply. A card posted meanwhile stays outside the fold.
export interface WorkFold {
  /// The first work item's ID: stable while the fold grows.
  id: string;
  items: ChatItem[];
  toolCount: number;
  noteCount: number;
  /// The request's time, else the first work item's.
  startedAt: string;
  /// The reply's time once there is one, else the last work item's.
  endedAt: string;
  /// The coordinator is still working on it.
  live: boolean;
}

export type TimelineEntry =
  | { type: "item"; item: ChatItem }
  | { type: "work"; fold: WorkFold };

function isWork(item: ChatItem): boolean {
  return item.type === "tool" || (item.type === "message" && item.role === "assistant" && item.phase === "commentary");
}

/// The timeline with each run of work folded. `working` says whether the
/// coordinator's turn runs now, which makes the last open run live, unless
/// that run's steps all came before the turn began.
export function foldWork(items: ChatItem[], working: boolean, turnStartedAt?: string | null): TimelineEntry[] {
  const entries: TimelineEntry[] = [];
  // Runs still waiting for a reply, with where their run ends in `entries`.
  const unanswered: { fold: WorkFold; end: number }[] = [];
  let fold: WorkFold | null = null;
  let requestAt: string | null = null;
  const end = () => {
    if (fold) unanswered.push({ fold, end: entries.length });
    fold = null;
  };
  for (const item of items) {
    if (isWork(item)) {
      if (!fold) {
        fold = { id: item.id, items: [], toolCount: 0, noteCount: 0, startedAt: requestAt ?? item.at, endedAt: item.at, live: false };
        entries.push({ type: "work", fold });
      }
      fold.items.push(item);
      if (item.type === "tool") fold.toolCount++;
      else fold.noteCount++;
      fold.endedAt = item.at;
      continue;
    }
    if (item.type === "message") {
      if (item.role === "user") {
        end();
        requestAt = item.at;
      } else {
        // The reply ends the run; work after it, as after a background
        // task wakes the coordinator, starts a new one.
        if (fold) (fold as WorkFold).endedAt = item.at;
        fold = null;
        requestAt = null;
      }
    }
    entries.push({ type: "item", item });
  }
  const last = fold as WorkFold | null;
  const started = turnStartedAt ? Date.parse(turnStartedAt) : Number.NaN;
  if (last && working && !(Date.parse(last.endedAt) < started)) last.live = true;
  else end();
  // A run that ended with no reply, as when the user stopped the turn,
  // shows its last message so the chat still says where it stopped.
  for (const { fold: open, end: index } of unanswered.reverse()) {
    const at = open.items.findLastIndex((item) => item.type === "message");
    if (at < 0) continue;
    const [message] = open.items.splice(at, 1);
    open.noteCount--;
    entries.splice(index, 0, { type: "item", item: message });
  }
  return entries.filter((entry) => entry.type === "item" || entry.fold.items.length > 0);
}

/// The live run's latest step: its newest message, which says what the
/// coordinator is doing in words, else its running tool.
export function latestStep(fold: WorkFold): string | null {
  const items = [...fold.items].reverse();
  const message = items.find((item): item is Message => item.type === "message");
  if (message) return firstLine(message.text);
  const tool = items.find((item) => item.type === "tool" && item.outcome === "running");
  return tool?.type === "tool" ? [tool.name, tool.detail].filter(Boolean).join(" ") : null;
}

function firstLine(text: string): string {
  return text.split("\n").find((line) => line.trim())?.trim() ?? "";
}

/// "48s" or "3m 05s", as the iPhone app shows a turn's time.
export function durationLabel(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(Number.isFinite(milliseconds) ? milliseconds / 1000 : 0));
  const minutes = Math.floor(seconds / 60);
  return minutes > 0 ? `${minutes}m ${String(seconds % 60).padStart(2, "0")}s` : `${seconds}s`;
}
