// Boltbar's panel, recreated for the web. The page's simulator drives it from
// keystrokes; the trailer drives it from a clock. Palettes, the highlighter
// and the layout are copied from the app (Appearance.swift, Views.swift).

export const THEMES = {
  paper: { name: "paper", label: "Paper", background: "#F6F3EC", text: "#292824", accent: "#39735C", error: "#A94442", dark: false },
  mist: { name: "mist", label: "Mist", background: "#F1F5F9", text: "#243247", accent: "#4268B3", error: "#AD435E", dark: false },
  graphite: { name: "graphite", label: "Graphite", background: "#1C1C1E", text: "#E8E7E4", accent: "#A0CCB8", error: "#E79891", dark: true },
  midnight: { name: "midnight", label: "Midnight", background: "#151D2B", text: "#E0E7F0", accent: "#A7B6F5", error: "#E6A0B2", dark: true },
};
export const THEME_ORDER = ["paper", "mist", "graphite", "midnight"];
/** The bolt's amber, as a custom accent (the app lets you pick any). */
export const AMBER = "#F2C46D";
export const withAccent = (theme, accent) => ({ ...theme, accent });

export const MODELS = [
  { id: "gpt-6.1-sol", title: "GPT-6.1 Sol", provider: "OpenAI" },
  { id: "claude-opus-5-5", title: "Claude Opus 5.5", provider: "Anthropic" },
  { id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", provider: "Anthropic" },
  { id: "gpt-6-astra", title: "GPT-6 Astra", provider: "OpenAI" },
  { id: "claude-haiku-5-5", title: "Claude Haiku 5.5", provider: "Anthropic" },
  { id: "claude-fable-5-1", title: "Claude Fable 5.1", provider: "Anthropic" },
  { id: "gpt-6-luna", title: "GPT-6 Luna", provider: "OpenAI" },
];
export const EFFORTS = ["low", "medium", "high"];

/** Agent permissions, read as a traffic light (AgentViews.swift). */
export const PERMISSIONS = ["look", "ask", "edit", "full"];
export const PERMISSION_SUMMARY = {
  look: "Reads files and runs read-only commands; never changes anything",
  ask: "Asks before every command or change",
  edit: "Changes files in the project without asking, deletes included; asks before other commands",
  full: "Runs any command and changes any file without asking",
};
export const title = (s) => s[0].toUpperCase() + s.slice(1);

/** Black or white on the accent, by relative luminance, as the app does. */
export function onAccent(hex) {
  const n = parseInt(hex.slice(1), 16);
  const linear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => linear(c / 255));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.179 ? "#000000" : "#FFFFFF";
}
function applyTheme(el, theme) {
  const d = theme.dark;
  const vars = {
    "--bb-bg": theme.background,
    "--bb-text": theme.text,
    "--bb-accent": theme.accent,
    "--bb-on-accent": onAccent(theme.accent),
    "--bb-kw": d ? "#C6A0E8" : "#7651A8",
    "--bb-num": d ? "#E5BB88" : "#986020",
    "--bb-str": d ? "#A0CCB8" : "#39735C",
    "--bb-com": d ? "#A1A6B3" : "#656968",
    "--bb-error": theme.error ?? (d ? "#E79891" : "#A94442"),
    "--bb-look": "#8E8E93",
    "--bb-ask": d ? "#A0CCB8" : "#39735C",
    "--bb-edit": d ? "#E5BB88" : "#986020",
    "--bb-full": theme.error ?? (d ? "#E79891" : "#A94442"),
  };
  for (const [k, v] of Object.entries(vars)) el.style.setProperty(k, v);
  el.style.colorScheme = d ? "dark" : "light";
}

// ——— Text ———————————————————————————————————————————————————————

