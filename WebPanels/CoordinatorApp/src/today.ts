import { esc } from "./render";
import { currentProject, projectID, projectTitle } from "./projects";
import { taskAge } from "./tasks";
import type { ChatState, TaskRow, Tone } from "./types";

function todayRow(row: TaskRow, now: Date, completion?: { kind: "merged" | "released"; at: string }): string {
  const label = completion?.kind ?? row.stageLabel;
  const tone: Tone = completion ? completion.kind === "released" ? "green" : "violet" : row.stageTone;
  const id = completion ? `today-completed-row-${row.id}` : `today-row-${row.id}`;
  return `<button type="button" class="minirow" id="${esc(id)}" data-act="today-open" data-id="${esc(row.id)}" data-row-id="${esc(row.id)}">`
    + `<span class="badge b-${tone}">${esc(label)}</span><span class="grow"><b>${esc(row.title)}</b>`
    + (!completion && row.status ? ` <span class="dim">· ${esc(row.status)}</span>` : "") + `</span>`
    + (row.project ? `<span class="badge b-plain">${esc(row.project)}</span>` : "")
    + `<span class="mono faint small age">${esc(taskAge(completion?.at ?? row.activityAt, now))}</span></button>`;
}

function section(id: string, title: string, rows: string[], empty: string): string {
  return `<section class="today-section" id="today-${id}"><h2 class="sec-h"><span>${esc(title)}</span><span>${rows.length}</span></h2>`
    + (rows.length ? rows.join("") : `<div class="today-empty dim">${esc(empty)}</div>`) + `</section>`;
}

export function renderToday(state: ChatState, now: Date): string {
  const selected = currentProject(state);
  const rows = (state.tasks ?? []).filter((row) => selected === null || projectID(row) === selected);
  const group = (id: string) => rows.filter((row) => row.group === id);
  const needsYou = group("needsYou");
  const running = group("running");
  const toShip = group("toShip");
  const completed = (state.today?.completed ?? []).flatMap((completion) => {
    const row = rows.find((candidate) => candidate.id === completion.rowID);
    return row ? [todayRow(row, now, completion)] : [];
  });
  return `<div class="gen"><span>Today</span><span>${esc(projectTitle(state))}</span></div>`
    + `<div class="kpis">`
    + [["running", "running", running.length], ["needsYou", "need you", needsYou.length], ["toShip", "to ship", toShip.length]].map(([id, title, count]) =>
      `<button type="button" class="kpi ${id}" id="today-stat-${id}" data-act="today-group" data-group="${id}"><span class="n">${count}</span><span class="l">${title}</span></button>`).join("")
    + `</div>`
    + section("needsYou", "Needs you", needsYou.map((row) => todayRow(row, now)), "Nothing needs you.")
    + section("running", "Running", running.map((row) => todayRow(row, now)), "No tasks running.")
    + section("completed", "Merged or released today", completed, "Nothing merged or released today.");
}
