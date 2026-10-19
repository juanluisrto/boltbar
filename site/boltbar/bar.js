// Boltbar's panel, recreated for the web. The page's simulator drives it from
// keystrokes; the trailer drives it from a clock. Palettes, the highlighter
// and the layout are copied from the app (Appearance.swift, Views.swift).

export const THEMES = {
  paper: { name: "paper", label: "Paper", background: "#F6F3EC", text: "#292824", accent: "#39735C", dark: false },
  mist: { name: "mist", label: "Mist", background: "#F1F5F9", text: "#243247", accent: "#4268B3", dark: false },
  graphite: { name: "graphite", label: "Graphite", background: "#1C1C1E", text: "#E8E7E4", accent: "#A0CCB8", dark: true },
  midnight: { name: "midnight", label: "Midnight", background: "#151D2B", text: "#E0E7F0", accent: "#A7B6F5", dark: true },
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
};

/** The model chip's effort gauge; effort is 0 (low) … 2 (high), fractional while it sweeps. */
export function gauge(effort) {
  const a = (-150 + effort * 60) * (Math.PI / 180);
  return `<svg width="18" height="16" viewBox="0 0 18 16" aria-hidden="true"><path d="M1.5 12a7.5 7.5 0 0 1 15 0" fill="none" stroke="currentColor" stroke-opacity=".45" stroke-width="1.7" stroke-linecap="round"/><path d="M9 12L${(9 + Math.cos(a) * 6).toFixed(2)} ${(12 + Math.sin(a) * 6).toFixed(2)}" stroke="var(--bb-accent)" stroke-width="1.8" stroke-linecap="round"/><circle cx="9" cy="12" r="1.5" fill="var(--bb-accent)"/></svg>`;
}

// ——— Markup ——————————————————————————————————————————————————————

function blockHTML(b) {
  if (b.kind === "code") {
    return `<div class="bb-code"><div class="bb-code-head"><span>${esc(b.lang || "Code")}</span>${ICONS.copy}</div><pre class="bb-pre">${highlightHTML(b.code)}</pre></div>`;
  }
  const inner = segments(b.text).map((s) => (s.bold ? `<strong>${esc(s.text)}</strong>` : s.code ? `<code>${esc(s.text)}</code>` : esc(s.text))).join("");
  return `<p class="bb-p">${inner}</p>`;
}
export function messageHTML(m) {
  const blocks = m.revealed == null ? m.blocks : sliceBlocks(m.blocks, m.revealed);
  const hasText = blocks.some((b) => (b.kind === "code" ? b.code : b.text).length > 0);
  const label = m.role === "user" ? "You" : m.author ?? "Assistant";
  const head = `<div class="bb-msg-head"><span class="bb-label">${esc(label)}</span>${m.interrupted ? '<span class="bb-badge">Interrupted</span>' : ""}</div>`;
  const body = hasText
    ? `<div class="bb-body">${blocks.map(blockHTML).join("")}</div>`
    : m.pending
      ? `<div class="bb-pending"><span class="bb-spinner"></span>${esc(m.activity ?? "Thinking…")}</div>`
      : "";
  return `<div class="bb-msg">${head}${body}</div>`;
}
export function popoverHTML(models, current, effort) {
  const efforts = EFFORTS.map((e) => `<button type="button" data-effort="${e}" class="${e === effort ? "on" : ""}">${e[0].toUpperCase() + e.slice(1)}</button>`).join("");
  const rows = models
    .map((m) => `<button type="button" class="bb-model-row" data-model="${esc(m.id)}"><span><span>${esc(m.title)}</span><span class="bb-model-provider">${esc(m.provider)}</span></span>${m.id === current ? ICONS.check : ""}</button>`)
    .join("");
  return `<div class="bb-popover" role="dialog" aria-label="Effort and model"><div class="bb-pop-title">Thinking effort</div><div class="bb-segmented">${efforts}</div><div class="bb-pop-divider"></div><div class="bb-models">${rows}</div></div>`;
}

/**
 * Build a panel and return `update(props)`, which repaints only what changed.
 * props: theme, messages, draft, caret, placeholder, model | modelHTML, effort,
 * selectingModel, webSearch, streaming, hasDraft, queue, queueStatus, hint,
 * popoverHTML, threadHeight.
 */
export function createBar({ interactive = false } = {}) {
  const el = document.createElement("div");
  el.className = "bb";
  el.innerHTML = `
    <div class="bb-move"></div>
    <div class="bb-thread-wrap" hidden><div class="bb-thread"></div><div class="bb-divider"></div></div>
    <div class="bb-queue" hidden></div>
    <div class="bb-composer">${
      interactive
        ? '<textarea class="bb-input" rows="1" spellcheck="false" aria-label="Message (simulated)"></textarea>'
        : '<span class="bb-draft"></span><span class="bb-caret"></span><span class="bb-placeholder"></span>'
    }<span class="bb-hint"></span></div>
    <div class="bb-toolbar">
      <span class="bb-circle">${ICONS.plus}</span>
      <span class="bb-chip-wrap"><button type="button" class="bb-chip" aria-label="Effort and model"><span class="bb-model"></span><span class="bb-gauge"></span></button><span class="bb-popover-slot"></span></span>
      <span class="bb-icon bb-history">${ICONS.history}</span>
      <button type="button" class="bb-icon bb-globe" aria-label="Search the web" aria-pressed="false">${ICONS.globe}</button>
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
  };
  const memo = {};
  const set = (key, value, apply) => {
    if (memo[key] === value) return;
    memo[key] = value;
    apply(value);
  };

  function update(p) {
    set("theme", p.theme, (t) => applyTheme(el, t));
    const messages = p.messages ?? [];
    set("messages", messages.map(messageHTML).join(""), (html) => {
      refs.thread.innerHTML = html;
      refs.threadWrap.hidden = html === "";
    });
    set("threadHeight", p.threadHeight ?? 330, (h) => (refs.thread.style.maxHeight = `${h}px`));
    const queue = p.queue ?? [];
    const queueHTML = queue.length
      ? `<div class="bb-queue-head"><span class="bb-label">${queue.length > 1 ? `Queued · ${queue.length}` : "Queued"}</span><span class="bb-queue-status">${esc(p.queueStatus ?? "")}</span><span class="bb-flex"></span><button type="button" class="bb-send-now">${p.hasDraft ? "Send now" : "Send now ↵"}</button></div>` +
        queue.map((q) => `<div class="bb-queue-row"><span class="bb-queue-text">${esc(q.text)}</span><button type="button" class="bb-queue-remove" data-remove="${esc(q.id)}" aria-label="Remove queued message">${ICONS.close}</button></div>`).join("")
      : "";
    set("queue", queueHTML, (html) => {
      refs.queue.innerHTML = html;
      refs.queue.hidden = html === "";
    });
    if (interactive) {
      set("placeholder", p.placeholder ?? "Ask anything…", (v) => (refs.input.placeholder = v));
    } else {
      set("draft", p.draft ?? "", (v) => {
        refs.draft.textContent = v;
        refs.placeholder.textContent = v ? "" : p.placeholder ?? "Ask anything…";
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
    set("web", !!p.webSearch, (v) => {
      refs.globe.classList.toggle("on", v);
      refs.globe.setAttribute("aria-pressed", String(v));
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
