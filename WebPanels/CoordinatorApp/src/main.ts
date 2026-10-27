// The coordinator chat page. The app pushes its whole state with
// `window.toasttyCoordinatorChat.receive(state)`; the page sends actions back
// through the `toasttyCoordinatorChat` message handler. The page keeps only
// what the user is doing here: open cards, typed replies, the merge confirm.
import { cardStateKey, collapseNewlySuperseded, fitsMessage, focusCardID, newUIState, renderHeader, renderTimeline, replyTarget, retainTaskCards } from "./render";
import { applyFilter, moveSelection, navigableRows, newTasksUIState, normalize, renderTasks } from "./tasks";
import type { ChatEvent, ChatItem, ChatState, PageView } from "./types";

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
const pendingSends = new Map<number, { draftKey: string | null; draftText: string | null; pendingKey?: string; questionID: string | null }>();
const composerDraftKey = "composer";

const header = document.getElementById("header")!;
const scroll = document.getElementById("scroll")!;
const tasksView = document.getElementById("tasks")!;
const composer = document.getElementById("composer") as HTMLFormElement;
const composerInput = composer.querySelector("textarea") as HTMLTextAreaElement;
const composerHint = document.getElementById("composer-hint-text")!;
const composerTerminal = document.getElementById("composer-open-terminal")!;
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

  // Re-rendering replaces reply boxes. Keep input selection and the visible
  // card's offset along with its stored draft.
  const focused = document.activeElement as HTMLInputElement | null;
  const focusedForm = focused?.closest<HTMLFormElement>("form.replybox");
  const focusedCard = focusedForm?.dataset.task ? focusCardID(state, focusedForm.dataset.task) : focusedForm?.dataset.id;
  const selection = focusedForm && focused ? { start: focused.selectionStart, end: focused.selectionEnd, direction: focused.selectionDirection } : null;
  const nearBottom = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 80;
  const previousTop = scroll.scrollTop;
  const viewport = scroll.getBoundingClientRect();
  const anchors = [...scroll.querySelectorAll<HTMLElement>("[data-item]")]
    .filter((element) => {
      const bounds = element.getBoundingClientRect();
      return bounds.bottom > viewport.top && bounds.top < viewport.top + scroll.clientHeight;
    })
    .map((element) => ({ id: element.dataset.item, top: element.getBoundingClientRect().top }));
  const focusedAnchor = focusedForm?.dataset.id
    ? anchors.find((anchor) => anchor.id === focusedForm.dataset.id) : null;
  scroll.innerHTML = renderTimeline(state, ui);

  if (focusedCard) {
    const input = scroll.querySelector<HTMLFormElement>(`form.replybox[data-id="${CSS.escape(focusedCard)}"]`)?.querySelector("input");
    input?.focus({ preventScroll: true });
    if (input && selection?.start != null && selection.end != null) input.setSelectionRange(selection.start, selection.end, selection.direction ?? undefined);
  }
  if (nearBottom) scroll.scrollTop = scroll.scrollHeight;
  else {
    const candidates = focusedCard && focusedAnchor ? [{ id: focusedCard, top: focusedAnchor.top }, ...anchors] : anchors;
    const anchor = candidates.map((anchor) => ({ ...anchor, element: anchor.id ? scroll.querySelector<HTMLElement>(`[data-item="${CSS.escape(anchor.id)}"]`) : null }))
      .find((anchor) => anchor.element !== null);
    scroll.scrollTop = previousTop + (anchor?.element ? anchor.element.getBoundingClientRect().top - anchor.top : 0);
  }

  post({ type: "rendered", expanded: [...ui.expanded], view, selected: tasksUI.selected });
  composerInput.disabled = !state.coordinator.canSend;
  composerHint.textContent = state.coordinator.sendHint ?? "";
  composerTerminal.classList.toggle("hidden", state.coordinator.canSend || !state.coordinator.hasTerminal);
  composerInput.placeholder = state.coordinator.canSend ? "Tell the coordinator…" : state.coordinator.sendHint ?? "The coordinator is not running";
}

