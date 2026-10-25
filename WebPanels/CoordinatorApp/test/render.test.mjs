import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildSync } from "esbuild";

// Bundle the real render module once, so the tests run what the page runs.
const directory = mkdtempSync(join(tmpdir(), "toastty-coordinator-render-"));
const outfile = join(directory, "render.mjs");
buildSync({
  entryPoints: [resolve(import.meta.dirname, "../src/render.ts")],
  bundle: true,
  format: "esm",
  platform: "neutral",
  outfile,
  logLevel: "silent",
});
const render = await import(outfile);
rmSync(directory, { recursive: true, force: true });

function task(overrides = {}) {
  return {
    id: "T1", title: "Fix the totals bar", slug: "fix-totals", project: "lumen",
    stageLabel: "review", stageTone: "blue", needsUser: true, hasTaskSpace: true,
    pullRequestURL: "https://github.com/o/r/pull/12", pullRequestLabel: "PR #12",
    packetVersion: 2, stale: false, mergePolicy: "Merge sends toastty-task-merge to the task's agent.",
    canMerge: true, canReply: true, ...overrides,
  };
}

function packet(overrides = {}) {
  return {
    version: 2, latestVersion: 2, summary: "Moves the totals up.", lookAt: "The bar at 390px",
    checks: [{ name: "unit", ok: true, log: "/tmp/u.log" }, { name: "e2e", ok: false, log: null }],
    notVerified: ["Safari"],
    screenshots: [
      { name: "before-390", pair: "before", width: 390, url: "/packet-files/T1/v2/before-390.png" },
      { name: "after-390", pair: "after", width: 390, url: "/packet-files/T1/v2/after-390.png" },
      { name: "after-1280", pair: "after", width: 1280, url: "/packet-files/T1/v2/after-1280.png" },
    ],
    ...overrides,
  };
}

function card(overrides = {}) {
  return { type: "card", id: "c1", at: "2026-10-24T10:00:00Z", kind: "packet", text: null, superseded: false, isNew: false, task: task(), packet: packet(), ...overrides };
}

test("agent text is escaped everywhere, and links become right-panel buttons", () => {
  const ui = render.newUIState();
  const html = render.renderItem({ type: "message", id: "m1", at: "", role: "assistant", text: "<img src=x onerror=alert(1)> see https://example.com/a." }, ui);
  assert.ok(!html.includes("<img"));
  assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
  assert.ok(html.includes('data-act="open-url" data-url="https://example.com/a"'));
  const hostile = card({ task: task({ title: '"><script>x</script>' }), packet: packet({ lookAt: "<b>bold</b>" }) });
  const compact = render.renderItem(hostile, ui);
  assert.ok(!compact.includes("<script>") && !compact.includes("<b>bold"));
});

test("a packet card is one line until opened, then shows the packet and its actions", () => {
  const ui = render.newUIState();
  const compact = render.renderItem(card(), ui);
  assert.ok(compact.includes('class="compact need"'));
  assert.ok(compact.includes("The bar at 390px"));
  assert.ok(compact.includes(">v2<"));
  assert.ok(!compact.includes("What changed"));

  ui.expanded.add("c1");
  const open = render.renderItem(card(), ui);
  for (const part of ["What changed", "Moves the totals up.", "Look at", "Checks · 1/2 passed", "✗", "Not verified · 1", "Safari",
    'data-shot="after-1280"', 'data-act="merge"', "Full report", "Open task space", 'data-to="task"', "PR #12 ↗"]) {
    assert.ok(open.includes(part), `missing ${part}`);
  }
  assert.ok(open.includes('data-version="2"'));
});

test("merge asks first and names the project's merge policy", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  ui.confirmingMerge = "c1";
  const html = render.renderItem(card(), ui);
  assert.ok(html.includes("Merge PR #12 as it is now? Merge sends toastty-task-merge to the task&#39;s agent."));
  assert.ok(html.includes('data-act="merge-go" data-task="T1"'));
  assert.ok(!html.includes('data-act="merge" '));
  const cannot = render.renderItem(card({ task: task({ canMerge: false }) }), { ...render.newUIState(), expanded: new Set(["c1"]) });
  assert.ok(!cannot.includes('data-act="merge"'));
});

