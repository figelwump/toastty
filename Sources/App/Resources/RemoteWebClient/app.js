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
const composeBar = document.getElementById("compose-bar");
const composeInput = document.getElementById("compose-input");
const composeSend = document.getElementById("compose-send");
const composeStatus = document.getElementById("compose-status");

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
  if (openConversation) {
    openConversation.availability = conversation.inputAvailability || null;
    updateComposeState();
  }
}

function rejectionLabel(reason) {
  return {
    epoch_mismatch: "The prompt changed — reopen to send.",
    local_draft_present: "You're typing on the Mac.",
    prompt_not_open: "Waiting for the agent.",
    pending_interaction: "The agent is waiting for input on the Mac.",
    surface_unavailable: "The terminal isn't ready.",
    not_bound: "This session isn't running.",
    session_writes_disabled: "Enable remote replies for this session on the Mac.",
    send_scope_denied: "This device can't send.",
    empty_text: "Message is empty.",
  }[reason] || "Can't send right now.";
}

function updateComposeState() {
  if (!openConversation) return;
  const availability = openConversation.availability;
  const canSend = availability && availability.kind === "open_prompt";
  const retryEpochChanged = Boolean(canSend
    && openConversation.pendingSend
    && !epochsEqual(openConversation.pendingSend.expectedInputEpoch, availability.epoch));
  composeBar.hidden = !canSend;
  composeSend.disabled = !canSend || openConversation.sending || retryEpochChanged;
  composeInput.disabled = !canSend || openConversation.sending;
  if (retryEpochChanged && !openConversation.sending) {
    setComposeStatus(
      "The prompt changed after an uncertain send. Check the transcript, then edit the message to send again.",
      "error"
    );
  }
}

function setComposeStatus(message, kind) {
  if (!message) {
    composeStatus.hidden = true;
    composeStatus.removeAttribute("data-kind");
    return;
  }
  composeStatus.hidden = false;
  composeStatus.textContent = message;
  if (kind) {
    composeStatus.dataset.kind = kind;
  } else {
    composeStatus.removeAttribute("data-kind");
  }
}

function newRequestID() {
  if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
  return "req-" + Date.now() + "-" + Math.floor(Math.random() * 1e9);
}

function epochsEqual(left, right) {
  return Boolean(left && right
    && left.bindingID === right.bindingID
    && left.counter === right.counter);
}

async function submitCompose(event) {
  event.preventDefault();
  if (!openConversation || openConversation.sending) return;
  const availability = openConversation.availability;
  if (!availability || availability.kind !== "open_prompt") return;
  const text = composeInput.value;
  if (!text.trim()) return;

  let sendRequest = openConversation.pendingSend;
  if (sendRequest && !epochsEqual(sendRequest.expectedInputEpoch, availability.epoch)) {
    setComposeStatus(
      "The prompt changed after an uncertain send. Check the transcript, then edit the message to send again.",
      "error"
    );
    updateComposeState();
    return;
  }
  if (!sendRequest || sendRequest.text !== text) {
    sendRequest = {
      conversationID: openConversation.conversationID,
      clientRequestID: newRequestID(),
      expectedInputEpoch: availability.epoch,
      text,
    };
    openConversation.pendingSend = sendRequest;
  }

  openConversation.sending = true;
  updateComposeState();
  setComposeStatus("Sending…");
  let result;
  try {
    const response = await fetch("/api/conversation.message.send", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(sendRequest),
    });
    result = await response.json();
    if (!response.ok) {
      openConversation.pendingSend = null;
      openConversation.sending = false;
      updateComposeState();
      setComposeStatus(
        rejectionLabel(response.status === 403 ? "send_scope_denied" : result.reason),
        "error"
      );
      return;
    }
  } catch (error) {
    openConversation.sending = false;
    updateComposeState();
    // Keep the exact request ID, text, and epoch. If the host accepted the
    // request but the response was lost, the next attempt must be a true
    // idempotent retry rather than a second injection.
    setComposeStatus("Couldn't reach Toastty.", "error");
    return;
  }
  openConversation.sending = false;
  if (result.status === "accepted" || result.status === "duplicate") {
    openConversation.pendingSend = null;
    composeInput.value = "";
    composeInput.style.height = "auto";
    setComposeStatus(null);
    if (epochsEqual(openConversation.availability?.epoch, sendRequest.expectedInputEpoch)) {
      openConversation.availability = { kind: "unavailable", reason: "working" };
    }
  } else if (result.status === "uncertain") {
    openConversation.pendingSend = null;
    if (epochsEqual(openConversation.availability?.epoch, sendRequest.expectedInputEpoch)) {
      openConversation.availability = { kind: "unavailable", reason: "working" };
    }
    setComposeStatus("Delivery is uncertain — check the Mac before sending again.", "error");
  } else {
    openConversation.pendingSend = null;
    setComposeStatus(rejectionLabel(result.reason), "error");
  }
  updateComposeState();
}