export const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** Inline **bold** and `code` inside a paragraph. */
export function segments(text) {
  const out = [];
  const re = /\*\*([^*]+)\*\*|`([^`]+)`/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push({ text: text.slice(last, m.index) });
    out.push(m[1] !== undefined ? { text: m[1], bold: true } : { text: m[2], code: true });
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push({ text: text.slice(last) });
  return out;
}
const plainLength = (b) => (b.kind === "code" ? b.code.length : segments(b.text).reduce((n, s) => n + s.text.length, 0));
export const totalLength = (blocks) => blocks.reduce((n, b) => n + plainLength(b), 0);

/** The visible part of a reply after `n` characters, never cutting markup. */
export function sliceBlocks(blocks, n) {
  const out = [];
  let left = Math.max(0, Math.floor(n));
  for (const b of blocks) {
    if (left <= 0) break;
    if (b.kind === "code") {
      out.push({ ...b, code: b.code.slice(0, left) });
      left -= b.code.length;
      continue;
    }
    let text = "";
    for (const s of segments(b.text)) {
      if (left <= 0) break;
      const part = s.text.slice(0, left);
      left -= s.text.length;
      text += s.bold ? `**${part}**` : s.code ? `\`${part}\`` : part;
    }
    out.push({ kind: "p", text });
  }
  return out;
}

