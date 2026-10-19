// The simulator's canned answers. Asking about Boltbar teaches Boltbar.

const REPLIES = [
  {
    match: /debounce|swift|code|function|regex|script/i,
    blocks: () => [
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
      { kind: "p", text: "Copy it from the icon in the corner of the block." },
    ],
  },
  {
    match: /shortcut|keys?\b|keyboard|hotkey|how do(es)? (it|i) (use|work)/i,
    blocks: () => [
      { kind: "p", text: "**⌥ Space** opens Boltbar over any app, and **Esc** hides it again." },
      { kind: "p", text: "With an empty message, **↑ ↓** switch models and **← →** set the thinking effort. **→** opens your previous chats." },
      { kind: "p", text: "**Return** sends. While a reply streams, Return queues your next message instead." },
    ],
  },
  {
    match: /queue|while it|interrupt|wait/i,
    blocks: () => [
      { kind: "p", text: "Keep typing while I answer: **Return** adds your message to a queue above the field, and the queue goes out as soon as this reply finishes." },
      { kind: "p", text: "**Return** on an empty field, or **Send now**, interrupts me and sends it right away. The cut reply stays, marked Interrupted." },
    ],
  },
  {
    match: /privacy|private|data|keychain|secure|safe|track|telemetry|api key/i,
    blocks: () => [
      { kind: "p", text: "API keys stay in your macOS **Keychain**. Chats and attachments are saved on your Mac, in `~/Library/Application Support/Boltbar`." },
      { kind: "p", text: "Boltbar only talks to the provider you choose, plus GitHub to check for signed updates. No accounts, no analytics." },
    ],
  },
  {
    match: /install|download|brew|get it|price|cost|free/i,
    blocks: () => [
      { kind: "p", text: "Boltbar is free and open source (MIT). Grab the signed DMG from GitHub, or run:" },
      { kind: "code", lang: "sh", code: "curl -fsSL https://raw.githubusercontent.com/juanluisrto/boltbar/main/install.sh | sh" },
      { kind: "p", text: "It needs macOS 13 or newer and runs natively on Apple Silicon and Intel." },
    ],
  },
  {
    match: /model|gpt|claude|openai|anthropic|codex|subscription|login/i,
    blocks: () => [
      { kind: "p", text: "Boltbar works with OpenAI and Anthropic models, through your own API keys or the **Codex** and **Claude Code** logins you already have." },
      { kind: "p", text: "Press **↑ ↓** on an empty message to switch, **← →** for effort, or click the model chip." },
    ],
  },
  {
    match: /theme|color|dark|light|look/i,
    blocks: () => [
      { kind: "p", text: "Four themes ship with Boltbar: **Paper** and **Mist** for light mode, **Graphite** and **Midnight** for dark. Pick any accent color in Settings." },
      { kind: "p", text: "Try the swatches under the bar." },
    ],
  },
  {
    match: /attach|image|pdf|file|screenshot|paste/i,
    blocks: () => [
      { kind: "p", text: "Paste, drop or pick images, PDFs and text files. They stay attached to the message, so follow-up questions can still see them." },
    ],
  },
  {
    match: /search|web|internet|source|cite/i,
    blocks: () => [
      { kind: "p", text: "Turn on the globe and the model can search the web when it needs to. Answers come back with numbered citations and a line listing their sources." },
    ],
  },
];

export function replyTo(text, model) {
  const found = REPLIES.find((r) => r.match.test(text));
  if (found) return found.blocks(model);
  return [
    { kind: "p", text: "This bar is a simulation running in your browser, so I can't really answer that one." },
    { kind: "p", text: `In Boltbar your message goes straight to **${model}**. Here, try asking for some code, the shortcuts, or how privacy works.` },
  ];
}
