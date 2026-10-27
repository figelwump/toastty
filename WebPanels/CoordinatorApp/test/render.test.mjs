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
    'data-shot="after-1280"', 'data-act="merge"', "Full report", "Open task space", 'class="replybox"', "PR #12 ↗"]) {
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

test("an open question sends replies to the coordinator, with no target switch", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  const question = render.renderItem(card({ id: "q1", kind: "question", text: "Which base branch?", packet: null }), ui);
  assert.ok(question.includes("Which base branch?"));
  assert.ok(question.includes('aria-label="Reply to the coordinator about fix-totals…"'));
  assert.ok(!question.includes('data-act="reply-to"') && !question.includes("data-to="));
});

test("a folded open question shows its text, a Show more link and its answers", () => {
  const ui = render.newUIState();
  const question = card({ id: "q1", kind: "question", packet: null, options: ["Add the hint", "Keep it"],
    text: "Add the hint to PR #213?\nRecommended: add the hint.\n\n- **Add the hint**: small, fits this PR.\n- **Keep it**: no change. <img src=x>" });
  const html = render.renderItem(question, ui);
  assert.ok(html.includes('class="card need qcard"'));
  assert.ok(html.includes('class="card need qcard" id="expand-body-q1" data-act="expand" data-id="q1" data-expand-body>'), "the body has its own stable expansion target without wrapping controls in a button");
  assert.ok(html.includes('id="expand-q1" data-act="expand"') && html.includes("Fix the totals bar"));
  assert.ok(html.includes("Recommended: add the hint.") && html.includes("<strong>Add the hint</strong>"));
  assert.ok(html.includes('data-clamp="q1"'));
  assert.match(html, /<button class="lnk more hidden" id="more-q1" data-act="expand" data-id="q1"/, "Show more waits for the page to measure the text");
  assert.ok(html.includes('id="option-q1-0"') && html.includes('id="option-q1-1"'));
  assert.ok(!html.includes("replybox") && !html.includes("<img src=x>"));
  const answered = render.renderItem({ ...question, answer: "Keep it" }, ui);
  assert.ok(answered.includes('class="compact') && answered.includes("Answered: Keep it") && !answered.includes('data-act="answer"'));
  const stuck = render.renderItem({ ...question, task: task({ stageLabel: "stuck", stageTone: "red" }) }, ui);
  assert.ok(stuck.includes('class="compact') && !stuck.includes("qcard"), "a stuck task's folded card shows its failure line");
  const closed = render.renderItem({ ...question, task: task({ canReply: false }) }, ui);
  assert.match(closed, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.ok(closed.includes("The task cannot take replies now."));
});

test("packet and task-started reply boxes name the task, and an unavailable task disables them", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  for (const kind of ["packet", "task-started"]) {
    const item = card({ kind });
    assert.match(render.renderItem(item, ui), /<input[^>]*id="reply-c1"(?![^>]*disabled)[^>]*>/);
    assert.match(render.renderItem({ ...item, task: task({ canReply: false }) }, ui), /<input[^>]*id="reply-c1"[^>]*disabled/);
  }
  assert.ok(render.renderItem(card(), ui).includes('aria-label="Review note for fix-totals, through the coordinator…"'));
  assert.ok(render.renderItem(card({ kind: "task-started" }), ui).includes('aria-label="Reply to the coordinator about fix-totals…"'));
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
  assert.equal(html.match(/class="who">You<\/span>/g)?.length, 2, "both kinds of user reply read as yours");
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
    options: ['Use "staging"', "<main>"] });
  const html = render.renderItem(question, ui);
  assert.ok(html.includes('id="option-q1-0"'));
  assert.ok(html.includes('data-act="answer" data-id="q1" data-index="1"'));
  assert.ok(html.includes("Use &quot;staging&quot;") && html.includes("&lt;main&gt;"));
  const answered = render.renderItem({ ...question, answer: 'Use "staging"' }, ui);
  assert.ok(answered.includes(">Answered<") && answered.includes("Use &quot;staging&quot;"));
  assert.ok(!answered.includes('data-act="answer"'));
  assert.ok(!answered.includes(">question<"));
  // Once answered, the badge shows the task's live stage.
  assert.ok(answered.includes('<span class="badge b-blue">review</span>'));
  ui.expanded.clear();
  const compact = render.renderItem({ ...question, answer: 'Use "staging"' }, ui);
  assert.ok(compact.includes("Answered: Use &quot;staging&quot;") && compact.includes(">review<"));
});

