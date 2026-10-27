// Pure HTML builders for the chat and the report. Every value from the app
// is text that an agent or a task wrote, so it is escaped here; the only
// markup is ours.
import { micromark } from "micromark";
import { gfm, gfmHtml } from "micromark-extension-gfm";
import { currentProject, projectForOption, projectID, projectsFor } from "./projects";
import type { ChatItem, ChatPacket, ChatScreenshot, ChatState, ChatTask, ChatUIState, ReportPacket, Tone } from "./types";

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
  return { expanded: new Set(), superseded: new Set(), drafts: new Map(), draftContext: new Map(), replyTarget: new Map(), pendingCards: new Set(), confirmingMerge: null };
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
  return item.type === "card" && (item.task == null ? item.kind === "question" && item.options.length > 0 : ui.expanded.has(item.id));
}

export function cardStateKey(item: Extract<ChatItem, { type: "card" }>): string {
  return item.task ? `task:${item.task.id}` : `route:${item.id}`;
}

/// The app replaces a task's card when new content arrives. Keep its open
/// state, but never carry a merge confirmation to the new content.
export function retainTaskCards(previous: ChatState | null, next: ChatState, ui: ChatUIState) {
  const nextIDs = new Set(next.items.map((item) => item.id));
  const replacements = new Map<string, string | null>();
  for (const item of previous?.items ?? []) {
    if (item.type !== "card" || !item.task || nextIDs.has(item.id)) continue;
    replacements.set(item.id, focusCardID(next, item.task.id));
    if (ui.confirmingMerge === item.id) ui.confirmingMerge = null;
  }
  ui.expanded = new Set([...ui.expanded].flatMap((id) => {
    const replacement = replacements.has(id) ? replacements.get(id) : id;
    return replacement && nextIDs.has(replacement) ? [replacement] : [];
  }));
  if (ui.confirmingMerge) {
    const before = previous?.items.find((item) => item.type === "card" && item.id === ui.confirmingMerge);
    const after = next.items.find((item) => item.type === "card" && item.id === ui.confirmingMerge);
    if (before?.type !== "card" || after?.type !== "card" || !after.isCurrent || after.superseded || !after.task?.canMerge
      || before.packet?.version !== after.packet?.version || before.task?.packetVersion !== after.task.packetVersion
      || before.task?.id !== after.task.id || before.task?.stageLabel !== after.task.stageLabel) ui.confirmingMerge = null;
  }
}

/// The task's current card, with a fallback for older app payloads.
export function focusCardID(state: ChatState, taskID: string): string | null {
  const cards = state.items.filter((item) => item.type === "card" && item.task?.id === taskID);
  const current = [...cards].reverse().find((item) => item.type === "card" && item.isCurrent && !item.superseded);
  const packet = [...cards].reverse().find((item) => item.type === "card" && item.kind === "packet" && !item.superseded);
  return (current ?? packet ?? cards[cards.length - 1])?.id ?? null;
}

export function renderProjectFilter(state: ChatState): string {
  const selected = currentProject(state);
  return `<div class="pfilter" role="group" aria-label="Project filter">`
    + `<button type="button" id="project-filter-all" class="${selected === null ? "on" : ""}" data-act="project-filter" aria-pressed="${selected === null}">All projects</button>`
    + projectsFor(state).map((project, index) => `<button type="button" id="project-filter-${index}" class="${selected === project.id ? "on" : ""}" data-act="project-filter" data-project="${esc(project.id)}" title="${esc(project.id)}" aria-pressed="${selected === project.id}">${esc(project.title)}</button>`).join("")
    + `</div>`;
}

export function renderHeader(state: ChatState): string {
  const c = state.coordinator;
  return `<div class="chead"><span class="cmark">C</span><div class="who"><div class="name">${esc(c.title)}</div>`
    + `<div class="mono dim small">${esc(c.detail)}</div></div>`
    + renderProjectFilter(state)
    + `<button class="tb-btn" id="open-routing" data-act="open-routing" title="Open routing.md in the right panel">routing.md</button>`
    + (c.hasTerminal ? `<button class="tb-btn" data-act="open-terminal" title="Show the coordinator's terminal">Open terminal</button>` : "")
    + `</div>`;
}

function visibleItems(state: ChatState): ChatItem[] {
  const project = currentProject(state);
  return state.items.filter((item) => project === null || item.type !== "card" || item.task == null || projectID(item.task) === project);
}

