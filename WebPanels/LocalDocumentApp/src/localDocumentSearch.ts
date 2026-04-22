import React from "react";
import {
  LocalDocumentPanelSearchCommand,
  LocalDocumentPanelSearchState
} from "./bootstrap";
import { localDocumentNativeBridge } from "./nativeBridge";

const MATCH_HIGHLIGHT_NAME = "toastty-local-document-find-match";
const ACTIVE_HIGHLIGHT_NAME = "toastty-local-document-find-active";
const FALLBACK_MATCH_CLASS = "toastty-local-document-find-match-fallback";
const FALLBACK_ACTIVE_CLASS = "toastty-local-document-find-active-fallback";

interface TextMatch {
  start: number;
  end: number;
}

interface TextSegment {
  node: Text;
  start: number;
  end: number;
}

interface EditorSelectionSnapshot {
  start: number;
  end: number;
}

interface CustomHighlightRegistry {
  set(name: string, highlight: object): void;
  delete(name: string): void;
}

interface HighlightConstructor {
  new (...ranges: Range[]): object;
}

interface PreviewRevealRect {
  top: number;
  left: number;
  width: number;
  height: number;
}

function emptySearchState(query = ""): LocalDocumentPanelSearchState {
  return {
    query,
    matchCount: 0,
    activeMatchIndex: null,
    matchFound: false
  };
}

function highlightRegistry(): CustomHighlightRegistry | null {
  const registry = (
    globalThis as typeof globalThis & {
      CSS?: typeof CSS & { highlights?: CustomHighlightRegistry };
    }
  ).CSS?.highlights;
  return registry ?? null;
}

function highlightConstructor(): HighlightConstructor | null {
  const constructor = (
    globalThis as typeof globalThis & { Highlight?: HighlightConstructor }
  ).Highlight;
  return constructor ?? null;
}

function unwrapElement(element: Element) {
  const parent = element.parentNode;
  if (!parent) {
    return;
  }

  while (element.firstChild) {
    parent.insertBefore(element.firstChild, element);
  }
  parent.removeChild(element);
}

function clearPreviewFallbackHighlights(root: ParentNode | null) {
  if (root === null || !("querySelectorAll" in root)) {
    return;
  }

  const wrappers = Array.from(
    root.querySelectorAll(`.${FALLBACK_MATCH_CLASS}, .${FALLBACK_ACTIVE_CLASS}`)
  );
  for (const wrapper of wrappers) {
    unwrapElement(wrapper);
  }

  if (root instanceof Node) {
    root.normalize();
  }
}

function clearPreviewHighlights(root: ParentNode | null = document) {
  highlightRegistry()?.delete(MATCH_HIGHLIGHT_NAME);
  highlightRegistry()?.delete(ACTIVE_HIGHLIGHT_NAME);
  window.getSelection()?.removeAllRanges();
  clearPreviewFallbackHighlights(root);
}

function searchQueryForCommand(
  command: LocalDocumentPanelSearchCommand,
  currentState: LocalDocumentPanelSearchState
): string {
  switch (command.type) {
    case "clear":
      return "";
    case "setQuery":
    case "next":
    case "previous":
      return command.query.length > 0 ? command.query : currentState.query;
  }
}

function findTextMatches(content: string, query: string): TextMatch[] {
  if (query.length === 0) {
    return [];
  }

  const haystack = content.toLocaleLowerCase();
  const needle = query.toLocaleLowerCase();
  const matches: TextMatch[] = [];
  let searchStart = 0;

  while (searchStart < haystack.length) {
    const matchStart = haystack.indexOf(needle, searchStart);
    if (matchStart === -1) {
      break;
    }
    matches.push({ start: matchStart, end: matchStart + needle.length });
    searchStart = matchStart + Math.max(needle.length, 1);
  }

  return matches;
}

