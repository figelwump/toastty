// The coordinator chat page. The app pushes its whole state with
// `window.toasttyCoordinatorChat.receive(state)`; the page sends actions back
// through the `toasttyCoordinatorChat` message handler. The page keeps only
// what the user is doing here: open cards, typed replies, the merge confirm.
import { collapseNewlySuperseded, fitsMessage, focusCardID, newUIState, renderHeader, renderTimeline } from "./render";
import { moveSelection, navigableRows, newTasksUIState, normalize, renderTasks } from "./tasks";
import type { ChatEvent, ChatState, PageView } from "./types";

interface WebKitMessageHandler {
  postMessage: (event: ChatEvent) => void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: Record<string, WebKitMessageHandler | undefined> };
    toasttyCoordinatorChat?: { receive: (state: ChatState) => void };
  }
}

function post(event: ChatEvent) {
  window.webkit?.messageHandlers?.toasttyCoordinatorChat?.postMessage(event);
}

const ui = newUIState();
const tasksUI = newTasksUIState();
let view: PageView = "chat";
let state: ChatState | null = null;
let lastFocusToken: number | null = null;
let lastViewToken: number | null = null;
let lastNoticeToken: number | null = null;
let nextToken = 1;
/// Sends waiting for the app's answer: what to clear once it is taken.
const pendingSends = new Map<number, { draftKey: string }>();
const composerDraftKey = "composer";

const header = document.getElementById("header")!;
const scroll = document.getElementById("scroll")!;
const tasksView = document.getElementById("tasks")!;
const composer = document.getElementById("composer") as HTMLFormElement;
const composerInput = composer.querySelector("textarea") as HTMLTextAreaElement;
const composerHint = document.getElementById("composer-hint")!;
const notice = document.getElementById("notice")!;

function render() {
  if (!state) return;
  header.innerHTML = renderHeader(state, view);
  scroll.classList.toggle("hidden", view !== "chat");
  composer.classList.toggle("hidden", view !== "chat");
  tasksView.classList.toggle("hidden", view !== "tasks");
  normalize(state, tasksUI);
  if (view === "tasks") {
    tasksView.innerHTML = renderTasks(state, tasksUI, new Date());
    post({ type: "rendered", expanded: [...ui.expanded], view, selected: tasksUI.selected });
    return;
  }

  // Re-rendering replaces the reply boxes; drafts live in `ui.drafts`, so
  // only focus needs carrying over.
  const focusedForm = (document.activeElement as HTMLElement | null)?.closest<HTMLFormElement>("form.replybox")?.dataset.id;
  const nearBottom = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 80;

  scroll.innerHTML = renderTimeline(state, ui);

  if (focusedForm) {
    scroll.querySelector<HTMLFormElement>(`form.replybox[data-id="${CSS.escape(focusedForm)}"]`)?.querySelector("input")?.focus();
  }
  if (nearBottom) scroll.scrollTop = scroll.scrollHeight;

  post({ type: "rendered", expanded: [...ui.expanded], view, selected: tasksUI.selected });
  composerInput.disabled = !state.coordinator.canSend;
  composerHint.textContent = state.coordinator.sendHint ?? "";
  composerInput.placeholder = state.coordinator.canSend ? "Tell the coordinator…" : state.coordinator.sendHint ?? "The coordinator is not running";
}

function receive(next: ChatState) {
  state = next;
  collapseNewlySuperseded(next, ui);
  if (next.ack && pendingSends.has(next.ack.token)) {
    const sent = pendingSends.get(next.ack.token)!;
    pendingSends.delete(next.ack.token);
    if (next.ack.ok) {
      ui.drafts.delete(sent.draftKey);
      if (sent.draftKey === composerDraftKey) composerInput.value = "";
    }
  }
  // The newer of a view request and a card focus decides the view: a page
  // that opens later gets both, with the older still set.
  const newView = next.view && next.view.token !== lastViewToken ? next.view : null;
  const newFocus = next.focus && next.focus.token !== lastFocusToken ? next.focus : null;
  if (newView) {
    lastViewToken = newView.token;
    if (!newFocus || newView.token > newFocus.token) setView(newView.view);
  }
  if (newFocus) {
    lastFocusToken = newFocus.token;
    if (!newView || newFocus.token > newView.token) view = "chat";
    const id = focusCardID(next, next.focus.taskID);
    if (id) {
      // Last in the set, so the app reads it as the card opened last.
      ui.expanded.delete(id);
      ui.expanded.add(id);
      render();
      const element = document.getElementById(`card-${id}`);
      element?.scrollIntoView({ block: "center" });
      element?.classList.add("flash");
      setTimeout(() => element?.classList.remove("flash"), 1200);
      return;
    }
  }
  if (next.notice && next.notice.token !== lastNoticeToken) {
    lastNoticeToken = next.notice.token;
    notice.textContent = next.notice.text;
    notice.className = next.notice.isError ? "notice error" : "notice";
    setTimeout(() => { if (lastNoticeToken === next.notice?.token) notice.className = "notice hidden"; }, 6000);
  }
  render();
}

function setView(next: PageView) {
  view = next;
  // The composer hides on All tasks; it must not keep the keyboard, or the
  // arrow keys would go to it.
  if (view === "tasks" && document.activeElement === composerInput) composerInput.blur();
  if (view === "tasks" && state && tasksUI.selected === null) {
    tasksUI.selected = navigableRows(state, tasksUI)[0]?.id ?? null;
  }
}

