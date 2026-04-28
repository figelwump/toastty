---
name: toastty-scratchpad
description: Use this skill when an agent should show information visually in a Toastty Scratchpad panel - architecture diagrams, data/control flow, data visualization, charts, tables, UI/UX wireframes, state machines, timelines, comparison grids, visual plans, spatial workflows, or text that is clearer when laid out visually. Use when the input is current thread context, a referenced file, or a user-provided prompt asking for a visual Scratchpad artifact.
---

# Toastty Scratchpad

Use Scratchpad when a visual surface will communicate better than terminal prose. Open the Scratchpad first with a quick loading screen, optionally replace it with meaningful intermediate valid HTML snapshots as the artifact takes shape, then publish the finished self-contained HTML artifact.

## Open First

When this skill triggers and a Toastty-managed session is available, publish a quick loading screen before doing deeper analysis, reading large files, or building the final artifact. The loading screen tells the user that a visual artifact is being prepared.

The loading screen is intentionally minimal: a title (if known) and a subtle animated indicator. Do not pre-mock the structure of the final artifact. Pre-mocking biases the design toward the same look every time and flattens visual variety across runs.

Publish the loading screen from the repo root:

```bash
.agents/skills/toastty-scratchpad/scripts/publish-scratchpad-outline.sh \
  "Architecture Map"
```

Then do the needed thread/file/prompt analysis and publish updates over the same session-linked Scratchpad.

## Input Modes

- **Thread context**: publish a loading screen, then synthesize the visual from the current conversation, implementation plan, bug investigation, or decision tradeoff.
- **File input**: publish a loading screen before deep reading, then read the referenced file, extract the structure that matters, and create a visual representation. Do not dump a long file verbatim into the panel.
- **Manual prompt**: publish a loading screen from the prompt, then follow the prompt as the design brief. If the prompt is broad, choose a compact final visual that answers the likely need.

## Good Uses

- architecture maps and module boundaries
- data flow, request flow, lifecycle flow, and state machines
- data visualization, charts, tables, dashboards, metric cards, trend views, distributions, and ranked comparisons
- UI/UX wireframes, screen flows, layout comparisons, and interaction maps
- timelines, sequencing, dependency graphs, risk maps, and test matrices
- visual summaries of text when grouping, hierarchy, or spatial layout adds clarity

Avoid Scratchpad for ordinary logs, raw command output, long code listings, or prose that is already clearer in chat or a local document.

## Design Direction

Treat each artifact as a fresh design problem. Pick an aesthetic that fits the content rather than defaulting to a generic dark dashboard with a grid of cards. Variety is part of the value of this surface.

Vary across runs:

- **Aesthetic**: technical blueprint, editorial print, scientific paper, infographic poster, hand-sketched, isometric/3D, retro CRT or terminal, modern minimal, bold magazine, schematic, cartographic map, annotated diagram, data art.
- **Palette**: dark slate plus blue is one option, not the default. Light cream, paper white, warm tan, deep navy, washed pastel, high-contrast monochrome, single accent on neutral, duotone, and content-driven palettes (sunset for time, red for risk, forest for systems, sepia for archive) all work. Match the palette to the subject matter.
- **Typography**: serif for editorial or scientific, mono or condensed for technical, geometric sans for modern UI, display weight for posters and headlines. Mix weights, sizes, and tracking for hierarchy. System fonts only — no remote fonts or imports.
- **Layout**: avoid auto-fit card grids by default. Try asymmetric two-column, single hero with annotations, full-bleed schematic, vertical narrative, radial/orbital, isometric stacks, swimlanes, table-as-art, broadside poster, magazine spread, side margin notes.
- **Visual primitives**: SVG arrows and connectors, dashed routes, hand-drawn strokes, isometric blocks, orthographic projections, sankey-style flows, dot matrices, sparklines, badges, callouts with leader lines, axes with real tick marks, hand-labeled annotations.
- **Texture and depth**: subtle paper grain, blueprint grid, halftone, soft shadow, line weight variation, deliberate negative space. Flat is fine; uniformly flat is boring.

