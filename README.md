# Boltbar — native macOS

A compact AI chat bar built in Swift, SwiftUI and AppKit. Starting with v0.2.0, the native implementation replaces the Tauri/React runtime. macOS 13 or newer.

![Compact native bar](docs/qa/screenshots/native-22-gauge-chip.jpg)

- **⌥ Space** opens a new conversation; **Esc** hides it. While a reply is streaming, messages are queued, or a reply finished while the bar was hidden, **⌥ Space** instead brings that conversation back where you left it, and the reply and queue carry on. **⌘N** always starts fresh, stopping any reply in progress (kept as Interrupted, with its queue saved paused), and **⌘,** opens a separate Settings window.
- A one-line editor grows upward to eight lines, then scrolls. Drag any border to resize one dimension, or a corner to resize both. Drag the blank top strip or toolbar background to move the bar.
- Paste, drop or choose images, PDFs and text documents (PDFs need API mode). Sent attachments stay visible in the conversation and remain available in follow-up requests.
- **Agent mode** (⌘J, configurable in Settings, or the terminal chip beside the model chip) hands the request to the Claude Code or Codex CLI, working in a project folder. The chip shows the project and a permission light: Look (gray) only reads, Ask (green) asks before every command or change, Edit (amber) changes files in the project without asking and asks before other commands, Full (red) never asks. Full takes a second press and returns to Ask after 24 hours unless that is turned off in Settings; each project remembers its level. Click the project name or light for the project list, click the terminal icon to turn agent mode off, or reach the chip with Tab and use ↑/↓ for the project, ←/→ for the permission and Return to toggle. Drop a folder on the bar to add it.
- Agent actions show as one line each in the reply, where they happened. Permission requests appear above the composer: **⌘Return** allows, **⌥⌘Return** allows the same request for the rest of the chat, **Esc** denies, and Stop denies anything still waiting. The agent follows the project's `CLAUDE.md` or `AGENTS.md` (Claude Code falls back to `AGENTS.md`, Codex to `CLAUDE.md`). Each agent chat is a real Claude Code session or Codex thread: `/terminal`, or Continue in terminal in the agent chip, copies the command that resumes it in a terminal. Web search is off in agent mode. Changing the permission applies at once, even mid-reply: Claude Code switches mode in place and Boltbar answers requests by the new light (Codex in Look or Full keeps its sandbox until the reply ends). Steps appear between the words written before and after them (chats saved before v0.7.0 kept no positions and show theirs first), and links to files open in their default app (⌘-click reveals them in Finder), relative ones resolved against the project.
- `/help` (or **⌘?**) shows every key and command inside the bar; `/new`, `/agent` and `/terminal` work the same way. With an empty composer, **Tab** outlines the model chip, Tab again the agent chip, and **⇧Tab** goes back.
- A single model chip with an effort gauge, streamed replies, selectable Markdown, aligned tables, and highlighted fenced code. Everything wraps at the bar's width; a wide table narrows its columns to fit. Copy a whole response from its hover/focus icon, or a code block from its own copy icon.
- Keep writing while a reply streams: **Return** adds the message to a queue shown above the composer, and the queue goes out as one turn when the reply finishes. **Return** in an empty composer, or **Send now**, interrupts the reply and sends the queue at once; a second Return within 0.6 s of queueing, or a held key, never interrupts. Click a queued message to edit it (with its attachments) in the composer, or × to remove it. An interrupted reply keeps its partial text, is marked Interrupted and stays in the context. Stop, a provider error, switching chats (including ⌘N) or quitting pause the queue and save it with the conversation; it resumes only with Return, Send now or Retry.
- Previous chats open inside the bar from the clock button or **→** in an empty composer. Start typing to filter titles and all message text locally; accents and case do not matter. Use ↑/↓ to select and **→** or Return to open. In a reopened chat, **←** with an empty composer returns to the same filter and selection. Dates show today’s time, Yesterday, or the month/day. Each chat keeps what you typed and didn’t send, back in the composer when you reopen it. Settings stays in the menu and at **⌘,**.
- Settings → Appearance offers Paper and Mist light themes, Graphite and Midnight dark themes, System/Light/Dark mode, a custom accent color, and the text size of every chat, which **⌘+** and **⌘−** also change in the bar and **⌘0** resets; it is remembered across restarts. Interface controls use monospaced text; rendered chat content retains its reading typography.
- With an empty composer, ↑/↓ cycles models and outlines the model chip. While outlined, ←/→ changes effort. Typing, clicking the composer, Escape, or Return ends selection. The effort menu also offers direct Low/Medium/High buttons.
- Delete a history item with its hover trash button or press Delete twice; Escape or navigation cancels keyboard confirmation.
- The globe (hover **+** to unroll it and the previous-chats button; it stays pinned while on) allows web search with OpenAI API and Claude API/CLI; the model decides when a search is needed and returns numbered, clickable source citations, with a Sources line listing each domain under the answer. Boltbar remembers that choice across new chats and app restarts. Codex CLI still requires switching to API mode for search. The saved choice is retained when switching providers.
- OpenAI Responses and Anthropic Messages through URLSession; optional existing Codex or Claude Code CLI sessions.
- API keys use macOS Keychain service `com.boltbar.keys`. Chats and attachments are saved locally in `~/Library/Application Support/Boltbar/Conversations`, with a private metadata index and a separate file per conversation. Keys are never included.