function taskRow(id: string | undefined) {
  return state?.tasks?.find((row) => row.id === id) ?? null;
}

function runTaskAction(rowID: string, actionID: string) {
  tasksUI.menuOpen = null;
  tasksUI.confirming = null;
  post({ type: "taskAction", rowID, actionID });
  render();
}

document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target || target.tagName === "FORM") return;
  const data = target.dataset;
  switch (data.act) {
    case "view":
      setView(data.view === "tasks" ? "tasks" : "chat");
      render();
      if (view === "chat") composerInput.focus();
      break;
    case "task-select":
      tasksUI.selected = data.id!;
      tasksUI.menuOpen = null;
      render();
      break;
    case "task-primary": {
      const row = taskRow(data.id);
      if (!row?.primary) break;
      tasksUI.selected = row.id;
      if (row.confirm) {
        tasksUI.menuOpen = null;
        tasksUI.confirming = { rowID: row.id, actionID: row.primary.id };
        render();
      } else {
        runTaskAction(row.id, row.primary.id);
      }
      break;
    }
    case "task-menu":
      tasksUI.selected = data.id!;
      tasksUI.menuOpen = tasksUI.menuOpen === data.id ? null : data.id!;
      tasksUI.confirming = null;
      render();
      break;
    case "task-action":
      runTaskAction(data.id!, data.action!);
      break;
    case "task-cancel":
      tasksUI.confirming = null;
      render();
      break;
    case "task-filter":
      tasksUI.project = data.project ?? null;
      render();
      break;
    case "task-group": {
      const group = data.group!;
      if (tasksUI.toggledGroups.has(group)) tasksUI.toggledGroups.delete(group);
      else tasksUI.toggledGroups.add(group);
      render();
      break;
    }
    case "expand": {
      const id = data.id!;
      if (ui.expanded.has(id)) ui.expanded.delete(id);
      else ui.expanded.add(id);
      if (ui.confirmingMerge === id) ui.confirmingMerge = null;
      render();
      break;
    }
    case "reply-to":
      ui.replyTarget.set(data.id!, data.to === "coordinator" ? "coordinator" : "task");
      render();
      break;
    case "merge":
      ui.confirmingMerge = data.id!;
      render();
      break;
    case "merge-cancel":
      ui.confirmingMerge = null;
      render();
      break;
    case "merge-go":
      ui.confirmingMerge = null;
      post({ type: "merge", taskID: data.task! });
      render();
      break;
    case "open-task":
      post({ type: "openTaskSpace", taskID: data.task! });
      break;
    case "open-url":
      post({ type: "openURL", url: data.url! });
      break;
    case "open-report":
      post({ type: "openReport", taskID: data.task!, version: Number(data.version), screenshot: data.shot ?? null });
      break;
    case "open-routing":
      post({ type: "openRouting" });
      break;
    case "open-terminal":
      post({ type: "openTerminal" });
      break;
  }
});

document.addEventListener("submit", (event) => {
  const form = event.target as HTMLFormElement;
  event.preventDefault();
  if (form === composer) {
    sendComposer();
    return;
  }
  if (!form.classList.contains("replybox")) return;
  const input = form.querySelector("input")!;
  const text = input.value.trim();
  if (!text || !checkLength(text)) return;
  const version = form.dataset.version ? Number(form.dataset.version) : null;
  const token = track(form.dataset.id!);
  if (form.dataset.to === "task" && version !== null) {
    post({ type: "reply", taskID: form.dataset.task!, version, text, token });
  } else {
    post({ type: "ask", taskID: form.dataset.task!, version, text, token });
  }
});

// Drafts survive re-renders and closing the card.
document.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  const form = input.closest<HTMLFormElement>("form.replybox");
  if (form) ui.drafts.set(form.dataset.id!, input.value);
});

function track(draftKey: string): number {
  const token = nextToken++;
  pendingSends.set(token, { draftKey });
  return token;
}

function checkLength(text: string): boolean {
  if (fitsMessage(text)) return true;
  notice.textContent = "That message is too long to send. Shorten it to 16 KB or less.";
  notice.className = "notice error";
  return false;
}

function sendComposer() {
  const text = composerInput.value.trim();
  if (!text || composerInput.disabled || !checkLength(text)) return;
  post({ type: "send", text, token: track(composerDraftKey) });
  scroll.scrollTop = scroll.scrollHeight;
}

composerInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    sendComposer();
  }
});

// All tasks: the arrow keys move the selection, Return opens the task, and
// Esc closes an open menu or question.
document.addEventListener("keydown", (event) => {
  if (view !== "tasks" || !state || event.isComposing) return;
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if ((event.target as HTMLElement).closest("input, textarea")) return;
  if (event.key === "Escape" && (tasksUI.menuOpen || tasksUI.confirming)) {
    tasksUI.menuOpen = null;
    tasksUI.confirming = null;
    render();
  } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    tasksUI.selected = moveSelection(state, tasksUI, event.key === "ArrowDown" ? 1 : -1);
    tasksUI.menuOpen = null;
    render();
    if (tasksUI.selected) document.getElementById(`task-row-${tasksUI.selected}`)?.scrollIntoView({ block: "nearest" });
  } else if (event.key === "Enter" && tasksUI.selected && !(event.target as HTMLElement).closest("button")) {
    event.preventDefault();
    runTaskAction(tasksUI.selected, "open");
  }
});

window.toasttyCoordinatorChat = { receive };
post({ type: "ready" });