test("new, stale and superseded cards say so", () => {
  const ui = render.newUIState();
  assert.ok(render.renderItem(card({ isNew: true }), ui).includes(">new<"));
  assert.ok(render.renderItem(card({ task: task({ stale: true }) }), ui).includes(">stale<"));
  const old = render.renderItem(card({ superseded: true, packet: packet({ version: 1, latestVersion: 2 }) }), ui);
  assert.ok(old.includes("replaced by v2") && old.includes("superseded"));
  ui.expanded.add("c1");
  assert.ok(!render.renderItem(card({ superseded: true, packet: packet({ version: 1 }) }), ui).includes('data-act="merge"'));
});

test("a question replies to the coordinator, and a note without a task is plain text", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  const question = render.renderItem(card({ id: "q1", kind: "question", text: "Which base branch?", packet: null }), ui);
  assert.ok(question.includes("Which base branch?"));
  assert.ok(question.includes('data-to="coordinator"') && !question.includes("to task</button>"));
  const note = render.renderItem(card({ id: "n1", kind: "note", text: "Fresh session.", task: null, packet: null }), ui);
  assert.ok(note.includes('class="note-card"') && note.includes("Fresh session."));
});

test("focus opens the task's newest packet card, else its last card", () => {
  const state = { items: [
    card({ id: "a", superseded: true }),
    card({ id: "b" }),
    card({ id: "c", kind: "task-started", packet: null }),
    card({ id: "d", task: task({ id: "T2" }), kind: "task-started", packet: null }),
  ] };
  assert.equal(render.focusCardID(state, "T1"), "b");
  assert.equal(render.focusCardID(state, "T2"), "d");
  assert.equal(render.focusCardID(state, "T3"), null);
});

test("the report pairs before and after by width, and keeps unpaired shots", () => {
  const report = { ...packet(), taskID: "T1", title: "Fix", headCommit: "abc", createdAt: null };
  report.screenshots.push({ name: "menu", pair: null, width: null, url: "/m.png" });
  assert.deepEqual(render.reportWidths(report), [390, 1280]);
  assert.deepEqual(render.reportShots(report, { mode: "side", width: 390 }).map((s) => s.name), ["before-390", "after-390", "menu"]);
  assert.deepEqual(render.reportShots(report, { mode: "after", width: 1280 }).map((s) => s.name), ["after-1280", "menu"]);
  assert.deepEqual(render.reportUIFor(report, "after-1280"), { mode: "side", width: 1280 });
  assert.deepEqual(render.reportUIFor(report, "before-390"), { mode: "before", width: 390 });
  const html = render.renderReport(report, { mode: "side", width: 390 });
  for (const part of ["Side by side", 'data-width="1280"', "before-390 · 390", "What changed", "Not verified", "abc"]) {
    assert.ok(html.includes(part), `missing ${part}`);
  }
});

test("a reply draft is kept while its card is closed, and a newly superseded card folds once", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  ui.drafts.set("c1", 'half a "note"');
  assert.ok(render.renderItem(card(), ui).includes('value="half a &quot;note&quot;"'));
  ui.expanded.delete("c1");
  ui.expanded.add("c1");
  assert.ok(render.renderItem(card(), ui).includes("half a &quot;note&quot;"));

  const state = { items: [card({ superseded: true })] };
  render.collapseNewlySuperseded(state, ui);
  assert.ok(!ui.expanded.has("c1"));
  ui.expanded.add("c1");
  render.collapseNewlySuperseded(state, ui);
  assert.ok(ui.expanded.has("c1"), "the user can open it again");
});

test("screenshots with pair and width left out still show, and long messages are refused", () => {
  const report = { ...packet(), taskID: "T1", title: "Fix", headCommit: null, createdAt: null,
    screenshots: [{ name: "menu", url: "/m.png" }] };
  assert.deepEqual(render.reportWidths(report), []);
  assert.deepEqual(render.reportShots(report, render.reportUIFor(report, "menu")).map((s) => s.name), ["menu"]);
  assert.ok(render.fitsMessage("x".repeat(16 * 1024)));
  assert.ok(!render.fitsMessage("é".repeat(8 * 1024 + 1)));
});
