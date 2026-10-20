// Agent mode in the simulator: example projects, the slash commands, the help
// pane, and two scripted runs. Nothing runs on your machine; the steps,
// approvals and replies follow what Claude Code and Codex do in the app.

export const PROJECTS = [
  { id: "searchkit", name: "searchkit", path: "~/Developer/searchkit", permission: "ask" },
  { id: "documents", name: "Documents", path: "~/Documents", permission: "look" },
  { id: "site", name: "site", path: "~/Developer/site", permission: "edit" },
];

export const COMMANDS = [
  { command: "/help", summary: "Everything about Boltbar" },
  { command: "/new", summary: "Start a new chat" },
  { command: "/agent", summary: "Turn agent mode on or off" },
  { command: "/terminal", summary: "Copy the command that continues this agent chat in a terminal" },
];

export const HELP = [
  { kind: "h", text: "Everyday keys" },
  {
    kind: "keys",
    rows: [
      ["⌥ Space", "Open Boltbar over any app. If a reply is still coming, it returns where you left it"],
      ["↵", "Send. While a reply streams, queue your next message"],
      ["⇧ ↵", "New line"],
      ["esc", "Hide the bar"],
      ["⌘ N", "New chat"],
      ["⌘ ?", "This help, also /help"],
    ],
  },
  { kind: "h", text: "Models and effort" },
  { kind: "p", text: "With an empty message, ↑ ↓ switch model and outline its chip; ← → then set the thinking effort. Click the chip for the full list." },
  { kind: "h", text: "Agent mode" },
  { kind: "p", text: "⌘J or the terminal button lets **Claude Code** or **Codex** act in a project folder. The light says how far it may go:" },
  {
    kind: "keys",
    rows: [
      ["Look · gray", "Reads files and runs read-only commands; never changes anything"],
      ["Ask · green", "Asks before every command or change"],
      ["Edit · amber", "Changes files in the project without asking; asks before other commands"],
      ["Full · red", "Never asks. It takes a second → and lasts 24 hours"],
    ],
  },
  { kind: "p", text: "Tab with an empty message outlines the model chip, Tab again the agent chip: ↑ ↓ change project, ← → permission, ↵ turns agent mode on or off. Click the project name for the list, or the terminal icon to turn it off." },
  { kind: "p", text: "When it asks, **⌘↵** allows, **⌥⌘↵** allows the same thing for the rest of the chat, and **esc** denies. It follows the project's `CLAUDE.md` or `AGENTS.md`, and each chat is a real CLI session that `/terminal` lets you continue in a terminal." },
  { kind: "h", text: "Commands" },
  { kind: "keys", rows: COMMANDS.map((c) => [c.command, c.summary]) },
  { kind: "h", text: "Previous chats" },
  { kind: "p", text: "→ with an empty message opens them. Type to search every message; ↑ ↓ select, → or ↵ open, ← goes back, ⌫ twice deletes." },
];

const p = (text) => [{ kind: "p", text }];

const FIX = {
  fix: true,
  steps: [
    { id: "read", kind: "read", title: "Read Tests/SearchFieldTests.swift" },
    { id: "search", kind: "search", title: 'Search "Debouncer" in Sources' },
    { id: "edit", kind: "edit", title: "Edit Sources/SearchField.swift", asks: ["ask"], approval: { action: "Edit", subject: "Sources/SearchField.swift" } },
    { id: "test", kind: "command", title: "$ swift test", detail: "42 passed", asks: ["ask", "edit"], approval: { action: "Run", subject: "swift test" } },
  ],
  replies: {
    done: p("The debounce fired on every keystroke: each call started a new timer instead of replacing the last one. **SearchField** now cancels the pending call first, and all 42 tests pass."),
    look: p("In **Look** I can only read. The bug: each `debounce.call` starts a new timer instead of replacing the last one, so every keystroke fires. Switch to **Ask** or **Edit** with ← → on the agent chip and I'll fix it."),
    deniedEdit: p("Okay, I left **SearchField.swift** as it was. The fix is to cancel the pending work item before scheduling a new one."),
    deniedCommand: p("The fix is in, but I didn't run the tests. Run `swift test` when you're ready."),
  },
};

const LOOK_AROUND = {
  fix: false,
  steps: [
    { id: "readme", kind: "read", title: "Read README.md" },
    { id: "log", kind: "command", title: "$ git log --oneline -5" },
  ],
  replies: {
    done: p("**SearchKit** is a small Swift package for instant search: a **SearchField** that debounces typing, and an index that ranks results as you type. The last commits added fuzzy matching and fixed a crash on empty queries."),
  },
};

/** A question only looks around; anything else is a job, here fixing the debounce. */
export function agentScript(text) {
  const t = text.trim().toLowerCase();
  const question = t.endsWith("?") || /^(what|how|why|where|which|who|explain|summari[sz]e|describe|tell me)\b/.test(t);
  return question ? LOOK_AROUND : FIX;
}

/** A session id in the shape both CLIs use. */
export function sessionId() {
  const hex = (n) => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  return `${hex(8)}-${hex(4)}-4${hex(3)}-${"89ab"[Math.floor(Math.random() * 4)]}${hex(3)}-${hex(12)}`;
}