function receive(next: ChatState) {
  retainTaskCards(state, next, ui);
  state = next;
  collapseNewlySuperseded(next, ui);
  if (next.ack && pendingSends.has(next.ack.token)) {
    const sent = pendingSends.get(next.ack.token)!;
    pendingSends.delete(next.ack.token);
    if (sent.pendingKey) ui.pendingCards.delete(sent.pendingKey);
    if (next.ack.ok && sent.pendingKey && sent.questionID) markDraftAsFollowup(sent.pendingKey, sent.questionID);
    if (next.ack.ok && sent.draftKey !== null) {
      if (sent.draftKey === composerDraftKey) {
        if (composerInput.value === sent.draftText) composerInput.value = "";
      } else if (ui.drafts.get(sent.draftKey) === sent.draftText) {
        ui.drafts.delete(sent.draftKey);
        ui.draftContext.delete(sent.draftKey);
      }
    }
  }
  for (const item of next.items) {
    if (item.type !== "card" || !item.task) continue;
    if (item.kind === "question" && item.answer !== null) markDraftAsFollowup(cardStateKey(item), item.id);
    for (const questionID of item.answeredQuestionIDs ?? []) markDraftAsFollowup(cardStateKey(item), questionID);
  }
  // The newer of a view request and a card focus decides the view: a page
  // that opens later gets both, with the older still set.
  const newView = next.view && next.view.token !== lastViewToken ? next.view : null;
  const newFocus = next.focus && next.focus.token !== lastFocusToken ? next.focus : null;
  let focusComposer = false;
  let revealSelected = false;
  if (newView) {
    lastViewToken = newView.token;
    if (!newFocus || newView.token > newFocus.token) {
      if (newView.view === "tasks" && newView.filter) {
        applyFilter(next, tasksUI, newView.filter);
        revealSelected = true;
      }
      setView(newView.view);
      // Asked for the chat, as its shortcut does: typing goes to it.
      focusComposer = view === "chat";
    }
  }
  if (newFocus) {
    lastFocusToken = newFocus.token;
  }
  // A focus older than a view request is spent: the view request wins.
  if (newFocus && (!newView || newFocus.token > newView.token)) {
    view = "chat";
    if (openCard(newFocus.taskID, newFocus.cardID)) return;
  }
  if (next.notice && next.notice.token !== lastNoticeToken) {
    lastNoticeToken = next.notice.token;
    notice.textContent = next.notice.text;
    notice.className = next.notice.isError ? "notice error" : "notice";
    setTimeout(() => { if (lastNoticeToken === next.notice?.token) notice.className = "notice hidden"; }, 6000);
  }
  render();
  if (focusComposer && !composerInput.disabled) composerInput.focus();
  if (revealSelected && tasksUI.selected) document.getElementById(`task-row-${tasksUI.selected}`)?.scrollIntoView({ block: "nearest" });
}

