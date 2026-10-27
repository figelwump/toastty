// Packet-local pins keep screenshot identity and packet version when sent.
import { renderReport, reportUIFor } from "./render";
import type { ReportMode, ReportUIState } from "./render";
import type { ReportPacket } from "./types";
import { validMarks } from "./marks";

const root = document.getElementById("report")!;
const status = document.createElement("div");
status.className = "report-status";
status.setAttribute("role", "status");
const [, , taskID, version] = location.pathname.split("/");
const shot = new URLSearchParams(location.search).get("shot");
let packet: ReportPacket | null = null;
let ui: ReportUIState = { mode: "after", width: null, marks: [] };

function updateSend() {
  const button = document.getElementById("report-send") as HTMLButtonElement | null;
  if (button) button.disabled = !!ui.sending || !packet?.canAnnotate || !validMarks(ui.marks ?? [], packet.screenshots.map((s) => s.name));
}

function render() {
  if (!packet) return;
  root.innerHTML = renderReport(packet, ui);
  const send = document.getElementById("report-send");
  if (send) send.after(status);
  else root.prepend(status);
  status.classList.toggle("hidden", !status.textContent);
  root.querySelectorAll<HTMLElement>("[data-pin]").forEach((pin) => {
    const mark = ui.marks![Number(pin.dataset.pin)];
    pin.style.left = `${mark.x * 100}%`;
    pin.style.top = `${mark.y * 100}%`;
  });
  updateSend();
}

root.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  if (input.dataset.note != null && !ui.sending) {
    ui.marks![Number(input.dataset.note)].note = input.value;
    updateSend();
  }
});

root.addEventListener("click", async (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target || ui.sending || !packet) return;
  switch (target.dataset.act) {
    case "mode": ui.mode = target.dataset.mode as ReportMode; break;
    case "width": ui.width = Number(target.dataset.width); break;
    case "annotate": ui.annotate = !ui.annotate; break;
    case "pin": {
      if (!ui.annotate || !packet.canAnnotate || ui.marks!.length >= 100) return;
      const image = target as HTMLImageElement;
      if (!image.complete || !image.naturalWidth) return;
      const box = image.getBoundingClientRect();
      if (!box.width || !box.height) return;
      ui.marks!.push({ shot: target.dataset.shot!, note: "", x: Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)), y: Math.max(0, Math.min(1, (event.clientY - box.top) / box.height)) });
      render();
      document.getElementById(`report-note-${ui.marks!.length - 1}`)?.focus();
      return;
    }
    case "remove-mark": ui.marks!.splice(Number(target.dataset.index), 1); break;
    case "send-marks": {
      if (!packet.canAnnotate || !validMarks(ui.marks!, packet.screenshots.map((s) => s.name))) return;
      ui.sending = true;
      status.textContent = "";
      render();
      try {
        const bridge = (window as unknown as { webkit?: { messageHandlers?: { toasttyCoordinatorReport?: { postMessage(body: unknown): Promise<{ ok: boolean; error?: string }> } } } }).webkit?.messageHandlers?.toasttyCoordinatorReport;
        if (!bridge) throw new Error("Open this report in Toastty to send marks.");
        const result = await bridge.postMessage({ marks: ui.marks });
        if (!result?.ok) throw new Error(result?.error ?? "The task could not receive these marks. Your notes are still here.");
        ui.marks = [];
        ui.annotate = false;
        status.textContent = `Sent to ${packet.slug}.`;
      } catch (error) {
        status.textContent = error instanceof Error ? error.message : "Could not send marks. Your notes are still here.";
      } finally {
        ui.sending = false;
        render();
      }
      return;
    }
  }
  render();
});

fetch(`/packet-data/${encodeURIComponent(taskID ?? "")}/${encodeURIComponent(version ?? "")}`)
  .then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json() as Promise<ReportPacket>;
  })
  .then((loaded) => {
    packet = loaded;
    ui = { ...reportUIFor(loaded, shot), marks: [] };
    document.title = `${loaded.title} · packet v${loaded.version}`;
    render();
  })
  .catch(() => {
    root.innerHTML = `<p class="dim">This packet is not available. The task may have been deleted, or its packets removed a week after it finished.</p>`;
  });
