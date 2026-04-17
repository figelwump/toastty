import React from "react";
import { createRoot } from "react-dom/client";
import { LocalDocumentPanelApp } from "./LocalDocumentPanelApp";
import "./bootstrap";

const container = document.getElementById("root");

if (!container) {
  throw new Error("Missing local document panel root container");
}

createRoot(container).render(
  <React.StrictMode>
    <LocalDocumentPanelApp />
  </React.StrictMode>
);
