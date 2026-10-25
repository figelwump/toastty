// The packet report, opened in a right-panel browser at
// toastty://coordinator/report/<task-id>/<version>?shot=<name>. It reads the
// stored packet from the same host, so it works in an ordinary browser
// panel, with its annotation mode.
import { renderReport, reportUIFor } from "./render";
import type { ReportMode, ReportUIState } from "./render";
import type { ReportPacket } from "./types";

const root = document.getElementById("report")!;
const [, , taskID, version] = location.pathname.split("/");
const shot = new URLSearchParams(location.search).get("shot");
let packet: ReportPacket | null = null;
let ui: ReportUIState = { mode: "after", width: null };

function render() {
  if (packet) root.innerHTML = renderReport(packet, ui);
}

root.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target) return;
  if (target.dataset.act === "mode") ui = { ...ui, mode: target.dataset.mode as ReportMode };
  if (target.dataset.act === "width") ui = { ...ui, width: Number(target.dataset.width) };
  render();
});

fetch(`/packet-data/${encodeURIComponent(taskID ?? "")}/${encodeURIComponent(version ?? "")}`)
  .then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json() as Promise<ReportPacket>;
  })
  .then((loaded) => {
    packet = loaded;
    ui = reportUIFor(loaded, shot);
    document.title = `${loaded.title} · packet v${loaded.version}`;
    render();
  })
  .catch(() => {
    root.innerHTML = `<p class="dim">This packet is not available. The task may have been deleted, or its packets removed a week after it finished.</p>`;
  });
