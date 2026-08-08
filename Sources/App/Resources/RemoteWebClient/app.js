"use strict";

const PROTOCOL_VERSION = "1.0";

const connectionBadge = document.getElementById("connection-state");
const pairView = document.getElementById("pair-view");
const pairForm = document.getElementById("pair-form");
const pairError = document.getElementById("pair-error");
const sessionsView = document.getElementById("sessions-view");
const sessionGroups = document.getElementById("session-groups");
const emptyState = document.getElementById("empty-state");

let socket = null;
let reconnectDelayMs = 1000;

function setConnectionState(state) {
  connectionBadge.dataset.state = state;
  connectionBadge.textContent = state;
}

function showPairing(message) {
  pairView.hidden = false;
  sessionsView.hidden = true;
  if (message) {
    pairError.textContent = message;
    pairError.hidden = false;
  } else {
    pairError.hidden = true;
  }
}

function showSessions() {
  pairView.hidden = true;
  sessionsView.hidden = false;
}

function stateLabel(state) {
  return {
    starting: "starting",
    working: "working",
    awaiting_input: "waiting for input",
    ready: "ready",
    interrupted: "interrupted",
    ended: "ended",
    error: "error",
    offline: "offline",
  }[state] || state;
}

function renderSnapshot(snapshot) {
  const conversations = snapshot.conversations || [];
  sessionGroups.replaceChildren();
  emptyState.hidden = conversations.length > 0;

  const groups = new Map();
  for (const conversation of conversations) {
    const key = (conversation.placement && conversation.placement.workspaceTitle) || "Workspace";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(conversation);
  }

  for (const [workspaceTitle, groupConversations] of groups) {
    const group = document.createElement("div");
    group.className = "workspace-group";

    const heading = document.createElement("h3");
    heading.textContent = workspaceTitle;
    group.appendChild(heading);

    for (const conversation of groupConversations) {
      const card = document.createElement("div");
      card.className = "session-card";
      card.dataset.state = conversation.state;

      const dot = document.createElement("span");
      dot.className = "dot";
      card.appendChild(dot);

      const info = document.createElement("div");
      info.className = "info";

      const title = document.createElement("div");
      title.className = "title";
      title.textContent = conversation.title;
      info.appendChild(title);

      const meta = document.createElement("div");
      meta.className = "meta";
      const provider = conversation.provider || "";
      const cwd = conversation.cwd ? " · " + conversation.cwd : "";
      meta.textContent = provider + " · " + stateLabel(conversation.state) + cwd;
      info.appendChild(meta);

      card.appendChild(info);
      group.appendChild(card);
    }
    sessionGroups.appendChild(group);
  }
}

async function fetchSessions() {
  let response;
  try {
    response = await fetch("/api/sessions", { credentials: "same-origin" });
  } catch (error) {
    setConnectionState("offline");
    return false;
  }
  if (response.status === 401) {
    setConnectionState("unpaired");
    showPairing();
    return false;
  }
  if (!response.ok) {
    setConnectionState("offline");
    return false;
  }
  const body = await response.json();
  showSessions();
  renderSnapshot(body.snapshot);
  return true;
}

function connectSocket() {
  if (socket) {
    socket.onclose = null;
    socket.close();
  }
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  socket = new WebSocket(scheme + "://" + location.host + "/api/subscribe");

  socket.onopen = () => {
    reconnectDelayMs = 1000;
    setConnectionState("live");
  };
  socket.onmessage = (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (error) {
      return;
    }
    if (message.type === "session_list" && message.snapshot) {
      renderSnapshot(message.snapshot);
    }
    // Unknown message types are ignored by design.
  };
  socket.onclose = () => {
    setConnectionState("offline");
    scheduleReconnect();
  };
}

function scheduleReconnect() {
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, 15000);
  setTimeout(async () => {
    if (await fetchSessions()) {
      connectSocket();
    } else if (connectionBadge.dataset.state !== "unpaired") {
      scheduleReconnect();
    }
  }, delay);
}

pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = document.getElementById("pair-code").value.trim();
  const deviceName = document.getElementById("pair-name").value.trim();
  let response;
  try {
    response = await fetch("/api/pair", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, deviceName }),
    });
  } catch (error) {
    showPairing("Could not reach Toastty. Is remote access enabled?");
    return;
  }
  if (!response.ok) {
    let message = "Pairing failed.";
    try {
      const body = await response.json();
      if (body.code === "invalid_code") message = "Invalid or expired code.";
      if (body.code === "rate_limited") message = "Too many attempts. Try again later.";
    } catch (error) { /* keep default */ }
    showPairing(message);
    return;
  }
  if (await fetchSessions()) {
    connectSocket();
  }
});

document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState === "visible" && (!socket || socket.readyState !== WebSocket.OPEN)) {
    if (await fetchSessions()) {
      connectSocket();
    }
  }
});

(async () => {
  if (await fetchSessions()) {
    connectSocket();
  }
})();
