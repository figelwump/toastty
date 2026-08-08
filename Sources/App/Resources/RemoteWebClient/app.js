"use strict";

const PROTOCOL_VERSION = "1.0";

const connectionBadge = document.getElementById("connection-state");
const pairView = document.getElementById("pair-view");
const pairForm = document.getElementById("pair-form");
const pairError = document.getElementById("pair-error");
const sessionsView = document.getElementById("sessions-view");
const sessionGroups = document.getElementById("session-groups");
const emptyState = document.getElementById("empty-state");

const chatView = document.getElementById("chat-view");
const chatBack = document.getElementById("chat-back");
const chatTitle = document.getElementById("chat-title");
const chatState = document.getElementById("chat-state");
const chatMessages = document.getElementById("chat-messages");
const chatEmpty = document.getElementById("chat-empty");

let socket = null;
let reconnectDelayMs = 1000;
let latestSnapshot = null;
// Non-null while the chat view is open:
// { conversationID, run, generation, lastSequence, loading }
let openConversation = null;

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
  latestSnapshot = snapshot;
  if (openConversation) {
    const current = (snapshot.conversations || []).find(
      (conversation) => conversation.conversationID === openConversation.conversationID
    );
    if (current) renderChatHeader(current);
  }
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
      card.addEventListener("click", () => openChat(conversation));
      group.appendChild(card);
    }
    sessionGroups.appendChild(group);
  }
}

function renderChatHeader(conversation) {
  chatTitle.textContent = conversation.title;
  chatState.textContent = conversation.provider + " · " + stateLabel(conversation.state);
}

function appendEventNode(event) {
  const kind = event.kind;
  const payload = event.payload || {};
  let node = null;
  if (kind === "user_message") {
    node = document.createElement("div");
    node.className = "bubble user";
    node.textContent = payload.text || "";
  } else if (kind === "assistant_message") {
    node = document.createElement("div");
    node.className = "bubble assistant" + (payload.phase === "commentary" ? " commentary" : "");
    node.textContent = payload.text || "";
  } else if (kind === "tool_started") {
    node = document.createElement("div");
    node.className = "chip";
    node.textContent = "▸ " + (payload.toolName || "tool") + (payload.detail ? ": " + payload.detail : "");
  } else if (kind === "tool_finished") {
    if (payload.outcome === "failed") {
      node = document.createElement("div");
      node.className = "chip";
      node.textContent = "✗ tool failed" + (payload.detail ? ": " + payload.detail : "");
    }
    // Successful completions stay quiet; the started chip covers them.
  } else if (kind === "subagent_summary") {
    node = document.createElement("div");
    node.className = "chip";
    node.textContent = "⧉ " + (payload.displayName || "subagent") + " " + (payload.phase || "");
  } else if (kind === "interaction_presented") {
    node = document.createElement("div");
    node.className = "chip status";
    node.textContent = "⚠︎ " + (payload.prompt || "waiting for input on the Mac");
  } else if (kind === "session_binding_changed") {
    node = document.createElement("div");
    node.className = "chip status";
    node.textContent = "— session " + ((payload.reason || "").replace(/_/g, " ")) + " —";
  }
  // status_changed / interaction_resolved rows are intentionally silent;
  // unknown kinds are ignored by design.
  if (node) chatMessages.appendChild(node);
}

function applyEvents(events) {
  let appended = false;
  for (const event of events) {
    if (event.sequence <= openConversation.lastSequence) continue;
    if (event.sequence > openConversation.lastSequence + 1) {
      // Gap: re-page from the confirmed cursor rather than guessing.
      void loadMoreEvents();
      return;
    }
    openConversation.lastSequence = event.sequence;
    appendEventNode(event);
    appended = true;
  }
  if (appended) {
    chatEmpty.hidden = chatMessages.children.length > 0;
    chatMessages.lastElementChild?.scrollIntoView({ block: "end" });
  }
}

async function fetchEventsPage(cursor) {
  const body = {
    conversationID: openConversation.conversationID,
    limit: 200,
  };
  if (cursor) body.cursor = cursor;
  const response = await fetch("/api/conversation.events.get", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) return null;
  return response.json();
}

async function loadMoreEvents() {
  if (!openConversation || openConversation.loading) return;
  openConversation.loading = true;
  try {
    while (openConversation) {
      const cursor = openConversation.run
        ? {
            projectionRunID: openConversation.run,
            projectionGeneration: openConversation.generation,
            afterSequence: openConversation.lastSequence,
          }
        : null;
      const result = await fetchEventsPage(cursor);
      if (!result || !openConversation) return;
      if (result.outcome === "resnapshot_required") {
        resetChatTranscript();
        continue;
      }
      if (result.outcome !== "page") {
        chatEmpty.hidden = false;
        return;
      }
      const page = result.page;
      openConversation.run = page.projectionRunID;
      openConversation.generation = page.projectionGeneration;
      for (const event of page.events) {
        if (event.sequence > openConversation.lastSequence) {
          openConversation.lastSequence = event.sequence;
          appendEventNode(event);
        }
      }
      chatEmpty.hidden = chatMessages.children.length > 0;
      if (page.events.length === 0 || openConversation.lastSequence >= page.latestSequence) {
        chatMessages.lastElementChild?.scrollIntoView({ block: "end" });
        return;
      }
    }
  } finally {
    if (openConversation) openConversation.loading = false;
  }
}

function resetChatTranscript() {
  chatMessages.replaceChildren();
  if (openConversation) {
    openConversation.run = null;
    openConversation.generation = 0;
    openConversation.lastSequence = 0;
  }
}

function openChat(conversation) {
  openConversation = {
    conversationID: conversation.conversationID,
    run: null,
    generation: 0,
    lastSequence: 0,
    loading: false,
  };
  chatMessages.replaceChildren();
  chatEmpty.hidden = true;
  renderChatHeader(conversation);
  sessionsView.hidden = true;
  chatView.hidden = false;
  void loadMoreEvents();
}

function closeChat() {
  openConversation = null;
  chatView.hidden = true;
  sessionsView.hidden = false;
  if (latestSnapshot) renderSnapshot(latestSnapshot);
}

chatBack.addEventListener("click", closeChat);

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
    } else if (message.type === "conversation_events" && message.page && openConversation
               && message.page.conversationID === openConversation.conversationID) {
      const page = message.page;
      if (openConversation.run
          && (page.projectionRunID !== openConversation.run
              || page.projectionGeneration !== openConversation.generation)) {
        resetChatTranscript();
        void loadMoreEvents();
      } else if (openConversation.run) {
        applyEvents(page.events);
      }
    } else if (message.type === "resnapshot_required" && openConversation
               && message.conversationID === openConversation.conversationID) {
      resetChatTranscript();
      void loadMoreEvents();
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
