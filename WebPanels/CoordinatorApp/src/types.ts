// The chat's state as the app sends it. Swift builds it from the
// coordinator's transcript, its cards in events.jsonl and each task's live
// state, already in time order; the page only renders it.

export type Tone = "blue" | "amber" | "green" | "violet" | "red" | "plain" | "working";

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
  projectID?: string | null;
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
  /// The task is open, so the coordinator can pass a card reply on to it.
  canReply: boolean;
  failureText?: string | null;
  canArchive?: boolean;
}

export type CardKind = "packet" | "task-started" | "question" | "note";

export interface ChatThreadMessage {
  id: string;
  at: string;
  role: "user-task" | "user-coordinator" | "coordinator" | "agent";
  text: string;
}

export type ChatItem =
  | {
      type: "message";
      id: string;
      at: string;
      role: "user" | "assistant";
      text: string;
      /// Set on a question the user asked from a card: the task it is about.
      aboutTaskID?: string | null;
      aboutTitle?: string | null;
      /// An assistant message between tool calls, which the chat folds with
      /// them, or the turn's final message. Absent when the provider does
      /// not say; such a message shows.
      phase?: "commentary" | "final" | null;
      /// The automatic first message of a coordinator session; not shown.
      launch?: boolean | null;
    }
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
      /// Swift omits the key for a card with no task.
      task?: ChatTask | null;
      packet: ChatPacket | null;
      packetVersions?: number[];
      options: string[];
      /// Saved by the app after it accepts a question's answer.
      answer: string | null;
      /// Questions already answered for this task, including older cards.
      answeredQuestionIDs?: string[];
      /// A route answer whose delivery has not been resolved by the app.
      answerPending?: boolean;
      thread: ChatThreadMessage[];
      /// The app marks one current card per task, regardless of card kind.
      isCurrent: boolean;
    };

export type PageView = "chat" | "today" | "tasks";

export interface ChatProject {
  id: string;
  title: string;
  /// Native's normalized absolute root, while id keeps the stored identity.
  rootPath?: string | null;
}

export interface TasksFilter {
  /// The project's stable ID; null for every project.
  project: string | null;
  /// A stage group ID, such as "toShip" or "done".
  group: string;
}

export interface TaskGroup {
  id: string;
  title: string;
  /// Every task in the group; Done and Archived send only the newest rows.
  total: number;
}

export interface TaskAction {
  id: string;
  title: string;
  isDestructive: boolean;
}

/// A row of All tasks: what the sidebar's Needs you row shows, for any task.
export interface TaskRow {
  id: string;
  taskID: string | null;
  title: string;
  project: string | null;
  projectID?: string | null;
  group: string;
  stageLabel: string;
  stageTone: Tone;
  status: string;
  activityAt: string;
  /// Whether the chat has a card for the task, which Open shows.
  hasCard: boolean;
  primary: TaskAction | null;
  /// Asked before the primary action runs, as Merge asks.
  confirm: string | null;
  menu: TaskAction[][];
}

export interface ChatState {
  /// Excludes the automatic launch prompt; stays true after timeline trimming.
  hasUserRequests: boolean;
  addresses?: import("./composer").ComposerAddress[];
  coordinator: {
    title: string;
    detail: string;
    canSend: boolean;
    sendHint: string | null;
    hasTerminal: boolean;
    /// The coordinator's turn runs, as its sidebar row shows.
    working?: boolean;
    /// When that turn began, when the provider reports it.
    turnStartedAt?: string | null;
  };
  items: ChatItem[];
  projects: ChatProject[];
  /// Native resolves stored route values without changing project IDs.
  routeProjects?: { value: string; project: ChatProject }[];
  /// The window's shared project filter, using a stable project ID.
  projectFilter?: string | null;
  /// Native selects today's actual merge or release timestamps.
  today?: { completed: { rowID: string; kind: "merged" | "released"; at: string }[] };
  /// Set by `coordinator.chat.show --task`: the card to open and scroll to.
  /// A new token asks again for the same task.
  /// `cardID`, when set, is the task's newest card, a question, to open
  /// instead of its newest packet.
  focus: { taskID: string; token: number; cardID?: string | null } | null;
  /// A short line after an action, such as a failed send.
  notice: { text: string; isError: boolean; token: number } | null;
  /// Whether the send, reply or ask with `token` was taken.
  ack?: { token: number; ok: boolean } | null;
  /// Asks for chat, Today or All tasks; a new token asks again.
  /// A filter, from the sidebar's To ship and Done counts, shows one
  /// project's tasks with one group open.
  view?: { view: PageView; filter?: TasksFilter | null; token: number } | null;
  /// The stage groups, in order.
  taskGroups?: TaskGroup[];
  tasks?: TaskRow[];
}

export type ChatEvent =
  | { type: "ready" }
  | { type: "projectFilter"; project: string | null }
  | { type: "showView"; view: "today" | "tasks" }
  | { type: "activate"; view: PageView; selected: string | null }
  | { type: "rendered"; expanded: string[]; view: PageView; selected: string | null }
  | { type: "taskAction"; rowID: string; actionID: string }
  | { type: "send"; text: string; token: number }
  | { type: "project"; projectID: string; text: string; token: number }
  | { type: "ask"; taskID: string; version: number | null; text: string; token: number; cardID?: string; questionID?: string | null }
  | { type: "answerRoute"; questionID: string; optionIndex: number; token: number }
  | { type: "archiveTask"; taskID: string }
  | { type: "merge"; taskID: string }
  | { type: "taskMenu"; taskID: string; x: number; y: number; width: number; height: number }
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
  /// Drafts use task identity, so new cards retain them.
  drafts: Map<string, string>;
  /// The content the user was replying to when this draft began.
  draftContext: Map<string, { cardID: string; questionID: string | null; version: number | null; questionText: string | null }>;
  /// Task or route identities waiting for acknowledgement.
  pendingCards: Set<string>;
  confirmingMerge: string | null;
  /// Folds of the coordinator's work that the user opened.
  expandedWork: Set<string>;
  /// A message the user just sent to the coordinator, so the chat shows it
  /// working before the app reports the turn. `replies` are the final
  /// messages the chat had then; a new one ends the wait. `queued` is set
  /// while the message waits behind a turn that was running at the send.
  awaiting: { since: number; token: number; sawWorking: boolean; queued: boolean; replies: Set<string> } | null;
}

/// What the user is doing on All tasks.
export interface TasksUIState {
  /// The project ID shown, or null for all.
  project: string | null;
  selected: string | null;
  /// Groups the user opened or closed; Done and Archived start closed.
  toggledGroups: Set<string>;
  menuOpen: string | null;
  /// The question shown before a row's action, tied to that action: a
  /// refresh that changes the row's action closes it.
  confirming: { rowID: string; actionID: string } | null;
}

export interface ReportPacket {
  taskID: string;
  slug: string;
  canAnnotate: boolean;
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
