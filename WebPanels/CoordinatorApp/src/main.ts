// The coordinator chat page. The app pushes its whole state with
// `window.toasttyCoordinatorChat.receive(state)`; the page sends actions back
// through the `toasttyCoordinatorChat` message handler. The page keeps only
// what the user is doing here: open cards, typed replies, the merge confirm.
import { collapseNewlySuperseded, esc, fitsMessage, focusCardID, newUIState, renderHeader, renderTimeline, visibleExpandedIDs, replyTarget } from "./render";
import { currentProject, projectID } from "./projects";
import { post } from "./bridge";
import { addressFor, addressMatches, pickedAddress } from "./composer";
import type { AddressPick, ComposerAddress } from "./composer";
import type { ChatItem, ChatState } from "./types";

const ui = newUIState();
let state: ChatState | null = null;
let lastFocusToken: number | null = null;
let lastViewToken: number | null = null;
let lastNoticeToken: number | null = null;
let nextToken = 1;
/// Sends waiting for the app's answer: what to clear once it is taken.
const pendingSends = new Map<number, { draftKey: string | null; text: string; cardID?: string }>();
const composerDraftKey = "composer";

const header = document.getElementById("header")!;
const scroll = document.getElementById("scroll")!;
const composer = document.getElementById("composer") as HTMLFormElement;
const composerInput = composer.querySelector("textarea") as HTMLTextAreaElement;
const composerHint = document.getElementById("composer-hint-text")!;
const composerTerminal = document.getElementById("composer-open-terminal")!;
const notice = document.getElementById("notice")!;
const suggestions = document.getElementById("suggestions")!;
const addressOptions = document.getElementById("address-options")!;
let addressPick: AddressPick | null = null;
let matches: ComposerAddress[] = [];
let matchIndex = 0;

function renderComposerOptions() {
  const choices = state?.addresses ?? [];
  matches = addressMatches(composerInput.value, choices);
  matchIndex = Math.min(matchIndex, Math.max(0, matches.length - 1));
  addressOptions.classList.toggle("hidden", !matches.length);
  addressOptions.innerHTML = matches.map((c, i) => `<button type="button" id="address-option-${i}" role="option" aria-selected="${i === matchIndex}" data-address="${i}"><span class="mono">@${esc(c.token)}</span><span>${esc(c.title)}</span><span class="dim">${c.kind}</span></button>`).join("");
  composerInput.setAttribute("aria-expanded", String(!!matches.length));
  if (matches.length) composerInput.setAttribute("aria-activedescendant", `address-option-${matchIndex}`);
  else composerInput.removeAttribute("aria-activedescendant");
  const firstTask = choices.find((c) => c.kind === "task");
  suggestions.classList.toggle("hidden", !state || state.hasUserRequests);
  suggestions.innerHTML = `<span class="faint small">Try:</span>` + [
    ["a request it can route", "Fix the coupon field losing focus on mobile"],
    ["one it has to ask about", "Add a dark mode toggle"],
    ...(firstTask ? [["a note to a task", `@${firstTask.token} What is left to verify?`]] : []),
    ["status", "status"],
  ].map(([label, text]) => `<button type="button" data-suggest="${esc(text)}">${label}</button>`).join("");
}

function pickAddress(index: number) {
  const choice = matches[index];
  if (!choice) return;
  addressPick = pickedAddress(choice);
  composerInput.value = `@${choice.token} `;
  renderComposerOptions();
  composerInput.focus();
}

addressOptions.addEventListener("click", (event) => {
  const button = (event.target as HTMLElement).closest<HTMLElement>("[data-address]");
  if (button) pickAddress(Number(button.dataset.address));
});
suggestions.addEventListener("click", (event) => {
  const button = (event.target as HTMLElement).closest<HTMLElement>("[data-suggest]");
  if (!button) return;
  composerInput.value = button.dataset.suggest!;
  addressPick = null;
  renderComposerOptions();
  composerInput.focus();
});
composerInput.addEventListener("input", () => {
  if (addressPick && !composerInput.value.startsWith(`@${addressPick.token} `)) addressPick = null;
  matchIndex = 0;
  renderComposerOptions();
});

function render(preserveHeaderFocus = true) {
  if (!state) return;
  const active = document.activeElement as HTMLElement | null;
  const focusedProject = preserveHeaderFocus && document.hasFocus() && active?.dataset.act === "project-filter" && header.contains(active)
    ? { project: active.dataset.project ?? null } : null;
  header.innerHTML = renderHeader(state);
  if (focusedProject) {
    [...header.querySelectorAll<HTMLButtonElement>('[data-act="project-filter"]')]
      .find((button) => (button.dataset.project ?? null) === focusedProject.project)?.focus({ preventScroll: true });
  }
  document.body.dataset.view = "chat";
  document.body.dataset.projectFilter = currentProject(state) ?? "";

  // Re-rendering replaces the reply boxes; drafts live in `ui.drafts`, so
  // only focus needs carrying over.
  const focusedForm = (document.activeElement as HTMLElement | null)?.closest<HTMLFormElement>("form.replybox")?.dataset.id;
  const nearBottom = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 80;

  // Keep the target the user first saw. A later task update must not send a
  // retained draft to a different recipient.
  for (const item of state.items) {
    if (item.type === "card" && item.task && ui.expanded.has(item.id) && !ui.replyTarget.has(item.id)) {
      ui.replyTarget.set(item.id, replyTarget(item, ui));
    }
  }
  scroll.innerHTML = renderTimeline(state, ui);

  if (focusedForm) {
    scroll.querySelector<HTMLFormElement>(`form.replybox[data-id="${CSS.escape(focusedForm)}"]`)?.querySelector("input")?.focus();
  }
  if (nearBottom) scroll.scrollTop = scroll.scrollHeight;

  post({ type: "rendered", expanded: visibleExpandedIDs(state, ui), view: "chat", selected: null });
  composerInput.disabled = !state.coordinator.canSend;
  composerHint.textContent = state.coordinator.sendHint ?? "";
  composerTerminal.classList.toggle("hidden", state.coordinator.canSend || !state.coordinator.hasTerminal);
  composerInput.placeholder = state.coordinator.canSend ? "Tell the coordinator… @task to point at one, @project to route" : state.coordinator.sendHint ?? "The coordinator is not running";
  renderComposerOptions();
}

