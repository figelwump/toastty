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
    canMerge: true, canReply: true, defaultReplyTarget: "task", ...overrides,
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
  return { type: "card", id: "c1", at: "2026-10-24T10:00:00Z", kind: "packet", text: null, superseded: false, isNew: false, task: task(), packet: packet(),
    options: [], answer: null, thread: [], isCurrent: true, ...overrides };
}

test("agent text is escaped everywhere, and links open in the right panel", () => {
  const ui = render.newUIState();
  const html = render.renderItem({ type: "message", id: "m1", at: "", role: "assistant", text: "<img src=x onerror=alert(1)> see https://example.com/a." }, ui);
  assert.ok(!html.includes("<img"));
  assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
  // Markdown links are the same right-panel buttons; the page has no <a>.
  assert.ok(html.includes('class="bubble md"') && html.includes('data-act="open-url" data-url="https://example.com/a"'));
  assert.ok(!html.includes("<a "));
  const user = render.renderItem({ type: "message", id: "u1", at: "", role: "user", text: "see https://example.com/b" }, ui);
  assert.ok(user.includes('data-act="open-url" data-url="https://example.com/b"'));
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

test("question cards use the app's default reply target and keep the target switch", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  const questionCard = card({ id: "q1", kind: "question", text: "Which base branch?", packet: null,
    task: task({ defaultReplyTarget: "coordinator" }) });
  const question = render.renderItem(questionCard, ui);
  assert.ok(question.includes("Which base branch?"));
  assert.match(question, /<form[^>]*data-to="coordinator"/);
  assert.ok(question.includes("to task</button>") && question.includes("to coordinator</button>"));
  const waiting = render.renderItem({ ...questionCard, task: task({ defaultReplyTarget: "task" }) }, ui);
  assert.match(waiting, /<form[^>]*data-to="task"/);
  assert.ok(waiting.includes("Reply to fix-totals…"));
  ui.replyTarget.set("q1", "task");
  assert.match(render.renderItem(questionCard, ui), /<form[^>]*data-to="task"/);
});

test("packet and task-started cards keep their task default and packet input label", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  for (const kind of ["packet", "task-started"]) {
    const item = card({ kind, task: task({ defaultReplyTarget: "coordinator" }) });
    assert.match(render.renderItem(item, ui), /<form[^>]*data-to="task"/);
    assert.match(render.renderItem({ ...item, task: task({ canReply: false, defaultReplyTarget: "task" }) }, ui), /<form[^>]*data-to="coordinator"/);
  }
  assert.ok(render.renderItem(card(), ui).includes('aria-label="Review note for fix-totals…"'));
});

test("a note without a task is plain text", () => {
  const ui = render.newUIState();
  const note = render.renderItem(card({ id: "n1", kind: "note", text: "Fresh session.", task: null, packet: null }), ui);
  assert.ok(note.includes('class="note-card md"') && note.includes("Fresh session."));
});

test("an open card shows explicit task thread roles and keeps agent text safe", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  const html = render.renderItem(card({ thread: [
    { id: "r1", at: "", role: "user-task", text: "Use **this** <button>" },
    { id: "r2", at: "", role: "user-coordinator", text: "Why this task?" },
    { id: "r3", at: "", role: "coordinator", text: "**The task** owns it. <img src=x>" },
    { id: "r4", at: "", role: "agent", text: "Updated the [report](https://example.com/report)." },
  ] }), ui);
  assert.ok(html.includes('class="thread"'));
  assert.ok(html.includes("You → task") && html.includes("You → coordinator"));
  assert.ok(html.includes('class="who co">coordinator</span>'));
  assert.ok(html.includes('class="who agent">fix-totals</span>'));
  assert.ok(html.includes("Use **this** &lt;button&gt;"));
  assert.ok(html.includes("<strong>The task</strong> owns it. &lt;img src=x&gt;"));
  assert.ok(html.includes('data-url="https://example.com/report"'));
  assert.ok(!html.includes("<img src=x>"));
});

test("question options are escaped buttons, and the saved answer replaces them", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  const question = card({ id: "q1", kind: "question", text: "Which base?", packet: null,
    options: ['Use "staging"', "<main>"], task: task({ defaultReplyTarget: "coordinator" }) });
  const html = render.renderItem(question, ui);
  assert.ok(html.includes('id="option-q1-0"'));
  assert.ok(html.includes('data-act="answer" data-id="q1" data-index="1"'));
  assert.ok(html.includes("Use &quot;staging&quot;") && html.includes("&lt;main&gt;"));
  const answered = render.renderItem({ ...question, answer: 'Use "staging"' }, ui);
  assert.ok(answered.includes(">answered<") && answered.includes("Use &quot;staging&quot;"));
  assert.ok(!answered.includes('data-act="answer"'));
  assert.ok(!answered.includes(">question<"));
  ui.expanded.clear();
  assert.ok(render.renderItem({ ...question, answer: 'Use "staging"' }, ui).includes(">answered<"));
});