function nextActiveMatchIndex(
  command: LocalDocumentPanelSearchCommand,
  currentState: LocalDocumentPanelSearchState,
  matchCount: number
): number | null {
  if (matchCount == 0) {
    return null;
  }

  switch (command.type) {
    case "clear":
      return null;
    case "setQuery":
      if (command.query === currentState.query && currentState.activeMatchIndex !== null) {
        return Math.min(currentState.activeMatchIndex, matchCount - 1);
      }
      return 0;
    case "next":
      if (command.query !== currentState.query || currentState.activeMatchIndex === null) {
        return 0;
      }
      return (currentState.activeMatchIndex + 1) % matchCount;
    case "previous":
      if (command.query !== currentState.query || currentState.activeMatchIndex === null) {
        return matchCount - 1;
      }
      return (currentState.activeMatchIndex - 1 + matchCount) % matchCount;
  }
}

function textSegmentsFor(root: HTMLElement): TextSegment[] {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const segments: TextSegment[] = [];
  let offset = 0;

  for (let current = walker.nextNode(); current; current = walker.nextNode()) {
    const textNode = current as Text;
    if (textNode.data.length === 0) {
      continue;
    }
    const nextOffset = offset + textNode.data.length;
    segments.push({
      node: textNode,
      start: offset,
      end: nextOffset
    });
    offset = nextOffset;
  }

  return segments;
}

function rangeForMatch(segments: TextSegment[], match: TextMatch): Range | null {
  const startSegment = segments.find((segment) => match.start >= segment.start && match.start < segment.end);
  const endCharacterIndex = Math.max(match.end - 1, match.start);
  const endSegment = segments.find((segment) => endCharacterIndex >= segment.start && endCharacterIndex < segment.end);

  if (!startSegment || !endSegment) {
    return null;
  }

  const range = document.createRange();
  range.setStart(startSegment.node, match.start - startSegment.start);
  range.setEnd(endSegment.node, match.end - endSegment.start);
  return range;
}

export function centeredPreviewScrollTop(options: {
  containerHeight: number;
  targetTop: number;
  targetHeight: number;
}): number {
  const {
    containerHeight,
    targetTop,
    targetHeight
  } = options;
  const nextScrollTop = targetTop - (containerHeight / 2) + (targetHeight / 2);
  return Math.max(0, nextScrollTop);
}

export function previewLineIndexForOffset(textContent: string, offset: number): number {
  const boundedOffset = Math.max(0, Math.min(offset, textContent.length));
  return textContent.slice(0, boundedOffset).split("\n").length - 1;
}

export function previewScrollOffsetInScrollSpace(options: {
  currentScroll: number;
  containerStart: number;
  targetStart: number;
}): number {
  const {
    currentScroll,
    containerStart,
    targetStart
  } = options;
  return currentScroll + (targetStart - containerStart);
}

export function previewNearestScrollOffset(options: {
  currentScroll: number;
  containerSize: number;
  targetStart: number;
  targetSize: number;
}): number {
  const {
    currentScroll,
    containerSize,
    targetStart,
    targetSize
  } = options;
  const viewportEnd = currentScroll + containerSize;
  const targetEnd = targetStart + targetSize;
  if (targetStart < currentScroll) {
    return Math.max(0, targetStart);
  }
  if (targetEnd > viewportEnd) {
    return Math.max(0, targetEnd - containerSize);
  }
  return currentScroll;
}

function resolvedPreviewLineHeight(root: HTMLElement): number {
  const codeElement = root.querySelector("code");
  const style = window.getComputedStyle(codeElement instanceof HTMLElement ? codeElement : root);
  const explicitLineHeight = Number.parseFloat(style.lineHeight);
  if (Number.isFinite(explicitLineHeight)) {
    return explicitLineHeight;
  }

  const fontSize = Number.parseFloat(style.fontSize);
  if (Number.isFinite(fontSize)) {
    return fontSize * 1.65;
  }

  return 21.45;
}

function previewRectForRange(range: Range): PreviewRevealRect | null {
  const clientRect = Array.from(range.getClientRects()).find((rect) => rect.width > 0 || rect.height > 0);
  if (clientRect) {
    return {
      top: clientRect.top,
      left: clientRect.left,
      width: clientRect.width,
      height: clientRect.height
    };
  }

  const boundingRect = range.getBoundingClientRect();
  if (boundingRect.width > 0 || boundingRect.height > 0) {
    return {
      top: boundingRect.top,
      left: boundingRect.left,
      width: boundingRect.width,
      height: boundingRect.height
    };
  }

  return null;
}

