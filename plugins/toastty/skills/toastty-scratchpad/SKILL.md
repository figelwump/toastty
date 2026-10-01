---
name: toastty-scratchpad
description: Use this skill to show the user anything visual — design mockups, UI/UX wireframes, layout or option comparisons, architecture and data-flow diagrams, charts, tables, dashboards, timelines, state machines, or any content clearer laid out spatially than as prose. Whenever you or another skill generates an HTML page for the user to view, present it in Toastty by default — publish it here instead of running `open` or launching an external browser — and prefer it over screenshotting an HTML file to /tmp, handing the user an image path, or sketching ASCII in chat; it renders the artifact directly in the user's Toastty workspace. Also use it to read, review, summarize, or update an existing Scratchpad panel.
---

# Toastty Scratchpad

**Reach for the Scratchpad whenever you have something visual to show the user — not only when asked for one.** If you produced a mockup, comparison, or diagram, present the result here rather than pointing the user at a file path. This includes artifacts you rendered and screenshotted with `agent-browser` to validate: the screenshot is for *your* verification, the Scratchpad is how the *user* sees it.

The same default applies when another skill or workflow produces an HTML page for the user — an explainer, report, comparison, or demo. In a Toastty-managed session, do not run `open` on the generated file or launch an external browser. Publish self-contained HTML to the Scratchpad. If the page genuinely exceeds Scratchpad constraints (multi-file assets, remote scripts, content over roughly 1 MB), open it in a Toastty browser panel instead via `panel.create.browser` with a `file://` URL; the toastty-capabilities skill covers workspace targeting. Fall back to an external browser only when the user explicitly asks for one.

Use Scratchpad when a visual surface will communicate better than terminal prose. If the user asks to read or review an existing Scratchpad, list the open Scratchpads bound to this session, select the intended document, and export it without replacing it. If the user asks to create or update a visual artifact, publish a quick loading screen to the selected or newly created document, optionally replace it with meaningful intermediate valid HTML snapshots or exact targeted patches as the artifact takes shape, then publish the finished self-contained HTML artifact.

## Managed Skill Root

Before invoking a bundled helper, require the skill root injected by Toastty:

```bash
if [[ -z "${TOASTTY_SKILLS_ROOT:-}" || ! -d "$TOASTTY_SKILLS_ROOT/toastty-scratchpad" ]]; then
  echo "error: toastty-scratchpad must run inside a Toastty-managed agent session" >&2
  exit 1
fi
```

Do not guess a repository checkout, global skill directory, or versioned Codex
plugin cache when `TOASTTY_SKILLS_ROOT` is missing.

## Select An Open Scratchpad

A managed session can have several open Scratchpads in its workspace tab. List them before reading or updating an existing artifact:

```bash
"$TOASTTY_CLI_PATH" --json query run panel.scratchpad.list \
  "sessionID=$TOASTTY_SESSION_ID"
```

The result contains `defaultDocumentID` and a `scratchpads` array. Each entry has a stable `documentID`, `panelID`, `title`, optional `purpose`, `revision`, `updatedAt`, and `isDefault`. Match the user's intended artifact by title and purpose, then use its `documentID` for each later publish, export, patch, or metadata update. Use the default only when the request clearly refers to it. Listing is metadata-only: it does not create, export, or focus a panel. Closed documents are not available to agent actions; reopening makes panel-targeted export available, and binding enables session-targeted actions.

## Read Existing Scratchpad

When the user asks to read, inspect, review, summarize, or propose changes based on the current Scratchpad, do not publish a loading screen and do not replace Scratchpad content.

Select the intended open document from `panel.scratchpad.list`; do not scan workspace layout or use focus to guess.

1. Confirm `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID` are available.
2. Export the selected Scratchpad directly:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  "sessionID=${TOASTTY_SESSION_ID}" \
  "documentID=<document-id>"
```

3. Read the returned `filePath` and answer from that content.
4. If diagnostics or runtime metadata are needed, query the returned `panelID`:

```bash
"$TOASTTY_CLI_PATH" --json query run panel.scratchpad.state \
  "panelID=<panel-id>"
