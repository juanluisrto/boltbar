# Boltbar — native macOS

A compact AI chat bar built entirely in Swift, SwiftUI and AppKit. The native implementation replaces the Tauri/React runtime on this branch. macOS 13 or newer.

![Compact native bar](docs/qa/screenshots/native-22-gauge-chip.jpg)

- **⌥ Space** opens a new conversation; **Esc** hides it. **⌘N** starts fresh and **⌘,** opens a separate Settings window.
- A one-line editor grows upward to eight lines, then scrolls. Drag any border to resize one dimension, or a corner to resize both. Drag the blank top strip or toolbar background to move the bar.
- Paste, drop or choose images, PDFs and text documents. Sent attachments stay visible in the conversation and remain available in follow-up requests.
- A single model chip with an effort gauge, streamed replies, selectable Markdown, and highlighted fenced code.
- Previous chats open inside the bar from the clock button beside the model chip: click a title or use ↑/↓ and Return. Escape, ← or the back arrow returns to the current chat. Dates show today’s time, Yesterday, or the month/day. Settings stays in the menu and at **⌘,**.
- OpenAI Responses and Anthropic Messages through URLSession; optional existing Codex, Claude Code or Cursor CLI sessions.
- API keys use macOS Keychain service `com.boltbar.keys`. Chats and attachments are saved locally in `~/Library/Application Support/Boltbar/Conversations`, with a private metadata index and a separate file per conversation. Keys are never included.

## Build and test

Install Xcode or its command-line tools, then:

```sh
swift test
sh scripts/build-native.sh
open build/Boltbar.app
```

No Node, Rust, WebKit or third-party Swift dependencies are needed. Quit older Boltbar builds before launching this one so they do not compete for the global shortcut.

A universal app containing Apple Silicon and Intel code:

```sh
BOLTBAR_UNIVERSAL=1 sh scripts/build-native.sh
```

The default build uses an ad hoc signature. For local development, supply an existing signing identity with `BOLTBAR_SIGN_IDENTITY`. Public distribution needs a **Developer ID Application** certificate and notarization; an Apple Development signature is not a substitute.

From this checkout, `sh install.sh` builds and installs the native app. It preserves an existing installation as a timestamped backup and preserves quarantine metadata.

**The published v0.1.3 release and its Homebrew cask still contain Tauri.** No native release has been published. The remote one-line installer downloads that published release until a native release is approved.

## Credentials and providers

Open Settings to choose the provider, default model, effort, transport and shortcut. Save API keys in Keychain. If an older executable created the saved key, use **Allow access to saved key** and approve the macOS prompt. Failed unattended access is reported without silently waiting behind the floating panel.

An explicit `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in the launching environment takes precedence; normal Finder launches use Keychain. The app never writes those environment credentials to a file.

For subscription login, run the command shown in Settings (`codex login`, `claude auth login`, or `agent login`), choose **CLI login**, and refresh. Boltbar lets the official CLI manage its tokens.

| Transport | Streaming | Attachments | Model discovery |
|---|---|---|---|
| OpenAI API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, latest Astra/Sol/Luna |
| Anthropic API | Text deltas | Images, PDFs, UTF-8 text | Live `/v1/models`, filtered |
| Claude Code CLI | Partial message events | UTF-8 text | Explicit fallback catalog |
| Codex CLI | Completed message events | UTF-8 text | Last synced API catalog or bundled defaults |
| Cursor CLI | CLI partial output | UTF-8 text | `agent --list-models` |

CLI image/PDF submissions produce an explicit error instead of silently losing files. CLI executables can maintain their own state according to their own settings. Cursor requires an authenticated official CLI; a dashboard key is not a public chat API.

OpenAI discovery is an explicit product policy: only stable aliases in the Astra, Sol and Luna families are eligible, and the highest numeric version of each family is shown. Refresh runs at launch, every six hours, and on demand from Settings. A new family needs a policy change; future versions within these three families are automatic. API failures keep the last successful catalog. CLI-only users without a cached API catalog get the three bundled defaults; that is not a live availability guarantee.

History begins with this native build; earlier in-memory conversations cannot be recovered. Stored chats include attachments and can be resumed after a restart. The history is local, not cloud-synced.

Markdown supports paragraphs, inline emphasis/links/code, headings, lists, quotes, and fenced code. Syntax coloring is intentionally a small native highlighter. Full GFM table layout is not implemented yet.

## Architecture

- `Sources/BoltbarNative/Application.swift`: NSPanel, Carbon shortcut, menu-bar item, window lifecycle.
- `ChatModel.swift` and `Domain.swift`: conversation state, persistent attachment ownership, preferences, Keychain.
- `Conversations.swift`, `HistoryView.swift`: private local history, native keyboard list and friendly dates.
- `FeaturedModels.swift`: approved OpenAI families and numeric version selection.
- `Editor.swift`, `Views.swift`, `SettingsView.swift`: AppKit text editor and native SwiftUI views.
- `Providers.swift`: URLSession SSE, provider catalogs, bounded CLI pipes and cancellation.
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

## License

[MIT](LICENSE)