function previewRectForElement(element: Element): PreviewRevealRect | null {
  const rect = element.getBoundingClientRect();
  if (rect.width > 0 || rect.height > 0) {
    return {
      top: rect.top,
      left: rect.left,
      width: rect.width,
      height: rect.height
    };
  }

  return null;
}

function scrollPreviewRectIntoView(root: HTMLElement, rect: PreviewRevealRect): boolean {
  if (root.clientHeight === 0 || root.clientWidth === 0) {
    return false;
  }

  const rootRect = root.getBoundingClientRect();
  const targetTop = previewScrollOffsetInScrollSpace({
    currentScroll: root.scrollTop,
    containerStart: rootRect.top,
    targetStart: rect.top
  });
  const targetLeft = previewScrollOffsetInScrollSpace({
    currentScroll: root.scrollLeft,
    containerStart: rootRect.left,
    targetStart: rect.left
  });
  const targetHeight = rect.height > 0
    ? rect.height
    : resolvedPreviewLineHeight(root);
  const targetWidth = Math.max(rect.width, 1);
  root.scrollTop = centeredPreviewScrollTop({
    containerHeight: root.clientHeight,
    targetTop,
    targetHeight
  });
  root.scrollLeft = previewNearestScrollOffset({
    currentScroll: root.scrollLeft,
    containerSize: root.clientWidth,
    targetStart: targetLeft,
    targetSize: targetWidth
  });
  return true;
}

function scrollPreviewMatchIntoView(
  root: HTMLElement,
  contentRoot: HTMLElement,
  textContent: string,
  rangedMatch: { match: TextMatch; range: Range }
) {
  const previewRect = previewRectForRange(rangedMatch.range);
  if (previewRect && scrollPreviewRectIntoView(root, previewRect)) {
    return;
  }

  // The preview is a non-wrapping <pre><code> surface, so a match's visual
  // position is fully determined by the newline count before its start offset.
  if (root.clientHeight === 0) {
    return;
  }
  const lineIndex = previewLineIndexForOffset(textContent, rangedMatch.match.start);
  const lineHeight = resolvedPreviewLineHeight(contentRoot);
  const paddingTop = Number.parseFloat(window.getComputedStyle(contentRoot).paddingTop);
  const rootRect = root.getBoundingClientRect();
  const contentRect = contentRoot.getBoundingClientRect();
  const contentTop = previewScrollOffsetInScrollSpace({
    currentScroll: root.scrollTop,
    containerStart: rootRect.top,
    targetStart: contentRect.top
  });
  root.scrollTop = centeredPreviewScrollTop({
    containerHeight: root.clientHeight,
    targetTop: contentTop + (Number.isFinite(paddingTop) ? paddingTop : 0) + (lineIndex * lineHeight),
    targetHeight: lineHeight
  });
}

function wrapRangeInHighlightSpan(range: Range, className: string): HTMLSpanElement | null {
  const wrapper = document.createElement("span");
  wrapper.className = className;
  const contents = range.extractContents();
  if (contents.childNodes.length === 0) {
    return null;
  }
  wrapper.append(contents);
  range.insertNode(wrapper);
  return wrapper;
}

function applyPreviewFallbackHighlights(
  rangedMatches: Array<{ match: TextMatch; range: Range }>,
  activeMatchIndex: number
): HTMLSpanElement | null {
  let activeWrapper: HTMLSpanElement | null = null;

  for (let originalIndex = rangedMatches.length - 1; originalIndex >= 0; originalIndex -= 1) {
    const entry = rangedMatches[originalIndex];
    const className = originalIndex === activeMatchIndex
      ? `${FALLBACK_MATCH_CLASS} ${FALLBACK_ACTIVE_CLASS}`
      : FALLBACK_MATCH_CLASS;
    const wrapper = wrapRangeInHighlightSpan(entry.range, className);
    if (originalIndex === activeMatchIndex && wrapper) {
      activeWrapper = wrapper;
    }
  }

  return activeWrapper;
}

