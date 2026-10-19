// Boltbar's trailer as a pure function of time: `frame(t)` paints the whole
// 1920×1080 stage for any t, so the page previews it and render.mjs captures
// it frame by frame. Cuts land on a 120 BPM grid (one beat = 0.5 s).
import { createBar, highlightHTML, totalLength, AMBER, THEMES, THEME_ORDER, withAccent, esc } from "/boltbar/bar.js";

export const DURATION = 36;
export const FPS = 60;

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const prog = (t, a, b) => clamp((t - a) / (b - a));
const lerp = (a, b, x) => a + (b - a) * x;
const easeOut = (x) => 1 - (1 - x) ** 3;
const easeIn = (x) => x ** 3;
const easeInOut = (x) => (x < 0.5 ? 4 * x ** 3 : 1 - (-2 * x + 2) ** 3 / 2);
const back = (x, k = 1.6) => 1 + (k + 1) * (x - 1) ** 3 + k * (x - 1) ** 2;
/** In over a→b, out over c→d. */
const fade = (t, a, b, c, d) => Math.min(easeOut(prog(t, a, b)), 1 - easeIn(prog(t, c, d)));

const TRAILER_THEME = withAccent(THEMES.graphite, AMBER);

// ——— Story ———————————————————————————————————————————————————————

const EDITOR_CODE = `import Foundation

final class SearchField {
    private let debounce = Debouncer(delay: 0.25)
    var onQuery: ((String) -> Void)?

    func textDidChange(_ text: String) {
        debounce.call { [weak self] in
            self?.onQuery?(text)
        }
    }
}`;
const ERROR_AT = EDITOR_CODE.indexOf("Debouncer(delay");

const QUESTION = "Write a debounce in Swift";
const ANSWER = [
  { kind: "p", text: "Here's a small **Debouncer**: each call cancels the pending one, so only the last runs." },
  {
    kind: "code",
    lang: "swift",
    code: `final class Debouncer {
    private var work: DispatchWorkItem?
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func call(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}`,
  },
  { kind: "p", text: "Then `debounce.call { search(text) }` fires once typing pauses." },
];
const ANSWER_LEN = totalLength(ANSWER);

function conversation(t) {
  if (t < 8.65) return [];
  return [
    { id: "q", role: "user", blocks: [{ kind: "p", text: QUESTION }] },
    { id: "a", role: "assistant", author: "Anthropic", blocks: ANSWER, pending: t < 9.25, revealed: ANSWER_LEN * easeInOut(prog(t, 9.25, 12.1)) },
  ];
}

const MODEL_ROLL = ["Claude Haiku 5.5", "GPT-6 Luna", "Claude Sonnet 5.5", "GPT-6 Astra", "Claude Fable 5.1", "GPT-6.1 Sol", "Claude Opus 5.5"];
const MODEL_BEATS = [13.5, 14, 14.5, 15, 15.5, 16];
const EFFORT_BEATS = [16.5, 17, 17.5];

const MINI = {
  paper: { q: "Translate “see you tomorrow” to Japanese", a: [{ kind: "p", text: "**また明日** (mata ashita) — casual and friendly." }], model: "Claude Sonnet 5.5", effort: 0, author: "Anthropic" },
  mist: { q: "Regex for an ISO date?", a: [{ kind: "code", lang: "regex", code: "^\\d{4}-\\d{2}-\\d{2}$" }], model: "GPT-6.1 Sol", effort: 1, author: "OpenAI" },
  graphite: { q: "Why does this crash?", a: [{ kind: "p", text: "`work` is captured strongly — use `[weak self]` in the closure." }], model: "Claude Opus 5.5", effort: 2, author: "Anthropic" },
  midnight: { q: "Plan a day in Kyoto", a: [{ kind: "p", text: "**Dawn** Fushimi Inari. **Noon** Nishiki market. **Dusk** Gion." }], model: "GPT-6 Astra", effort: 1, author: "OpenAI" },
};

