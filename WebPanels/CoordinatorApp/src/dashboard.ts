// Today and All tasks use the same native state push and action bridge as
// the chat. Native remembers the project filter for this window.
import { post } from "./bridge";
import { currentProject } from "./projects";
import { applyFilter, moveSelection, newTasksUIState, normalize, renderTasks } from "./tasks";
import { renderToday } from "./today";
import type { ChatState } from "./types";

type DashboardView = "today" | "tasks";

const ui = newTasksUIState();
const root = document.getElementById("dashboard")!;
const tabs = document.getElementById("dashboard-tabs")!;
const notice = document.getElementById("notice")!;
let state: ChatState | null = null;
let view: DashboardView = location.pathname.replace(/\/$/, "") === "/tasks" ? "tasks" : "today";
let lastViewToken: number | null = null;
let lastNoticeToken: number | null = null;

function activate() {
  if (!document.hasFocus()) return;
  post({ type: "activate", view, selected: view === "tasks" ? ui.selected : null });
}

function render() {
  if (!state) return;
  const active = document.hasFocus() ? document.activeElement as HTMLElement | null : null;
  const restoreFocus = active !== null && active !== root && active !== tabs && (root.contains(active) || tabs.contains(active));
  const focusedID = restoreFocus ? active.id : null;
  normalize(state, ui);
  document.body.dataset.view = view;
  document.body.dataset.projectFilter = currentProject(state) ?? "";
  document.title = view === "today" ? "Today" : "All tasks";
  tabs.innerHTML = ([ ["today", "Today"], ["tasks", "All tasks"] ] as const).map(([id, title]) =>
    `<button type="button" id="dashboard-tab-${id}" class="${view === id ? "on" : ""}" data-act="dashboard-view" data-view="${id}" aria-pressed="${view === id}">${title}</button>`).join("");
  root.classList.toggle("tasks", view === "tasks");
  root.innerHTML = view === "today" ? renderToday(state, new Date()) : renderTasks(state, ui, new Date());
  if (restoreFocus) {
    const replacement = focusedID ? document.getElementById(focusedID) : null;
    const destination = replacement && (root.contains(replacement) || tabs.contains(replacement)) ? replacement : root;
    destination.focus({ preventScroll: true });
  }
  post({ type: "rendered", expanded: [], view, selected: view === "tasks" ? ui.selected : null });
}

function revealSelection() {
  if (ui.selected) document.getElementById(`task-row-${ui.selected}`)?.scrollIntoView({ block: "nearest" });
}

function receive(next: ChatState) {
  const wasLive = state !== null;
  const projectChanged = state !== null && currentProject(state) !== currentProject(next);
  state = next;
  ui.project = currentProject(next);
  const request = next.view && next.view.token !== lastViewToken ? next.view : null;
  if (projectChanged || (request && request.view !== view)) {
    ui.menuOpen = null;
    ui.confirming = null;
  }
  let reveal = false;
  if (request) {
    lastViewToken = request.token;
    if (request.view !== "chat") {
      view = request.view;
      if (request.view === "tasks" && request.filter) {
        applyFilter(next, ui, request.filter);
        reveal = true;
      }
    }
  }
  if (next.notice && next.notice.token !== lastNoticeToken) {
    lastNoticeToken = next.notice.token;
    notice.textContent = next.notice.text;
    notice.className = next.notice.isError ? "notice error" : "notice";
    setTimeout(() => { if (lastNoticeToken === next.notice?.token) notice.className = "notice hidden"; }, 6000);
  }
  render();
  // Native page requests are explicit navigation. Passive live refreshes
  // and the initial background mount must not take the keyboard.
  if (wasLive && request?.view === "tasks") root.focus({ preventScroll: true });
  if (reveal) revealSelection();
}

function showView(next: DashboardView) {
  view = next;
  ui.menuOpen = null;
  ui.confirming = null;
  render();
  activate();
  post({ type: "showView", view });
}

function runTaskAction(rowID: string, actionID: string) {
  ui.menuOpen = null;
  ui.confirming = null;
  post({ type: "taskAction", rowID, actionID });
  render();
}

document.addEventListener("pointerdown", activate);
document.addEventListener("focusin", activate);
document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target || !state) return;
  const data = target.dataset;
  switch (data.act) {
    case "dashboard-view":
      showView(data.view === "tasks" ? "tasks" : "today");
      break;
    case "today-group":
      applyFilter(state, ui, { project: currentProject(state), group: data.group! });
      showView("tasks");
      revealSelection();
      break;
    case "today-open":
      runTaskAction(data.id!, "open");
      break;
    case "task-select":
      ui.selected = data.id!;
      ui.menuOpen = null;
      render();
      activate();
      break;
    case "task-primary": {
      const row = state.tasks?.find((row) => row.id === data.id);
      if (!row?.primary) break;
      ui.selected = row.id;
      activate();
      if (row.confirm) {
        ui.menuOpen = null;
        ui.confirming = { rowID: row.id, actionID: row.primary.id };
        render();
      } else runTaskAction(row.id, row.primary.id);
      break;
    }
    case "task-menu":
      ui.selected = data.id!;
      ui.menuOpen = ui.menuOpen === data.id ? null : data.id!;
      ui.confirming = null;
      render();
      activate();
      break;
    case "task-action":
      runTaskAction(data.id!, data.action!);
      break;
    case "task-cancel":
      ui.confirming = null;
      render();
      break;
    case "task-group": {
      const group = data.group!;
      if (ui.toggledGroups.has(group)) ui.toggledGroups.delete(group);
      else ui.toggledGroups.add(group);
      render();
      activate();
      break;
    }
  }
});

// Keep All tasks' existing keyboard actions in its new surface.
document.addEventListener("keydown", (event) => {
  if (view !== "tasks" || !state || event.isComposing) return;
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if ((event.target as HTMLElement).closest("input, textarea")) return;
  if (event.key === "Escape" && (ui.menuOpen || ui.confirming)) {
    ui.menuOpen = null;
    ui.confirming = null;
    render();
  } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    ui.selected = moveSelection(state, ui, event.key === "ArrowDown" ? 1 : -1);
    ui.menuOpen = null;
    render();
    revealSelection();
    activate();
  } else if (event.key === "Enter" && ui.selected && !(event.target as HTMLElement).closest("button")) {
    event.preventDefault();
    runTaskAction(ui.selected, "open");
  }
});

window.toasttyCoordinatorChat = { receive };
// A cached document resumes without rerunning startup, while native
// navigation has reset its live-state grant for this page.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) post({ type: "ready" });
});
post({ type: "ready" });