function applyPreviewSearch(
  root: HTMLElement | null,
  contentRoot: HTMLElement | null,
  command: LocalDocumentPanelSearchCommand,
  currentState: LocalDocumentPanelSearchState
): LocalDocumentPanelSearchState {
  clearPreviewHighlights(contentRoot);

  const query = searchQueryForCommand(command, currentState);
  if (query.length === 0 || root === null || contentRoot === null) {
    return emptySearchState(query);
  }

  const segments = textSegmentsFor(contentRoot);
  const textContent = segments.map((segment) => segment.node.data).join("");
  const matches = findTextMatches(textContent, query);
  const activeMatchIndex = nextActiveMatchIndex(command, currentState, matches.length);

  if (matches.length === 0 || activeMatchIndex === null) {
    return emptySearchState(query);
  }

  const rangedMatches = matches
    .map((match) => {
      const range = rangeForMatch(segments, match);
      if (range === null) {
        return null;
      }
      return { match, range };
    })
    .filter((entry): entry is { match: TextMatch; range: Range } => entry !== null);
  const resolvedActiveIndex = Math.min(activeMatchIndex, Math.max(rangedMatches.length - 1, 0));

  if (rangedMatches.length == 0) {
    return emptySearchState(query);
  }

  const ranges = rangedMatches.map((entry) => entry.range);

  const registry = highlightRegistry();
  const Highlight = highlightConstructor();
  let activeFallbackHighlight: HTMLSpanElement | null = null;
  if (registry && Highlight) {
    registry.set(MATCH_HIGHLIGHT_NAME, new Highlight(...ranges));
    registry.set(ACTIVE_HIGHLIGHT_NAME, new Highlight(ranges[resolvedActiveIndex]));
  } else {
    activeFallbackHighlight = applyPreviewFallbackHighlights(
      rangedMatches,
      resolvedActiveIndex
    );
  }

  if (activeFallbackHighlight) {
    const previewRect = previewRectForElement(activeFallbackHighlight);
    if (previewRect && scrollPreviewRectIntoView(root, previewRect)) {
      return {
        query,
        matchCount: ranges.length,
        activeMatchIndex: resolvedActiveIndex,
        matchFound: true
      };
    }
  }

  scrollPreviewMatchIntoView(root, contentRoot, textContent, rangedMatches[resolvedActiveIndex]);
  return {
    query,
    matchCount: ranges.length,
    activeMatchIndex: resolvedActiveIndex,
    matchFound: true
  };
}

function resolvedEditorLineHeight(textarea: HTMLTextAreaElement): number {
  const style = window.getComputedStyle(textarea);
  const explicitLineHeight = Number.parseFloat(style.lineHeight);
  if (Number.isFinite(explicitLineHeight)) {
    return explicitLineHeight;
  }

  const fontSize = Number.parseFloat(style.fontSize);
  if (Number.isFinite(fontSize)) {
    return fontSize * 1.65;
  }

  return 21;
}

function restoreEditorSelection(
  textarea: HTMLTextAreaElement | null,
  selectionSnapshot: EditorSelectionSnapshot | null
) {
  if (!textarea) {
    return;
  }

  if (selectionSnapshot) {
    textarea.setSelectionRange(selectionSnapshot.start, selectionSnapshot.end, "none");
    return;
  }

  const caret = textarea.selectionEnd;
  textarea.setSelectionRange(caret, caret, "none");
}

function scrollEditorMatchIntoView(textarea: HTMLTextAreaElement, matchStart: number) {
  const contentBeforeMatch = textarea.value.slice(0, matchStart);
  const lineIndex = contentBeforeMatch.split("\n").length - 1;
  const lineHeight = resolvedEditorLineHeight(textarea);
  const targetTop = Math.max(
    0,
    lineIndex * lineHeight - (textarea.clientHeight / 2) + (lineHeight / 2)
  );
  textarea.scrollTop = targetTop;
}