```

If no document is bound and the user identified an open unbound panel, use its known `panelID` for panel-targeted export. Otherwise ask the user to reopen the panel or bind it from the link menu in this session's terminal header; a closed document cannot be accessed through the agent API. If `panel.scratchpad.export` is unavailable in the running app, say so briefly and use the best available panel-targeted fallback rather than guessing silently.

## Open First

When creating or replacing a visual Scratchpad artifact and a Toastty-managed session is available, publish a quick loading screen before doing deeper analysis, reading large files, or building the final artifact. List first when selecting an existing artifact. Use `--document-id` for the selected document; for a distinct artifact requested by the user, use `--additional` and save the returned `documentID` for later updates.

The loading screen is intentionally minimal: a title (if known) and a subtle animated indicator. Do not pre-mock the structure of the final artifact. Pre-mocking biases the design toward the same look every time and flattens visual variety across runs.

Publish the loading screen:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-outline.sh" \
  "Architecture Map"
```

If the user explicitly asks for a new, separate, or additional Scratchpad, pass `--additional` on this first loading-screen publish only:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-outline.sh" \
  --additional \
  --purpose "Compare architecture options" \
  "Architecture Map"
```

Save the helper's returned `documentID`. Then do the needed analysis and publish updates with `--document-id <returned-id>`. `--new` remains available for legacy callers, but it unbinds the previous default and should not be used for a separate artifact that must stay agent-accessible.

## Input Modes

- **Thread context**: publish a loading screen, then synthesize the visual from the current conversation, implementation plan, bug investigation, or decision tradeoff.
- **File input**: publish a loading screen before deep reading, then read the referenced file, extract the structure that matters, and create a visual representation. Do not dump a long file verbatim into the panel.
- **Manual prompt**: publish a loading screen from the prompt, then follow the prompt as the design brief. If the prompt is broad, choose a compact final visual that answers the likely need.
- **Existing Scratchpad**: list the Scratchpads bound to `TOASTTY_SESSION_ID`, choose by purpose/title, export by `documentID`, and answer in chat unless the user explicitly asks you to republish an updated artifact.

## Good Uses

- architecture maps and module boundaries
- data flow, request flow, lifecycle flow, and state machines
- data visualization, charts, tables, dashboards, metric cards, trend views, distributions, and ranked comparisons
- UI/UX wireframes, screen flows, layout comparisons, and interaction maps
- timelines, sequencing, dependency graphs, risk maps, and test matrices
- visual summaries of text when grouping, hierarchy, or spatial layout adds clarity

Avoid Scratchpad for ordinary logs, raw command output, long code listings, or prose that is already clearer in chat or a local document.

## Design Direction

Reach for the simplest visual that communicates the structure. Restraint is the goal, not richness. Three boxes and two arrows on a clean background usually beats an ornate poster with the same information. Variety should emerge from picking the right structure for each subject, not from changing the decorative skin.

Match the visual to the structure of the content:

- Architecture or systems → labeled boxes with explicit connectors. Show boundaries, hide internals.
- Data or metrics → one well-annotated chart, or a ranked list with hierarchy. Annotate the points that matter; drop the rest.
- Flows or sequences → numbered steps or a swimlane. Linear beats radial unless the data is genuinely cyclic.
- Comparisons → side-by-side columns sharing rows, or a 2×2.
- Timelines → one horizontal track with proportional spacing.
- Wireframes → line drawings on a neutral background with sparse annotations.
- State machines → nodes and labeled transitions.
- Risk or tradeoffs → 2×2 or quadrant.

Default visual choices:

- **Palette**: two to four colors total. One background, one foreground for text, one accent for emphasis. Add a second accent only when the content has two real categories. Prefer light or neutral backgrounds; avoid saturated dark dashboards and full-bleed gradients. Let content-driven palettes (red for risk, sepia for archive) inform choice when relevant, but stay restrained.
- **Typography**: one typeface, with weight and size carrying hierarchy. Add a second face only with a real reason (mono for code or tabular data, a display weight for a single headline). Prefer system fonts by default. Remote HTTPS font files are allowed only through inline `@font-face` declarations; remote font CSS imports remain blocked.
- **Layout**: generous whitespace, clear alignment, deliberate negative space. Avoid auto-fit grids of identical cards (the AI-default look) and avoid magazine spreads or poster compositions that compete with the content.
- **Visual primitives**: thin clean strokes, simple boxes, plain arrows, real tick marks. Decorative texture (paper grain, halftone, blueprint grid, isometric stacks) only when the subject genuinely calls for it — never as default polish.

Two failure modes to avoid:

- **AI-default dashboard**: `display: grid; grid-template-columns: repeat(auto-fit, minmax(...))` of identical cards on dark slate. Stop and pick a structure that expresses the content.
- **Over-designed poster**: heavy ornament, multiple typefaces, decorative textures, and high-saturation palettes that drown the actual information. If the artifact looks impressive before you read it, it is too loud.

## Distill First

Concision is the second goal, alongside restraint. Even when the source is large or complex, the artifact should show the smallest set of nodes, lines, and labels that answers the user's question.

Before generating HTML:

1. State, in one sentence, what the artifact must communicate. Build around that and cut anything that does not serve it.
2. Cluster and group. If the source has thirty items, find the four or five groupings that explain the shape. Show the groupings; leave specifics to chat or a follow-up artifact.
3. Shorten labels. Three or four words per node usually beats a sentence. Move detail to small captions or a single side-margin block.
4. Prefer one tight diagram over a dashboard of small multiples, unless comparison across multiples is the point.
5. Drop decoration that does not encode meaning. Every line, color, and shape should carry information.

If the artifact starts to feel busy, the answer is almost always to remove elements, not to redesign them.

## Build The Artifact

1. After the loading screen is visible, write the one-sentence purpose, pick the simplest visual form that captures it, and choose a restrained palette and typeface. Sketch the structure mentally first; do not start with a card grid by reflex, and do not start with poster ornament.
2. Generate one complete HTML document with inline CSS and optional inline JavaScript.
3. Keep it self-contained:
   - no remote scripts, stylesheets, images, or network fetches
   - use remote HTTPS font files only through inline `@font-face` declarations, and only when they materially improve the artifact
   - use inline SVG, CSS, HTML, and small inline data assets when useful
   - keep content under roughly 1 MB
4. Make artifacts responsive by default for resizable panels and smaller desktops, and support mobile widths where practical:
   - adapt to the available panel width, not just a large desktop viewport; include a device-width viewport meta tag
   - reflow columns and reduce spacing at narrow widths while keeping text readable; avoid fixed page widths, clipped content, and overlapping labels
   - keep wide tables or diagrams in their own scrollable region when reflow would obscure their meaning, rather than shrinking text or making the whole page scroll horizontally
   - make interactive controls usable with touch and expose essential information without requiring hover
   - enough labels that the user can understand the artifact without chat context
   - when previewing, check a smaller desktop panel and a mobile width as well as the wide layout
5. Replace the initial loading screen by publishing again with `--document-id <id>` from the loading-screen response. If updating an existing topic, reuse its document ID. If the first loading screen used `--additional`, omit that flag on later publishes and target the returned ID.

## Progressive Updates

Use whole-document publishing for the first Scratchpad update, full redesigns, major structure changes, or any case where you cannot form an exact unique `oldText` from the current HTML. To create a progressive-building effect, publish complete valid HTML snapshots at meaningful checkpoints while the artifact is being built, then publish the polished final version.

- Each update must be a full HTML document or complete renderable HTML snapshot, not a fragment or diff.
- Publish only at stable points where the content is useful and syntactically valid. Good checkpoints are a finalized layout shell, populated major sections, complete data visualization, and final polish.
- Avoid publishing every small edit or token stream. Each update reloads the generated iframe, which can reset scroll, focus, animation, and JavaScript state.
- Keep using the same helper, session, and `--document-id` for repeated publishes to one artifact.
- Use `--additional` only on the first publish of an explicitly separate artifact. Save its returned document ID. `--new` is a legacy option that creates a new default and unbinds the prior default.
- If an intermediate snapshot uses JavaScript, keep the no-blank-state and diagnostics guidance below in place just as you would for the final artifact.

## Targeted Patch Updates

Use `panel.scratchpad.patch-content` only for small, exact edits to a selected open Scratchpad. Before patching, export that document or query its state so you have the current `revision`; export whenever you do not already have the exact current HTML. Do not patch from stale memory.

Patch rules:

- `expectedRevision` is required and must match the current Scratchpad revision.
- `patch` is a JSON string, best passed with `--stdin patch`.
- Patch JSON is limited to 262,144 UTF-8 bytes.
- The top-level patch object only accepts `replacements`; each replacement object only accepts `oldText` and `newText`. Unknown fields are rejected.
- `replacements` must be non-empty.
- Each `oldText` must be non-empty and occur exactly once in the current intermediate HTML.
- Replacements apply sequentially, so earlier edits can affect later matches.
- A successful patch still reloads the generated iframe, so scroll, focus, animation, and JavaScript runtime state are not preserved.

Example:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  "sessionID=$TOASTTY_SESSION_ID" \
  "documentID=<document-id>"
```

