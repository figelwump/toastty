const TAB = "\t";

function clampSelectionIndex(index, valueLength) {
  if (!Number.isFinite(index)) {
    return 0;
  }

  return Math.min(Math.max(0, Math.trunc(index)), valueLength);
}

function lineStartForIndex(value, index) {
  if (index <= 0) {
    return 0;
  }

  return value.lastIndexOf("\n", index - 1) + 1;
}

function selectedLineStarts(value, selectionStart, selectionEnd) {
  const firstLineStart = lineStartForIndex(value, selectionStart);
  const selectionIsCollapsed = selectionStart === selectionEnd;
  const lastSelectedIndex = selectionIsCollapsed
    ? selectionStart
    : Math.max(selectionStart, selectionEnd - 1);
  const lastLineStart = lineStartForIndex(value, lastSelectedIndex);
  const lineStarts = [];

  let currentLineStart = firstLineStart;
  while (currentLineStart <= lastLineStart) {
    lineStarts.push(currentLineStart);
    const nextNewlineIndex = value.indexOf("\n", currentLineStart);
    if (nextNewlineIndex === -1) {
      break;
    }
    currentLineStart = nextNewlineIndex + 1;
  }

  return lineStarts;
}

function lineEndForLineStart(value, lineStart) {
  const newlineIndex = value.indexOf("\n", lineStart);
  return newlineIndex === -1 ? value.length : newlineIndex;
}

function selectedLineRange(value, selectionStart, selectionEnd) {
  const lineStarts = selectedLineStarts(value, selectionStart, selectionEnd);
  const replacementStart = lineStarts[0] ?? 0;
  const replacementEnd = lineEndForLineStart(
    value,
    lineStarts[lineStarts.length - 1] ?? replacementStart
  );

  return {
    lineStarts,
    replacementStart,
    replacementEnd
  };
}

function applyRemovals(value, removalIndexes) {
  let nextValue = value;
  let offset = 0;

  for (const index of removalIndexes) {
    const adjustedIndex = index - offset;
    nextValue = `${nextValue.slice(0, adjustedIndex)}${nextValue.slice(adjustedIndex + TAB.length)}`;
    offset += TAB.length;
  }

  return nextValue;
}

function indentSelectedLines(value, selectionStart, selectionEnd) {
  if (selectionStart === selectionEnd) {
    const nextSelection = selectionStart + TAB.length;
    return {
      value: `${value.slice(0, selectionStart)}${TAB}${value.slice(selectionEnd)}`,
      selectionStart: nextSelection,
      selectionEnd: nextSelection,
      replacementStart: selectionStart,
      replacementEnd: selectionEnd,
      replacementText: TAB
    };
  }

  const range = selectedLineRange(value, selectionStart, selectionEnd);
  const originalBlock = value.slice(range.replacementStart, range.replacementEnd);
  const replacementText = `${TAB}${originalBlock.replace(/\n/g, `\n${TAB}`)}`;
  const nextSelectionStart = selectionStart + range.lineStarts.filter((index) => index < selectionStart).length;
  const nextSelectionEnd = selectionEnd + range.lineStarts.filter((index) => index < selectionEnd).length;

  return {
    value: `${value.slice(0, range.replacementStart)}${replacementText}${value.slice(range.replacementEnd)}`,
    selectionStart: nextSelectionStart,
    selectionEnd: nextSelectionEnd,
    replacementStart: range.replacementStart,
    replacementEnd: range.replacementEnd,
    replacementText
  };
}

function outdentSelectedLines(value, selectionStart, selectionEnd) {
  const range = selectedLineRange(value, selectionStart, selectionEnd);
  const removalIndexes = range.lineStarts.filter((index) => value.startsWith(TAB, index));

  if (removalIndexes.length === 0) {
    return {
      value,
      selectionStart,
      selectionEnd,
      replacementStart: selectionStart,
      replacementEnd: selectionEnd,
      replacementText: value.slice(selectionStart, selectionEnd)
    };
  }

  const originalBlock = value.slice(range.replacementStart, range.replacementEnd);
  const replacementText = applyRemovals(
    originalBlock,
    removalIndexes.map((index) => index - range.replacementStart)
  );
  const nextSelectionStart = selectionStart - removalIndexes.filter((index) => index < selectionStart).length;
  const nextSelectionEnd = selectionEnd - removalIndexes.filter((index) => index < selectionEnd).length;

  return {
    value: `${value.slice(0, range.replacementStart)}${replacementText}${value.slice(range.replacementEnd)}`,
    selectionStart: nextSelectionStart,
    selectionEnd: nextSelectionEnd,
    replacementStart: range.replacementStart,
    replacementEnd: range.replacementEnd,
    replacementText
  };
}

export function applyEditorIndentation(args) {
  const value = String(args.value ?? "");
  const rawSelectionStart = clampSelectionIndex(args.selectionStart, value.length);
  const rawSelectionEnd = clampSelectionIndex(args.selectionEnd, value.length);
  const selectionStart = Math.min(rawSelectionStart, rawSelectionEnd);
  const selectionEnd = Math.max(rawSelectionStart, rawSelectionEnd);

  return args.direction === "outdent"
    ? outdentSelectedLines(value, selectionStart, selectionEnd)
    : indentSelectedLines(value, selectionStart, selectionEnd);
}