composeBar.addEventListener("submit", submitCompose);
composeInput.addEventListener("input", () => {
  if (openConversation?.pendingSend
      && openConversation.pendingSend.text !== composeInput.value) {
    openConversation.pendingSend = null;
    setComposeStatus(null);
    updateComposeState();
  }
  composeInput.style.height = "auto";
  composeInput.style.height = Math.min(composeInput.scrollHeight, 140) + "px";
});
composeInput.addEventListener("keydown", (event) => {
  // Enter sends; Shift+Enter inserts a newline (multi-line send preserved).
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    composeBar.requestSubmit();
  }
});

function appendEventNode(event) {
  const kind = event.kind;
  const payload = event.payload || {};
  let node = null;
  if (kind === "user_message") {
    if (openConversation?.pendingSend
        && payload.clientRequestID === openConversation.pendingSend.clientRequestID) {
      openConversation.pendingSend = null;
      composeInput.value = "";
      composeInput.style.height = "auto";
      setComposeStatus(null);
      updateComposeState();
    }
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

function drainPendingEventPages() {
  if (!openConversation?.run) return null;
  if (openConversation.pendingEventPagesOverflowed) {
    openConversation.pendingEventPagesOverflowed = false;
    return "gap";
  }
  while (openConversation.pendingEventPages.length > 0) {
    const page = openConversation.pendingEventPages.shift();
    if (page.projectionRunID !== openConversation.run
        || page.projectionGeneration !== openConversation.generation) {
      resetChatTranscript();
      return "resnapshot";
    }
    const firstNewEvent = page.events.find(
      (event) => event.sequence > openConversation.lastSequence
    );
    if (firstNewEvent && firstNewEvent.sequence > openConversation.lastSequence + 1) {
      openConversation.pendingEventPages.unshift(page);
      return "gap";
    }
    applyEvents(page.events);
  }
  return null;
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
      const lastSequenceBeforePage = openConversation.lastSequence;
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
      const pendingPageResult = drainPendingEventPages();
      if (pendingPageResult) {
        // A queued live page should become contiguous after REST fills the
        // gap. If REST made no progress, discard the handoff queue and restart
        // from a fresh snapshot instead of spinning forever on the same gap.
        if (pendingPageResult === "gap"
            && openConversation.lastSequence === lastSequenceBeforePage) {
          resetChatTranscript();
        }
        continue;
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
    openConversation.pendingEventPages = [];
    openConversation.pendingEventPagesOverflowed = false;
  }
}

function openChat(conversation) {
  openConversation = {
    conversationID: conversation.conversationID,
    run: null,
    generation: 0,
    lastSequence: 0,
    loading: false,
    sending: false,
    availability: null,
    pendingSend: null,
    pendingEventPages: [],
    pendingEventPagesOverflowed: false,
  };
  chatMessages.replaceChildren();
  chatEmpty.hidden = true;
  composeInput.value = "";
  setComposeStatus(null);
  renderChatHeader(conversation);
  sessionsView.hidden = true;
  chatView.hidden = false;
  void loadMoreEvents();
}

function closeChat() {
  openConversation = null;
  chatView.hidden = true;
  composeBar.hidden = true;
  setComposeStatus(null);
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
      } else {
        // The socket is connected before the initial REST page establishes
        // its run/generation. Buffer that handoff window instead of dropping
        // the only copy of a live event that may postdate the REST snapshot.
        openConversation.pendingEventPages.push(page);
        if (openConversation.pendingEventPages.length > 32) {
          openConversation.pendingEventPages.shift();
          openConversation.pendingEventPagesOverflowed = true;
        }
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
