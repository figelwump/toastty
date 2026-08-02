import assert from "node:assert/strict";
import test from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { outputFiles } = await build({
  stdin: {
    contents: `
      export {
        measureRevealLayout,
        resolveComputedLineHeight
      } from "./src/LineRevealMeasurement.ts";
    `,
    resolveDir: packageRoot,
    sourcefile: "line-reveal-measurement-test-entry.mjs"
  },
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
  logLevel: "silent"
});

const {
  measureRevealLayout,
  resolveComputedLineHeight
} = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].contents).toString("base64")}`);

function installMeasurementDOM() {
  const previousDocument = globalThis.document;
  const previousNodeFilter = globalThis.NodeFilter;
  const previousWindow = globalThis.window;

  globalThis.NodeFilter = { SHOW_TEXT: 4 };
  globalThis.window = {
    getComputedStyle(element) {
      return { lineHeight: element.lineHeight };
    }
  };
  globalThis.document = {
    createTreeWalker(element) {
      const textNodes = element.textNodes ?? [element.textNode];
      let nextNodeIndex = 0;
      return {
        nextNode() {
          const nextNode = textNodes[nextNodeIndex] ?? null;
          nextNodeIndex += 1;
          return nextNode;
        }
      };
    },
    createRange() {
      let selectedElement = null;
      let textNode = null;
      let startOffset = null;
      return {
        selectNodeContents(element) {
          selectedElement = element;
        },
        setStart(node, offset) {
          textNode = node;
          startOffset = offset;
        },
        setEnd() {},
        getClientRects() {
          if (selectedElement !== null) {
            return selectedElement.firstLineRects;
          }
          const rect = textNode.rectsByStartOffset.get(startOffset);
          return rect ? [rect] : [];
        }
      };
    }
  };

  return () => {
    globalThis.document = previousDocument;
    globalThis.NodeFilter = previousNodeFilter;
    globalThis.window = previousWindow;
  };
}

function measuredTextElement(textContent, lineHeight, rectsByStartOffset) {
  const textNode = {
    textContent,
    rectsByStartOffset: new Map(Object.entries(rectsByStartOffset).map(([offset, rect]) => (
      [Number(offset), rect]
    )))
  };
  return {
    textContent,
    lineHeight: String(lineHeight),
    textNode,
    firstLineRects: [{ top: 52, height: 14 }]
  };
}

test("computed line-height resolution rejects missing and non-positive geometry", () => {
  const restoreDOM = installMeasurementDOM();
  try {
    assert.equal(resolveComputedLineHeight({ lineHeight: "20px" }), 20);
    assert.equal(resolveComputedLineHeight({ lineHeight: "normal" }), null);
    assert.equal(resolveComputedLineHeight({ lineHeight: "0px" }), null);
    assert.equal(
      measureRevealLayout({
        lineNumber: 1,
        lineCount: 1,
        scrollElement: { clientHeight: 100, scrollHeight: 500 },
        contentFrameElement: {
          offsetTop: 10,
          getBoundingClientRect: () => ({ top: 20 })
        },
        gutterFrameElement: {
          getBoundingClientRect: () => ({ top: 20 })
        },
        contentElement: measuredTextElement("one", "normal", {}),
        gutterElement: measuredTextElement("1", 20, {})
      }),
      null
    );
  } finally {
    restoreDOM();
  }
});

test("reveal measurement centers direct glyph rectangles in line-height bands", () => {
  const restoreDOM = installMeasurementDOM();
  try {
    const contentElement = measuredTextElement("one\ntwo", 20, {
      5: { top: 72, height: 14 }
    });
    const gutterElement = measuredTextElement("1\n2", 20, {
      2: { top: 72, height: 14 }
    });

    assert.deepEqual(
      measureRevealLayout({
        lineNumber: 2,
        lineCount: 2,
        scrollElement: { clientHeight: 100, scrollHeight: 500 },
        contentFrameElement: {
          offsetTop: 10,
          getBoundingClientRect: () => ({ top: 20 })
        },
        gutterFrameElement: {
          getBoundingClientRect: () => ({ top: 20 })
        },
        contentElement,
        gutterElement
      }),
      {
        lineNumber: 1,
        contentTop: 49,
        gutterTop: 49,
        contentHeight: 20,
        gutterHeight: 20,
        targetScrollTop: 34
      }
    );
  } finally {
    restoreDOM();
  }
});

test("empty target lines extrapolate from the nearest rendered glyph", () => {
  const restoreDOM = installMeasurementDOM();
  try {
    const contentElement = measuredTextElement("one\n\nthree", 20, {
      6: { top: 92, height: 14 }
    });
    const gutterElement = measuredTextElement("1\n2\n3", 20, {
      2: { top: 72, height: 14 }
    });

    const layout = measureRevealLayout({
      lineNumber: 2,
      lineCount: 3,
      scrollElement: { clientHeight: 100, scrollHeight: 500 },
      contentFrameElement: {
        offsetTop: 10,
        getBoundingClientRect: () => ({ top: 20 })
      },
      gutterFrameElement: {
        getBoundingClientRect: () => ({ top: 20 })
      },
      contentElement,
      gutterElement
    });

    assert.equal(layout.contentTop, 49);
    assert.equal(layout.gutterTop, 49);
  } finally {
    restoreDOM();
  }
});

test("direct glyph measurement crosses highlighted text-node boundaries", () => {
  const restoreDOM = installMeasurementDOM();
  try {
    const highlightedTargetNode = {
      textContent: "t",
      rectsByStartOffset: new Map([[0, { top: 72, height: 14 }]])
    };
    const contentElement = {
      textContent: "one\ntwo",
      lineHeight: "20",
      textNodes: [
        { textContent: "one\n", rectsByStartOffset: new Map() },
        highlightedTargetNode,
        { textContent: "wo", rectsByStartOffset: new Map() }
      ],
      firstLineRects: [{ top: 52, height: 14 }]
    };
    const gutterElement = measuredTextElement("1\n2", 20, {
      2: { top: 72, height: 14 }
    });

    const layout = measureRevealLayout({
      lineNumber: 2,
      lineCount: 2,
      scrollElement: { clientHeight: 100, scrollHeight: 500 },
      contentFrameElement: {
        offsetTop: 10,
        getBoundingClientRect: () => ({ top: 20 })
      },
      gutterFrameElement: {
        getBoundingClientRect: () => ({ top: 20 })
      },
      contentElement,
      gutterElement
    });

    assert.equal(layout.contentTop, 49);
    assert.equal(layout.gutterTop, 49);
  } finally {
    restoreDOM();
  }
});