const TITLES = [
  { text: "Mid-thought.", at: 0.5, out: 1.85, x: 960, y: 520, size: 168 },
  { text: "Mid-code.", at: 2.0, out: 3.6, x: 960, y: 520, size: 168 },
  { text: "Boltbar", at: 5.45, out: 6.85, x: 960, y: 370, size: 150, weight: 650, stagger: 0.04 },
  { text: "Ask anything.", at: 7.75, out: 12.55, x: 120, y: 430, size: 86, align: "left" },
  { text: "From anywhere.", at: 9.9, out: 12.55, x: 120, y: 540, size: 86, align: "left", color: AMBER },
  { text: "GPT and Claude. One bar.", at: 13.55, out: 15.95, x: 960, y: 330, size: 104 },
  { text: "Your API keys —", at: 16.2, out: 18.75, x: 960, y: 300, size: 84 },
  { text: "or the Claude Code and Codex login you already have.", at: 16.7, out: 18.75, x: 960, y: 392, size: 44, weight: 500, stagger: 0.03, color: "rgba(255,255,255,0.72)" },
  { text: "Native to macOS.", at: 19.55, out: 21.9, x: 960, y: 175, size: 96 },
  { text: "Swift. 3 MB. Instant.", at: 22.0, out: 24.6, x: 960, y: 175, size: 96, stagger: 0.5, accent: [1] },
  { text: "Gone when you’re done.", at: 26.25, out: 27.6, x: 960, y: 520, size: 116 },
  { text: "Keys in Keychain.", at: 27.75, out: 28.95, x: 960, y: 470, size: 92 },
  { text: "Chats on your Mac.", at: 28.0, out: 28.95, x: 960, y: 580, size: 92, color: AMBER },
  { text: "Boltbar", at: 29.95, out: 99, x: 960, y: 640, size: 128, weight: 650, stagger: 0.04 },
  { text: "Free & open source · macOS 13+", at: 31.05, out: 99, x: 960, y: 858, size: 30, weight: 450, stagger: 0.03, color: "rgba(255,255,255,0.7)" },
];

const KEYS = [
  { label: "⌥", x: 790, y: 600, w: 170, at: 4.0, presses: [5.0], out: 5.12, glyph: true },
  { label: "space", x: 1090, y: 600, w: 380, h: 170, at: 4.2, presses: [5.0], out: 5.12, size: 34 },
  { label: "return", x: 1300, y: 1015, w: 150, h: 58, at: 8.25, presses: [8.55], out: 8.95, size: 17 },
  { label: "↓", x: 960, y: 985, w: 74, at: 13.3, presses: MODEL_BEATS, out: 16.2, size: 30 },
  { label: "→", x: 960, y: 985, w: 74, at: 16.3, presses: EFFORT_BEATS, out: 18.3, size: 30 },
  { label: "esc", x: 960, y: 1000, w: 120, h: 64, at: 25.25, presses: [25.7], out: 26.05, size: 20 },
  { label: "⌥", x: 905, y: 760, w: 70, at: 30.5, out: 99, size: 28 },
  { label: "space", x: 1030, y: 760, w: 160, h: 70, at: 30.6, out: 99, size: 18 },
];

const ICON_SVG = `<svg viewBox="72 72 880 880" width="220" height="220" aria-hidden="true"><defs><linearGradient id="tp" x2="0" y2="1"><stop stop-color="#353638"/><stop offset="1" stop-color="#17181b"/></linearGradient><linearGradient id="tb" x2="0" y2="1"><stop stop-color="#ffdc89"/><stop offset="1" stop-color="#f4ad39"/></linearGradient></defs><rect x="72" y="72" width="880" height="880" rx="198" fill="url(#tp)" stroke="#ffffff" stroke-opacity=".12" stroke-width="2"/><path d="M562 216 304 548Q296 560 312 560H474L430 798 724 450Q734 438 716 438H550L600 230Q604 212 586 212H574Q567 212 562 216Z" fill="url(#tb)"/></svg>`;

// ——— Building the stage once ——————————————————————————————————————

const h = (tag, cls, html = "") => {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (html) el.innerHTML = html;
  return el;
};
const css = (el, styles) => Object.assign(el.style, styles);