/** The app's highlighter: later rules win, one class per character. */
const RULES = [
  [/\b(let|var|func|fn|struct|class|enum|import|use|return|if|else|for|while|async|await|def|const|function|true|false|nil|null|public|private|static|throw|try)\b/g, "kw"],
  [/\b[0-9]+(?:\.[0-9]+)?\b/g, "num"],
  [/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, "str"],
  [/\/\/[^\n]*|^[ \t]*#[^\n]*/gm, "com"],
];
export function highlight(code) {
  const classes = new Array(code.length).fill("");
  for (const [re, cls] of RULES) {
    re.lastIndex = 0;
    for (let m = re.exec(code); m; m = re.exec(code)) {
      for (let i = m.index; i < m.index + m[0].length; i++) classes[i] = cls;
      if (m[0].length === 0) re.lastIndex++;
    }
  }
  const out = [];
  for (let i = 0; i < code.length; i++) {
    const last = out[out.length - 1];
    if (last && last.cls === classes[i]) last.text += code[i];
    else out.push({ text: code[i], cls: classes[i] });
  }
  return out;
}
export const highlightHTML = (code, prefix = "bb-") =>
  highlight(code).map((t) => (t.cls ? `<span class="${prefix}${t.cls}">${esc(t.text)}</span>` : esc(t.text))).join("");

// ——— Icons (simple stand-ins for the app's SF Symbols) ————————————————

const svg = (size, body, attrs = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"') =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" ${attrs} aria-hidden="true">${body}</svg>`;
export const ICONS = {
  plus: svg(16, '<path d="M12 4v16M4 12h16"/>'),
  arrowUp: svg(16, '<path d="M12 20V5M5.5 11.5 12 5l6.5 6.5"/>'),
  stop: (size = 13) => svg(size, '<rect x="4" y="4" width="16" height="16" rx="3" fill="currentColor"/>', ""),
  history: svg(16, '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6"/><path d="M3 4v4.5h4.5"/><path d="M12 7.5V12l3 2"/>'),
  globe: svg(16, '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9S9.4 5.6 12 3Z"/>'),
  copy: svg(13, '<rect x="8.5" y="8.5" width="11" height="12" rx="2"/><path d="M15.5 8.5V6a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h2"/>'),
  check: svg(13, '<path d="m5 12.5 4.5 4.5L19 7"/>'),
  close: svg(10, '<path d="M6 6l12 12M18 6 6 18"/>'),
  back: svg(15, '<path d="M15 5l-7 7 7 7"/>'),
  compose: svg(16, '<path d="M11 4.5H6.5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V13"/><path d="M17.8 3.7a1.9 1.9 0 0 1 2.7 2.7L12.6 14.3 9 15l.7-3.6Z"/>'),
  terminal: svg(15, '<rect x="2.5" y="4" width="19" height="16" rx="3.5"/><path d="m7 9.5 3 2.5-3 2.5M12.5 15h4.5"/>', 'fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"'),
  pencil: svg(12, '<path d="M4.5 19.5 6 14 15.5 4.5a2.1 2.1 0 0 1 3 3L9 17Z"/>'),
  fail: svg(12, '<path d="M6 6l12 12M18 6 6 18"/>'),
  nosign: svg(12, '<circle cx="12" cy="12" r="8.5"/><path d="m6 6 12 12"/>'),
};

/** The model chip's effort gauge; effort is 0 (low) … 2 (high), fractional while it sweeps. */
export function gauge(effort) {
  const a = (-150 + effort * 60) * (Math.PI / 180);
  return `<svg width="18" height="16" viewBox="0 0 18 16" aria-hidden="true"><path d="M1.5 12a7.5 7.5 0 0 1 15 0" fill="none" stroke="currentColor" stroke-opacity=".45" stroke-width="1.7" stroke-linecap="round"/><path d="M9 12L${(9 + Math.cos(a) * 6).toFixed(2)} ${(12 + Math.sin(a) * 6).toFixed(2)}" stroke="var(--bb-accent)" stroke-width="1.8" stroke-linecap="round"/><circle cx="9" cy="12" r="1.5" fill="var(--bb-accent)"/></svg>`;
}

// ——— Markup ——————————————————————————————————————————————————————

function inlineHTML(text) {
  return segments(text).map((s) => (s.bold ? `<strong>${esc(s.text)}</strong>` : s.code ? `<code>${esc(s.text)}</code>` : esc(s.text))).join("");
}
function blockHTML(b) {
  if (b.kind === "h") return `<p class="bb-h">${esc(b.text)}</p>`;
  if (b.kind === "keys") return `<div class="bb-keys">${b.rows.map(([k, v]) => `<span class="bb-keys-k">${esc(k)}</span><span>${inlineHTML(v)}</span>`).join("")}</div>`;
  if (b.kind === "code") {
    return `<div class="bb-code"><div class="bb-code-head"><span>${esc(b.lang || "Code")}</span>${ICONS.copy}</div><pre class="bb-pre">${highlightHTML(b.code)}</pre></div>`;
  }
  return `<p class="bb-p">${inlineHTML(b.text)}</p>`;
}
/** One line per agent action, above the reply. */
export function stepsHTML(steps) {
  return `<div class="bb-steps">${steps
    .map((s) => {
      const icon = s.status === "running" ? '<span class="bb-spinner"></span>' : s.status === "failed" ? ICONS.fail : s.status === "denied" ? ICONS.nosign : s.kind === "edit" ? ICONS.pencil : ICONS.check;
      const detail = s.status === "denied" ? "declined" : s.detail;
      return `<div class="bb-step ${s.status}"><span class="bb-step-icon">${icon}</span><span class="bb-step-title">${esc(s.title)}</span>${detail ? `<span class="bb-step-detail">${esc(detail)}</span>` : ""}</div>`;
    })
    .join("")}</div>`;
}
export function messageHTML(m) {
  const blocks = m.revealed == null ? m.blocks : sliceBlocks(m.blocks, m.revealed);
  const hasText = blocks.some((b) => (b.kind === "code" ? b.code : b.text).length > 0);
  const label = m.role === "user" ? "You" : m.author ?? "Assistant";
  const head = `<div class="bb-msg-head"><span class="bb-label">${esc(label)}</span>${m.interrupted ? '<span class="bb-badge">Interrupted</span>' : ""}</div>`;
  const steps = m.steps?.length ? stepsHTML(m.steps) : "";
  const body = hasText
    ? `<div class="bb-body">${blocks.map(blockHTML).join("")}</div>`
    : m.pending && !steps
      ? `<div class="bb-pending"><span class="bb-spinner"></span>${esc(m.activity ?? "Thinking…")}</div>`
      : "";
  return `<div class="bb-msg">${head}${steps}${body}</div>`;
}
export function popoverHTML(models, current, effort) {
  const efforts = EFFORTS.map((e) => `<button type="button" data-effort="${e}" class="${e === effort ? "on" : ""}">${e[0].toUpperCase() + e.slice(1)}</button>`).join("");
  const rows = models
    .map((m) => `<button type="button" class="bb-model-row" data-model="${esc(m.id)}"><span><span>${esc(m.title)}</span><span class="bb-model-provider">${esc(m.provider)}</span></span>${m.id === current ? ICONS.check : ""}</button>`)
    .join("");
  return `<div class="bb-popover" role="dialog" aria-label="Effort and model"><div class="bb-pop-title">Thinking effort</div><div class="bb-segmented">${efforts}</div><div class="bb-pop-divider"></div><div class="bb-models">${rows}</div></div>`;
}

/** The agent chip: a terminal button when off; with the project and its light when on. */
export function agentChipHTML(a) {
  if (!a?.on) {
    return `<button type="button" class="bb-agent-off${a?.selected ? " on" : ""}" aria-label="Agent mode" aria-pressed="false" title="Agent mode (⌘J)">${ICONS.terminal}${a?.selected ? '<span class="bb-agent-hint">↵ turn on</span>' : ""}</button>`;
  }
  const hint = a.hint ? `<span class="bb-agent-hint ${esc(a.hintLevel ?? "")}">${esc(a.hint)}</span>` : "";
  return `<span class="bb-agent${a.selected ? " on" : ""}"><button type="button" class="bb-agent-switch" aria-label="Turn off agent mode" title="Turn off agent mode · ⌘J">${ICONS.terminal}</button><button type="button" class="bb-agent-project" aria-label="Agent project: ${esc(a.name)}, ${esc(a.permission)}" title="Click to change">${a.nameHTML ?? `<span class="bb-agent-name">${esc(a.name)}</span>`}<span class="bb-dot ${esc(a.permission)}"></span>${hint}</button></span>`;
}
export function agentPopoverHTML({ projects, selected, permission, pendingFull, pendingRemoval, session }) {
  const rows = projects
    .map((p) => {
      const removing = pendingRemoval === p.id;
      return `<button type="button" class="bb-project-row${p.id === selected ? " on" : ""}" data-project="${esc(p.id)}"><span class="bb-dot ${p.permission}"></span><span class="bb-project-text"><span>${esc(p.name)}</span><span class="bb-project-path${removing ? " warn" : ""}">${esc(removing ? "Press ⌫ again to remove from the list" : p.path)}</span></span>${p.id === selected ? ICONS.check : ""}</button>`;
    })
    .join("");
  const levels = PERMISSIONS.map((l) => `<button type="button" data-permission="${l}" class="${l === permission ? "on" : ""}"><span class="bb-dot ${l}"></span>${title(l)}</button>`).join("");
  const summary = pendingFull
    ? `<div class="bb-pop-summary warn">Full runs any command and changes any file without asking, for 24 hours. Press → or click Full again to turn it on.</div>`
    : `<div class="bb-pop-summary">${esc(PERMISSION_SUMMARY[permission])}</div>`;
  return `<div class="bb-popover bb-agent-popover" role="dialog" aria-label="Agent project and permission">
    <div class="bb-pop-row"><span class="bb-pop-title">Project</span><span class="bb-dim">↑ ↓</span></div>
    <div class="bb-projects">${rows}<div class="bb-add-folder"><span>+ Add folder…</span><span class="bb-dim">or drop one on the bar</span></div></div>
    <div class="bb-pop-divider"></div>
    <div class="bb-pop-row"><span class="bb-pop-title">Permission</span><span class="bb-dim">← →</span></div>
    <div class="bb-segmented bb-levels">${levels}</div>${summary}
    <div class="bb-pop-divider"></div>
    ${session ? `<button type="button" class="bb-pop-action" data-action="terminal"><span>Continue in terminal</span><span class="bb-dim">${esc(session)}</span></button>` : ""}
    <button type="button" class="bb-pop-action" data-action="agent-off"><span>Turn off agent mode</span><span class="bb-dim">⌘J</span></button>
  </div>`;
}
/** A permission request, inline above the field: never a modal. */
export function approvalHTML(a) {
  const button = (key, label, keys) => `<button type="button" data-approve="${key}" class="${a.pressed === key ? "on" : ""}">${label} <span>${keys}</span></button>`;
  return `<div class="bb-approval" role="group" aria-label="Permission request"><div class="bb-approval-head"><span class="bb-dim">${esc(a.action)}</span><span class="bb-approval-subject">${esc(a.subject)}</span><span class="bb-flex"></span><span class="bb-dim">in ${esc(a.project)}</span></div><div class="bb-approval-buttons">${button("allow", "Allow", "⌘↵")}${button("chat", "Allow in this chat", "⌥⌘↵")}${button("deny", "Deny", "esc")}</div></div>`;
}
export const slashHTML = (matches) =>
  `<div class="bb-slash" role="listbox" aria-label="Commands">${matches
    .map((m, i) => `<button type="button" class="bb-slash-row${i === 0 ? " on" : ""}" data-command="${esc(m.command)}"><span class="bb-slash-cmd">${esc(m.command)}</span><span class="bb-slash-sum">${esc(m.summary)}</span>${i === 0 ? '<span class="bb-flex"></span><span class="bb-dim">tab</span>' : ""}</button>`)
    .join("")}</div>`;

/**
 * Build a panel and return `update(props)`, which repaints only what changed.
 * props: theme, messages, draft, caret, placeholder, model | modelHTML, effort,
 * selectingModel, webSearch, streaming, hasDraft, queue, queueStatus, hint,
 * popoverHTML, threadHeight, and history: { query, items: [{ id, title, date }],
 * total, selected, pending } to show the previous-chats browser instead.
 * Agent mode: agent (agentChipHTML's input), agentPopoverHTML, approval, slash,
 * notice, help (blocks shown in place of the thread), tools: { reveal, turn }
 * to unroll + without a pointer (the trailer).
 */
export function createBar({ interactive = false } = {}) {
  const el = document.createElement("div");
  el.className = interactive ? "bb" : "bb bb-static";
  el.innerHTML = `
    <div class="bb-move"></div>
    <div class="bb-thread-wrap" hidden><div class="bb-thread"></div><div class="bb-divider"></div></div>
    <div class="bb-help" hidden><div class="bb-help-head"><button type="button" class="bb-help-back" aria-label="Close help">${ICONS.back}</button><span class="bb-history-title">Boltbar help</span><span class="bb-flex"></span><span class="bb-dim">esc closes</span></div><div class="bb-help-body"></div></div>
    <div class="bb-queue" hidden></div>
    <div class="bb-approval-slot" hidden></div>
    <div class="bb-slash-slot" hidden></div>
    <div class="bb-history" hidden>
      <div class="bb-history-head"><button type="button" class="bb-back" aria-label="Back to chat">${ICONS.back}</button><span class="bb-history-title">Previous chats</span><span class="bb-flex"></span><button type="button" class="bb-new" aria-label="New chat">${ICONS.compose}</button></div>
      <div class="bb-search"><span class="bb-prompt">&gt;</span>${
        interactive
          ? '<input class="bb-search-input" type="text" placeholder="search all messages" aria-label="Search conversations" spellcheck="false" autocomplete="off">'
          : '<span class="bb-search-text"></span><span class="bb-caret bb-search-caret"></span><span class="bb-search-placeholder">search all messages</span>'
      }</div>
      <div class="bb-history-list" role="listbox" aria-label="Previous conversations"></div>
      <div class="bb-history-hint">↑ ↓ select · → / Return open · ⌫ delete · ← back</div>
    </div>
    <div class="bb-composer">${
      interactive
        ? '<textarea class="bb-input" rows="1" spellcheck="false" aria-label="Message (simulated)"></textarea>'
        : '<span class="bb-draft"></span><span class="bb-caret"></span><span class="bb-placeholder"></span>'
    }<span class="bb-hint"></span></div>
    <div class="bb-notice" hidden></div>
    <div class="bb-toolbar">
      <span class="bb-chip-wrap"><button type="button" class="bb-chip" aria-label="Effort and model"><span class="bb-model"></span><span class="bb-gauge"></span></button><span class="bb-popover-slot"></span></span>
      <span class="bb-agent-wrap"><span class="bb-agent-slot"></span><span class="bb-agent-pop-slot"></span></span>
      <span class="bb-tools"><button type="button" class="bb-plus" aria-label="Attach files" title="Attach images, PDFs or text files">${ICONS.plus}</button><button type="button" class="bb-icon bb-globe" aria-label="Search the web" aria-pressed="false">${ICONS.globe}</button><button type="button" class="bb-icon bb-clock" aria-label="Previous chats">${ICONS.history}</button></span>
      <span class="bb-flex"></span>
      <button type="button" class="bb-stop2" aria-label="Stop" hidden>${ICONS.stop(11)}</button>
      <button type="button" class="bb-send" aria-label="Send">${ICONS.arrowUp}</button>
    </div>`;
  const $ = (sel) => el.querySelector(sel);
  const refs = {
    threadWrap: $(".bb-thread-wrap"), thread: $(".bb-thread"), queue: $(".bb-queue"), input: $(".bb-input"),
    draft: $(".bb-draft"), caret: $(".bb-caret"), placeholder: $(".bb-placeholder"), hint: $(".bb-hint"),
    chip: $(".bb-chip"), model: $(".bb-model"), gauge: $(".bb-gauge"), popover: $(".bb-popover-slot"),
    globe: $(".bb-globe"), stop2: $(".bb-stop2"), send: $(".bb-send"),
    history: $(".bb-history"), list: $(".bb-history-list"), searchInput: $(".bb-search-input"),
    searchText: $(".bb-search-text"), searchCaret: $(".bb-search-caret"), searchPlaceholder: $(".bb-search-placeholder"),
    composer: $(".bb-composer"), toolbar: $(".bb-toolbar"),
    help: $(".bb-help"), helpBody: $(".bb-help-body"), approval: $(".bb-approval-slot"), slash: $(".bb-slash-slot"), notice: $(".bb-notice"),
    agent: $(".bb-agent-slot"), agentPop: $(".bb-agent-pop-slot"), tools: $(".bb-tools"), plus: $(".bb-plus svg"),
  };
  const memo = {};
  const set = (key, value, apply) => {
    if (memo[key] === value) return;
    memo[key] = value;
    apply(value);
  };

  function update(p) {
    set("theme", p.theme, (t) => applyTheme(el, t));
    // The history browser replaces the thread, queue, composer and toolbar.
    const h = p.history;
    refs.history.hidden = !h;
    refs.composer.hidden = refs.toolbar.hidden = !!h;
    if (h) {
      const rows = h.items.length
        ? h.items.map((item) => {
            const pending = item.id === h.pending;
            return `<div class="bb-row${item.id === h.selected ? " on" : ""}" role="option" aria-selected="${item.id === h.selected}" data-chat="${esc(item.id)}"><span class="bb-row-title">${esc(item.title)}</span><span class="bb-row-date${pending ? " warn" : ""}">${pending ? "Press Delete again · Esc cancel" : esc(item.date)}</span></div>`;
          }).join("")
        : `<div class="bb-history-empty">No matching conversations</div>`;
      set("historyRows", rows, (html) => (refs.list.innerHTML = html));
      set("historyHeight", Math.min(308, Math.max(88, (h.total ?? h.items.length) * 44)), (v) => (refs.list.style.height = `${v}px`));
      if (!interactive) {
        set("search", h.query ?? "", (v) => {
          refs.searchText.textContent = v;
          refs.searchPlaceholder.hidden = !!v;
        });
        set("searchCaret", !!h.caret, (v) => (refs.searchCaret.style.visibility = v ? "visible" : "hidden"));
      }
      // Keep the selection in view by scrolling the list, never the page.
      const on = refs.list.querySelector(".bb-row.on");
      if (on) {
        const top = on.offsetTop, bottom = top + on.offsetHeight;
        if (top < refs.list.scrollTop) refs.list.scrollTop = top;
        else if (bottom > refs.list.scrollTop + refs.list.clientHeight) refs.list.scrollTop = bottom - refs.list.clientHeight;
      }
    }
    const messages = p.messages ?? [];
    set("messages", messages.map(messageHTML).join(""), (html) => (refs.thread.innerHTML = html));
    set("help", p.help ? p.help.map(blockHTML).join("") : "", (html) => (refs.helpBody.innerHTML = html));
    refs.help.hidden = !p.help || !!h;
    refs.threadWrap.hidden = memo.messages === "" || !!h || !!p.help;
    set("threadHeight", p.threadHeight ?? 330, (h) => (refs.thread.style.maxHeight = `${h}px`));
    const queue = p.queue ?? [];
    const queueHTML = queue.length
      ? `<div class="bb-queue-head"><span class="bb-label">${queue.length > 1 ? `Queued · ${queue.length}` : "Queued"}</span><span class="bb-queue-status">${esc(p.queueStatus ?? "")}</span><span class="bb-flex"></span><button type="button" class="bb-send-now">${p.hasDraft ? "Send now" : "Send now ↵"}</button></div>` +
        queue.map((q) => `<div class="bb-queue-row"><span class="bb-queue-text">${esc(q.text)}</span><button type="button" class="bb-queue-remove" data-remove="${esc(q.id)}" aria-label="Remove queued message">${ICONS.close}</button></div>`).join("")
      : "";
    set("queue", queueHTML, (html) => (refs.queue.innerHTML = html));
    refs.queue.hidden = memo.queue === "" || !!h;
    set("approval", p.approval ? approvalHTML(p.approval) : "", (html) => (refs.approval.innerHTML = html));
    refs.approval.hidden = memo.approval === "" || !!h;
    set("slash", p.slash?.length ? slashHTML(p.slash) : "", (html) => (refs.slash.innerHTML = html));
    refs.slash.hidden = memo.slash === "" || !!h;
    set("notice", p.notice ?? "", (v) => (refs.notice.textContent = v));
    refs.notice.hidden = !p.notice || !!h;
    if (interactive) {
      set("placeholder", p.placeholder ?? "Ask anything…", (v) => (refs.input.placeholder = v));
    } else {
      set("draft", `${p.draft ?? ""}\u0000${p.placeholder ?? ""}`, () => {
        refs.draft.textContent = p.draft ?? "";
        refs.placeholder.textContent = p.draft ? "" : p.placeholder ?? "Ask anything…";
      });
      set("caret", !!p.caret, (v) => (refs.caret.style.visibility = v ? "visible" : "hidden"));
    }
    set("hint", p.hint ?? "", (v) => {
      refs.hint.textContent = v;
      refs.hint.hidden = !v;
    });
    set("model", p.modelHTML ?? `<span>${esc(p.model ?? "")}</span>`, (html) => (refs.model.innerHTML = html));
    const effort = typeof p.effort === "number" ? p.effort : EFFORTS.indexOf(p.effort ?? "medium");
    set("effort", effort.toFixed(3), () => (refs.gauge.innerHTML = gauge(effort)));
    set("selecting", !!p.selectingModel, (v) => refs.chip.classList.toggle("on", v));
    set("popover", p.popoverHTML ?? "", (html) => (refs.popover.innerHTML = html));
    set("agent", agentChipHTML(p.agent), (html) => (refs.agent.innerHTML = html));
    set("agentPop", p.agentPopoverHTML ?? "", (html) => {
      refs.agentPop.innerHTML = html;
      // Keep the popover inside the bar on narrow screens; its arrow stays on the chip.
      const pop = refs.agentPop.firstElementChild;
      if (!pop) return;
      const shift = Math.max(0, pop.getBoundingClientRect().right - (el.getBoundingClientRect().right - 8));
      pop.style.left = `${-shift}px`;
      pop.style.setProperty("--arrow", `${28 + shift}px`);
    });
    // Without a pointer (the trailer), + unrolls from props; in the page, on hover.
    if (p.tools) {
      set("tools", `${p.tools.reveal.toFixed(3)}|${(p.tools.turn ?? 0).toFixed(2)}`, () => {
        refs.tools.style.setProperty("--reveal", p.tools.reveal.toFixed(3));
        refs.plus.style.transform = `rotate(${(p.tools.turn ?? 0).toFixed(2)}deg)`;
      });
    }
    set("web", !!p.webSearch, (v) => {
      refs.globe.classList.toggle("on", v);
      refs.globe.setAttribute("aria-pressed", String(v));
      refs.tools.classList.toggle("pinned", v);
    });
    set("agentMode", !!p.agent?.on, (v) => {
      refs.globe.disabled = v;
      refs.globe.title = v ? "Web search is off in agent mode" : "Search the web";
    });
    // During a reply, text turns the main button into "queue" and Stop moves beside it.
    const stops = !!p.streaming && !p.hasDraft;
    set("buttons", `${!!p.streaming}|${!!p.hasDraft}`, () => {
      refs.stop2.hidden = !(p.streaming && p.hasDraft);
      refs.send.innerHTML = stops ? ICONS.stop() : ICONS.arrowUp;
      refs.send.setAttribute("aria-label", stops ? "Stop" : p.streaming ? "Add to queue" : "Send");
      refs.send.dataset.action = stops ? "stop" : "send";
    });
  }
  return { el, update, refs };
}