## Install

With Homebrew:

```sh
brew install --cask juanluisrto/boltbar/boltbar
```

Or download the universal ZIP or DMG from [v0.7.3](https://github.com/juanluisrto/boltbar/releases/tag/v0.7.3), or run:

```sh
curl -fsSL https://raw.githubusercontent.com/juanluisrto/boltbar/main/install.sh | sh
```

The installer verifies the release's SHA-256 checksum and preserves an existing `Boltbar.app` as a timestamped backup. Quit older Boltbar builds before launching the new app.

**v0.7.3 uses Developer ID signing and Apple notarization.** The installer preserves quarantine and does not disable Gatekeeper. Older releases were ad hoc signed.

The cask lives in the [juanluisrto/homebrew-boltbar](https://github.com/juanluisrto/homebrew-boltbar) tap and pins the same universal ZIP and checksum. Boltbar updates itself, so `brew upgrade` leaves it alone unless you pass `--greedy`.

## Build and test

Install Xcode or its command-line tools, then:

```sh
swift test
sh scripts/build-native.sh
open build/Boltbar.app
```

No Node, Rust or WebKit runtime is needed. Swift Package Manager fetches Sparkle for secure updates. Quit older Boltbar builds before launching this one so they do not compete for the global shortcut.

A universal app containing Apple Silicon and Intel code:

```sh
BOLTBAR_UNIVERSAL=1 sh scripts/build-native.sh
```

The default build uses an ad hoc signature. For local development, supply an existing signing identity with `BOLTBAR_SIGN_IDENTITY`. Public distribution needs a **Developer ID Application** certificate and notarization; an Apple Development signature is not a substitute.

From this checkout, `sh install.sh` builds and installs the native app. It preserves an existing installation as a timestamped backup and preserves quarantine metadata.

With the [signing and notarization configuration](docs/UPDATES.md), `sh scripts/package-release.sh` builds the universal app and creates a notarized ZIP/DMG, signed update feed and `SHA256SUMS` under `build/releases/v0.7.3`. It does not publish anything. The previous v0.1.3 release is the legacy Tauri app.

## Credentials and providers

Open Settings to choose the provider, default model, effort, transport and shortcut. Save API keys in Keychain. If an older executable created the saved key, use **Allow access to saved key** and approve the macOS prompt. Failed unattended access is reported without silently waiting behind the floating panel.

An explicit `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in the launching environment takes precedence; normal Finder launches use Keychain. The app never writes those environment credentials to a file.

For subscription login, sign in once in Terminal with `codex login` or `claude auth login`. Settings → Connections shows whether each CLI is installed and signed in, and whether an API key is saved; **Automatic** uses the API key when there is one, otherwise the CLI. Boltbar lets the official CLI manage its tokens.

| Transport | Streaming | Attachments | Model discovery |
|---|---|---|---|
| OpenAI API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, filtered chat catalog |
| Anthropic API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, filtered |
| Claude Code CLI | Partial message events | Images, UTF-8 text | Explicit fallback catalog |
| Codex CLI | App Server text deltas | Images, UTF-8 text | Last synced API catalog or bundled defaults |

CLI requests send images and text documents through stdin. PDFs require API mode and produce an explicit error in CLI mode. In chat mode, Codex uses ephemeral App Server threads and Claude runs with session persistence disabled; both skip custom extensions (Claude in safe mode). In agent mode, each chat keeps one saved Claude Code session or Codex thread, so later turns continue it and `/terminal` can resume it in a terminal; Claude still runs in safe mode, with Boltbar passing on the project's `CLAUDE.md` or `AGENTS.md`.

The Models section in Settings keeps a persistent shortlist shared by the model menu and keyboard cycling. Use Add more below the list to search the catalog and add a model; drag selected rows to reorder them or use their context menu. Defaults can keep Latest used or select a fixed starting model. At least one model must remain. Compatible general chat models are listed; specialized audio, image, embedding, coding and research models are excluded. Models without configurable reasoning omit the API reasoning parameter.

Catalogs refresh at launch, every six hours, and on demand. Refresh never adds, replaces, removes or reorders selections. A selected model missing from a successful sync is marked unavailable; failed/offline syncs preserve the cached catalog. CLI-only catalogs are suggestions or cached API results, not verified subscription access.

History begins with this native build; earlier in-memory conversations cannot be recovered. Stored chats include attachments and can be resumed after a restart. Search reads message text on a background queue and caches it in memory; it does not search inside attachment files or call a model. A missing or damaged chat file does not block other results; its indexed title remains searchable and opening it reports the error. The history is local, not cloud-synced.

Markdown supports paragraphs, inline emphasis/links/code, headings, lists, quotes, fenced code and pipe tables. Links are underlined and numeric citations appear as tinted chips, spaced from neighbouring words, including in chats saved by earlier versions. Tables respect column alignment, wrap cells and scroll horizontally when too wide. Syntax coloring is intentionally a small native highlighter.

Web search adds the hosted `web_search` tool to the same OpenAI Responses request; it does not start an agent server or MCP process. With the globe on, [automatic tool selection](https://developers.openai.com/api/docs/guides/tools#usage-in-the-api) lets the model answer directly or search when needed. The searching indicator only appears after an actual provider search event. A search adds provider/tool latency when invoked. With the globe off, the request contains no search tool. An OpenAI API key is required even if a Codex subscription login is available.

## Architecture

- `Sources/BoltbarNative/Application.swift`: NSPanel, Carbon shortcut, menu-bar item, window lifecycle.
- `License.swift`: offline supporter license keys and when to remind an unlicensed copy.
- `ChatModel.swift` and `Domain.swift`: conversation state, persistent attachment ownership, preferences, Keychain.
- `Conversations.swift`, `HistoryView.swift`: private local history, native keyboard list and friendly dates.
- `FeaturedModels.swift`: approved OpenAI families and numeric version selection.
- `Editor.swift`, `Views.swift`, `SettingsView.swift`: AppKit text editor and native SwiftUI views.
- `Providers.swift`, `CLIChat.swift`, `WebSearch.swift`: URLSession SSE, hosted web search and citation links, provider catalogs, CLI stdin/stdout pipes and cancellation.
- `MarkdownTable.swift`: native Markdown table parsing, alignment and horizontal overflow.
- `Tests/BoltbarNativeTests`: state, attachment payloads, cancellation, SSE and model-filter regression tests.
- `native-spike/`: initial minimal comparison prototype, retained for the QA measurements.

The `mac-qa` branch preserves the Tauri investigation and fixes. See [the QA report](docs/qa/REPORT.md) for evidence, measurements and remaining limits. CI builds test artifacts only; it does not publish releases.

## Reproduce a transport measurement

The opt-in probe uses the same provider implementation as the UI and emits only timing/count metadata for its fixed numeric prompt:

```sh
build/Boltbar.app/Contents/MacOS/Boltbar --qa-probe openai gpt-6.1-sol
BOLTBAR_QA_TRANSPORT=cli build/Boltbar.app/Contents/MacOS/Boltbar --qa-probe anthropic claude-sonnet-5-5
```

Optional file arguments are for synthetic QA fixtures only. With fixtures, the probe also prints the synthetic response so vision/document handling can be checked. Never pass private documents to a logged probe.

`BOLTBAR_QA_WEB=1` changes the probe to a fixed search for Swift’s official download page and prints the synthetic response with its citations.

## License

[MIT](LICENSE)

## Support

Boltbar is free, open source and fully functional. If it's useful to you, a one-off supporter license keeps it going. Unlicensed copies show a quiet reminder above the toolbar at most once a week, and only after a week of use and 30 replies; it never interrupts a reply, a permission request or the shortcut. Settings → License shows who a copy is licensed to, takes a pasted key and links to the store; **Buy a license…** in the menu-bar menu does the same while unlicensed. Licenses are sold at [juanluis.me/boltbar/buy](https://juanluis.me/boltbar/buy) through Stripe, which handles VAT; the key appears right after payment. A lost key can be shown again at [juanluis.me/boltbar/license](https://juanluis.me/boltbar/license) from the email and invoice number on Stripe's receipt.

License keys are checked offline against the Ed25519 public key in `Resources/license-public-key.txt` and kept in the Keychain (service `com.boltbar.keys`, account `license`). Boltbar never contacts a server about them. Keys are signed with `scripts/make-license.swift`; see [signed release setup](docs/UPDATES.md#supporter-licenses).

## Automatic updates

Sparkle provides automatic update checks and an Install and Relaunch flow. Settings includes update controls, and both app menus offer Check for Updates. See [signed release setup](docs/UPDATES.md) for Developer ID signing, notarization, and publishing the update feed. Existing releases require one manual upgrade to gain this feature.
