# Boltbar — native macOS

A compact AI chat bar built in Swift, SwiftUI and AppKit. Starting with v0.2.0, the native implementation replaces the Tauri/React runtime. macOS 13 or newer.

![Compact native bar](docs/qa/screenshots/native-22-gauge-chip.jpg)

- **⌥ Space** opens a new conversation; **Esc** hides it. While a reply is streaming, messages are queued, or a reply finished while the bar was hidden, **⌥ Space** instead brings that conversation back where you left it, and the reply and queue carry on. **⌘N** always starts fresh, stopping any reply in progress (kept as Interrupted, with its queue saved paused), and **⌘,** opens a separate Settings window.
- A one-line editor grows upward to eight lines, then scrolls. Drag any border to resize one dimension, or a corner to resize both. Drag the blank top strip or toolbar background to move the bar.
- Paste, drop or choose images, PDFs and text documents. Sent attachments stay visible in the conversation and remain available in follow-up requests.
- A single model chip with an effort gauge, streamed replies, selectable Markdown, aligned tables, and highlighted fenced code. Copy a whole response from its hover/focus icon, or a code block from its own copy icon.
- Keep writing while a reply streams: **Return** adds the message to a queue shown above the composer, and the queue goes out as one turn when the reply finishes. **Return** in an empty composer, or **Send now**, interrupts the reply and sends the queue at once; a second Return within 0.6 s of queueing, or a held key, never interrupts. Click a queued message to edit it (with its attachments) in the composer, or × to remove it. An interrupted reply keeps its partial text, is marked Interrupted and stays in the context. Stop, a provider error, switching chats (including ⌘N) or quitting pause the queue and save it with the conversation; it resumes only with Return, Send now or Retry.
- Previous chats open inside the bar from the clock button or **→** in an empty composer. Start typing to filter titles and all message text locally; accents and case do not matter. Use ↑/↓ to select and **→** or Return to open. In a reopened chat, **←** with an empty composer returns to the same filter and selection. Dates show today’s time, Yesterday, or the month/day. Settings stays in the menu and at **⌘,**.
- Settings → Appearance offers Paper and Mist light themes, Graphite and Midnight dark themes, System/Light/Dark mode, and a custom accent color. Interface controls use monospaced text; rendered chat content retains its reading typography.
- With an empty composer, ↑/↓ cycles models and outlines the model chip. While outlined, ←/→ changes effort. Typing, clicking the composer, Escape, or Return ends selection. The effort menu also offers direct Low/Medium/High buttons.
- Delete a history item with its hover trash button or press Delete twice; Escape or navigation cancels keyboard confirmation.
- The globe allows web search with OpenAI API and Claude API/CLI; the model decides when a search is needed and returns numbered, clickable source citations, with a Sources line listing each domain under the answer. Boltbar remembers that choice across new chats and app restarts. Codex CLI still requires switching to API mode for search. The saved choice is retained when switching providers.
- OpenAI Responses and Anthropic Messages through URLSession; optional existing Codex or Claude Code CLI sessions.
- API keys use macOS Keychain service `com.boltbar.keys`. Chats and attachments are saved locally in `~/Library/Application Support/Boltbar/Conversations`, with a private metadata index and a separate file per conversation. Keys are never included.

## Install

Download the universal ZIP or DMG from [v0.5.2](https://github.com/juanluisrto/boltbar/releases/tag/v0.5.2), or run:

```sh
curl -fsSL https://raw.githubusercontent.com/juanluisrto/boltbar/main/install.sh | sh
```

The installer verifies the release's SHA-256 checksum and preserves an existing `Boltbar.app` as a timestamped backup. Quit older Boltbar builds before launching the new app.

**v0.5.2 uses Developer ID signing and Apple notarization.** The installer preserves quarantine and does not disable Gatekeeper. Older releases were ad hoc signed.

The [Homebrew cask](homebrew/Casks/boltbar.rb) pins the same universal ZIP and checksum; it is supplied in this repository, not in the official Homebrew cask registry.

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

With the [signing and notarization configuration](docs/UPDATES.md), `sh scripts/package-release.sh` builds the universal app and creates a notarized ZIP/DMG, signed update feed and `SHA256SUMS` under `build/releases/v0.5.2`. It does not publish anything. The previous v0.1.3 release is the legacy Tauri app.

## Credentials and providers

Open Settings to choose the provider, default model, effort, transport and shortcut. Save API keys in Keychain. If an older executable created the saved key, use **Allow access to saved key** and approve the macOS prompt. Failed unattended access is reported without silently waiting behind the floating panel.

An explicit `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in the launching environment takes precedence; normal Finder launches use Keychain. The app never writes those environment credentials to a file.

For subscription login, run the command shown in Settings (`codex login` or `claude auth login`), choose **CLI login**, and refresh. Boltbar lets the official CLI manage its tokens.

| Transport | Streaming | Attachments | Model discovery |
|---|---|---|---|
| OpenAI API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, filtered chat catalog |
| Anthropic API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, filtered |
| Claude Code CLI | Partial message events | Images, UTF-8 text | Explicit fallback catalog |
| Codex CLI | App Server text deltas | Images, UTF-8 text | Last synced API catalog or bundled defaults |

CLI requests send images and text documents through stdin. PDFs require API mode and produce an explicit error in CLI mode. Codex uses ephemeral App Server threads; Claude runs with session persistence disabled and skips custom extensions in safe mode.

The Models section in Settings keeps a persistent shortlist shared by the model menu and keyboard cycling. Use Add more below the list to search the catalog and add a model; drag selected rows to reorder them or use their context menu. Defaults can keep Latest used or select a fixed starting model. At least one model must remain. Compatible general chat models are listed; specialized audio, image, embedding, coding and research models are excluded. Models without configurable reasoning omit the API reasoning parameter.

Catalogs refresh at launch, every six hours, and on demand. Refresh never adds, replaces, removes or reorders selections. A selected model missing from a successful sync is marked unavailable; failed/offline syncs preserve the cached catalog. CLI-only catalogs are suggestions or cached API results, not verified subscription access.

History begins with this native build; earlier in-memory conversations cannot be recovered. Stored chats include attachments and can be resumed after a restart. Search reads message text on a background queue and caches it in memory; it does not search inside attachment files or call a model. A missing or damaged chat file does not block other results; its indexed title remains searchable and opening it reports the error. The history is local, not cloud-synced.

Markdown supports paragraphs, inline emphasis/links/code, headings, lists, quotes, fenced code and pipe tables. Links are underlined and numeric citations appear as tinted chips, spaced from neighbouring words, including in chats saved by earlier versions. Tables respect column alignment, wrap cells and scroll horizontally when too wide. Syntax coloring is intentionally a small native highlighter.

Web search adds the hosted `web_search` tool to the same OpenAI Responses request; it does not start an agent server or MCP process. With the globe on, [automatic tool selection](https://developers.openai.com/api/docs/guides/tools#usage-in-the-api) lets the model answer directly or search when needed. The searching indicator only appears after an actual provider search event. A search adds provider/tool latency when invoked. With the globe off, the request contains no search tool. An OpenAI API key is required even if a Codex subscription login is available.

## Architecture

- `Sources/BoltbarNative/Application.swift`: NSPanel, Carbon shortcut, menu-bar item, window lifecycle.
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

## Automatic updates

Sparkle provides automatic update checks and an Install and Relaunch flow. Settings includes update controls, and both app menus offer Check for Updates. See [signed release setup](docs/UPDATES.md) for Developer ID signing, notarization, and publishing the update feed. Existing releases require one manual upgrade to gain this feature.