test("a pending card disables its answers and reply without changing its draft", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  ui.pendingCards.add("q1");
  ui.drafts.set("q1", "another thought");
  const question = card({ id: "q1", kind: "question", packet: null, options: ["Staging"] });
  const pending = render.renderItem(question, ui);
  assert.match(pending, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.match(pending, /<input[^>]*value="another thought"[^>]*disabled/);
  const unavailable = render.renderItem({ ...question, task: task({ canReply: false }) }, { ...render.newUIState(), expanded: new Set(["q1"]) });
  assert.match(unavailable, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.match(unavailable, /<input[^>]*disabled/);
  assert.ok(unavailable.includes("The task cannot receive replies now."));
  const coordinatorButton = unavailable.match(/<button[^>]*id="reply-to-coordinator-q1"[^>]*>/)?.[0];
  assert.ok(coordinatorButton && !coordinatorButton.includes("disabled"));
  const coordinatorUnavailable = render.renderItem({ ...question, task: task({ defaultReplyTarget: "coordinator" }) }, { ...render.newUIState(), expanded: new Set(["q1"]) }, false);
  assert.match(coordinatorUnavailable, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.ok(coordinatorUnavailable.includes("The coordinator cannot receive messages now."));
});

test("only the current card can merge, regardless of its kind, and menus stay native", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  for (const kind of ["packet", "question", "note", "task-started"]) {
    const item = card({ kind, packet: kind === "packet" ? packet() : null });
    const html = render.renderItem(item, ui);
    assert.ok(html.includes('id="merge-c1"'), `missing Merge on ${kind}`);
    assert.ok(html.includes('id="menu-c1"') && html.includes('data-act="card-menu" data-task="T1"'));
    assert.ok(!html.includes('data-act="task-action"'), "Swift owns menu actions");
    assert.ok(!render.renderItem({ ...item, isCurrent: false }, ui).includes('data-act="merge"'));
  }
  const state = { coordinator: { canSend: true }, items: [card({ id: "old", isCurrent: false }), card({ id: "current", kind: "question", packet: null })] };
  ui.expanded = new Set(["old", "current"]);
  assert.equal((render.renderTimeline(state, ui).match(/data-act="merge"/g) ?? []).length, 1);
});

test("the coordinator's markdown renders, and stays safe", () => {
  const html = render.markdown([
    "**Running (1 task)**",
    "- **Fix totals** (`AB41B01A`, Claude)",
    "",
    "First line",
    "second line",
    "",
    "| a | b |", "|---|---|", "| 1 | 2 |",
    "",
    "```sh", "ls -la", "```",
  ].join("\n"));
  assert.ok(html.includes("<p><strong>Running (1 task)</strong></p>"));
  assert.ok(html.includes("<li><strong>Fix totals</strong> (<code>AB41B01A</code>, Claude)</li>"));
  // The line break stays in the paragraph; the stylesheet shows it.
  assert.ok(html.includes("<p>First line\nsecond line</p>"));
  assert.ok(html.includes("<table>") && html.includes("<td>1</td>"));
  assert.ok(html.includes('<pre><code class="language-sh">ls -la'));

  const hostile = render.markdown("<script>alert(1)</script>\n\nText <b onclick=x>b</b> [x](javascript:alert(1)) ![i](https://e.com/a.png)");
  assert.ok(!/<script|<b |<img/.test(hostile));
  assert.ok(hostile.includes("&lt;script&gt;") && hostile.includes("&lt;b onclick=x&gt;"));
  // An unsafe link loses its target; an image becomes a link to it.
  assert.ok(hostile.includes('<button class="lnk inline" disabled>x</button>') && !hostile.includes("javascript:"));
  assert.ok(hostile.includes('!<button class="lnk inline" data-act="open-url" data-url="https://e.com/a.png">i</button>'));
  assert.ok(!hostile.includes("<a "));
  // The app takes only a lowercase http(s) scheme.
  assert.ok(render.markdown('[Docs](HTTPS://example.com/A?b=1&c=2 "t")').includes('data-url="https://example.com/A?b=1&amp;c=2">Docs</button>'));
});

test("a question asked from a card shows only what the user typed, with its task", () => {
  const ui = render.newUIState();
  const html = render.renderItem({
    type: "message", id: "u1", at: "", role: "user", text: "yes, **move it**",
    aboutTaskID: "T1", aboutTitle: 'the "coordinator" session',
  }, ui);
  assert.ok(html.includes('data-act="focus-task" data-task="T1"'));
  assert.ok(html.includes("About the &quot;coordinator&quot; session"));
  // What the user typed is plain text, not markdown.
  assert.ok(html.includes("yes, **move it**"));
  const plain = render.renderItem({ type: "message", id: "u2", at: "", role: "user", text: "hi" }, ui);
  assert.ok(!plain.includes("focus-task"));
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
