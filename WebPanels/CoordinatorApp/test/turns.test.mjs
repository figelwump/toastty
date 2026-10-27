import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildSync } from "esbuild";

// Bundle the real modules once, so the tests run what the page runs.
const directory = mkdtempSync(join(tmpdir(), "toastty-coordinator-turns-"));
const modules = {};
for (const name of ["turns", "render"]) {
  const outfile = join(directory, `${name}.mjs`);
  buildSync({ entryPoints: [resolve(import.meta.dirname, `../src/${name}.ts`)], bundle: true, format: "esm", platform: "neutral", outfile, logLevel: "silent" });
  modules[name] = await import(outfile);
}
rmSync(directory, { recursive: true, force: true });
const { foldWork, latestStep, durationLabel } = modules.turns;
const render = modules.render;

let second = 0;
const at = () => new Date(Date.UTC(2026, 9, 27, 17, 0, second++)).toISOString();
const user = (id, text = "cleanup worktrees", extra = {}) => ({ type: "message", id, at: at(), role: "user", text, ...extra });
const note = (id, text = "Checking the project.") => ({ type: "message", id, at: at(), role: "assistant", text, phase: "commentary" });
const reply = (id, text = "Started a task.", phase = "final") => ({ type: "message", id, at: at(), role: "assistant", text, ...(phase ? { phase } : {}) });
const tool = (id, outcome = "succeeded", detail = "toastty task list") => ({ type: "tool", id, at: at(), name: "Bash", detail, outcome });
const card = (id) => ({ type: "card", id, at: at(), kind: "note", text: "A note", superseded: false, isNew: false, task: null, packet: null, options: [], answer: null, thread: [], isCurrent: true });
const shape = (entries) => entries.map((entry) => entry.type === "work" ? `work:${entry.fold.items.map((item) => item.id).join(",")}${entry.fold.live ? ":live" : ""}` : entry.item.id);

test("a turn's tools and in-between messages fold into one run beside its request and reply", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), note("n1"), tool("t2"), card("c1"), tool("t3"), reply("r1")];
  const entries = foldWork(items, false);
  // A card posted during the turn stays visible, after the run's line.
  assert.deepEqual(shape(entries), ["u1", "work:t1,n1,t2,t3", "c1", "r1"]);
  const fold = entries[1].fold;
  assert.equal(fold.toolCount, 3);
  assert.equal(fold.noteCount, 1);
  // From the request to the reply.
  assert.equal(fold.startedAt, items[0].at);
  assert.equal(fold.endedAt, items[6].at);
});

test("work after a reply with no request, as after a background wake-up, folds on its own", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), reply("r1"), tool("t2"), note("n2"), reply("r2")];
  assert.deepEqual(shape(foldWork(items, false)), ["u1", "work:t1", "r1", "work:t2,n2", "r2"]);
  // Its time starts at its first step, not at the earlier request.
  assert.equal(foldWork(items, false)[3].fold.startedAt, items[3].at);
});

test("only the open run at the end is live, and only while the coordinator works", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), reply("r1"), user("u2"), tool("t2"), note("n2"), tool("t3", "running")];
  assert.deepEqual(shape(foldWork(items, true)), ["u1", "work:t1", "r1", "u2", "work:t2,n2,t3:live"]);
  const settled = [user("u1"), tool("t1"), reply("r1")];
  assert.deepEqual(shape(foldWork(settled, true)), ["u1", "work:t1", "r1"], "a run with its reply is never live");
});

test("a run that stopped without a reply shows its last message where the run ended", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), note("n1", "I stopped here."), card("c1"), user("u2"), tool("t2"), note("n2", "Still going.")];
  // Idle: both runs ended without a reply, as when the user pressed Esc.
  assert.deepEqual(shape(foldWork(items, false)), ["u1", "work:t1", "c1", "n1", "u2", "work:t2", "n2"]);
  // Working: the open run keeps its newest message in the working row.
  assert.deepEqual(shape(foldWork(items, true)), ["u1", "work:t1", "c1", "n1", "u2", "work:t2,n2:live"]);
  // A run of only a message still shows the message.
  assert.deepEqual(shape(foldWork([user("u3"), note("n3")], false)), ["u3", "n3"]);
  // A run stopped during a tool call still shows its last message.
  assert.deepEqual(shape(foldWork([user("u4"), note("n4"), tool("t4", "unknown")], false)), ["u4", "work:t4", "n4"]);
});

