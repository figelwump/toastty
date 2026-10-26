// All tasks: every task the app knows of, in stage groups, beside the chat.
// The app sends the rows with their actions; the page keeps only the project
// filter, the selected row, open groups and an open menu or question.
import { esc } from "./render";
import { currentProject, projectID, projectTitle } from "./projects";
import type { ChatState, TaskAction, TaskRow, TasksFilter, TasksUIState, Tone } from "./types";

/// Groups that start closed, since they only grow.
const closedByDefault = new Set(["done", "archived"]);

export function newTasksUIState(): TasksUIState {
  return { project: null, selected: null, toggledGroups: new Set(), menuOpen: null, confirming: null };
}

export function isGroupOpen(groupID: string, ui: TasksUIState): boolean {
  return closedByDefault.has(groupID) === ui.toggledGroups.has(groupID);
}

/// "now", "5m", "3h", "2d", as the sidebar says how long ago.
export function taskAge(activityAt: string, now: Date): string {
  const seconds = Math.max(0, (now.getTime() - new Date(activityAt).getTime()) / 1000);
  if (Number.isNaN(seconds)) return "";
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

function shownRows(state: ChatState, ui: TasksUIState): TaskRow[] {
  const rows = state.tasks ?? [];
  const project = currentProject(state, ui.project);
  return project === null ? rows : rows.filter((row) => projectID(row) === project);
}

/// The rows the arrow keys move through, top to bottom: those in open groups.
export function navigableRows(state: ChatState, ui: TasksUIState): TaskRow[] {
  const rows = shownRows(state, ui);
  return (state.taskGroups ?? []).flatMap((group) => isGroupOpen(group.id, ui) ? rows.filter((row) => row.group === group.id) : []);
}

/// Keeps the selection on a row the user can see: a row the filter hides, a
/// closed group holds, or that went away gives way to the first row. A
/// question or menu whose row went, or whose action changed, closes.
export function normalize(state: ChatState, ui: TasksUIState) {
  const rows = navigableRows(state, ui);
  if (!rows.some((row) => row.id === ui.selected)) ui.selected = rows[0]?.id ?? null;
  if (ui.menuOpen !== null && !rows.some((row) => row.id === ui.menuOpen)) ui.menuOpen = null;
  const confirming = ui.confirming;
  if (confirming) {
    const row = rows.find((r) => r.id === confirming.rowID);
    if (!row || !row.confirm || row.primary?.id !== confirming.actionID) ui.confirming = null;
  }
}

/// Shows what a filter asks for: the project, the group open, and the
/// group's first row selected. A known project with no rows stays empty.
export function applyFilter(state: ChatState, ui: TasksUIState, filter: TasksFilter) {
  ui.project = filter.project;
  if (!isGroupOpen(filter.group, ui)) {
    if (ui.toggledGroups.has(filter.group)) ui.toggledGroups.delete(filter.group);
    else ui.toggledGroups.add(filter.group);
  }
  ui.menuOpen = null;
  ui.confirming = null;
  // An unknown stale project falls back to all rows, but must not select
  // a row from a different project.
  ui.selected = shownRows(state, ui).find((row) => row.group === filter.group
    && (filter.project === null || projectID(row) === filter.project))?.id ?? null;
}

/// The row after (`delta` 1) or before (-1) the selected one; the first row
/// when none is selected or the selected row went away.
export function moveSelection(state: ChatState, ui: TasksUIState, delta: number): string | null {
  const rows = navigableRows(state, ui);
  if (rows.length === 0) return null;
  const index = rows.findIndex((row) => row.id === ui.selected);
  if (index < 0) return rows[0].id;
  return rows[Math.min(rows.length - 1, Math.max(0, index + delta))].id;
}

function badge(text: string, tone: Tone): string {
  return `<span class="badge b-${tone}">${esc(text)}</span>`;
}

function actionButton(row: TaskRow, action: TaskAction): string {
  return `<button type="button" role="menuitem" id="task-action-${esc(row.id)}-${esc(action.id)}" class="${action.isDestructive ? "destructive" : ""}" data-act="task-action" data-id="${esc(row.id)}" data-action="${esc(action.id)}">${esc(action.title)}</button>`;
}

export function renderTaskRow(row: TaskRow, ui: TasksUIState, now: Date): string {
  const selected = ui.selected === row.id;
  let html = `<div class="task-row ${selected ? "sel" : ""} ${row.group === "needsYou" ? "need" : ""}" id="task-row-${esc(row.id)}" data-act="task-select" data-id="${esc(row.id)}" role="option" aria-selected="${selected}">`
    + `<div class="task-line">${badge(row.stageLabel, row.stageTone)}`
    + `<span class="grow"><b>${esc(row.title)}</b> <span class="sub">· ${esc(row.status)}</span></span>`
    + (row.project ? badge(row.project, "plain") : "")
    + `<span class="mono faint small age">${esc(taskAge(row.activityAt, now))}</span>`;
  const confirming = ui.confirming?.rowID === row.id && row.primary?.id === ui.confirming.actionID && row.confirm ? row.primary : null;
  if (!confirming) {
    html += (row.primary
      ? `<button type="button" class="btn sm ${row.confirm ? "primary" : ""}" id="task-primary-${esc(row.id)}" data-act="task-primary" data-id="${esc(row.id)}">${esc(row.primary.title)}</button>`
      : "")
      + (row.menu.length
        ? `<button type="button" class="btn sm more" id="task-menu-${esc(row.id)}" data-act="task-menu" data-id="${esc(row.id)}" aria-haspopup="menu" aria-expanded="${ui.menuOpen === row.id}" aria-label="More actions for ${esc(row.title)}">▾</button>`
        : "");
  }
  html += `</div>`;
  if (confirming) {
    html += `<div class="confirm"><div>${esc(row.confirm)}</div><div class="btns">`
      + `<button type="button" class="btn primary sm" id="task-confirm-${esc(row.id)}" data-act="task-action" data-id="${esc(row.id)}" data-action="${esc(confirming.id)}">${esc(confirming.title)}</button>`
      + `<button type="button" class="btn sm" data-act="task-cancel">Cancel</button></div></div>`;
  }
  if (ui.menuOpen === row.id) {
    html += `<div class="menu" role="menu">` + row.menu.map((section) => section.map((action) => actionButton(row, action)).join("")).join(`<hr>`) + `</div>`;
  }
  return html + `</div>`;
}

export function renderTasks(state: ChatState, ui: TasksUIState, now: Date): string {
  const rows = shownRows(state, ui);
  let html = `<div class="tasks-head"><span class="mono faint small">${esc(projectTitle(state, currentProject(state, ui.project)))}</span><span class="mono faint small">↑ ↓ to move · ↩ to open</span></div>`;
  if ((state.tasks ?? []).length === 0) {
    return html + `<div class="empty-chat"><p>No tasks yet.</p><p class="dim">Tell the coordinator what you want done, or press the + by Coordinator in the sidebar.</p></div>`;
  }
  if (rows.length === 0) return html + `<div class="empty-chat"><p>No tasks in this project.</p></div>`;
  html += `<div class="task-list" role="listbox" aria-label="All tasks">`;
  for (const group of state.taskGroups ?? []) {
    const inGroup = rows.filter((row) => row.group === group.id);
    if (inGroup.length === 0) continue;
    const open = isGroupOpen(group.id, ui);
    // The filter counts what it shows; without it, the group's total.
    const count = currentProject(state, ui.project) === null ? Math.max(group.total ?? 0, inGroup.length) : inGroup.length;
    html += `<button type="button" class="grp" id="group-${esc(group.id)}" data-act="task-group" data-group="${esc(group.id)}" aria-expanded="${open}">`
      + `<span>${open ? "▾" : "▸"} ${esc(group.title)}</span><span>${count}</span></button>`;
    if (open) {
      html += inGroup.map((row) => renderTaskRow(row, ui, now)).join("");
      if (count > inGroup.length) html += `<div class="dim small more-rows">The newest ${inGroup.length} of ${count}. <span class="mono">toastty task list</span> lists them all.</div>`;
    }
  }
  return html + `</div>`;
}
