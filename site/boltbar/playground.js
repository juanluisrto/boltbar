// Boltbar in the browser: the app's keys and rules, with canned replies.
// Text written during a reply queues and goes out with the next turn; Esc
// hides the bar and ⌥ Space brings it back.
import { createBar, popoverHTML, totalLength, EFFORTS, MODELS, THEMES } from "/boltbar/bar.js";
import { replyTo } from "/boltbar/replies.js";

const CHARS_PER_SECOND = 170;
const INTERRUPT_DELAY = 600;

export function mountPlayground(root) {
  const stage = root.querySelector("[data-stage]");
  const slot = root.querySelector("[data-bar]");
  const hiddenNote = root.querySelector("[data-hidden]");
  const bar = createBar({ interactive: true });
  slot.append(bar.el);
  const { input } = bar.refs;

  let ids = 0;
  const id = () => `m${++ids}`;
  const st = {
    theme: "graphite",
    visible: true,
    messages: [],
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
  };
  const used = new Set();
  const streaming = () => st.stream !== null;
  const draft = () => input.value;
  const hasDraft = () => draft().trim().length > 0;

  function use(skill) {
    if (used.has(skill)) return;
    used.add(skill);
    root.querySelector(`[data-skill="${skill}"]`)?.classList.add("done");
  }

  function render() {
    const queueStatus = st.held ? "Paused" : st.queue.length > 1 ? "Sent together when this reply finishes" : "Sends when this reply finishes";
    const hint = !draft() && st.queue.length ? (streaming() ? "↵ interrupt and send" : "↵ send queued") : "";
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
    });
    stage.dataset.visible = String(st.visible);
    hiddenNote.querySelector("[data-hidden-text]").textContent = streaming() ? "Boltbar is hidden, and still answering." : "Boltbar is hidden.";
    for (const b of root.querySelectorAll("[data-theme]")) b.setAttribute("aria-checked", String(b.dataset.theme === st.theme));
    // The editor grows to eight lines, then scrolls.
    input.style.height = "0px";
    input.style.height = `${Math.min(160, Math.max(22, input.scrollHeight))}px`;
  }

  function begin(asked) {
    const model = MODELS[st.model];
    const reply = replyTo(asked.join(" "), model.title);
    const replyId = id();
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
    if (!working) {
      st.messages = [];
      input.value = "";
    }
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
