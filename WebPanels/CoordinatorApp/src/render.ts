// Pure HTML builders for the chat and the report. Every value from the app
// is text that an agent or a task wrote, so it is escaped here; the only
// markup is ours.
import { micromark } from "micromark";
import { gfm, gfmHtml } from "micromark-extension-gfm";
import type { ChatItem, ChatPacket, ChatScreenshot, ChatState, ChatTask, ChatUIState, PageView, ReportPacket, Tone } from "./types";

export function esc(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/// The longest message the app takes, in UTF-8 bytes.
export const maximumTextLength = 16 * 1024;

export function fitsMessage(text: string): boolean {
  return new TextEncoder().encode(text).length <= maximumTextLength;
}

const urlPattern = /\bhttps?:\/\/[^\s<>"')\]]+/g;

/// Escaped text with http(s) links that open in the right panel.
export function linkify(text: string): string {
  let html = "";
  let last = 0;
  for (const match of text.matchAll(urlPattern)) {
    const url = match[0].replace(/[.,;:!?]+$/, "");
    const start = match.index ?? 0;
    html += esc(text.slice(last, start));
    html += `<button class="lnk inline" data-act="open-url" data-url="${esc(url)}">${esc(url)}</button>`;
    last = start + url.length;
  }
  return html + esc(text.slice(last));
}

/// Markdown that an agent wrote, as HTML. micromark escapes raw HTML and
/// drops links with unsafe schemes, so the agent's text never becomes markup
/// of its own. Images become links: the page loads nothing remote.
export function markdown(text: string): string {
  const html = micromark(text, {
    extensions: [gfm(), { disable: { null: ["labelStartImage"] } }],
    htmlExtensions: [gfmHtml()],
  });
  // Links become the buttons `linkify` makes, which open in the right panel,
  // so the page has no link that could navigate it. Text is escaped, so
  // every `<a` here is micromark's own tag.
  return html
    .replace(/<a href="([^"]*)"(?: title="[^"]*")?>/g, (_, href: string) => {
      const url = href.replace(/^https?(?=:\/\/)/i, (scheme) => scheme.toLowerCase());
      return /^https?:\/\//.test(url)
        ? `<button class="lnk inline" data-act="open-url" data-url="${url}">`
        : `<button class="lnk inline" disabled>`;
    })
    .replace(/<\/a>/g, "</button>");
}

function badge(text: string, tone: Tone): string {
  return `<span class="badge b-${tone}">${esc(text)}</span>`;
}

export function newUIState(): ChatUIState {
  return { expanded: new Set(), superseded: new Set(), drafts: new Map(), replyTarget: new Map(), confirmingMerge: null };
}

/// Folds a card that a newer packet just replaced, once; the user can open
/// it again.
export function collapseNewlySuperseded(state: ChatState, ui: ChatUIState) {
  for (const item of state.items) {
    if (item.type !== "card" || !item.superseded || ui.superseded.has(item.id)) continue;
    ui.superseded.add(item.id);
    ui.expanded.delete(item.id);
  }
}

export function isExpanded(item: ChatItem, ui: ChatUIState): boolean {
  return item.type === "card" && item.task !== null && ui.expanded.has(item.id);
}

/// The card to open for `coordinator.chat.show --task`: the task's newest
/// packet card that is not superseded, else its last card.
export function focusCardID(state: ChatState, taskID: string): string | null {
  const cards = state.items.filter((item) => item.type === "card" && item.task?.id === taskID);
  const packet = [...cards].reverse().find((item) => item.type === "card" && item.kind === "packet" && !item.superseded);
  return (packet ?? cards[cards.length - 1])?.id ?? null;
}

export function renderViewSwitch(view: PageView): string {
  return `<span class="seg view-switch" role="group" aria-label="View">`
    + `<button type="button" id="view-chat" class="${view === "chat" ? "on" : ""}" data-act="view" data-view="chat" aria-pressed="${view === "chat"}">Chat</button>`
    + `<button type="button" id="view-tasks" class="${view === "tasks" ? "on" : ""}" data-act="view" data-view="tasks" aria-pressed="${view === "tasks"}">All tasks</button></span>`;
}