Read the exported `filePath`, choose a unique exact `oldText`, and use the returned `revision`:

```bash
cat > /tmp/scratchpad-patch.json <<'JSON'
{
  "replacements": [
    {
      "oldText": "<section id=\"risk\">Old copy</section>",
      "newText": "<section id=\"risk\">New copy</section>"
    }
  ]
}
JSON

"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.patch-content \
  --stdin patch \
  "sessionID=$TOASTTY_SESSION_ID" \
  "documentID=<document-id>" \
  "expectedRevision=<revision>" < /tmp/scratchpad-patch.json
```

If `oldText` is missing, duplicated, hard to quote, or spread across unrelated regions, publish a complete replacement document instead.

## Inline JavaScript

Scratchpad supports inline JavaScript, but the generated document runs in a sandboxed iframe with a strict content security policy. JavaScript can enhance the artifact, but the core information should remain visible without it whenever practical.

- Prefer pre-rendered HTML/SVG for charts, tables, metric cards, and other static data views.
- Use inline JavaScript for real interactivity such as filtering, sorting, expand/collapse, hover details, or client-side measurements.
- Put executable code in `<script>` blocks and wire interactions with `addEventListener` after the relevant DOM nodes exist.
- Inline event attributes such as `onclick`, `onchange`, and `onload` are blocked by CSP (`script-src-attr 'none'`), and `javascript:` URLs are unsupported. Do not use them.
- Do not rely on external scripts, imports, remote styles, CDN chart libraries, network fetches, XHR, websockets, workers, nested frames, forms, local storage, or remote assets other than HTTPS font files declared directly with inline `@font-face`.
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

