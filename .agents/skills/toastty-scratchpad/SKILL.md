---
name: toastty-scratchpad
description: Use this skill when an agent should show information visually in a Toastty Scratchpad panel - architecture diagrams, data/control flow, data visualization, charts, tables, UI/UX wireframes, state machines, timelines, comparison grids, visual plans, spatial workflows, or text that is clearer when laid out visually. Use when the input is current thread context, a referenced file, or a user-provided prompt asking for a visual Scratchpad artifact.
---

# Toastty Scratchpad

Use Scratchpad when a visual surface will communicate better than terminal prose. Open the Scratchpad first with a rough visual outline, then replace it with the finished self-contained HTML artifact after analysis.

## Open First

When this skill triggers and a Toastty-managed session is available, publish an initial rough Scratchpad before doing deeper analysis, reading large files, or building the final artifact. The initial outline should show the user that a visual artifact is being worked on.

Use placeholders, silhouettes, skeleton blocks, empty chart axes, wireframe panels, generic lanes, or unlabeled connector shapes. Keep this first pass intentionally low-detail:

- no real data values
- no conclusions
- no file-derived facts beyond a generic title if already known
- subtle animation is preferred, such as shimmer, pulse, or moving placeholder strokes

Publish the rough outline from the repo root:

```bash
.agents/skills/toastty-scratchpad/scripts/publish-scratchpad-outline.sh \
  "Architecture Map" \
  architecture
```

Then do the needed thread/file/prompt analysis and publish the completed artifact over the same session-linked Scratchpad.

## Input Modes

- **Thread context**: publish a rough outline, then synthesize the visual from the current conversation, implementation plan, bug investigation, or decision tradeoff.
- **File input**: publish a rough outline before deep reading, then read the referenced file, extract the structure that matters, and create a visual representation. Do not dump a long file verbatim into the panel.
- **Manual prompt**: publish a rough outline from the prompt, then follow the prompt as the design brief. If the prompt is broad, choose a compact final visual that answers the likely need.

## Good Uses

- architecture maps and module boundaries
- data flow, request flow, lifecycle flow, and state machines
- data visualization, charts, tables, dashboards, metric cards, trend views, distributions, and ranked comparisons
- UI/UX wireframes, screen flows, layout comparisons, and interaction maps
- timelines, sequencing, dependency graphs, risk maps, and test matrices
- visual summaries of text when grouping, hierarchy, or spatial layout adds clarity

Avoid Scratchpad for ordinary logs, raw command output, long code listings, or prose that is already clearer in chat or a local document.

## Build The Artifact

1. After the rough outline is visible, decide the most useful final visual form before writing the detailed HTML.
2. Generate one complete HTML document with inline CSS and optional inline JavaScript.
3. Keep it self-contained:
   - no remote scripts, fonts, stylesheets, images, or network fetches
   - use inline SVG, CSS, HTML, and small inline data assets when useful
   - keep content under roughly 1 MB
4. Design for a resizable panel:
   - responsive layout
   - readable at narrow and wide widths
   - no text overlap
   - enough labels that the user can understand the artifact without chat context
5. Replace the initial outline by publishing again. If updating an existing topic in the same managed session, reuse the current Scratchpad instead of creating a separate artifact.

## Inline JavaScript

Scratchpad supports inline JavaScript, but the generated document runs in a sandboxed iframe with a strict content security policy. JavaScript can enhance the artifact, but the core information should remain visible without it whenever practical.

- Prefer pre-rendered HTML/SVG for charts, tables, metric cards, and other static data views.
- Use inline JavaScript for real interactivity such as filtering, sorting, expand/collapse, hover details, or client-side measurements.
- Do not rely on external scripts, imports, remote styles, CDN chart libraries, network fetches, XHR, websockets, workers, nested frames, forms, local storage, or remote assets.
- Embed all data inline, either directly in the script or in a local `<script type="application/json">` block.
- Wrap startup/rendering code in `try`/`catch`. On failure, render a visible error message in the artifact and call `console.error(...)` with useful context.
- Avoid blank startup states where all data appears only after JavaScript runs. If JavaScript is required, include a visible loading/failure container that is replaced after successful render.

## Diagnostics

If a published Scratchpad looks blank or incomplete, do not assume JavaScript is disabled. First inspect the panel state for generated-content diagnostics. Use the `panelID` returned by the publish helper:

```bash
"$TOASTTY_CLI_PATH" --json query run panel.scratchpad.state "panelID=<panel-id>"
```

The state response includes `recentDiagnostics` when the generated iframe reports console messages, JavaScript errors, unhandled promise rejections, or CSP violations. Pay attention to:

- `source`: `generated-content` means the agent-authored iframe reported it.
- `kind`: `javascript-error`, `unhandled-rejection`, `csp-violation`, or `console-message`.
- `message` and `metadata`: the failure detail, blocked URI/directive, source location, or stack when available.

Fix the artifact from those diagnostics before republishing. If `recentDiagnostics` is empty but the panel is still blank, confirm the current document/revision and content length in the same state response.

## Publish

From the repo root, pipe generated HTML into the helper:

```bash
.agents/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh \
  --title "Architecture Map" < /tmp/scratchpad.html
```

Or publish an already-generated HTML file:

```bash
.agents/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh \
  --title "Data Flow" \
  --file /tmp/data-flow.html
```

The helper requires `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID`, which are present in Toastty-managed agent terminals. It sends content via `panel.scratchpad.set-content` using stdin so shell quoting is not part of the protocol.

## After Publishing

- Tell the user what you put in the Scratchpad and summarize the key visual.
- Mention if the helper reported a panel/document/revision so the user knows the update succeeded.
- If the helper succeeds but the panel is not visible or appears incomplete, query `panel.scratchpad.state` for the returned `panelID` and inspect `recentDiagnostics` before republishing.

## HTML Starting Point

Use this as a compact baseline when no stronger visual pattern is obvious:

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Scratchpad</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    body { margin: 0; background: #111827; color: #f9fafb; }
    main { max-width: 1100px; margin: 0 auto; padding: 28px; }
    h1 { margin: 0 0 18px; font-size: 28px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; }
    .card { border: 1px solid #374151; border-radius: 8px; padding: 16px; background: #1f2937; }
    .muted { color: #9ca3af; }
  </style>
</head>
<body>
  <main>
    <h1>Scratchpad</h1>
    <section class="grid">
      <article class="card"><strong>Item</strong><p class="muted">Explain the visual unit.</p></article>
    </section>
  </main>
</body>
</html>
```