export function renderHeader(state: ChatState, view: PageView = "chat"): string {
  const c = state.coordinator;
  return `<div class="chead"><span class="cmark">C</span><div class="who"><div class="name">${esc(c.title)}</div>`
    + `<div class="mono dim small">${esc(c.detail)}</div></div>`
    + renderViewSwitch(view)
    + `<button class="tb-btn" id="open-routing" data-act="open-routing" title="Open routing.md in the right panel">routing.md</button>`
    + (c.hasTerminal ? `<button class="tb-btn" data-act="open-terminal" title="Show the coordinator's terminal">Open terminal</button>` : "")
    + `</div>`;
}

export function renderTimeline(state: ChatState, ui: ChatUIState): string {
  if (state.items.length === 0) {
    return `<div class="empty-chat"><div class="cmark big">C</div><p>Tell the coordinator what you want done.</p>`
      + `<p class="dim">It routes each request to a task in the right project and posts here when one needs you.</p></div>`;
  }
  return state.items.map((item) => renderItem(item, ui)).join("");
}

export function renderItem(item: ChatItem, ui: ChatUIState): string {
  switch (item.type) {
    case "message":
      if (item.role === "assistant") {
        return `<div class="msg-co" data-item="${esc(item.id)}"><span class="cmark">C</span><div class="bubble md">${markdown(item.text)}</div></div>`;
      }
      return `<div class="msg-user" data-item="${esc(item.id)}">`
        + (item.aboutTaskID
          ? `<button class="about" data-act="focus-task" data-task="${esc(item.aboutTaskID)}" title="Show the task's card">About ${esc(item.aboutTitle ?? "a task")}</button>`
          : "")
        + `${linkify(item.text)}</div>`;
    case "tool":
      return `<div class="tool" data-item="${esc(item.id)}"><span class="tool-mark ${esc(item.outcome)}"></span>`
        + `<span class="mono">${esc(item.name)}</span>${item.detail ? ` <span class="dim">${esc(item.detail)}</span>` : ""}</div>`;
    case "status":
      return `<div class="status-line" data-item="${esc(item.id)}">${esc(item.text)}</div>`;
    case "card":
      return `<div class="msg-co card-row" id="card-${esc(item.id)}" data-item="${esc(item.id)}"><span class="cmark">C</span><div class="bubble">`
        + (isExpanded(item, ui) ? renderOpenCard(item, ui) : renderCompactCard(item)) + `</div></div>`;
  }
}

function cardSubtitle(item: Extract<ChatItem, { type: "card" }>): string {
  if (item.kind === "packet") {
    if (item.packet) return item.packet.lookAt;
    return "no packet yet";
  }
  if (item.kind === "task-started") return "started";
  return item.text ?? "";
}

export function renderCompactCard(item: Extract<ChatItem, { type: "card" }>): string {
  const task = item.task;
  if (!task) {
    // A note that names no task is the coordinator speaking.
    return `<div class="note-card md">${markdown(item.text ?? "")}</div>`;
  }
  const kindBadge = item.kind === "question" ? badge("question", "amber") : badge(task.stageLabel, task.stageTone);
  if (item.superseded && item.packet) {
    return `<button class="compact superseded" id="expand-${esc(item.id)}" data-act="expand" data-id="${esc(item.id)}" aria-expanded="false">`
      + `<span class="chev">v${item.packet.version}</span><span class="grow dim">${esc(task.title)} · replaced by v${item.packet.latestVersion}</span><span class="chev">▸</span></button>`;
  }
  return `<button class="compact ${task.needsUser ? "need" : ""}" id="expand-${esc(item.id)}" data-act="expand" data-id="${esc(item.id)}" aria-expanded="false">`
    + kindBadge
    + (item.isNew ? badge("new", "green") : "")
    + (task.stale && item.kind === "packet" ? badge("stale", "red") : "")
    + `<span class="grow"><b>${esc(task.title)}</b> <span class="sub">· ${esc(cardSubtitle(item))}</span></span>`
    + (task.project ? badge(task.project, "plain") : "")
    + (item.packet ? `<span class="chev">v${item.packet.version}</span>` : "")
    + `<span class="chev">▸</span></button>`;
}