/// Opens the task's card, scrolls to it and flashes it. False when the chat
/// has no card for the task.
/// Uses the card the app names, else the task's current card.
function openCard(taskID: string, cardID?: string | null): boolean {
  if (!state) return false;
  const id = cardID && state.items.some((item) => item.id === cardID) ? cardID : focusCardID(state, taskID);
  if (!id) return false;
  // Last in the set, so the app reads it as the card opened last.
  ui.expanded.delete(id);
  ui.expanded.add(id);
  render();
  const element = document.getElementById(`card-${id}`);
  element?.scrollIntoView({ block: "center" });
  element?.classList.add("flash");
  setTimeout(() => element?.classList.remove("flash"), 1200);
  return true;
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

function card(id: string | undefined): Extract<ChatItem, { type: "card" }> | null {
  return state?.items.find((item): item is Extract<ChatItem, { type: "card" }> => item.type === "card" && item.id === id) ?? null;
}

function sendCard(item: Extract<ChatItem, { type: "card" }>, text: string, clearDraft: boolean) {
  const key = cardStateKey(item);
  if (!state || !item.task || !text || ui.pendingCards.has(key) || !checkLength(text)) return;
  const target = replyTarget(item, ui);
  if (target === "task" ? !item.task.canReply : !state.coordinator.canSend) {
    notice.textContent = target === "task" ? "The task cannot receive replies now. Your draft is kept." : "The coordinator cannot receive messages now. Your draft is kept.";
    notice.className = "notice error";
    return;
  }
  const context = clearDraft ? ui.draftContext.get(key) : null;
  const questionID = context ? context.questionID : item.kind === "question" && item.answer === null ? item.id : null;
  const token = track(clearDraft ? key : null, clearDraft ? ui.drafts.get(key) ?? text : null, key, questionID);
  const fields = {
    taskID: item.task.id, version: context ? context.version : item.packet?.version ?? null, text, token, cardID: context?.cardID ?? item.id,
    questionID,
  };
  post({ type: target === "task" ? "reply" : "ask", ...fields });
  render();
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
    case "reply-to": {
      const item = card(data.id);
      const to = data.to === "coordinator" ? "coordinator" : "task";
      if (!item?.task || ui.pendingCards.has(cardStateKey(item)) || (to === "task" ? !item.task.canReply : !state?.coordinator.canSend)) break;
      ui.replyTarget.set(cardStateKey(item), to);
      render();
      document.getElementById(`reply-${item.id}`)?.focus();
      break;
    }
    case "answer": {
      const item = card(data.id);
      const index = Number(data.index);
      if (!item || item.kind !== "question" || item.answer !== null || !Number.isInteger(index) || index < 0) break;
      const answer = item.options[index];
      if (answer) sendCard(item, answer, false);
      break;
    }
    case "answer-route": {
      const item = card(data.id);
      const index = Number(data.index);
      if (!item || item.task || item.kind !== "question" || item.answer !== null || item.answerPending || !state?.coordinator.canSend
        || data.index == null || !/^\d+$/.test(data.index) || !Number.isInteger(index) || index < 0 || index >= item.options.length || ui.pendingCards.has(cardStateKey(item))) break;
      post({ type: "answerRoute", questionID: item.id, optionIndex: index, token: track(null, null, cardStateKey(item)) });
      render();
      break;
    }
    case "card-menu": {
      const bounds = target.getBoundingClientRect();
      post({ type: "taskMenu", taskID: data.task!, x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height });
      break;
    }
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
    case "archive-task": {
      const item = state?.items.find((item): item is Extract<ChatItem, { type: "card" }> => item.type === "card" && item.task?.id === data.task && item.isCurrent && !item.superseded);
      if (item?.task?.stageLabel === "stuck" && item.task.canArchive) post({ type: "archiveTask", taskID: item.task.id });
      break;
    }
    case "focus-task":
      openCard(data.task!);
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
  const item = card(form.dataset.id);
  if (item?.task) {
    if (ui.pendingCards.has(cardStateKey(item))) return;
    rememberDraft(item, input.value);
    sendCard(item, text, true);
  }
});

// Drafts survive re-renders and closing the card.
document.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  const form = input.closest<HTMLFormElement>("form.replybox");
  const item = form ? card(form.dataset.id) : null;
  if (item?.task) {
    rememberDraft(item, input.value);
    if (!input.value) render();
  }
});

function rememberDraft(item: Extract<ChatItem, { type: "card" }>, text: string) {
  const key = cardStateKey(item);
  if (!text) {
    ui.drafts.delete(key);
    ui.draftContext.delete(key);
    return;
  }
  ui.drafts.set(key, text);
  if (!ui.draftContext.has(key)) ui.draftContext.set(key, {
    cardID: item.id,
    questionID: item.kind === "question" && item.answer === null ? item.id : null,
    version: item.packet?.version ?? null,
    questionText: item.kind === "question" ? item.text : null,
    target: replyTarget(item, ui),
  });
}

function markDraftAsFollowup(key: string, questionID: string) {
  const context = ui.draftContext.get(key);
  if (context?.questionID === questionID) ui.draftContext.set(key, { ...context, questionID: null });
}

function track(draftKey: string | null, draftText: string | null, pendingKey?: string, questionID: string | null = null): number {
  const token = nextToken++;
  pendingSends.set(token, { draftKey, draftText, pendingKey, questionID });
  if (pendingKey) ui.pendingCards.add(pendingKey);
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
  post({ type: "send", text, token: track(composerDraftKey, composerInput.value) });
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