test("a working task's badge is neutral, and only an open question is amber", () => {
  const ui = render.newUIState();
  const working = task({ stageLabel: "working", stageTone: "working", needsUser: false });
  const started = render.renderItem(card({ id: "s1", kind: "task-started", packet: null, task: working }), ui);
  assert.ok(started.includes('<span class="badge b-working">working</span>'));
  assert.ok(!started.includes("b-amber"));
  const question = card({ id: "q1", kind: "question", text: "Change the hint?", packet: null, task: working });
  assert.ok(render.renderItem(question, ui).includes('<span class="badge b-amber">question</span>'));
  const answered = render.renderItem({ ...question, answer: "Yes" }, ui);
  assert.ok(answered.includes('<span class="badge b-working">working</span>') && !answered.includes("b-amber"));
});

test("a pending card disables its answers and reply without changing its draft", () => {
  const ui = render.newUIState();
  ui.expanded.add("q1");
  ui.pendingCards.add("task:T1");
  ui.drafts.set("task:T1", "another thought");
  const question = card({ id: "q1", kind: "question", packet: null, options: ["Staging"] });
  const pending = render.renderItem(question, ui);
  assert.match(pending, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.match(pending, /<input[^>]*value="another thought"[^>]*disabled/);
  const unavailable = render.renderItem({ ...question, task: task({ canReply: false }) }, { ...render.newUIState(), expanded: new Set(["q1"]) });
  assert.match(unavailable, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.match(unavailable, /<input[^>]*disabled/);
  assert.ok(unavailable.includes("The task cannot take replies now."));
  const coordinatorUnavailable = render.renderItem(question, { ...render.newUIState(), expanded: new Set(["q1"]) }, false);
  assert.match(coordinatorUnavailable, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.ok(coordinatorUnavailable.includes("The coordinator cannot receive messages now."));
  const uncertain = render.renderItem({ ...question, answerPending: true }, { ...render.newUIState(), expanded: new Set(["q1"]) });
  assert.match(uncertain, /<button[^>]*id="option-q1-0"[^>]*disabled/);
  assert.match(uncertain, /<input[^>]*disabled/);
  assert.ok(uncertain.includes("Waiting for the coordinator to confirm this answer."));
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

test("focus opens the task's current card, else its newest packet or last card", () => {
  const state = { items: [
    card({ id: "a", superseded: true }),
    card({ id: "b", isCurrent: false }),
    card({ id: "c", kind: "task-started", packet: null }),
    card({ id: "d", task: task({ id: "T2" }), kind: "task-started", packet: null }),
  ] };
  assert.equal(render.focusCardID(state, "T1"), "c");
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

test("report annotation send buttons use singular and plural mark labels", () => {
  const report = { ...packet(), taskID: "T1", title: "Fix", slug: "fix-totals", canAnnotate: true, headCommit: null, createdAt: null };
  const mark = { shot: "after-390", note: "Move this up", x: 0.5, y: 0.5 };
  const single = render.renderReport(report, { mode: "after", width: 390, marks: [mark] });
  assert.match(single, /id="report-send"[^>]*>Send 1 mark to fix-totals<\/button>/);
  const multiple = render.renderReport(report, { mode: "after", width: 390, marks: [mark, { ...mark, note: "Keep this label" }] });
  assert.match(multiple, /id="report-send"[^>]*>Send 2 marks to fix-totals<\/button>/);
});

test("a reply draft is kept while its card is closed, and a newly superseded card folds once", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  ui.drafts.set("task:T1", 'half a "note"');
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

test("taskless route questions stay expanded and offer only the saved choices", () => {
  const ui = render.newUIState();
  const route = card({ id: "route-1", task: null, kind: "question", packet: null,
    text: "Which project?\nNo project was named.\nChoose where this task belongs.", options: ["Lumen", "<Infra>"] });
  assert.equal(render.isExpanded(route, ui), true);
  const html = render.renderItem(route, ui);
  assert.ok(html.includes('class="grow ctitle">Which project?</span>'));
  assert.ok(html.includes("No project was named.\nChoose where this task belongs."));
  assert.ok(html.includes('data-act="answer-route" data-id="route-1" data-index="1"'));
  assert.ok(html.includes("&lt;Infra&gt;"));
  assert.ok(!html.includes("replybox") && !html.includes('data-act="expand"'));
  const unavailable = render.renderItem(route, ui, false);
  assert.match(unavailable, /<button[^>]*id="option-route-1-0"[^>]*disabled/);
  const unresolved = render.renderItem({ ...route, answerPending: true }, ui);
  assert.match(unresolved, /<button[^>]*id="option-route-1-0"[^>]*disabled/);
  assert.ok(unresolved.includes("Waiting for the coordinator"));
  const answered = render.renderItem({ ...route, answer: "Lumen" }, ui);
  assert.ok(answered.includes(">answered<") && answered.includes(">Lumen</span>"));
  assert.ok(!answered.includes('data-act="answer-route"'));
});

test("route project choices disambiguate duplicate titles with exact path tooltips and leave unknown choices literal", () => {
  const ui = render.newUIState();
  const route = card({ task: null, kind: "question", packet: null, text: "Which project?", options: ["project-one", "/repos/two", "/unknown/<three>"] });
  const state = { coordinator: { canSend: true }, items: [route], projects: [
    { id: "project-one", rootPath: "/repos/one", title: "Same <name>" },
    { id: "project-two", rootPath: "/repos/two", title: "Same <name>" },
  ] };
  const html = render.renderTimeline(state, ui);
  assert.match(html, /id="option-c1-0"[^>]*title="\/repos\/one"[^>]*>Same &lt;name&gt;<\/button>/);
  assert.match(html, /id="option-c1-1"[^>]*title="\/repos\/two"[^>]*>Same &lt;name&gt;<\/button>/);
  assert.match(html, /id="option-c1-2"[^>]*>\/unknown\/&lt;three&gt;<\/button>/);
  const answered = render.renderTimeline({ ...state, items: [{ ...route, answer: "/repos/two" }] }, ui);
  assert.match(answered, /class="txt" title="\/repos\/two">Same &lt;name&gt;<\/span>/);
});

test("an unknown literal matching a project title stays literal and makes the known project's path available", () => {
  const ui = render.newUIState();
  const route = card({ task: null, kind: "question", packet: null, options: ["billing-project", "Billing app"] });
  const state = { coordinator: { canSend: true }, items: [route], projects: [{ id: "billing-project", rootPath: "/repos/billing", title: "Billing app" }] };
  const html = render.renderTimeline(state, ui);
  assert.match(html, /id="option-c1-0"[^>]*title="\/repos\/billing"[^>]*>Billing app<\/button>/);
  assert.match(html, /id="option-c1-1"[^>]*>Billing app<\/button>/);
  assert.ok(!/id="option-c1-1"[^>]*title=/.test(html), "the literal choice does not gain a project identity");
  assert.deepEqual(route.options, ["billing-project", "Billing app"]);
});

test("a project's raw ID and canonical-root choices share its title without a false collision", () => {
  const ui = render.newUIState();
  const route = card({ task: null, kind: "question", packet: null, options: ["/stored/project", "/canonical/project"] });
  const state = { coordinator: { canSend: true }, items: [route],
    projects: [
      { id: "/stored/project", rootPath: "/canonical/project", title: "One project" },
      { id: "/canonical/project", rootPath: "/canonical/project", title: "One project" },
    ],
    addresses: [{ kind: "project", id: "/canonical/project", title: "Address alias", token: "project", version: null }],
  };
  const html = render.renderTimeline(state, ui);
  assert.match(html, /id="option-c1-0"[^>]*>One project<\/button>/);
  assert.match(html, /id="option-c1-1"[^>]*>One project<\/button>/);
  assert.ok(!/id="option-c1-[01]"[^>]*title=/.test(html), "one project's aliases are not two projects with colliding titles");
  assert.ok(!html.includes("Address alias"));
});

test("a legacy taskless question without options renders as a safe markdown note", () => {
  const ui = render.newUIState();
  const item = card({ task: null, kind: "question", options: [], text: "**Earlier update**\n<img src=x onerror=alert(1)>" });
  assert.equal(render.isExpanded(item, ui), false);
  const html = render.renderItem(item, ui);
  assert.ok(html.includes('class="note-card md"'));
  assert.ok(html.includes("<strong>Earlier update</strong>"));
  assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
  assert.ok(!html.includes('data-act="answer-route"') && !html.includes(">question<") && !html.includes("<img"));
});

test("replacement cards keep expansion order and discard an old merge confirmation", () => {
  const ui = render.newUIState();
  const first = card({ id: "first" });
  const second = card({ id: "second", task: task({ id: "T2" }) });
  ui.expanded = new Set(["first", "second"]);
  ui.confirmingMerge = "first";
  render.retainTaskCards({ items: [first, second] }, { items: [{ ...first, id: "replacement" }, second] }, ui);
  assert.deepEqual([...ui.expanded], ["replacement", "second"], "updating a card does not make it the last card the user opened");
  assert.equal(ui.confirmingMerge, null);
});

test("Merge confirmation resets on an in-place packet or eligibility change", () => {
  const before = card();
  for (const after of [
    card({ packet: packet({ version: 3, latestVersion: 3 }) }),
    card({ task: task({ packetVersion: 3 }) }),
    card({ isCurrent: false }),
    card({ superseded: true }),
    card({ task: task({ canMerge: false }) }),
    card({ task: task({ stale: true }) }),
    card({ task: task({ stageLabel: "stuck", stageTone: "red" }) }),
    card({ task: task({ stageLabel: "failed", stageTone: "red" }) }),
    card({ task: task({ stageLabel: "cleanup stopped", stageTone: "red" }) }),
  ]) {
    for (const previous of [before, card({ task: task({ stageLabel: "working", stageTone: "amber" }) })]) {
      const ui = render.newUIState();
      ui.confirmingMerge = "c1";
      render.retainTaskCards({ items: [previous] }, { items: [after] }, ui);
      assert.equal(ui.confirmingMerge, null, `confirmation kept after ${previous.task.stageLabel} -> ${after.task.stageLabel}`);
    }
  }
  const unchanged = render.newUIState();
  unchanged.confirmingMerge = "c1";
  render.retainTaskCards({ items: [before] }, { items: [card()] }, unchanged);
  assert.equal(unchanged.confirmingMerge, "c1");
});

test("Merge confirmation survives safe stage and thread updates", () => {
  const before = card({ task: task({ stageLabel: "working", stageTone: "amber" }) });
  const reply = { id: "agent-ready", at: "2026-10-24T10:01:00Z", role: "agent", text: "READY-B" };
  for (const after of [
    card({ task: task({ stageLabel: "review", stageTone: "blue" }) }),
    card({ task: task({ stageLabel: "finished", stageTone: "blue" }) }),
    card({ task: before.task, thread: [reply] }),
    card({ task: task({ stageLabel: "review", stageTone: "blue" }), thread: [reply] }),
  ]) {
    const ui = render.newUIState();
    ui.expanded.add("c1");
    ui.confirmingMerge = "c1";
    render.retainTaskCards({ items: [before] }, { items: [after] }, ui);
    assert.equal(ui.confirmingMerge, "c1", `confirmation lost at ${after.task.stageLabel}`);
    const html = render.renderItem(after, ui);
    assert.ok(html.includes('id="merge-go-c1"'), "the confirmation still offers Merge");
    assert.ok(!html.includes('data-act="merge"'), "the card does not ask for confirmation again");
    assert.ok(render.renderItem(after, { ...ui, confirmingMerge: null }).includes('data-act="merge"'), "the ordinary Merge action is available without confirmation");
    if (after.thread.length) assert.ok(html.includes("READY-B"), "the reply joins the thread");
  }
});

test("Merge confirmation survives updates to a card that was already stale or red", () => {
  const reply = { id: "agent-ready", at: "2026-10-24T10:01:00Z", role: "agent", text: "READY-B" };
  for (const fields of [{ stale: true }, { stageLabel: "stuck", stageTone: "red" }]) {
    const before = card({ task: task(fields) });
    const ui = render.newUIState();
    ui.confirmingMerge = "c1";
    render.retainTaskCards({ items: [before] }, { items: [card({ task: task(fields), thread: [reply] })] }, ui);
    assert.equal(ui.confirmingMerge, "c1", `confirmation lost on an unchanged ${JSON.stringify(fields)} card`);
  }
});

test("Merge confirmation survives task resumption while merge safety is unchanged", () => {
  for (const stageLabel of ["working", "needs input"]) {
    const ui = render.newUIState();
    ui.confirmingMerge = "c1";
    render.retainTaskCards({ items: [card()] }, { items: [card({ task: task({ stageLabel, stageTone: "amber" }) })] }, ui);
    assert.equal(ui.confirmingMerge, "c1");
  }
});

test("vanished cards are removed from the expanded IDs sent to native", () => {
  const ui = render.newUIState();
  ui.expanded = new Set(["route-1", "c1", "already-gone"]);
  render.retainTaskCards({ items: [card(), card({ id: "route-1", task: null, kind: "question" })] }, { items: [] }, ui);
  assert.deepEqual([...ui.expanded], []);
});

test("current question and start cards retain the latest report and earlier version links", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  for (const kind of ["packet", "question", "task-started"]) {
    const item = card({ kind, packetVersions: [2, 1, 3, 2], packet: packet({ version: 3, latestVersion: 3 }), task: task({ packetVersion: 3 }) });
    const html = render.renderItem(item, ui);
    assert.ok(html.includes('data-version="3">Full report</button>'), `latest report missing on ${kind}`);
    assert.ok(html.includes("Earlier reports"));
    assert.ok(html.includes('data-version="1">v1</button>') && html.includes('data-version="2">v2</button>'));
    assert.ok(!html.includes('data-version="3">v3</button>'));
  }
  const legacy = render.renderItem(card({ kind: "question", packet: null }), ui);
  assert.ok(legacy.includes('data-version="2">Full report</button>'));
  assert.ok(!legacy.includes("Earlier reports"), "missing history does not invent versions");
});

test("stuck cards show the failure and supported native actions with tolerant defaults", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  const item = card({ kind: "note", text: "The task stopped.", task: task({ stageLabel: "stuck", stageTone: "red", canMerge: false,
    failureText: "The API returned <503> after three attempts.", canArchive: true }) });
  const html = render.renderItem(item, ui);
  for (const part of [">stuck<", "The API returned &lt;503&gt; after three attempts.", "Open the task space", "Archive it", 'data-act="archive-task"']) assert.ok(html.includes(part), `missing ${part}`);
  assert.ok(!html.includes("Move to") && !html.includes("Hand to Claude"));
  const legacy = render.renderItem({ ...item, task: task({ stageLabel: "stuck", canMerge: false }) }, ui);
  assert.ok(!legacy.includes('data-act="archive-task"'));
});

test("collapsed stuck cards show the failure ahead of an earlier answer or started label", () => {
  const ui = render.newUIState();
  for (const kind of ["question", "task-started"]) {
    const item = card({ kind, packet: null, answer: kind === "question" ? "Staging only" : null,
      task: task({ stageLabel: "stuck", failureText: "The API returned <503>.", canMerge: false }) });
    const html = render.renderItem(item, ui);
    assert.ok(html.includes("The API returned &lt;503&gt;."), `missing failure for ${kind}`);
    assert.ok(!html.includes("Answered: Staging only") && !html.includes('class="sub">· started'));
  }
  const fallback = render.renderItem(card({ kind: "task-started", packet: null, task: task({ stageLabel: "stuck", failureText: null }) }), ui);
  assert.ok(fallback.includes("The task&#39;s agent reported an error."));
});

test("stuck recovery actions precede earlier question context and the reply thread", () => {
  const ui = render.newUIState();
  ui.expanded.add("c1");
  const item = card({ kind: "question", text: "Use staging first?", answer: "Staging only", packetVersions: [1, 2],
    thread: [{ id: "answered-q1", at: "", role: "user-task", text: "Staging only" }],
    task: task({ stageLabel: "stuck", stageTone: "red", canMerge: false, failureText: "The deployment check failed.", canArchive: true }) });
  const html = render.renderItem(item, ui);
  const failure = html.indexOf("The deployment check failed.");
  const open = html.indexOf('id="open-stuck-c1"');
  const archive = html.indexOf('id="archive-c1"');
  const context = html.indexOf("Use staging first?");
  const thread = html.indexOf('class="thread"');
  assert.ok(failure > html.indexOf('class="crow"') && failure < open && open < archive && archive < context && context < thread);
  assert.equal((html.match(/id="open-stuck-c1"/g) ?? []).length, 1);
  assert.equal((html.match(/id="archive-c1"/g) ?? []).length, 1);
  assert.ok(!html.includes('class="answer"'), "the earlier answer already appears in the thread");
  assert.equal((html.match(/Staging only/g) ?? []).length, 1);
  assert.ok(html.includes("Earlier question") && html.includes('id="menu-c1"') && html.includes('id="report-c1-1"'));

  const unanswered = render.renderItem({ ...item, answer: null, options: ["Staging", "Production"] }, ui);
  assert.ok(unanswered.includes("Use staging first?") && unanswered.includes('id="option-c1-0"'), "an unanswered question and its choices remain visible");
});

test("screenshots with pair and width left out still show, and long messages are refused", () => {
  const report = { ...packet(), taskID: "T1", title: "Fix", headCommit: null, createdAt: null,
    screenshots: [{ name: "menu", url: "/m.png" }] };
  assert.deepEqual(render.reportWidths(report), []);
  assert.deepEqual(render.reportShots(report, render.reportUIFor(report, "menu")).map((s) => s.name), ["menu"]);
  assert.ok(render.fitsMessage("x".repeat(16 * 1024)));
  assert.ok(!render.fitsMessage("é".repeat(8 * 1024 + 1)));
});

test("the header uses native summary and stable project IDs with display titles", () => {
  const html = render.renderHeader({
    coordinator: { title: "Coordinator", detail: "Claude Code · opus · 7 tasks in 3 projects", hasTerminal: true },
    projects: [{ id: '/projects/one"', title: "same" }, { id: "/projects/two", title: "same" }],
    projectFilter: "/projects/two",
  });
  assert.match(html, /Claude Code · opus · 7 tasks in 3 projects/);
  assert.match(html, /id="project-filter-0"[^>]*data-project="\/projects\/one&quot;"[^>]*>same/);
  assert.match(html, /id="project-filter-1" class="on"[^>]*data-project="\/projects\/two"[^>]*>same/);
  assert.ok(!html.includes("view-chat") && !html.includes("view-tasks"));
  assert.match(html, /id="open-routing"/);
});

test("fallback project buttons keep distinct IDs with the same title and deduplicate repeated rows", () => {
  const html = render.renderHeader({
    coordinator: { title: "Coordinator", detail: "Codex", hasTerminal: false },
    tasks: [
      { project: "same", projectID: "one" }, { project: "same", projectID: "two" }, { project: "same", projectID: "two" },
    ],
    projectFilter: "two",
  });
  assert.equal([...html.matchAll(/data-project="/g)].length, 2);
  assert.match(html, /data-project="one"/);
  assert.match(html, /id="project-filter-1" class="on"[^>]*data-project="two"/);
});

test("project filtering hides thread-bearing cards and preserves hidden card drafts", () => {
  const ui = render.newUIState();
  ui.expanded.add("other");
  ui.drafts.set("task:T2", "Unsent reply");
  const state = {
    coordinator: { canSend: true },
    projects: [{ id: "one", title: "same" }, { id: "two", title: "same" }, { id: "empty", title: "Empty" }],
    projectFilter: "one",
    items: [
      card({ id: "ours", task: task({ project: "same", projectID: "one" }) }),
      card({ id: "other", task: task({ id: "T2", project: "same", projectID: "two" }), thread: [{ id: "thread-other", role: "agent", text: "Only project two sees this thread", at: "" }] }),
      card({ id: "note", task: null, packet: null, kind: "note", text: "A general note" }),
      { type: "message", id: "message", role: "assistant", text: "A general message" },
      { type: "tool", id: "tool", name: "Read", detail: null, outcome: "succeeded" },
      { type: "status", id: "status", text: "Waiting" },
    ],
  };
  let html = render.renderTimeline(state, ui);
  // The tool line folds into its run of work, which stays visible.
  for (const id of ["ours", "note", "message", "work-tool", "status"]) assert.ok(html.includes(`data-item="${id}"`));
  assert.ok(!html.includes('data-item="other"'));
  assert.deepEqual(render.visibleExpandedIDs(state, ui), []);
  assert.ok(ui.expanded.has("other"));
  assert.equal(ui.drafts.get("task:T2"), "Unsent reply");
  html = render.renderTimeline({ ...state, projectFilter: "empty" }, ui);
  assert.ok(!html.includes('data-item="ours"') && !html.includes('data-item="other"'));
  html = render.renderTimeline({ ...state, projectFilter: "two" }, ui);
  assert.deepEqual(render.visibleExpandedIDs({ ...state, projectFilter: "two" }, ui), ["other"]);
  assert.match(html, /Unsent reply/);
  assert.match(html, /Only project two sees this thread/);
  assert.equal(ui.drafts.get("task:T2"), "Unsent reply");
});

test("a taskless card with the task property omitted stays visible under a project filter", () => {
  const ui = render.newUIState();
  const note = card({ id: "note", kind: "note", text: "A native coordinator note", packet: null });
  delete note.task;
  const state = {
    coordinator: { canSend: true },
    projects: [{ id: "one", title: "Project one" }], projectFilter: "one",
    items: [card({ id: "ours", task: task({ projectID: "one" }) }), note],
  };
  ui.expanded.add("ours");
  assert.match(render.renderTimeline(state, ui), /A native coordinator note/);
  ui.expanded.add("note");
  assert.match(render.renderTimeline(state, ui), /A native coordinator note/);
  assert.deepEqual(render.visibleExpandedIDs(state, ui), ["ours"]);
});
