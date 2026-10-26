// The coordinator chat page. The app pushes its whole state with
// `window.toasttyCoordinatorChat.receive(state)`; the page sends actions back
// through the `toasttyCoordinatorChat` message handler. The page keeps only
// what the user is doing here: open cards, typed replies, the merge confirm.
import { collapseNewlySuperseded, fitsMessage, focusCardID, newUIState, renderHeader, renderTimeline, visibleExpandedIDs } from "./render";
import { currentProject, projectID } from "./projects";
import { post } from "./bridge";
import type { ChatState } from "./types";

const ui = newUIState();
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
const composer = document.getElementById("composer") as HTMLFormElement;
const composerInput = composer.querySelector("textarea") as HTMLTextAreaElement;
const composerHint = document.getElementById("composer-hint-text")!;
const composerTerminal = document.getElementById("composer-open-terminal")!;
const notice = document.getElementById("notice")!;

function render() {
  if (!state) return;
  header.innerHTML = renderHeader(state);
  document.body.dataset.view = "chat";
  document.body.dataset.projectFilter = currentProject(state) ?? "";

  // Re-rendering replaces the reply boxes; drafts live in `ui.drafts`, so
  // only focus needs carrying over.
  const focusedForm = (document.activeElement as HTMLElement | null)?.closest<HTMLFormElement>("form.replybox")?.dataset.id;
  const nearBottom = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 80;

  scroll.innerHTML = renderTimeline(state, ui);

  if (focusedForm) {
    scroll.querySelector<HTMLFormElement>(`form.replybox[data-id="${CSS.escape(focusedForm)}"]`)?.querySelector("input")?.focus();
  }
  if (nearBottom) scroll.scrollTop = scroll.scrollHeight;

  post({ type: "rendered", expanded: visibleExpandedIDs(state, ui), view: "chat", selected: null });
  composerInput.disabled = !state.coordinator.canSend;
  composerHint.textContent = state.coordinator.sendHint ?? "";
  composerTerminal.classList.toggle("hidden", state.coordinator.canSend || !state.coordinator.hasTerminal);
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
  const newView = next.view && next.view.token !== lastViewToken ? next.view : null;
  const newFocus = next.focus && next.focus.token !== lastFocusToken ? next.focus : null;
  if (newView) lastViewToken = newView.token;
  if (newFocus) lastFocusToken = newFocus.token;
  // Today and All tasks live in the right panel. Only a chat request
  // returns typing to this page's composer.
  const focusComposer = newView?.view === "chat" && (!newFocus || newView.token > newFocus.token);
  if (next.notice && next.notice.token !== lastNoticeToken) {
    lastNoticeToken = next.notice.token;
    notice.textContent = next.notice.text;
    notice.className = next.notice.isError ? "notice error" : "notice";
    setTimeout(() => { if (lastNoticeToken === next.notice?.token) notice.className = "notice hidden"; }, 6000);
  }
  // A retained old focus must not override a newer request for a page.
  if (newFocus && (!newView || newFocus.token > newView.token) && openCard(newFocus.taskID, newFocus.cardID, false)) return;
  render();
  if (focusComposer && !composerInput.disabled) composerInput.focus();
}

/// Opens a task's card: `cardID` when the chat has it, as the app names the
/// task's newest question, else the task's newest packet card or its last.
/// False when the chat has no visible card for the task. Only an explicit
/// local About click can reveal a card hidden by the shared filter.
function openCard(taskID: string, cardID?: string | null, revealHidden = false): boolean {
  if (!state) return false;
  const id = cardID && state.items.some((item) => item.id === cardID) ? cardID : focusCardID(state, taskID);
  if (!id) return false;
  const card = state.items.find((item) => item.id === id);
  if (card?.type === "card" && card.task && currentProject(state) !== null && projectID(card.task) !== currentProject(state)) {
    if (!revealHidden) return false;
    state = { ...state, projectFilter: projectID(card.task) };
    post({ type: "projectFilter", project: projectID(card.task) });
  }
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

// The app uses the active surface for command-palette actions. A state
// refresh must not make a background right-panel page the active surface.
function activate() {
  if (!document.hasFocus()) return;
  post({ type: "activate", view: "chat", selected: null });
}
document.addEventListener("pointerdown", activate);
document.addEventListener("focusin", activate);

document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target || target.tagName === "FORM") return;
  const data = target.dataset;
  switch (data.act) {
    case "project-filter":
      if (state) {
        state = { ...state, projectFilter: data.project ?? null };
        post({ type: "projectFilter", project: data.project ?? null });
        render();
      }
      break;
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
    case "focus-task":
      openCard(data.task!, undefined, true);
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

window.toasttyCoordinatorChat = { receive };
post({ type: "ready" });