When the user asks you to look at, read, inspect, use, or implement what is in a Scratchpad, list the session's open Scratchpads and export the selected document through Toastty before acting on it.

In a Toastty-managed agent terminal, run:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  "sessionID=$TOASTTY_SESSION_ID" "documentID=<document-id>"
```

Read the returned `filePath` as the current Scratchpad HTML, then use that content as the source for the requested work. The response also includes `panelID`, `documentID`, `revision`, and `title` for diagnostics or follow-up state queries.

If the list is empty, use a known open panel ID for panel-targeted export or ask the user to reopen the intended Scratchpad and bind it from this session's terminal-header link menu. Scratchpad-side rebind remains available.

## Publish

Pipe generated HTML into the helper:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-html.sh" \
  --title "Architecture Map" < /tmp/scratchpad.html
```

Or publish an already-generated HTML file:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-html.sh" \
  --title "Data Flow" \
  --file /tmp/data-flow.html
```

For an explicit new/separate Scratchpad, add `--additional` to the first publish and use the returned `documentID` for later updates:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-html.sh" \
  --additional \
  --purpose "Data flow for the review" \
  --title "Data Flow" \
  --file /tmp/data-flow.html
```

To update a selected existing artifact:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-html.sh" \
  --document-id <document-id> \
  --file /tmp/data-flow.html
```

The helper requires `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID`, which are present in Toastty-managed agent terminals. It sends content via `panel.scratchpad.set-content` using stdin so shell quoting is not part of the protocol.

## After Publishing

- Tell the user what you put in the Scratchpad and summarize the key visual.
- Mention if the helper reported a panel/document/revision so the user knows the update succeeded.
- If the helper succeeds but the panel is not visible or appears incomplete, query `panel.scratchpad.state` for the returned `panelID` and inspect `recentDiagnostics` before republishing.
