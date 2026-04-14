import React from "react";
import { createRoot } from "react-dom/client";
import { MarkdownPanelApp } from "./MarkdownPanelApp";
import "./bootstrap";

const container = document.getElementById("root");

if (!container) {
  throw new Error("Missing markdown panel root container");
}

createRoot(container).render(
  <React.StrictMode>
    <MarkdownPanelApp />
  </React.StrictMode>
);