function renderChecks(packet: ChatPacket): string {
  if (packet.checks.length === 0) return `<span class="dim">No checks listed</span>`;
  return packet.checks.map((check) => `<span class="check"><span class="${check.ok ? "ok" : "bad"}">${check.ok ? "✓" : "✗"}</span> ${esc(check.name)}`
    + (check.log ? ` <span class="faint log">${linkify(check.log)}</span>` : "") + `</span>`).join("");
}

function renderThumbs(task: ChatTask, packet: ChatPacket): string {
  if (packet.screenshots.length === 0) return "";
  return `<div class="thumbs">` + packet.screenshots.map((shot: ChatScreenshot) =>
    `<button class="thumb" data-act="open-report" data-task="${esc(task.id)}" data-version="${packet.version}" data-shot="${esc(shot.name)}" aria-label="Open ${esc(shot.name)} in the right panel">`
    + `<img src="${esc(shot.url)}" alt="" loading="lazy"><span class="lbl">${esc(shot.name)}</span></button>`).join("")
    + `<span class="mono faint small">click a screenshot to open the report</span></div>`;
}

function renderReplyBox(item: Extract<ChatItem, { type: "card" }>, task: ChatTask, ui: ChatUIState): string {
  if (!task.canReply) return "";
  const target = item.kind === "question" ? "coordinator" : ui.replyTarget.get(item.id) ?? "task";
  const segment = item.kind === "question" ? "" : `<span class="seg" role="group" aria-label="Send reply to">`
    + `<button type="button" id="reply-to-task-${esc(item.id)}" class="${target === "task" ? "on" : ""}" data-act="reply-to" data-id="${esc(item.id)}" data-to="task">to task</button>`
    + `<button type="button" id="reply-to-coordinator-${esc(item.id)}" class="${target === "coordinator" ? "on" : ""}" data-act="reply-to" data-id="${esc(item.id)}" data-to="coordinator">to coordinator</button></span>`;
  const placeholder = target === "task" ? `Review note for ${task.slug}…` : "Ask the coordinator about this…";
  return `<form class="replybox" data-act="reply" data-id="${esc(item.id)}" data-task="${esc(task.id)}" data-version="${item.packet?.version ?? ""}" data-to="${target}">`
    + segment + `<input id="reply-${esc(item.id)}" name="text" autocomplete="off" autocorrect="off" spellcheck="false" maxlength="${maximumTextLength}" placeholder="${esc(placeholder)}" aria-label="${esc(placeholder)}" value="${esc(ui.drafts.get(item.id) ?? "")}"><span class="kbd">↩</span></form>`;
}

