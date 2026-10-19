// Boltbar in the browser: the app's keys and rules, with canned replies.
// Text written during a reply queues and goes out with the next turn; → opens
// previous chats; Esc hides the bar and ⌥ Space brings it back.
import { createBar, popoverHTML, totalLength, EFFORTS, MODELS, THEMES } from "/boltbar/bar.js";
import { replyTo } from "/boltbar/replies.js";
import { HISTORY, dateLabel, matches } from "/boltbar/history-data.js";

const CHARS_PER_SECOND = 170;
const INTERRUPT_DELAY = 600;

export function mountPlayground(root) {
  const stage = root.querySelector("[data-stage]");
  const slot = root.querySelector("[data-bar]");
  const hiddenNote = root.querySelector("[data-hidden]");
  const bar = createBar({ interactive: true });
  slot.append(bar.el);
  const { input, searchInput } = bar.refs;

  let ids = 0;
  const id = () => `m${++ids}`;
  const st = {
    theme: "graphite",
    visible: true,
    messages: [],
    chatId: null,
    dirty: false, // only a changed chat moves to the top of the history
    queue: [],
    held: false,
    model: 1,
    effort: "medium",
    selecting: false,
    popover: false,
    web: false,
    unread: false,
    stream: null, // { id, start, length, delay }
    queuedAt: 0,
    chats: HISTORY.map((c) => ({ ...c, date: dateLabel(c) })),
    history: null, // { query, selected, pending, onList }
    lastHistory: null, // where ← returns to, after opening a chat from history
  };
  const used = new Set();
  const streaming = () => st.stream !== null;
  const draft = () => input.value;
  const hasDraft = () => draft().trim().length > 0;
  const visibleChats = () => st.chats.filter((c) => matches(c, st.history?.query ?? ""));

  function use(skill) {
    if (used.has(skill)) return;
    used.add(skill);
    root.querySelector(`[data-skill="${skill}"]`)?.classList.add("done");
  }

  function render() {
    const queueStatus = st.held ? "Paused" : st.queue.length > 1 ? "Sent together when this reply finishes" : "Sends when this reply finishes";
    const hint = !draft() && st.queue.length ? (streaming() ? "↵ interrupt and send" : "↵ send queued") : "";
    const h = st.history;
    bar.update({
      theme: THEMES[st.theme],
      messages: st.messages,
      model: MODELS[st.model].title,
      effort: st.effort,
      selectingModel: st.selecting,
      webSearch: st.web,
      streaming: streaming(),
      hasDraft: hasDraft(),
      queue: st.queue,
      queueStatus,
      hint,
      placeholder: streaming() || st.queue.length ? "Queue a follow-up…" : "Ask anything…",
      popoverHTML: st.popover ? popoverHTML(MODELS, MODELS[st.model].id, st.effort) : "",
      history: h ? { query: h.query, items: visibleChats(), total: st.chats.length, selected: h.selected, pending: h.pending } : null,
    });
    stage.dataset.visible = String(st.visible);
    hiddenNote.querySelector("[data-hidden-text]").textContent = streaming() ? "Boltbar is hidden, and still answering." : "Boltbar is hidden.";
    for (const b of root.querySelectorAll("[data-theme]")) b.setAttribute("aria-checked", String(b.dataset.theme === st.theme));
    // The editor grows to eight lines, then scrolls.
    input.style.height = "0px";
    input.style.height = `${Math.min(160, Math.max(22, input.scrollHeight))}px`;
  }

  // ——— Conversation ————————————————————————————————————————————————

  function begin(asked) {
    const model = MODELS[st.model];
    const reply = replyTo(asked.join(" "), model.title);
    const replyId = id();
    st.chatId ??= id();
    st.dirty = true;
    st.stream = { id: replyId, start: performance.now(), length: totalLength(reply), delay: st.web ? 1400 : 550 };
    st.messages = [
      ...st.messages,
      ...asked.map((text) => ({ id: id(), role: "user", blocks: [{ kind: "p", text }] })),
      { id: replyId, role: "assistant", author: model.provider, blocks: reply, pending: true, revealed: 0, activity: st.web ? "Searching the web…" : undefined },
    ];
    render();
  }

  function tick(now) {
    const s = st.stream;
    if (s) {
      const elapsed = now - s.start - s.delay;
      const revealed = Math.max(0, elapsed) * (CHARS_PER_SECOND / 1000);
      const done = revealed >= s.length;
      st.messages = st.messages.map((m) => (m.id === s.id ? { ...m, pending: elapsed < 0, revealed: done ? undefined : revealed } : m));
      if (done) {
        st.stream = null;
        if (!st.visible) st.unread = true;
        // Only a reply that finished normally sends the queue by itself.
        if (st.queue.length && !st.held) {
          const asked = st.queue.map((q) => q.text);
          st.queue = [];
          begin(asked);
        }
      }
      render();
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);

  function stop() {
    const s = st.stream;
    if (!s) return;
    st.stream = null;
    st.messages = st.messages.map((m) => (m.id === s.id ? { ...m, pending: false, interrupted: true } : m));
    if (st.queue.length) st.held = true;
    render();
  }
  function sendQueue() {
    if (!st.queue.length) return;
    if (streaming()) stop();
    const asked = st.queue.map((q) => q.text);
    st.queue = [];
    st.held = false;
    begin(asked);
  }
  function send(text = draft()) {
    const value = text.trim();
    if (!value) {
      // Return on an empty field sends the queue now, but not right after queueing.
      if (streaming() && performance.now() - st.queuedAt < INTERRUPT_DELAY) return;
      sendQueue();
      return;
    }
    input.value = "";
    st.selecting = false;
    if (streaming() || st.queue.length) {
      st.queue = [...st.queue, { id: id(), text: value }];
      st.queuedAt = performance.now();
      use("queue");
      if (!streaming()) {
        // A paused queue resumes on an explicit send, in order.
        st.held = false;
        sendQueue();
      } else render();
      return;
    }
    use("send");
    begin([value]);
  }
  function newChat() {
    stop();
    saveChat();
    st.messages = [];
    st.chatId = null;
    st.dirty = false;
    st.queue = [];
    st.held = false;
    st.lastHistory = null;
    input.value = "";
  }

  // ——— History ——————————————————————————————————————————————————————

  /** The open conversation joins the history when the browser opens, as in the app. */
  function saveChat() {
    const first = st.messages.find((m) => m.role === "user");
    if (!first || !st.dirty) return;
    st.dirty = false;
    const now = new Date();
    const time = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const messages = st.messages.map((m) => ({ ...m, pending: false, revealed: undefined }));
    const entry = { id: st.chatId, title: first.blocks[0].text.slice(0, 90), daysAgo: 0, time, date: time, model: MODELS[st.model].title, author: MODELS[st.model].provider, messages };
    st.chats = [entry, ...st.chats.filter((c) => c.id !== st.chatId)];
  }
  function openHistory(resume) {
    saveChat();
    st.selecting = false;
    st.popover = false;
    st.history = resume && st.lastHistory ? { ...st.lastHistory, pending: null, onList: false } : { query: "", selected: st.chats[0]?.id ?? null, pending: null, onList: false };
    searchInput.value = st.history.query;
    use("history");
    render();
    requestAnimationFrame(() => searchInput.focus({ preventScroll: true }));
  }
  function closeHistory() {
    st.history = null;
    render();
    requestAnimationFrame(() => input.focus({ preventScroll: true }));
  }
  function moveSelection(delta) {
    const list = visibleChats();
    if (!list.length) return;
    const at = Math.max(0, list.findIndex((c) => c.id === st.history.selected));
    st.history.selected = list[Math.min(list.length - 1, Math.max(0, at + delta))].id;
    st.history.pending = null;
    st.history.onList = true;
    render();
  }
  function openChat(chatId) {
    const chat = st.chats.find((c) => c.id === chatId);
    if (!chat) return;
    if (chat.id !== st.chatId) stop();
    st.lastHistory = { query: st.history.query, selected: chat.id };
    st.messages = chat.messages.map((m) => ({ ...m }));
    st.chatId = chat.id;
    st.dirty = false;
    st.queue = [];
    st.held = false;
    const model = MODELS.findIndex((m) => m.title === chat.model);
    if (model >= 0) st.model = model;
    use("search");
    closeHistory();
  }
  function deleteSelected() {
    const h = st.history;
    if (!h.selected) return;
    if (h.pending !== h.selected) {
      h.pending = h.selected;
      return render();
    }
    // Deleting asks twice: the second press removes it and selects the next row.
    const list = visibleChats();
    const at = list.findIndex((c) => c.id === h.selected);
    st.chats = st.chats.filter((c) => c.id !== h.selected);
    if (h.selected === st.chatId) {
      stop();
      st.messages = [];
      st.chatId = null;
    }
    const rest = visibleChats();
    h.selected = rest.length ? rest[Math.min(at, rest.length - 1)].id : null;
    h.pending = null;
    render();
  }

  searchInput.addEventListener("input", () => {
    const h = st.history;
    h.query = searchInput.value;
    h.pending = null;
    h.onList = false;
    const list = visibleChats();
    if (!list.some((c) => c.id === h.selected)) h.selected = list[0]?.id ?? null;
    render();
  });
  searchInput.addEventListener("keydown", (e) => {
    const h = st.history;
    if (!h || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") return e.preventDefault(), moveSelection(e.key === "ArrowDown" ? 1 : -1);
    if (e.key === "Enter" || e.key === "ArrowRight") return e.preventDefault(), h.selected && openChat(h.selected);
    if (e.key === "ArrowLeft") return e.preventDefault(), closeHistory();
    if (e.key === "Escape") {
      e.preventDefault();
      if (h.pending) return (h.pending = null), render();
      if (h.query) {
        searchInput.value = h.query = "";
        h.selected = st.chats[0]?.id ?? null;
        return render();
      }
      return closeHistory();
    }
    // After moving through the list, Delete removes a chat; typing searches again.
    if ((e.key === "Backspace" || e.key === "Delete") && h.onList) {
      e.preventDefault();
      if (!e.repeat) deleteSelected();
      return;
    }
    h.onList = false;
    if (h.pending) {
      h.pending = null;
      render();
    }
  });
  bar.refs.list.addEventListener("click", (e) => {
    const row = e.target.closest("[data-chat]");
    if (row) openChat(row.dataset.chat);
  });

  // ——— Models, hiding and summoning ————————————————————————————————————

  function cycle(direction) {
    st.model = (st.model + direction + MODELS.length) % MODELS.length;
    st.selecting = true;
    use("models");
    render();
  }
  function step(direction) {
    st.effort = EFFORTS[Math.min(2, Math.max(0, EFFORTS.indexOf(st.effort) + direction))];
    use("effort");
    render();
  }
  function hide() {
    st.visible = false;
    st.selecting = false;
    st.popover = false;
    use("hide");
    render();
  }
  function summon() {
    use("summon");
    // The app's rule: a chat that is still working comes back; an idle one gives way to a new chat.
    const working = streaming() || st.queue.length > 0 || st.unread;
    if (!working) newChat();
    st.history = null;
    st.unread = false;
    st.visible = true;
    render();
    requestAnimationFrame(() => input.focus({ preventScroll: true }));
  }

  input.addEventListener("input", () => {
    if (input.value) st.selecting = false;
    render();
  });
  input.addEventListener("mousedown", () => {
    if (st.selecting) {
      st.selecting = false;
      render();
    }
  });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
    const empty = draft().length === 0;
    const arrow = { ArrowDown: 1, ArrowUp: -1 }[e.key];
    const side = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
    if (st.popover) {
      if (arrow) return e.preventDefault(), cycle(arrow);
      if (side) return e.preventDefault(), step(side);
      if (e.key === "Enter" || e.key === "Escape") return e.preventDefault(), (st.popover = false), render();
    }
    if (e.key === "Escape") {
      e.preventDefault();
      if (st.selecting) {
        st.selecting = false;
        render();
      } else hide();
      return;
    }
    if (empty && !e.shiftKey && arrow && !streaming()) return e.preventDefault(), cycle(arrow);
    if (empty && st.selecting && side) return e.preventDefault(), step(side);
    // With an empty message, → opens previous chats and ← returns to the search you came from.
    if (empty && !e.shiftKey && e.key === "ArrowRight") return e.preventDefault(), openHistory(true);
    if (empty && !e.shiftKey && e.key === "ArrowLeft" && st.lastHistory) return e.preventDefault(), openHistory(true);
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (e.repeat) return;
      if (empty && st.selecting) {
        st.selecting = false;
        render();
        return;
      }
      send();
    }
  });
  window.addEventListener("keydown", (e) => {
    if (e.altKey && e.code === "Space") {
      e.preventDefault();
      summon();
    }
  });

  bar.el.addEventListener("click", (e) => {
    const target = e.target.closest("button");
    if (!target) {
      if (e.target.closest(".bb-composer, .bb-thread")) input.focus();
      return;
    }
    if (target.matches(".bb-send")) return target.dataset.action === "stop" ? stop() : send();
    if (target.matches(".bb-stop2")) return stop();
    if (target.matches(".bb-globe")) return (st.web = !st.web), render();
    if (target.matches(".bb-clock")) return openHistory(false);
    if (target.matches(".bb-back")) return closeHistory();
    if (target.matches(".bb-new")) return newChat(), closeHistory();
    if (target.matches(".bb-chip")) return (st.popover = !st.popover), (st.selecting = false), render();
    if (target.matches(".bb-send-now")) return sendQueue();
    if (target.dataset.remove) {
      st.queue = st.queue.filter((q) => q.id !== target.dataset.remove);
      if (!st.queue.length) st.held = false;
      return render();
    }
    if (target.dataset.effort) return (st.effort = target.dataset.effort), use("effort"), render();
    if (target.dataset.model) {
      st.model = MODELS.findIndex((m) => m.id === target.dataset.model);
      st.popover = false;
      use("models");
      render();
      input.focus({ preventScroll: true });
    }
  });
  document.addEventListener("mousedown", (e) => {
    if (st.popover && !e.target.closest(".bb-chip-wrap")) {
      st.popover = false;
      render();
    }
  });

  hiddenNote.addEventListener("click", summon);
  for (const b of root.querySelectorAll("[data-suggest]")) {
    b.addEventListener("click", () => {
      if (!st.visible) summon();
      if (st.history) closeHistory();
      if (b.dataset.suggest === "history") return openHistory(false);
      send(b.dataset.suggest);
    });
  }
  for (const b of root.querySelectorAll("[data-theme]")) {
    b.addEventListener("click", () => {
      st.theme = b.dataset.theme;
      use("theme");
      render();
    });
  }
  render();
}