test("a stopped run is not the working row for a turn that began after it", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), note("n1", "I stopped here.")];
  const later = new Date(Date.parse(items[2].at) + 5_000).toISOString();
  assert.deepEqual(shape(foldWork(items, true, later)), ["u1", "work:t1", "n1"]);
  assert.deepEqual(shape(foldWork(items, true, items[0].at)), ["u1", "work:t1,n1:live"]);
  const html = render.renderTimeline({ coordinator: { canSend: true, working: true, turnStartedAt: later }, items, projects: [] }, render.newUIState(), Date.parse(later) + 3_000);
  // The new turn has its own row, without the old run's message as its step.
  assert.match(html, /<div class="work-strip live"><span class="tool-mark running"><\/span><span id="coordinator-activity" class="work-label">Working · <span[^>]*>3s<\/span><\/span>/);
});

test("an empty chat still shows the coordinator working", () => {
  const html = render.renderTimeline({ coordinator: { canSend: true, working: true }, items: [], projects: [] }, render.newUIState());
  assert.ok(html.includes('id="coordinator-activity"') && !html.includes("empty-chat"));
  const idle = render.renderTimeline({ coordinator: { canSend: true, working: false }, items: [], projects: [] }, render.newUIState());
  assert.ok(idle.includes("empty-chat") && !idle.includes('id="coordinator-activity"'));
});

test("a message with no phase is a reply, so providers that do not mark one still show it", () => {
  second = 0;
  const items = [user("u1"), tool("t1"), reply("r1", "Codex reply", null), tool("t2")];
  assert.deepEqual(shape(foldWork(items, false)), ["u1", "work:t1", "r1", "work:t2"]);
});

test("the working row names the newest message, else the running tool", () => {
  second = 0;
  const [, entry] = foldWork([user("u1"), tool("t1"), note("n1", "\nI'll check how task create\ntakes a project."), tool("t2", "running")], true);
  assert.equal(latestStep(entry.fold), "I'll check how task create");
  const [, toolOnly] = foldWork([user("u1"), tool("t1", "running", "toastty task create")], true);
  assert.equal(latestStep(toolOnly.fold), "Bash toastty task create");
  assert.equal(durationLabel(48_400), "48s");
  assert.equal(durationLabel(185_000), "3m 05s");
  assert.equal(durationLabel(Number.NaN), "0s");
});

test("the chat hides the launch prompt and shows the turn as one line that opens", () => {
  second = 0;
  const ui = render.newUIState();
  const items = [user("launch", "Use the toastty-coordinator skill.", { launch: true }), tool("t1"), note("n1", "<b>checking</b>"), tool("t2"), reply("r1", "Nothing needs you.")];
  const state = { coordinator: { canSend: true, working: false }, items, projects: [] };
  let html = render.renderTimeline(state, ui);
  assert.ok(!html.includes("Use the toastty-coordinator skill."));
  assert.match(html, /id="work-t1"[^>]*data-act="toggle-work"[^>]*aria-expanded="false"/);
  assert.ok(html.includes("worked 4s · 2 tool calls · 1 note"));
  assert.ok(!html.includes('class="tool"') && !html.includes("checking"));
  assert.ok(html.includes("Nothing needs you."));
  assert.ok(!html.includes('id="coordinator-activity"'));
  ui.expandedWork.add("t1");
  html = render.renderTimeline(state, ui);
  assert.ok(html.includes('aria-expanded="true"') && (html.match(/class="tool"/g) ?? []).length === 2);
  // A run under a second does not claim "0s".
  const instant = items.map((item) => ({ ...item, at: "2026-10-27T17:00:00.000Z" }));
  assert.ok(render.renderTimeline({ ...state, items: instant }, render.newUIState()).includes(">worked · 2 tool calls · 1 note<"));
  // An in-between message stays escaped and quieter than a reply.
  assert.ok(html.includes("msg-co commentary") && html.includes("&lt;b&gt;checking&lt;/b&gt;"));
});

test("while the coordinator works, its run is the working row with the turn's time", () => {
  second = 0;
  const ui = render.newUIState();
  const items = [user("u1"), tool("t1"), note("n1", "Checking the project.")];
  const started = "2026-10-27T17:00:00.000Z";
  const html = render.renderTimeline({ coordinator: { canSend: true, working: true, turnStartedAt: started }, items, projects: [] }, ui, Date.parse(started) + 12_000);
  assert.match(html, /<button[^>]*class="work-strip live"[^>]*>/);
  assert.ok(html.includes('id="coordinator-activity"') && html.includes(`data-since="${started}">12s<`));
  assert.ok(html.includes("Checking the project."));
  assert.equal((html.match(/id="coordinator-activity"/g) ?? []).length, 1);
  // Before the turn's first step there is still a working row.
  const fresh = render.renderTimeline({ coordinator: { canSend: true, working: true }, items: [user("u2")], projects: [] }, ui);
  assert.match(fresh, /class="work-strip live"><span class="tool-mark running"><\/span><span id="coordinator-activity"/);
});