export function renderOpenCard(item: Extract<ChatItem, { type: "card" }>, ui: ChatUIState): string {
  const task = item.task!;
  const packet = item.packet;
  let html = `<div class="card ${task.needsUser ? "need" : ""}"><div class="crow">`
    + (item.kind === "question" ? badge("question", "amber") : badge(task.stageLabel, task.stageTone))
    + (item.isNew ? badge("new", "green") : "")
    + `<span class="grow ctitle">${esc(task.title)}</span>`
    + (task.project ? badge(task.project, "plain") : "")
    + (packet ? `<span class="mono faint small">packet v${packet.version}${packet.version < packet.latestVersion ? ` of ${packet.latestVersion}` : ""}</span>` : "")
    + (task.stale && packet ? badge("stale: new commits", "red") : "")
    + (task.hasTaskSpace ? `<button class="lnk" data-act="open-task" data-task="${esc(task.id)}">task ↗</button>` : "")
    + (task.pullRequestURL ? `<button class="lnk" data-act="open-url" data-url="${esc(task.pullRequestURL)}">${esc(task.pullRequestLabel ?? "PR")} ↗</button>` : "")
    + `<button class="collapse" id="collapse-${esc(item.id)}" data-act="expand" data-id="${esc(item.id)}" aria-expanded="true">▾ collapse</button></div>`;

  if (item.kind === "question" || item.kind === "note") {
    html += `<div class="card-text md">${markdown(item.text ?? "")}</div>`;
  }
  if (packet && item.kind === "packet") {
    html += `<div class="pgrid">`
      + `<div class="pbox"><div class="h">What changed</div><div>${linkify(packet.summary)}</div></div>`
      + `<div class="pbox"><div class="h">Look at</div><div>${linkify(packet.lookAt)}</div></div>`
      + `<div class="pbox"><div class="h">Checks · ${packet.checks.filter((c) => c.ok).length}/${packet.checks.length} passed</div><div class="checks">${renderChecks(packet)}</div></div>`
      + `<div class="pbox"><div class="h">Not verified · ${packet.notVerified.length}</div><div class="${packet.notVerified.length ? "warn" : "dim"}">`
      + (packet.notVerified.length ? packet.notVerified.map(esc).join("<br>") : "Everything was checked") + `</div></div></div>`;
    html += renderThumbs(task, packet);
  } else if (item.kind === "packet") {
    html += `<div class="dim">The task has not published a packet yet.</div>`;
  } else if (item.kind === "task-started") {
    html += `<div class="dim">Started${task.project ? ` in ${esc(task.project)}` : ""}.</div>`;
  }
  html += renderReplyBox(item, task, ui);

  if (packet && item.kind === "packet" && !item.superseded) {
    if (ui.confirmingMerge === item.id) {
      html += `<div class="confirm"><div>Merge ${esc(task.pullRequestLabel ?? "the pull request")} as it is now? ${esc(task.mergePolicy)}</div>`
        + `<div class="btns"><button class="btn primary" id="merge-go-${esc(item.id)}" data-act="merge-go" data-task="${esc(task.id)}">Merge</button><button class="btn" data-act="merge-cancel">Cancel</button></div></div>`;
    } else {
      html += `<div class="btns">`
        + (task.canMerge ? `<button class="btn primary" id="merge-${esc(item.id)}" data-act="merge" data-id="${esc(item.id)}">Merge</button>` : "")
        + `<button class="btn" id="report-${esc(item.id)}" data-act="open-report" data-task="${esc(task.id)}" data-version="${packet.version}">Full report</button>`
        + (task.hasTaskSpace ? `<button class="btn" data-act="open-task" data-task="${esc(task.id)}">Open task space</button>` : "")
        + (task.pullRequestURL ? `<button class="btn" id="open-pr-${esc(item.id)}" data-act="open-url" data-url="${esc(task.pullRequestURL)}">Open PR</button>` : "")
        + `</div>`;
    }
    html += `<div class="policy">${esc(task.project ?? "this project")}: ${esc(task.mergePolicy)}</div>`;
  }
  return html + `</div>`;
}

// MARK: - Report

export type ReportMode = "before" | "after" | "side";

export interface ReportUIState {
  mode: ReportMode;
  width: number | null;
  annotate?: boolean;
  marks?: import("./marks").ReportMark[];
  sending?: boolean;
}

/// The widths the screenshots were taken at, smallest first.
export function reportWidths(packet: ReportPacket): number[] {
  // `== null` also takes a field the app left out.
  return [...new Set(packet.screenshots.map((s) => s.width).filter((w): w is number => w != null))].sort((a, b) => a - b);
}

/// The screenshots to show for a mode and width. Unpaired screenshots show
/// in every mode, so nothing the agent attached is hidden.
export function reportShots(packet: ReportPacket, ui: ReportUIState): ChatScreenshot[] {
  const atWidth = packet.screenshots.filter((s) => ui.width == null || s.width == null || s.width === ui.width);
  const unpaired = atWidth.filter((s) => s.pair == null);
  const before = atWidth.filter((s) => s.pair === "before");
  const after = atWidth.filter((s) => s.pair === "after");
  switch (ui.mode) {
    case "before": return [...before, ...unpaired];
    case "after": return [...after, ...unpaired];
    case "side": return [...before, ...after, ...unpaired];
  }
}

/// The starting view for a screenshot the user clicked.
export function reportUIFor(packet: ReportPacket, screenshot: string | null): ReportUIState {
  const widths = reportWidths(packet);
  const shot = packet.screenshots.find((s) => s.name === screenshot);
  const hasPairs = packet.screenshots.some((s) => s.pair === "before") && packet.screenshots.some((s) => s.pair === "after");
  return {
    mode: shot?.pair === "before" ? "before" : shot?.pair === "after" && !hasPairs ? "after" : hasPairs ? "side" : "after",
    width: shot?.width ?? widths[0] ?? null,
  };
}

