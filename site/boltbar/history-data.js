// Example chats for the history browser. Search covers titles and every
// message, as in the app, so some chats match words that only appear inside.
const p = (text) => ({ kind: "p", text });
const code = (lang, text) => ({ kind: "code", lang, code: text });
const chat = (id, daysAgo, time, model, author, title, reply) => ({
  id, daysAgo, time, model, author, title,
  messages: [
    { id: `${id}-q`, role: "user", blocks: [p(title)] },
    { id: `${id}-a`, role: "assistant", author, blocks: reply },
  ],
});

export const HISTORY = [
  chat("debounce", 0, "17:42", "Claude Opus 5.5", "Anthropic", "Write a debounce in Swift", [
    p("Here's a small **Debouncer**: each call cancels the pending one, so only the last runs."),
    code("swift", "final class Debouncer {\n    private var work: DispatchWorkItem?\n    let delay: TimeInterval\n    init(delay: TimeInterval) { self.delay = delay }\n\n    func call(_ action: @escaping () -> Void) {\n        work?.cancel()\n        let item = DispatchWorkItem(block: action)\n        work = item\n        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)\n    }\n}"),
  ]),
  chat("deck", 0, "16:05", "GPT-6.1 Sol", "OpenAI", "Summarize the Q3 board deck in five bullets", [
    p("**Revenue** up 18% year over year, led by the new enterprise plan."),
    p("**Churn** down to 2.1% after the onboarding redesign. **Hiring** paused outside engineering. **Runway** 31 months. **Ask**: approve the Lisbon office."),
  ]),
  chat("regex", 0, "11:20", "GPT-6 Astra", "OpenAI", "Regex for an ISO date", [
    code("regex", "^\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])$"),
    p("It checks the shape and month and day ranges, not leap years."),
  ]),
  chat("kyoto", 1, "21:14", "Claude Sonnet 5.5", "Anthropic", "Plan a day in Kyoto", [
    p("**Dawn** Fushimi Inari before the crowds. **Noon** Nishiki market for lunch. **Afternoon** walk the Philosopher's Path. **Dusk** Gion and Pontocho."),
  ]),
  chat("japanese", 1, "20:58", "Claude Sonnet 5.5", "Anthropic", "Translate “see you tomorrow” to Japanese", [
    p("**また明日** (mata ashita): casual, for friends. Before the Kyoto trip, **また明日お会いしましょう** is the polite version for your hosts."),
  ]),
  chat("swiftui", 4, "10:32", "Claude Opus 5.5", "Anthropic", "Why does my SwiftUI list re-render on every keystroke?", [
    p("The search text lives in the same `@Observable` model the rows read, so every keystroke invalidates them. Move the query into the view's own `@State`, or give each row an `Equatable` subview."),
  ]),
  chat("decline", 6, "09:15", "GPT-6.1 Sol", "OpenAI", "Draft a reply declining Thursday's meeting", [
    p("Thanks for the invite. I can't make Thursday, but I'd be glad to read the notes and follow up on anything that needs me. Would a short call next week help?"),
  ]),
  chat("zsh", 8, "18:47", "Claude Haiku 5.5", "Anthropic", "zsh: command not found: swift", [
    p("Xcode's toolchain isn't on your PATH. Run `xcode-select --install`, or point to an installed Xcode with `sudo xcode-select -s /Applications/Xcode.app`."),
  ]),
  chat("sqlite", 11, "15:03", "GPT-6 Astra", "OpenAI", "Postgres or SQLite for a desktop app?", [
    p("**SQLite**: one file, no server, ships inside the app. Choose Postgres only if several machines must write to the same data."),
  ]),
  chat("gift", 17, "12:26", "Claude Fable 5.1", "Anthropic", "Gift ideas for a six-year-old who loves space", [
    p("A glow-in-the-dark star map for the ceiling, a kids' telescope with a moon filter, or a model rocket kit to build together."),
  ]),
];

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"];
/** The app's labels: today's time, Yesterday, or the month and day. */
export function dateLabel(item, now = new Date()) {
  if (item.daysAgo === 0) return item.time;
  if (item.daysAgo === 1) return "Yesterday";
  const d = new Date(now);
  d.setDate(d.getDate() - item.daysAgo);
  return `${MONTHS[d.getMonth()]} ${d.getDate()}${d.getFullYear() === now.getFullYear() ? "" : `, ${d.getFullYear()}`}`;
}

/** Case- and accent-insensitive match of every word, over titles and messages. */
const fold = (s) => s.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
const searchable = new Map();
export function matches(item, query) {
  const terms = fold(query).split(/\s+/).filter(Boolean);
  if (!terms.length) return true;
  if (!searchable.has(item.id)) {
    const text = [item.title, ...item.messages.flatMap((m) => m.blocks.map((b) => (b.kind === "code" ? b.code : b.text)))].join("\n");
    searchable.set(item.id, fold(text));
  }
  return terms.every((t) => searchable.get(item.id).includes(t));
}