export function buildScene(stage) {
  const scene = h("div", "t-scene");
  stage.append(scene);
  const add = (el) => (scene.append(el), el);

  add(h("div", "t-void"));
  const glow = add(h("div", "t-glow"));

  // The desktop the bar appears over.
  const deskWrap = add(h("div", "t-deskWrap"));
  deskWrap.innerHTML = `
    <div class="t-desk">
      <div class="t-wallpaper"></div>
      <div class="t-menubar"><span class="t-menuApp">Xcode</span><span>File</span><span>Edit</span><span>View</span><span>Find</span><span>Editor</span><span class="t-flex"></span>
        <svg width="13" height="16" viewBox="0 0 14 18" aria-hidden="true" class="t-menuBolt"><path d="M8.4 0.6 1.3 9.9c-.3.4 0 .8.4.8h4.2L4.7 17.4l7.9-9.6c.3-.4 0-.8-.4-.8H7.9L9.3 1.1C9.4.5 8.8.2 8.4.6Z" fill="currentColor"/></svg><span>Mon 19 Oct 17:42</span></div>
      <div class="t-window t-browser"><div class="t-chrome"><i></i><i></i><i></i><span class="t-address">developer.apple.com/documentation/dispatch</span></div>
        <div class="t-doc"><b class="t-docTitle">DispatchWorkItem</b><span class="t-docLead">The work you want to perform, encapsulated in a way that lets you attach a completion handle or execution dependencies.</span>
        ${[92, 78, 85, 60, 88, 70, 40].map((w) => `<i style="width:${w}%"></i>`).join("")}</div></div>
      <div class="t-window t-editor"><div class="t-chrome"><i></i><i></i><i></i><span class="t-address">SearchField.swift</span></div>
        <div class="t-code"><div class="t-gutter"></div><pre><span class="t-typed"></span><span class="t-editorCaret"></span></pre><span class="t-squiggle"></span><span class="t-errorPill">Cannot find 'Debouncer' in scope</span></div></div>
      <div class="t-window t-terminal"><div class="t-chrome"><i></i><i></i><i></i><span class="t-address">zsh</span></div><pre class="t-term"></pre></div>
    </div>`;
  const desk = {
    gutter: deskWrap.querySelector(".t-gutter"), typed: deskWrap.querySelector(".t-typed"), caret: deskWrap.querySelector(".t-editorCaret"),
    squiggle: deskWrap.querySelector(".t-squiggle"), pill: deskWrap.querySelector(".t-errorPill"), term: deskWrap.querySelector(".t-term"),
  };

  const anchor = () => add(h("div", "t-anchor"));
  const mainAnchor = anchor();
  const main = createBar();
  mainAnchor.append(main.el);
  const chipAnchor = anchor();
  const chip = createBar();
  chipAnchor.append(chip.el);

  const ring = add(h("div", "t-ring"));
  const ringItems = THEME_ORDER.map((name) => {
    const item = h("div", "t-ringItem");
    const bar = createBar();
    const mini = MINI[name];
    bar.update({
      theme: THEMES[name],
      messages: [
        { id: "q", role: "user", blocks: [{ kind: "p", text: mini.q }] },
        { id: "a", role: "assistant", author: mini.author, blocks: mini.a },
      ],
      model: mini.model,
      effort: mini.effort,
    });
    item.append(bar.el, h("span", "t-ringLabel", esc(THEMES[name].label)));
    ring.append(item);
    return item;
  });

  const end = add(h("div", "t-end"));
  const icon = h("div", "t-icon", `<span class="t-iconGlow"></span>${ICON_SVG}`);
  const iconGlow = icon.querySelector(".t-iconGlow");
  const url = h("div", "t-url", "juanluis.me/boltbar");
  end.append(icon, url);

  const scrim = add(h("div", "t-scrim"));
  const titles = TITLES.map((spec) => {
    const el = add(h("div", "t-title"));
    css(el, {
      left: `${spec.x}px`, top: `${spec.y}px`, fontSize: `${spec.size}px`, fontWeight: String(spec.weight ?? 620),
      color: spec.color ?? "", textAlign: spec.align ?? "center",
      transform: spec.align === "left" ? "translateY(-50%)" : "translate(-50%, -50%)",
    });
    const words = spec.text.split(" ");
    const spans = words.map((w, i) => {
      const span = h("span", "t-word");
      span.textContent = w + (i < words.length - 1 ? " " : "");
      if (spec.accent?.includes(i)) span.style.color = AMBER;
      el.append(span);
      return span;
    });
    return { spec, el, spans };
  });
  const keys = KEYS.map((spec) => {
    const w = spec.w, hh = spec.h ?? spec.w;
    const el = add(h("div", "t-key", `<span class="t-keyLegend">${esc(spec.label)}</span>`));
    css(el, { left: `${spec.x - w / 2}px`, top: `${spec.y - hh / 2}px`, width: `${w}px`, height: `${hh}px` });
    el.firstChild.style.fontSize = `${spec.size ?? w * (spec.glyph ? 0.42 : 0.2)}px`;
    return { spec, el, h: hh };
  });
  const flash = add(h("div", "t-flash"));
  add(h("div", "t-vignette"));
  const grain = add(h("div", "t-grain"));

  let lastTyped = -1, lastTerm = "";

  // ——— One frame ————————————————————————————————————————————————————
  return function frame(t) {
    css(glow, { transform: `translate(${Math.sin(t * 0.4) * 120}px, ${Math.cos(t * 0.3) * 60}px)` });

    // Desktop: in focus, blurred behind the bar, gone for the carousel, back (softly) after Esc.
    const deskBlur = t < 25 ? lerp(0, 18, easeOut(prog(t, 4.0, 4.7))) : lerp(18, 3, easeInOut(prog(t, 25.9, 26.8)));
    const deskDim = t < 25 ? lerp(1, 0.42, easeOut(prog(t, 4.0, 4.7))) : lerp(0.42, 0.68, easeInOut(prog(t, 25.9, 26.8)));
    const deskOpacity = t < 19 ? easeOut(prog(t, 0, 0.7)) * (t > 12.9 ? 0.55 : 1) : fade(t, 24.95, 25.2, 28.9, 29.4);
    const push = prog(t, 0, 4.7);
    css(deskWrap, {
      opacity: String(deskOpacity),
      filter: `blur(${deskBlur}px) brightness(${deskDim})`,
      transform: t < 19 ? `perspective(2600px) rotateX(${lerp(14, 6, easeOut(push))}deg) rotateZ(${lerp(-3.5, -1.2, push)}deg) scale(${lerp(1.08, 1.18, push)})` : "scale(1.04)",
      visibility: deskOpacity > 0.001 ? "visible" : "hidden",
    });
    const typed = Math.floor(EDITOR_CODE.length * prog(t, 0.15, 3.3));
    if (typed !== lastTyped) {
      lastTyped = typed;
      const text = EDITOR_CODE.slice(0, typed);
      desk.typed.innerHTML = highlightHTML(text, "t-c_");
      desk.gutter.innerHTML = Array.from({ length: Math.max(1, text.split("\n").length) }, (_, i) => `<span>${i + 1}</span>`).join("");
      const showError = typed > ERROR_AT + 12;
      desk.squiggle.style.display = desk.pill.style.display = showError ? "" : "none";
    }
    desk.pill.style.opacity = String(easeOut(prog(t, 2.25, 2.6)));
    desk.caret.style.opacity = Math.floor(t * 2.2) % 2 === 0 || t < 3.4 ? "1" : "0";
    const term = "$ swift build\n" + (t > 1.2 ? "Compiling SearchField.swift\n" : "") + (t > 2.4 ? "\u0001" : "") + (t > 2.6 ? "$ " : "");
    if (term !== lastTerm) {
      lastTerm = term;
      desk.term.innerHTML = esc(term).replace("\u0001", `<span class="t-termError">error: cannot find 'Debouncer' in scope\n</span>`);
    }

    // The main bar: summoned, asked, then hidden with Esc.
    const appear = prog(t, 5.05, 5.8);
    const move = easeInOut(prog(t, 7.0, 7.9));
    const exit = easeIn(prog(t, 25.75, 26.2));
    const inS6 = t >= 25;
    const barVisible = (t >= 5.0 && t < 13.0) || (inS6 && t < 26.3);
    mainAnchor.style.display = barVisible ? "" : "none";
    if (barVisible) {
      const a = inS6 ? { x: 960, y: 880, scale: 1.3 } : { x: lerp(960, 1300, move), y: lerp(700, 985, move), scale: lerp(1.75, 1.4, move) };
      const zoomOut = easeIn(prog(t, 12.55, 13.0));
      const typing = prog(t, 7.3, 8.45);
      css(mainAnchor, {
        left: `${a.x}px`, top: `${a.y}px`,
        opacity: String(inS6 ? 1 - exit : easeOut(appear) * (1 - zoomOut)),
        transform: `scale(${a.scale * (inS6 ? 1 - exit * 0.05 : lerp(0.86, 1, back(appear, 1.2)) * (1 + zoomOut * 0.35))}) translateY(${inS6 ? 0 : (1 - easeOut(appear)) * 30}px)`,
        filter: `blur(${inS6 ? exit * 8 : (1 - easeOut(appear)) * 12 + zoomOut * 6}px)`,
      });
      main.update({
        theme: TRAILER_THEME,
        messages: inS6 ? conversation(99) : conversation(t),
        draft: inS6 || t >= 8.6 ? "" : QUESTION.slice(0, Math.round(QUESTION.length * typing)),
        caret: (t > 7.25 && t < 8.6) || Math.floor(t * 2) % 2 === 0,
        model: "Claude Opus 5.5",
        effort: 1,
        threadHeight: 440,
        streaming: !inS6 && t > 8.65 && t < 12.1,
      });
    }

    // Models: a fresh bar, close up.
    const s4 = fade(t, 13.0, 13.35, 18.75, 19.05);
    chipAnchor.style.display = t >= 13 && t < 19.1 ? "" : "none";
    if (t >= 13 && t < 19.1) {
      css(chipAnchor, { left: "960px", top: "770px", opacity: String(s4), transform: `scale(${2.3 + prog(t, 13, 19) * 0.12})`, filter: `blur(${(1 - s4) * 8}px)` });
      let index = 0;
      for (const b of MODEL_BEATS) if (t >= b) index++;
      const p = easeOut(clamp((index > 0 ? t - MODEL_BEATS[index - 1] : 1) / 0.2));
      const prev = MODEL_ROLL[Math.max(0, index - 1)];
      const modelHTML =
        (index > 0 && p < 1 ? `<span style="transform:translateY(${(-p * 100).toFixed(1)}%);opacity:${(1 - p).toFixed(3)}">${esc(prev)}</span>` : "") +
        `<span style="transform:translateY(${((1 - p) * 100).toFixed(1)}%);opacity:${p.toFixed(3)}">${esc(MODEL_ROLL[index])}</span>`;
      const effort = EFFORT_BEATS.reduce((v, b) => v + easeOut(prog(t, b, b + 0.22)), 0);
      chip.update({ theme: TRAILER_THEME, caret: Math.floor(t * 2) % 2 === 0, modelHTML, effort, selectingModel: t > 13.35 && t < 18.4 });
    }

    // Themes: four bars on a turning ring.
    const s5 = fade(t, 19.0, 19.5, 24.55, 25.0);
    ring.style.display = t >= 19 && t < 25.1 ? "" : "none";
    if (t >= 19 && t < 25.1) {
      css(ring, { opacity: String(s5), transform: `translateY(${(1 - easeOut(prog(t, 19, 19.6))) * 80}px) scale(${lerp(0.92, 1, easeOut(prog(t, 19, 20)))})` });
      const turn = [20.5, 21.75, 23.0].reduce((acc, b) => acc + easeInOut(prog(t, b, b + 0.6)), 0);
      ringItems.forEach((item, i) => {
        // Graphite starts in front; each turn brings the next theme round.
        const a = (((((i - 2 - turn) * 90) % 360) + 540) % 360 - 180) * (Math.PI / 180);
        const front = (Math.cos(a) + 1) / 2;
        css(item, {
          transform: `translateX(${Math.sin(a) * 640}px) translateZ(${(Math.cos(a) - 1) * 420}px) rotateY(${((a * 180) / Math.PI) * 0.6}deg) scale(1.3)`,
          opacity: String(0.18 + front * 0.82),
          filter: `blur(${(1 - front) * 2.5}px) brightness(${0.55 + front * 0.45})`,
          zIndex: String(Math.round(front * 10)),
        });
      });
    }

    // End card.
    end.style.display = t >= 29 ? "" : "none";
    if (t >= 29) {
      const s7 = prog(t, 29.3, 30.3);
      end.style.opacity = String(1 - easeIn(prog(t, 35.3, 36)));
      css(icon, { opacity: String(easeOut(s7)), transform: `scale(${lerp(0.7, 1, back(s7, 1.3))})`, filter: `blur(${(1 - easeOut(s7)) * 14}px)` });
      iconGlow.style.opacity = String(0.55 + Math.sin(t * 2.4) * 0.12);
      const u = easeOut(prog(t, 31.5, 32.1));
      css(url, { opacity: String(u), transform: `translateY(${(1 - u) * 14}px)` });
    }

    scrim.style.opacity = String(Math.max(fade(t, 0.3, 0.8, 3.5, 4.1), fade(t, 26.0, 26.5, 28.9, 29.3)));

    const fadeOut = 1 - easeIn(prog(t, 35.3, 36));
    for (const { spec, el, spans } of titles) {
      const on = t >= spec.at - 0.05 && t <= spec.out + 0.5;
      el.style.display = on ? "" : "none";
      if (!on) continue;
      const stagger = spec.stagger ?? 0.07;
      const out = prog(t, spec.out, spec.out + 0.4);
      spans.forEach((span, i) => {
        const p = easeOut(prog(t, spec.at + i * stagger, spec.at + i * stagger + 0.55));
        css(span, {
          opacity: String(p * (1 - easeIn(out)) * (spec.out > 90 ? fadeOut : 1)),
          transform: `translateY(${(1 - p) * 0.42 - out * 0.18}em)`,
          filter: `blur(${(1 - p) * 12 + out * 10}px)`,
        });
      });
    }

    for (const { spec, el, h: hh } of keys) {
      const on = t >= spec.at && t <= spec.out + 0.5;
      el.style.display = on ? "" : "none";
      if (!on) continue;
      const drop = back(prog(t, spec.at, spec.at + 0.45));
      const leave = easeIn(prog(t, spec.out, spec.out + 0.4));
      const depth = hh * 0.09;
      let press = 0;
      for (const p of spec.presses ?? []) press = Math.max(press, t < p ? 0 : t < p + 0.07 ? (t - p) / 0.07 : 1 - prog(t, p + 0.07, p + 0.25));
      const endFade = spec.out > 90 ? fadeOut : 1;
      css(el, {
        opacity: String(Math.min(1, prog(t, spec.at, spec.at + 0.15)) * (1 - leave) * endFade),
        transform: `translateY(${(1 - drop) * -420 + press * depth * 0.85 + leave * 60}px) scale(${1 - leave * 0.15})`,
        filter: `blur(${leave * 8}px)`,
      });
      el.style.setProperty("--depth", `${depth * (1 - press * 0.85)}px`);
      el.style.setProperty("--glow", String(press));
    }

    flash.style.opacity = String(0.5 * Math.max(...[5.02, 13.0, 19.0, 25.0].map((b) => (t < b ? 0 : 1 - prog(t, b, b + 0.35)))));
    const g = Math.floor(t * 24);
    grain.style.backgroundPosition = `${(g * 73) % 180}px ${(g * 37) % 180}px`;
  };
}