export function renderReport(packet: ReportPacket, ui: ReportUIState): string {
  const widths = reportWidths(packet);
  const modes: [ReportMode, string][] = [["before", "Before"], ["after", "After"], ["side", "Side by side"]];
  const shots = reportShots(packet, ui);
  let html = `<header class="rhead"><div class="ctitle">${esc(packet.title)}</div>`
    + `<div class="mono dim small">packet v${packet.version}${packet.version < packet.latestVersion ? ` (latest v${packet.latestVersion})` : ""}`
    + (packet.headCommit ? ` · ${esc(packet.headCommit.slice(0, 12))}` : "") + `</div></header>`;
  if (packet.screenshots.length) {
    html += `<div class="rbar"><span class="seg" role="group" aria-label="Compare">`
      + modes.map(([mode, label]) => `<button type="button" class="${ui.mode === mode ? "on" : ""}" data-act="mode" data-mode="${mode}">${label}</button>`).join("")
      + `</span>`;
    if (widths.length) {
      html += `<span class="seg" role="group" aria-label="Width">`
        + widths.map((w) => `<button type="button" class="${ui.width === w ? "on" : ""}" data-act="width" data-width="${w}">${w}</button>`).join("")
        + `</span>`;
    }
    html += `<button id="report-annotate" type="button" class="btn ${ui.annotate ? "amber" : ""}" data-act="annotate" aria-pressed="${!!ui.annotate}" ${packet.canAnnotate === false || ui.sending ? "disabled" : ""}>✎ ${ui.annotate ? "Annotating" : "Annotate"}</button>`;
    html += `</div><div class="viewer ${ui.mode === "side" ? "side" : ""} ${ui.annotate ? "annotating" : ""}">`
      + (shots.length ? shots.map((s) => `<figure class="shot"><figcaption class="mono dim small">${esc(s.name)}${s.width ? ` · ${s.width}` : ""}</figcaption><div class="shot-image"><img id="shot-${esc(s.name)}" data-act="pin" data-shot="${esc(s.name)}" src="${esc(s.url)}" alt="${esc(s.name)}">`
        + (ui.marks ?? []).map((m, i) => m.shot === s.name ? `<span class="apin" data-pin="${i}" aria-label="Mark ${i + 1}">${i + 1}</span>` : "").join("") + `</div></figure>`).join("")
        : `<div class="dim">No screenshot for this view.</div>`)
      + `</div>`;
    if (ui.annotate && !ui.marks?.length) html += `<div class="dim small">Click the screenshot to drop a mark, then write what you see.</div>`;
    if (ui.marks?.length) {
      html += `<div class="report-notes">` + ui.marks.map((m, i) => `<div class="report-note"><span class="mono">${i + 1}</span><input id="report-note-${i}" data-note="${i}" value="${esc(m.note)}" placeholder="What's wrong here?" aria-label="Note ${i + 1}" ${ui.sending ? "disabled" : ""}><span class="mono dim small">${esc(m.shot)}</span><button type="button" data-act="remove-mark" data-index="${i}" aria-label="Remove mark ${i + 1}" ${ui.sending ? "disabled" : ""}>×</button></div>`).join("") + `</div>`;
      html += `<button id="report-send" class="btn amber" data-act="send-marks" ${ui.sending ? "disabled" : ""}>${ui.sending ? "Sending…" : `Send ${ui.marks.length} mark${ui.marks.length === 1 ? "" : "s"} to ${esc(packet.slug ?? packet.title)}`}</button>`;
    }
  }
  html += `<section class="rsec"><h2>What changed</h2><p>${esc(packet.summary)}</p></section>`
    + `<section class="rsec"><h2>Look at</h2><p>${esc(packet.lookAt)}</p></section>`
    + `<section class="rsec"><h2>Checks</h2><div class="checks">`
    + (packet.checks.length ? packet.checks.map((c) => `<span class="check"><span class="${c.ok ? "ok" : "bad"}">${c.ok ? "✓" : "✗"}</span> ${esc(c.name)}${c.log ? ` <span class="faint log">${esc(c.log)}</span>` : ""}</span>`).join("") : `<span class="dim">No checks listed</span>`)
    + `</div></section>`
    + `<section class="rsec"><h2>Not verified</h2>`
    + (packet.notVerified.length ? `<ul>${packet.notVerified.map((n) => `<li>${esc(n)}</li>`).join("")}</ul>` : `<p class="dim">Everything was checked.</p>`)
    + `</section>`;
  return html;
}