function receive(next: ChatState) {
  state = next;
  collapseNewlySuperseded(next, ui);
  if (next.ack && pendingSends.has(next.ack.token)) {
    const sent = pendingSends.get(next.ack.token)!;
    pendingSends.delete(next.ack.token);
    if (sent.cardID) ui.pendingCards.delete(sent.cardID);
    if (next.ack.ok && sent.draftKey !== null) {
      if (sent.draftKey === composerDraftKey && composerInput.value === sent.text) {
        composerInput.value = "";
        addressPick = null;
      } else if (ui.drafts.get(sent.draftKey) === sent.text) ui.drafts.delete(sent.draftKey);
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
  // A native request can hand the keyboard to the right panel before
  // WebKit updates document.hasFocus(). Do not restore the old header then.
  render(!newView);
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
  render(false);
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

function card(id: string | undefined): Extract<ChatItem, { type: "card" }> | null {
  return state?.items.find((item): item is Extract<ChatItem, { type: "card" }> => item.type === "card" && item.id === id) ?? null;
}

function sendCard(item: Extract<ChatItem, { type: "card" }>, text: string, clearDraft: boolean) {
  if (!state || !item.task || !text || ui.pendingCards.has(item.id) || !checkLength(text)) return;
  const target = replyTarget(item, ui);
  if (target === "task" ? !item.task.canReply : !state.coordinator.canSend) {
    notice.textContent = target === "task" ? "The task cannot receive replies now. Your draft is kept." : "The coordinator cannot receive messages now. Your draft is kept.";
    notice.className = "notice error";
    return;
  }
  const token = track(clearDraft ? item.id : null, item.id);
  const fields = {
    taskID: item.task.id, version: item.packet?.version ?? null, text, token, cardID: item.id,
    questionID: item.kind === "question" && item.answer === null ? item.id : null,
  };
  post({ type: target === "task" ? "reply" : "ask", ...fields });
  render();
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
    case "reply-to": {
      const item = card(data.id);
      const to = data.to === "coordinator" ? "coordinator" : "task";
      if (!item?.task || ui.pendingCards.has(item.id) || (to === "task" ? !item.task.canReply : !state?.coordinator.canSend)) break;
      ui.replyTarget.set(item.id, to);
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
  const item = card(form.dataset.id);
  if (item) sendCard(item, text, true);
});

// Drafts survive re-renders and closing the card.
document.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  const form = input.closest<HTMLFormElement>("form.replybox");
  if (form) ui.drafts.set(form.dataset.id!, input.value);
});

function track(draftKey: string | null, cardID?: string): number {
  const token = nextToken++;
  pendingSends.set(token, {
    draftKey, cardID,
    text: draftKey === composerDraftKey ? composerInput.value : draftKey === null ? "" : ui.drafts.get(draftKey) ?? "",
  });
  if (cardID) ui.pendingCards.add(cardID);
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
  if (addressPick && text === `@${addressPick.token}`) return;
  if ([...pendingSends.values()].some((s) => s.draftKey === composerDraftKey)) return;
  const resolved = addressFor(text, state?.addresses ?? [], addressPick);
  if (addressPick && !resolved) {
    notice.textContent = "That target is no longer available. Pick it again before sending.";
    notice.className = "notice error";
    return;
  }
  const token = track(composerDraftKey);
  if (resolved?.address.kind === "task") {
    post({ type: "ask", taskID: resolved.address.id, version: resolved.address.version, text: resolved.text, token });
  } else if (resolved?.address.kind === "project") {
    post({ type: "project", projectID: resolved.address.id, text: resolved.text, token });
  } else post({ type: "send", text, token });
  scroll.scrollTop = scroll.scrollHeight;
}

composerInput.addEventListener("keydown", (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  if (matches.length && ["ArrowDown", "ArrowUp", "Enter", "Tab", "Escape"].includes(event.key)) {
    event.preventDefault();
    if (event.key === "Enter" || event.key === "Tab") pickAddress(matchIndex);
    else if (event.key === "Escape") { matches = []; addressOptions.classList.add("hidden"); }
    else { matchIndex = (matchIndex + (event.key === "ArrowDown" ? 1 : matches.length - 1)) % matches.length; renderComposerOptions(); }
    return;
  }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    sendComposer();
  }
});

window.toasttyCoordinatorChat = { receive };
post({ type: "ready" });