/// The native command palette acts only on cards the user can see. Keep
/// the complete UI set so hidden cards reopen with their drafts intact.
export function visibleExpandedIDs(state: ChatState, ui: ChatUIState): string[] {
  const visible = new Set(visibleItems(state).filter((item) => item.type === "card" && item.task != null).map((item) => item.id));
  return [...ui.expanded].filter((id) => visible.has(id));
}

export function renderTimeline(state: ChatState, ui: ChatUIState): string {
  if (state.items.length === 0) {
    return `<div class="empty-chat"><div class="cmark big">C</div><p>Tell the coordinator what you want done.</p>`
      + `<p class="dim">It routes each request to a task in the right project and posts here when one needs you.</p></div>`;
  }
  return visibleItems(state).map((item) => renderItem(item, ui, state.coordinator.canSend, state)).join("");
}

export function renderItem(item: ChatItem, ui: ChatUIState, coordinatorCanSend = true, state?: ChatState): string {
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
      return `<div class="msg-co card-row" id="card-${esc(item.id)}" data-item="${esc(item.id)}"${item.task ? ` data-task="${esc(item.task.id)}"` : ""}><span class="cmark">C</span><div class="bubble">`
        + (!item.task ? item.kind === "question" && item.options.length > 0 ? renderRoute(item, ui, coordinatorCanSend, state) : renderCompactCard(item)
          : isExpanded(item, ui) ? renderOpenCard(item, ui, coordinatorCanSend) : renderCompactCard(item)) + `</div></div>`;
  }
}