function applyEditorSearch(
  textarea: HTMLTextAreaElement | null,
  command: LocalDocumentPanelSearchCommand,
  currentState: LocalDocumentPanelSearchState,
  selectionSnapshotRef: React.MutableRefObject<EditorSelectionSnapshot | null>
): LocalDocumentPanelSearchState {
  const query = searchQueryForCommand(command, currentState);
  if (command.type === "clear") {
    restoreEditorSelection(textarea, selectionSnapshotRef.current);
    selectionSnapshotRef.current = null;
    return emptySearchState();
  }

  if (!textarea || query.length === 0) {
    restoreEditorSelection(textarea, selectionSnapshotRef.current);
    return emptySearchState(query);
  }

  if (currentState.query.length === 0 && selectionSnapshotRef.current === null) {
    selectionSnapshotRef.current = {
      start: textarea.selectionStart,
      end: textarea.selectionEnd
    };
  }

  const matches = findTextMatches(textarea.value, query);
  const activeMatchIndex = nextActiveMatchIndex(command, currentState, matches.length);
  if (matches.length === 0 || activeMatchIndex === null) {
    restoreEditorSelection(textarea, selectionSnapshotRef.current);
    return emptySearchState(query);
  }

  const activeMatch = matches[activeMatchIndex];
  textarea.setSelectionRange(activeMatch.start, activeMatch.end, "forward");
  scrollEditorMatchIntoView(textarea, activeMatch.start);

  return {
    query,
    matchCount: matches.length,
    activeMatchIndex,
    matchFound: true
  };
}

export function useLocalDocumentSearchController(options: {
  content: string;
  isEditing: boolean;
  previewRootRef: React.RefObject<HTMLElement | null>;
  previewContentRef: React.RefObject<HTMLElement | null>;
  textareaRef: React.RefObject<HTMLTextAreaElement | null>;
}) {
  const { content, isEditing, previewRootRef, previewContentRef, textareaRef } = options;
  const searchStateRef = React.useRef<LocalDocumentPanelSearchState>(
    window.ToasttyLocalDocumentPanel?.getCurrentSearchState() ?? emptySearchState()
  );
  const editorSelectionSnapshotRef = React.useRef<EditorSelectionSnapshot | null>(null);

  React.useEffect(() => {
    if (isEditing == false) {
      editorSelectionSnapshotRef.current = null;
    }
  }, [isEditing]);

  const applyCommand = React.useCallback((command: LocalDocumentPanelSearchCommand) => {
    const nextState = isEditing
      ? applyEditorSearch(
          textareaRef.current,
          command,
          searchStateRef.current,
          editorSelectionSnapshotRef
        )
      : applyPreviewSearch(
          previewRootRef.current,
          previewContentRef.current,
          command,
          searchStateRef.current
        );
    searchStateRef.current = nextState;
    window.ToasttyLocalDocumentPanel?.setCurrentSearchState(nextState);
    return nextState;
  }, [isEditing, previewContentRef, previewRootRef, textareaRef]);

  React.useEffect(() => {
    window.ToasttyLocalDocumentPanel?.registerSearchController({
      perform: applyCommand
    });
    localDocumentNativeBridge.searchControllerReady();

    return () => {
      window.ToasttyLocalDocumentPanel?.registerSearchController(null);
      localDocumentNativeBridge.searchControllerUnavailable();
    };
  }, [applyCommand]);

  React.useLayoutEffect(() => {
    const currentQuery = searchStateRef.current.query;
    if (currentQuery.length === 0) {
      if (isEditing === false) {
        clearPreviewHighlights(previewContentRef.current);
      }
      return;
    }

    applyCommand({ type: "setQuery", query: currentQuery });
  }, [applyCommand, content, isEditing]);

  React.useEffect(() => {
    if (isEditing) {
      return;
    }

    const previewContentRoot = previewContentRef.current;
    if (!previewContentRoot) {
      return;
    }

    let animationFrameID: number | null = null;
    const observer = new MutationObserver(() => {
      if (animationFrameID !== null || searchStateRef.current.query.length === 0) {
        return;
      }
      animationFrameID = window.requestAnimationFrame(() => {
        animationFrameID = null;
        const currentQuery = searchStateRef.current.query;
        if (currentQuery.length === 0) {
          return;
        }
        applyCommand({ type: "setQuery", query: currentQuery });
      });
    });

    observer.observe(previewContentRoot, {
      childList: true,
      characterData: true,
      subtree: true
    });

    return () => {
      observer.disconnect();
      if (animationFrameID !== null) {
        window.cancelAnimationFrame(animationFrameID);
      }
    };
  }, [applyCommand, isEditing, previewContentRef]);
}