Match the visual to the structure of the content:

- Architecture or systems → schematic, blueprint, or layered diagram with explicit connectors and labeled boundaries.
- Data or metrics → editorial chart with annotation, ranked list with typography hierarchy, or small-multiples — not just bars in cards.
- Flows or sequences → swimlane, sankey, numbered narrative, or step-by-step storyboard — not a card grid.
- Comparisons → side-by-side as deliberate typography, scoring matrix, head-to-head columns with shared rows.
- Timelines → horizontal track or vertical narrative with proportional spacing — not equal-sized boxes.
- Wireframes → fidelity-matched line drawings on a neutral background with annotations.
- State machines → nodes and labeled transitions, not a grid.
- Risk or tradeoffs → 2x2, radar, or quadrant.

If you find yourself reaching for `display: grid; grid-template-columns: repeat(auto-fit, minmax(...))` of identical cards on a dark slate background, stop. That is the AI-default look. Pick a structure and palette that actually expresses the content.

## Build The Artifact

1. After the loading screen is visible, decide the most useful final visual form, aesthetic, and palette before writing the detailed HTML. Sketch the structure mentally first; do not start with a card grid by reflex.
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
5. Replace the initial loading screen by publishing again. If updating an existing topic in the same managed session, reuse the current Scratchpad instead of creating a separate artifact.

## Progressive Updates

Scratchpad publishing replaces the whole session-linked document each time. To create a progressive-building effect, publish complete valid HTML snapshots at meaningful checkpoints while the artifact is being built, then publish the polished final version.

- Each update must be a full HTML document or complete renderable HTML snapshot, not a fragment or diff.
- Publish only at stable points where the content is useful and syntactically valid. Good checkpoints are a finalized layout shell, populated major sections, complete data visualization, and final polish.
- Avoid publishing every small edit or token stream. Each update reloads the generated iframe, which can reset scroll, focus, animation, and JavaScript state.
- Keep using the same helper and session. The helper sends the full content through `panel.scratchpad.set-content`, so repeated publishes update the existing Scratchpad instead of creating separate panels.
- If an intermediate snapshot uses JavaScript, keep the no-blank-state and diagnostics guidance below in place just as you would for the final artifact.

## Inline JavaScript

Scratchpad supports inline JavaScript, but the generated document runs in a sandboxed iframe with a strict content security policy. JavaScript can enhance the artifact, but the core information should remain visible without it whenever practical.

- Prefer pre-rendered HTML/SVG for charts, tables, metric cards, and other static data views.
- Use inline JavaScript for real interactivity such as filtering, sorting, expand/collapse, hover details, or client-side measurements.
- Put executable code in `<script>` blocks and wire interactions with `addEventListener` after the relevant DOM nodes exist.
- Inline event attributes such as `onclick`, `onchange`, and `onload` are blocked by CSP (`script-src-attr 'none'`), and `javascript:` URLs are unsupported. Do not use them.
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

When debugging JavaScript, add short `console.info(...)` checkpoints around startup and event handlers, republish, and verify they appear as `generated-content` `console-message` diagnostics.

## Read Current Scratchpad

When the user asks you to look at, read, inspect, use, or implement what is in the current Scratchpad, export the session-linked Scratchpad through Toastty before acting on it.

In a Toastty-managed agent terminal, run:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export "sessionID=$TOASTTY_SESSION_ID"
```

Read the returned `filePath` as the current Scratchpad HTML, then use that content as the source for the requested work. The response also includes `panelID`, `documentID`, `revision`, and `title` for diagnostics or follow-up state queries.

If export reports that the session has no linked Scratchpad, ask the user to bind the Scratchpad to this agent from the Scratchpad action menu or specify the relevant Scratchpad panel.

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
