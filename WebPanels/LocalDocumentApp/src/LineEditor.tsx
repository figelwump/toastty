import React from "react";
import { history, historyKeymap, standardKeymap } from "@codemirror/commands";
import { Compartment, EditorSelection, EditorState } from "@codemirror/state";
import { drawSelection, EditorView, keymap } from "@codemirror/view";
import type { LocalDocumentPanelBootstrap } from "./bootstrap";
import { applyEditorIndentation } from "./editorIndentation.mjs";

// Edit mode for hosts that set `editorEngine: "codemirror"` (Linux). In
// WebKitGTK a <textarea> keeps the whole file in one text node, so each
// keystroke re-lays out every line after the caret: ~10-15 ms per key on a
// 70 KB file. CodeMirror gives each line its own element and only renders the
// visible ones, so typing cost does not grow with the file.

// What edit-mode search drives in place of the textarea.
export interface LocalDocumentLineEditorHandle {
  readonly value: string;
  readonly selectionStart: number;
  readonly selectionEnd: number;
  setSelectionRange(start: number, end: number, direction?: "forward" | "backward" | "none"): void;
  // Scrolls `offset` to the middle of the editor.
  revealOffset(offset: number): void;
}

// Matches the textarea editor (`.local-document-editor` in styles.css).
const lineEditorTheme = EditorView.theme({
  "&": {
    flex: "1",
    minHeight: "0",
    backgroundColor: "transparent",
    color: "var(--pre-text)"
  },
  "&.cm-focused": {
    outline: "none"
  },
  ".cm-scroller": {
    font: '500 calc(13px * var(--toastty-markdown-text-scale)) / 1.65 "IBM Plex Mono", "SFMono-Regular", Menlo, monospace',
    tabSize: "2",
    cursor: "text"
  },
  ".cm-content": {
    padding: "20px 0 28px"
  },
  ".cm-line": {
    padding: "0 28px"
  },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--pre-text)"
  },
  ".cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, var(--accent) 22%, transparent)"
  },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, var(--accent) 36%, transparent)"
  }
});

function clampOffset(offset: number, length: number): number {
  return Math.min(Math.max(0, Math.trunc(offset)), length);
}

function makeHandle(view: EditorView): LocalDocumentLineEditorHandle {
  return {
    get value() {
      return view.state.doc.toString();
    },
    get selectionStart() {
      return view.state.selection.main.from;
    },
    get selectionEnd() {
      return view.state.selection.main.to;
    },
    setSelectionRange(start, end, direction) {
      const length = view.state.doc.length;
      const from = clampOffset(start, length);
      const to = clampOffset(end, length);
      view.dispatch({
        selection: direction === "backward"
          ? EditorSelection.single(to, from)
          : EditorSelection.single(from, to)
      });
    },
    revealOffset(offset) {
      view.dispatch({
        effects: EditorView.scrollIntoView(clampOffset(offset, view.state.doc.length), { y: "center" })
      });
    }
  };
}

export function LocalDocumentLineEditor(props: {
  bootstrap: LocalDocumentPanelBootstrap;
  draftContent: string;
  editorRef: React.RefObject<LocalDocumentLineEditorHandle | null>;
  updateDraftContent: (nextContent: string) => void;
}) {
  const hostRef = React.useRef<HTMLDivElement | null>(null);
  const viewRef = React.useRef<EditorView | null>(null);
  const readOnlyCompartment = React.useRef(new Compartment());
  // The last document text this editor reported or received, so a draft that
  // round-trips through React is not written back into the editor.
  const knownContentRef = React.useRef(props.draftContent);
  const isApplyingExternalContentRef = React.useRef(false);
  const updateDraftContentRef = React.useRef(props.updateDraftContent);
  const isSavingRef = React.useRef(props.bootstrap.isSaving);
  updateDraftContentRef.current = props.updateDraftContent;
  isSavingRef.current = props.bootstrap.isSaving;

  React.useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host) {
      return;
    }

    // Tab and Shift+Tab indent like the textarea editor; while saving, Tab
    // falls through to the browser.
    const indent = (direction: "indent" | "outdent") => (view: EditorView) => {
      if (isSavingRef.current) {
        return false;
      }
      const value = view.state.doc.toString();
      const { from, to } = view.state.selection.main;
      const result = applyEditorIndentation({
        value,
        selectionStart: from,
        selectionEnd: to,
        direction
      });
      if (result.value === value) {
        return true;
      }
      view.dispatch({
        changes: { from: result.replacementStart, to: result.replacementEnd, insert: result.replacementText },
        selection: EditorSelection.single(result.selectionStart, result.selectionEnd),
        scrollIntoView: true,
        userEvent: direction === "indent" ? "input.indent" : "delete.dedent"
      });
      return true;
    };

    const view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: knownContentRef.current,
        extensions: [
          history(),
          drawSelection(),
          lineEditorTheme,
          keymap.of([
            { key: "Tab", run: indent("indent"), shift: indent("outdent") },
            ...historyKeymap,
            ...standardKeymap
          ]),
          EditorState.tabSize.of(2),
          readOnlyCompartment.current.of(EditorState.readOnly.of(isSavingRef.current)),
          EditorView.contentAttributes.of({
            spellcheck: "false",
            autocorrect: "off",
            autocapitalize: "off",
            "aria-label": "Document editor"
          }),
          EditorView.updateListener.of((update) => {
            if (!update.docChanged || isApplyingExternalContentRef.current) {
              return;
            }
            const nextContent = update.state.doc.toString();
            knownContentRef.current = nextContent;
            updateDraftContentRef.current(nextContent);
          })
        ]
      })
    });
    viewRef.current = view;
    props.editorRef.current = makeHandle(view);
    view.focus();

    return () => {
      props.editorRef.current = null;
      viewRef.current = null;
      view.destroy();
    };
  }, []);

  React.useEffect(() => {
    const view = viewRef.current;
    if (!view || props.draftContent === knownContentRef.current) {
      return;
    }
    knownContentRef.current = props.draftContent;
    if (view.state.doc.toString() === props.draftContent) {
      return;
    }
    isApplyingExternalContentRef.current = true;
    try {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: props.draftContent },
        selection: EditorSelection.cursor(Math.min(view.state.selection.main.head, props.draftContent.length))
      });
    } finally {
      isApplyingExternalContentRef.current = false;
    }
  }, [props.draftContent]);

  React.useEffect(() => {
    viewRef.current?.dispatch({
      effects: readOnlyCompartment.current.reconfigure(EditorState.readOnly.of(props.bootstrap.isSaving))
    });
  }, [props.bootstrap.isSaving]);

  React.useEffect(() => {
    // Text scale changes the font size through a CSS variable, which
    // CodeMirror does not observe.
    viewRef.current?.requestMeasure();
  }, [props.bootstrap.textScale]);

  return <div ref={hostRef} className="local-document-line-editor" />;
}