function cardSubtitle(item: Extract<ChatItem, { type: "card" }>): string {
  if (item.task?.stageLabel === "stuck") return item.task.failureText || "The task's agent reported an error.";
  if (item.kind === "question" && item.answer !== null) return `Answered: ${item.answer}`;
  const last = item.thread.at(-1);
  if (last) {
    const who = last.role === "agent" ? item.task?.slug ?? "agent" : last.role === "coordinator" ? "coordinator" : "you";
    return `${who}: ${last.text}`;
  }
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
  const kindBadge = cardBadge(item, task);
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

function cardBadge(item: Extract<ChatItem, { type: "card" }>, task: ChatTask): string {
  if (task.stageLabel === "stuck") return badge("stuck", task.stageTone);
  if (item.kind !== "question") return badge(task.stageLabel, task.stageTone);
  return item.answer !== null ? badge("answered", "green") : badge("question", "amber");
}

export function replyTarget(item: Extract<ChatItem, { type: "card" }>, ui: ChatUIState): "task" | "coordinator" {
  return ui.replyTarget.get(cardStateKey(item)) ?? ui.draftContext.get(cardStateKey(item))?.target ?? (item.kind === "question"
    ? item.task?.defaultReplyTarget ?? "coordinator"
    : item.task?.canReply ? "task" : "coordinator");
}

function renderReplyBox(item: Extract<ChatItem, { type: "card" }>, task: ChatTask, ui: ChatUIState, coordinatorCanSend: boolean): string {
  const target = replyTarget(item, ui);
  const pending = ui.pendingCards.has(cardStateKey(item));
  const available = target === "task" ? task.canReply : coordinatorCanSend;
  const segment = `<span class="seg" role="group" aria-label="Send reply to">`
    + `<button type="button" id="reply-to-task-${esc(item.id)}" class="${target === "task" ? "on" : ""}" data-act="reply-to" data-id="${esc(item.id)}" data-to="task" aria-pressed="${target === "task"}"${!task.canReply || pending ? " disabled" : ""}>to task</button>`
    + `<button type="button" id="reply-to-coordinator-${esc(item.id)}" class="${target === "coordinator" ? "on" : ""}" data-act="reply-to" data-id="${esc(item.id)}" data-to="coordinator" aria-pressed="${target === "coordinator"}"${!coordinatorCanSend || pending ? " disabled" : ""}>to coordinator</button></span>`;
  const placeholder = target === "task"
    ? `${item.kind === "packet" ? "Review note for" : "Reply to"} ${task.slug}…`
    : "Ask the coordinator about this…";
  const context = ui.draftContext.get(cardStateKey(item));
  const earlierDraft = context && context.cardID !== item.id
    ? context.questionID ? `Draft for earlier question${context.questionText ? `: ${context.questionText}` : ""}`
      : context.version != null ? `Draft for packet v${context.version}` : "Draft for an earlier task update"
    : null;
  return `<form class="replybox" data-act="reply" data-id="${esc(item.id)}" data-task="${esc(task.id)}" data-version="${item.packet?.version ?? ""}" data-to="${target}">`
    + segment + `<input id="reply-${esc(item.id)}" name="text" autocomplete="off" autocorrect="off" spellcheck="false" maxlength="${maximumTextLength}" placeholder="${esc(placeholder)}" aria-label="${esc(placeholder)}" value="${esc(ui.drafts.get(cardStateKey(item)) ?? "")}"${!available || pending ? " disabled" : ""}><span class="kbd">↩</span></form>`
    + (earlierDraft ? `<div class="reply-hint dim small" data-draft-context>${esc(earlierDraft)}</div>` : "")
    + (!available ? `<div class="reply-hint dim small">${target === "task" ? "The task cannot receive replies now." : "The coordinator cannot receive messages now."}</div>` : "");
}

function renderRoute(item: Extract<ChatItem, { type: "card" }>, ui: ChatUIState, coordinatorCanSend: boolean, state?: ChatState): string {
  const [title, ...why] = (item.text ?? "").split(/\r?\n/);
  const answered = item.answer !== null;
  const pending = item.answerPending || ui.pendingCards.has(cardStateKey(item));
  const choices = item.options.map((value) => ({ value, project: state ? projectForOption(state, value) : null }));
  const tooltip = ({ project }: typeof choices[number]) => {
    if (!project) return "";
    const identity = project.rootPath ?? project.id;
    const collision = choices.some((other) => other.project
      ? (other.project.rootPath ?? other.project.id) !== identity && other.project.title === project.title
      : other.value === project.title);
    return collision ? ` title="${esc(identity)}"` : "";
  };
  const answer = choices.find((choice) => choice.value === item.answer);
  return `<div class="card${answered ? "" : " need"}"><div class="crow">`
    + badge(answered ? "answered" : "question", answered ? "green" : "amber")
    + `<span class="grow ctitle">${esc(title)}</span></div>`
    + (why.length ? `<div class="card-text dim md">${markdown(why.join("\n"))}</div>` : "")
    + (answered ? `<div class="answer"><span class="mono dim small">Answered</span><span class="txt"${answer ? tooltip(answer) : ""}>${esc(answer?.project?.title ?? item.answer)}</span></div>`
      : `<div class="opts">${choices.map((choice, index) => `<button class="btn" id="option-${esc(item.id)}-${index}" data-act="answer-route" data-id="${esc(item.id)}" data-index="${index}"${tooltip(choice)}${!coordinatorCanSend || pending ? " disabled" : ""}>${esc(choice.project?.title ?? choice.value)}</button>`).join("")}</div>`)
    + (pending && !answered ? `<div class="dim small">Waiting for the coordinator to confirm this answer.</div>` : "")
    + `</div>`;
}

function packetVersions(item: Extract<ChatItem, { type: "card" }>): number[] {
  return [...new Set([...(item.packetVersions ?? []), item.packet?.version, item.task?.packetVersion]
    .filter((version): version is number => Number.isInteger(version) && (version ?? 0) > 0))].sort((a, b) => a - b);
}

function renderThread(item: Extract<ChatItem, { type: "card" }>, task: ChatTask, ui: ChatUIState, coordinatorCanSend: boolean): string {
  return `<div class="thread">` + item.thread.map((message) => {
    const who = message.role === "agent" ? task.slug : message.role === "coordinator" ? "coordinator" : message.role === "user-task" ? "You → task" : "You → coordinator";
    const agent = message.role === "agent" || message.role === "coordinator";
    const tone = message.role === "agent" ? " agent" : message.role === "coordinator" ? " co" : "";
    return `<div class="tmsg" data-thread-item="${esc(message.id)}"><span class="who${tone}">${esc(who)}</span><div class="txt${agent ? " md" : ""}">${agent ? markdown(message.text) : linkify(message.text)}</div></div>`;
  }).join("") + renderReplyBox(item, task, ui, coordinatorCanSend) + `</div>`;
}

export function renderOpenCard(item: Extract<ChatItem, { type: "card" }>, ui: ChatUIState, coordinatorCanSend = true): string {
  const task = item.task!;
  const packet = item.packet;
  const current = item.isCurrent && !item.superseded;
  const stuck = task.stageLabel === "stuck";
  let html = `<div class="card ${task.needsUser ? "need" : ""}"><div class="crow">`
    + cardBadge(item, task)
    + (item.isNew ? badge("new", "green") : "")
    + `<span class="grow ctitle">${esc(task.title)}</span>`
    + (task.project ? badge(task.project, "plain") : "")
    + (packet ? `<span class="mono faint small">packet v${packet.version}${packet.version < packet.latestVersion ? ` of ${packet.latestVersion}` : ""}</span>` : "")
    + (task.stale && packet ? badge("stale: new commits", "red") : "")
    + (task.hasTaskSpace ? `<button class="lnk" data-act="open-task" data-task="${esc(task.id)}">task ↗</button>` : "")
    + (task.pullRequestURL ? `<button class="lnk" data-act="open-url" data-url="${esc(task.pullRequestURL)}">${esc(task.pullRequestLabel ?? "PR")} ↗</button>` : "")
    + `<button class="collapse" id="collapse-${esc(item.id)}" data-act="expand" data-id="${esc(item.id)}" aria-expanded="true">▾ collapse</button></div>`;

  if (stuck) {
    if (task.failureText) html += `<div class="card-text md">${markdown(task.failureText)}</div>`;
    if (task.hasTaskSpace || current && task.canArchive) html += `<div class="btns">`
      + (task.hasTaskSpace ? `<button class="btn" id="open-stuck-${esc(item.id)}" data-act="open-task" data-task="${esc(task.id)}">Open the task space</button>` : "")
      + (current && task.canArchive ? `<button class="btn" id="archive-${esc(item.id)}" data-act="archive-task" data-task="${esc(task.id)}">Archive it</button>` : "") + `</div>`;
  }
  if (item.kind === "question" || item.kind === "note") {
    if (stuck && item.kind === "question" && item.answer !== null) html += `<div class="mono dim small">Earlier question</div>`;
    html += `<div class="card-text md">${markdown(item.text ?? "")}</div>`;
  }
  if (item.kind === "question") {
    if (item.answer !== null) {
      if (!stuck) html += `<div class="answer"><span class="mono dim small">Answered</span><span class="txt">${linkify(item.answer)}</span></div>`;
    } else if (item.options.length) {
      const available = replyTarget(item, ui) === "task" ? task.canReply : coordinatorCanSend;
      html += `<div class="opts">` + item.options.map((option, index) => `<button class="btn" id="option-${esc(item.id)}-${index}" data-act="answer" data-id="${esc(item.id)}" data-index="${index}"${!available || ui.pendingCards.has(cardStateKey(item)) ? " disabled" : ""}>${esc(option)}</button>`).join("") + `</div>`;
    }
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
  html += renderThread(item, task, ui, coordinatorCanSend);

  const versions = packetVersions(item);
  const reportVersion = current ? versions.at(-1) : item.kind === "packet" ? packet?.version : null;
  const showPacketActions = reportVersion != null && !item.superseded;
  if (current || showPacketActions) {
    if (current && task.canMerge && ui.confirmingMerge === item.id) {
      html += `<div class="confirm"><div>Merge ${esc(task.pullRequestLabel ?? "the pull request")} as it is now? ${esc(task.mergePolicy)}</div>`
        + `<div class="btns"><button class="btn primary" id="merge-go-${esc(item.id)}" data-act="merge-go" data-task="${esc(task.id)}">Merge</button><button class="btn" data-act="merge-cancel">Cancel</button></div></div>`;
    } else {
      html += `<div class="btns">`
        + (current && task.canMerge ? `<button class="btn primary" id="merge-${esc(item.id)}" data-act="merge" data-id="${esc(item.id)}">Merge</button>` : "")
        + (current ? `<button class="btn more" id="menu-${esc(item.id)}" data-act="card-menu" data-task="${esc(task.id)}" aria-label="Actions for ${esc(task.title)}" aria-haspopup="menu">▾</button>` : "")
        + (showPacketActions ? `<button class="btn" id="report-${esc(item.id)}" data-act="open-report" data-task="${esc(task.id)}" data-version="${reportVersion}">Full report</button>` : "")
        + (!stuck && task.hasTaskSpace ? `<button class="btn" data-act="open-task" data-task="${esc(task.id)}">Open task space</button>` : "")
        + (task.pullRequestURL ? `<button class="btn" id="open-pr-${esc(item.id)}" data-act="open-url" data-url="${esc(task.pullRequestURL)}">Open PR</button>` : "")
        + `</div>`;
    }
    if (current && task.canMerge) html += `<div class="policy">${esc(task.project ?? "this project")}: ${esc(task.mergePolicy)}</div>`;
  }
  const earlier = current ? versions.filter((version) => version !== reportVersion) : [];
  if (earlier.length) html += `<div class="btns"><span class="mono dim small">Earlier reports</span>`
    + earlier.map((version) => `<button class="lnk" id="report-${esc(item.id)}-${version}" data-act="open-report" data-task="${esc(task.id)}" data-version="${version}">v${version}</button>`).join("") + `</div>`;
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
