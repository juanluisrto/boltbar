// Boltbar in the browser: the app's keys and rules, with canned replies.
// Text written during a reply queues and goes out with the next turn; → opens
// previous chats; Esc hides the bar and ⌥ Space brings it back. ⌘J turns on
// agent mode, where a scripted Claude Code or Codex works in a demo project.
import { createBar, popoverHTML, agentPopoverHTML, totalLength, EFFORTS, MODELS, PERMISSIONS, THEMES } from "/boltbar/bar.js?v=0.6.0.1";
import { replyTo } from "/boltbar/replies.js?v=0.6.0.1";
import { HISTORY, dateLabel, matches } from "/boltbar/history-data.js?v=0.6.0.1";
import { PROJECTS, COMMANDS, HELP, agentScript, sessionId } from "/boltbar/agent-data.js?v=0.6.0.1";

const CHARS_PER_SECOND = 170;
const INTERRUPT_DELAY = 600;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
    // Agent mode
    agent: false,
    agentSel: false, // the chip is outlined and takes the arrows
    agentPop: false,
    projects: PROJECTS.map((p) => ({ ...p })),
    project: PROJECTS[0].id,
    pendingFull: null,
    pendingRemoval: null,
    run: null, // the agent's turn while it works: { cancelled }
    approval: null, // { action, subject, project, resolve }
    allowed: new Set(), // "Allow in this chat"
    session: null, // { cli, id, project }: the CLI session behind this chat
    help: false,
    notice: "",
  };
  const used = new Set();
  const streaming = () => st.stream !== null || st.run !== null;
  const draft = () => input.value;
  const hasDraft = () => draft().trim().length > 0;
  const visibleChats = () => st.chats.filter((c) => matches(c, st.history?.query ?? ""));
  const project = () => st.projects.find((p) => p.id === st.project) ?? st.projects[0];
  const cli = () => (MODELS[st.model].provider === "Anthropic" ? "claude" : "codex");
  const slashMatches = () => {
    const text = draft().toLowerCase();
    return text.startsWith("/") && !/\s/.test(text) ? COMMANDS.filter((c) => c.command.startsWith(text)) : [];
  };

  function use(skill) {
    if (used.has(skill)) return;
    used.add(skill);
    root.querySelector(`[data-skill="${skill}"]`)?.classList.add("done");
  }

  function render() {
    const queueStatus = st.held ? "Paused" : st.queue.length > 1 ? "Sent together when this reply finishes" : "Sends when this reply finishes";
    const hint = !draft() && st.queue.length ? (streaming() ? "↵ interrupt and send" : "↵ send queued") : "";
    const h = st.history;
    const proj = project();
    let agentHint = null, hintLevel = null;
    if (st.agentSel && st.agent) {
      if (st.pendingRemoval === proj.id) (agentHint = "⌫ again removes"), (hintLevel = "error");
      else if (st.pendingFull === proj.id) (agentHint = "→ again for full"), (hintLevel = "full");
      else (agentHint = proj.permission), (hintLevel = proj.permission);
    }
    bar.update({
      theme: THEMES[st.theme],
      messages: st.messages,
      model: MODELS[st.model].title,
      effort: st.effort,
      selectingModel: st.selecting,
      webSearch: st.web && !st.agent,
      streaming: streaming(),
      hasDraft: hasDraft(),
      queue: st.queue,
      queueStatus,
      hint,
      placeholder: streaming() || st.queue.length ? "Queue a follow-up…" : st.agent ? `Tell it what to do in ${proj.name}…` : "Ask anything…",
      popoverHTML: st.popover ? popoverHTML(MODELS, MODELS[st.model].id, st.effort) : "",
      agent: { on: st.agent, selected: st.agentSel, name: proj.name, permission: proj.permission, hint: agentHint, hintLevel },
      agentPopoverHTML: st.agentPop
        ? agentPopoverHTML({ projects: st.projects, selected: proj.id, permission: proj.permission, pendingFull: st.pendingFull === proj.id, pendingRemoval: st.pendingRemoval, session: st.session ? `${st.session.cli} ${st.session.cli === "claude" ? "--resume" : "resume"}` : null })
        : "",
      approval: st.approval,
      slash: st.help || st.history ? [] : slashMatches(),
      help: st.help ? HELP : null,
      notice: st.notice,
      history: h ? { query: h.query, items: visibleChats(), total: st.chats.length, selected: h.selected, pending: h.pending } : null,
    });
    stage.dataset.visible = String(st.visible);
    hiddenNote.querySelector("[data-hidden-text]").textContent = streaming() ? "Boltbar is hidden, and still answering." : "Boltbar is hidden.";
    for (const b of root.querySelectorAll("[data-theme]")) b.setAttribute("aria-checked", String(b.dataset.theme === st.theme));
    // The editor grows to eight lines, then scrolls.
    input.style.height = "0px";
    input.style.height = `${Math.min(160, Math.max(22, input.scrollHeight))}px`;
  }

  let noticeTimer = 0;
  function notify(text) {
    st.notice = text;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => ((st.notice = ""), render()), 4000);
    render();
  }

  // ——— Conversation ————————————————————————————————————————————————

  function begin(asked) {
    const model = MODELS[st.model];
    const replyId = id();
    st.chatId ??= id();
    st.dirty = true;
    st.help = false;
    const users = asked.map((text) => ({ id: id(), role: "user", blocks: [{ kind: "p", text }] }));
    if (st.agent) {
      st.messages = [...st.messages, ...users, { id: replyId, role: "assistant", author: model.provider, blocks: [], steps: [], pending: true }];
      runAgent(replyId, asked.join(" "));
      return render();
    }
    const reply = replyTo(asked.join(" "), model.title);
    st.stream = { id: replyId, start: performance.now(), length: totalLength(reply), delay: st.web ? 1400 : 550 };
    st.messages = [...st.messages, ...users, { id: replyId, role: "assistant", author: model.provider, blocks: reply, pending: true, revealed: 0, activity: st.web ? "Searching the web…" : undefined }];
    render();
  }

  function setStep(messageId, step) {
    st.messages = st.messages.map((m) => {
      if (m.id !== messageId) return m;
      const steps = m.steps.some((s) => s.id === step.id) ? m.steps.map((s) => (s.id === step.id ? step : s)) : [...m.steps, step];
      return { ...m, steps };
    });
    render();
  }
  function askApproval(request) {
    return new Promise((resolve) => {
      st.approval = { ...request, resolve };
      render();
    });
  }
  function resolveApproval(decision) {
    const a = st.approval;
    if (!a) return false;
    st.approval = null;
    if (decision !== "deny") use("approve");
    a.resolve(decision);
    render();
    return true;
  }

  /** One agent turn: its steps, the approvals the permission calls for, then the reply. */
  async function runAgent(messageId, text) {
    const run = { cancelled: false };
    st.run = run;
    const proj = project();
    const level = proj.permission;
    // A chat keeps one CLI session; another project or CLI starts a new one.
    if (!st.session || st.session.project !== proj.id || st.session.cli !== cli()) st.session = { cli: cli(), id: sessionId(), project: proj.id, path: proj.path };
    const script = agentScript(text);
    const steps = level === "look" ? script.steps.filter((s) => s.kind !== "edit" && !s.asks?.includes("edit")) : script.steps;
    let outcome = level === "look" && script.fix ? "look" : "done";
    await sleep(400);
    for (const s of steps) {
      if (run.cancelled) return;
      const { asks, approval, detail, ...line } = s;
      setStep(messageId, { ...line, status: "running" });
      await sleep(s.kind === "command" ? 650 : 420);
      if (run.cancelled) return;
      if (asks?.includes(level) && !st.allowed.has(approval.subject)) {
        const decision = await askApproval({ ...approval, project: proj.name });
        if (run.cancelled) return;
        if (decision === "deny") {
          setStep(messageId, { ...line, status: "denied" });
          outcome = s.kind === "edit" ? "deniedEdit" : "deniedCommand";
          break;
        }
        if (decision === "chat") st.allowed.add(approval.subject);
        await sleep(450);
        if (run.cancelled) return;
      }
      setStep(messageId, { ...line, status: "done", detail });
    }
    const reply = script.replies[outcome];
    st.run = null;
    st.messages = st.messages.map((m) => (m.id === messageId ? { ...m, blocks: reply, revealed: 0 } : m));
    st.stream = { id: messageId, start: performance.now(), length: totalLength(reply), delay: 120 };
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
    if (!streaming()) return;
    // A stopped turn answers its open permission request with a refusal.
    if (st.run) {
      st.run.cancelled = true;
      resolveApproval("deny");
    }
    const replyId = st.stream?.id ?? st.messages[st.messages.length - 1]?.id;
    st.stream = null;
    st.run = null;
    st.messages = st.messages.map((m) =>
      m.id === replyId ? { ...m, pending: false, interrupted: true, steps: m.steps?.map((s) => (s.status === "running" ? { ...s, status: "failed", detail: "stopped" } : s)) } : m,
    );
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
    if (COMMANDS.some((c) => c.command === value.toLowerCase())) {
      input.value = "";
      return runCommand(value.toLowerCase());
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
    st.session = null;
    st.allowed = new Set();
    st.help = false;
    input.value = "";
  }

  // ——— Commands, help and the terminal ——————————————————————————————————

  function runCommand(command) {
    endSelection();
    if (command === "/help") return showHelp();
    if (command === "/new") return newChat(), render();
    if (command === "/agent") return toggleAgent(false);
    if (command === "/terminal") return copyTerminal();
  }
  function showHelp() {
    st.history = null;
    st.help = true;
    use("help");
    render();
  }
  function closeHelp() {
    st.help = false;
    render();
  }
  function copyTerminal() {
    const s = st.session;
    if (!s) return notify("No agent session yet: send a message in agent mode first.");
    const command = `cd ${s.path} && ${s.cli === "claude" ? `claude --resume ${s.id}` : `codex resume ${s.id}`}`;
    navigator.clipboard?.writeText(command).catch(() => {});
    use("terminal");
    st.agentPop = false;
    notify(`Copied: ${command}`);
  }

  // ——— Agent mode: the chip, its keys and its popover —————————————————————

  function endSelection() {
    const active = st.selecting || st.popover || st.agentSel || st.agentPop;
    st.selecting = st.popover = st.agentSel = st.agentPop = false;
    st.pendingFull = st.pendingRemoval = null;
    return active;
  }
  /** ⌘J and the terminal button. Turning it on outlines the chip; ↵ on the chip keeps it outlined either way. */
  function toggleAgent(keepSelection) {
    st.agent = !st.agent;
    st.selecting = st.popover = st.agentPop = false;
    st.pendingFull = st.pendingRemoval = null;
    st.agentSel = st.agent || keepSelection;
    if (st.agent) use("agent");
    render();
  }
  /** Tab walks to the model chip, then the agent chip, and stays; ⇧Tab walks back. */
  function walkChips(forward) {
    const onChip = st.selecting || st.popover || st.agentSel || st.agentPop;
    const toAgent = forward && onChip;
    st.popover = st.agentPop = false;
    st.selecting = !toAgent;
    st.agentSel = toAgent;
    st.pendingFull = st.pendingRemoval = null;
    use("chips");
    render();
  }
  function cycleProject(direction) {
    const at = st.projects.findIndex((p) => p.id === st.project);
    st.project = st.projects[(at + direction + st.projects.length) % st.projects.length].id;
    st.pendingFull = st.pendingRemoval = null;
    render();
  }
  function setPermission(level) {
    project().permission = level;
    st.pendingFull = st.pendingRemoval = null;
    use("permission");
    render();
  }
  /** Full takes a second press, from the keys or the popover. */
  function choosePermission(level) {
    const proj = project();
    if (level === proj.permission) return (st.pendingFull = null), render();
    if (level === "full" && st.pendingFull !== proj.id) {
      st.pendingRemoval = null;
      st.pendingFull = proj.id;
      return render();
    }
    setPermission(level);
  }
  function stepPermission(direction) {
    const proj = project();
    if (direction < 0 && st.pendingFull === proj.id) return (st.pendingFull = null), render();
    const at = PERMISSIONS.indexOf(proj.permission);
    choosePermission(PERMISSIONS[Math.min(PERMISSIONS.length - 1, Math.max(0, at + direction))]);
  }
  function requestRemoval() {
    const proj = project();
    st.pendingFull = null;
    if (st.pendingRemoval !== proj.id) return (st.pendingRemoval = proj.id), render();
    if (st.projects.length > 1) {
      const at = st.projects.findIndex((p) => p.id === proj.id);
      st.projects = st.projects.filter((p) => p.id !== proj.id);
      st.project = st.projects[Math.min(at, st.projects.length - 1)].id;
    }
    st.pendingRemoval = null;
    render();
  }
  /** The arrows and Return on the agent chip; false lets the key through. */
  function agentKey(e) {
    if (!(st.agentSel || st.agentPop) || e.key === "Tab") return false;
    if (!st.agent) {
      if (e.key === "Enter") toggleAgent(true);
      else if (e.key === "Escape") endSelection(), render();
      else if (!e.key.startsWith("Arrow")) return endSelection(), render(), false;
      return true;
    }
    switch (e.key) {
      case "ArrowDown": case "ArrowUp": cycleProject(e.key === "ArrowDown" ? 1 : -1); break;
      case "ArrowLeft": case "ArrowRight": stepPermission(e.key === "ArrowRight" ? 1 : -1); break;
      case "Backspace": case "Delete": requestRemoval(); break;
      case "Enter":
        // In the popover a click opened, Return just closes it.
        if (st.agentSel && !st.agentPop) toggleAgent(true);
        else endSelection(), render();
        break;
      case "Escape": endSelection(); render(); break;
      default: endSelection(); render(); return false;
    }
    return true;
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
    endSelection();
    st.help = false;
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
    if (chat.id !== st.chatId) {
      stop();
      st.session = null;
      st.allowed = new Set();
    }
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
    st.agentSel = false;
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
    endSelection();
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
    if (input.value) {
      st.selecting = st.agentSel = false;
      st.pendingFull = st.pendingRemoval = null;
    }
    render();
  });
  input.addEventListener("mousedown", () => {
    if (st.selecting || st.agentSel) {
      endSelection();
      render();
    }
  });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing) return;
    // ⌘↵ allows and ⌥⌘↵ allows in this chat: never a bare Return, which is too easy to press twice.
    if (e.metaKey && e.key === "Enter" && st.approval) return e.preventDefault(), e.repeat || resolveApproval(e.altKey ? "chat" : "allow");
    if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "j") return e.preventDefault(), toggleAgent(false);
    if (e.metaKey && e.shiftKey && (e.key === "?" || e.key === "/")) return e.preventDefault(), showHelp();
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const empty = draft().length === 0;
    const arrow = { ArrowDown: 1, ArrowUp: -1 }[e.key];
    const side = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
    if (st.popover) {
      if (arrow) return e.preventDefault(), cycle(arrow);
      if (side) return e.preventDefault(), step(side);
      if (e.key === "Enter" || e.key === "Escape") return e.preventDefault(), (st.popover = false), render();
    }
    if (agentKey(e)) return e.preventDefault();
    if (e.key === "Escape") {
      e.preventDefault();
      if (resolveApproval("deny")) return;
      if (st.help) return closeHelp();
      if (endSelection()) return render();
      hide();
      return;
    }
    if (e.key === "Tab") {
      const matchesNow = slashMatches();
      if (matchesNow.length && !e.shiftKey) return e.preventDefault(), (input.value = matchesNow[0].command), render();
      if (empty) return e.preventDefault(), walkChips(!e.shiftKey);
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
    const refocus = () => input.focus({ preventScroll: true });
    if (target.matches(".bb-send")) return target.dataset.action === "stop" ? stop() : send();
    if (target.matches(".bb-stop2")) return stop();
    if (target.matches(".bb-plus")) return notify("In the app, + attaches images, PDFs and text files.");
    if (target.matches(".bb-globe")) return (st.web = !st.web), render();
    if (target.matches(".bb-clock")) return openHistory(false);
    if (target.matches(".bb-back")) return closeHistory();
    if (target.matches(".bb-new")) return newChat(), closeHistory();
    if (target.matches(".bb-help-back")) return closeHelp(), refocus();
    if (target.matches(".bb-chip")) return (st.popover = !st.popover), (st.selecting = st.agentSel = st.agentPop = false), render();
    if (target.matches(".bb-agent-off")) return toggleAgent(false), refocus();
    if (target.matches(".bb-agent-switch")) return toggleAgent(false), refocus();
    if (target.matches(".bb-agent-project")) return (st.agentPop = !st.agentPop), (st.popover = st.selecting = false), render(), refocus();
    if (target.dataset.project) return (st.project = target.dataset.project), (st.pendingFull = st.pendingRemoval = null), render(), refocus();
    if (target.dataset.permission) return choosePermission(target.dataset.permission), refocus();
    if (target.dataset.action === "terminal") return copyTerminal(), refocus();
    if (target.dataset.action === "agent-off") return toggleAgent(false), refocus();
    if (target.dataset.approve) return resolveApproval(target.dataset.approve), refocus();
    if (target.dataset.command) return (input.value = ""), runCommand(target.dataset.command), refocus();
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
      refocus();
    }
  });
  document.addEventListener("mousedown", (e) => {
    let changed = false;
    if (st.popover && !e.target.closest(".bb-chip-wrap")) (st.popover = false), (changed = true);
    if (st.agentPop && !e.target.closest(".bb-agent-wrap")) (st.agentPop = false), (st.pendingFull = null), (changed = true);
    if (changed) render();
  });

  hiddenNote.addEventListener("click", summon);
  for (const b of root.querySelectorAll("[data-suggest]")) {
    b.addEventListener("click", () => {
      if (!st.visible) summon();
      if (st.history) closeHistory();
      if (b.dataset.suggest === "history") return openHistory(false);
      if (b.dataset.suggest === "/help") return showHelp();
      // Agent suggestions turn agent mode on first; chat suggestions turn it off.
      const wantsAgent = "agent" in b.dataset;
      if (wantsAgent !== st.agent) toggleAgent(false), endSelection();
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
