# Boltbar

A lightning-fast global chat bar for macOS. Press **Opt+Space** (configurable) and a Spotlight-style overlay appears over whatever you are doing. Every summon starts a new conversation.

Boltbar is the open-source stand-in for the ChatGPT desktop “Chat Bar” that used to open with Opt+Space and was later removed.

![Boltbar overlay](docs/screenshots/chat-bar.svg)

_Placeholder visual of the floating bar. Replace this SVG with a real screenshot from a Mac after the first signed build._

## Why Tauri v2 (Rust)

This is a **resident menu-bar app**, not a page that cold-starts on every hotkey.

- The **Rust** side owns global shortcuts, the Keychain, provider streaming, and official-CLI fallbacks. That work stays off the UI thread.
- The window is created once, kept hidden, and shown on Opt+Space. That is how you get a Spotlight-like feel without a full native widget toolkit.
- The webview exists only to render **streaming markdown and fenced code**. Native Rust GUIs (egui/iced) still make that painful. A tiny React + Tailwind surface is the tradeoff.
- A shared `boltbar-core` crate is unit-tested on Linux. The Tauri shell is macOS-first.

A fully native AppKit app would start a few milliseconds faster and look slightly more “system.” It would also make markdown, syntax highlighting, and attachments much worse. Tauri v2 is the honest middle.

## Features

- Global hotkey (default `alt+space`) shows a frameless, always-on-top bar
- New conversation on every summon
- Token-by-token streaming with GitHub-flavored markdown and highlighted code
- Two-level composer: a text box that grows **upward** as you type (then scrolls), plus a compact control row
- Drag the handle above the composer to resize the input
- Image thumbnails and document cards (with a remove ✕) when you paste, drop, or attach files
- Quick **Thinking effort** + model chip (Low / Medium / High, mapped to each provider’s reasoning param)
- Live model lists from OpenAI `/v1/models`, Anthropic `/v1/models`, and `agent --list-models`, with October 2026 fallbacks
- Dedicated **Settings** window (⌘, / menu-bar extra) for API keys, auth, and defaults — not in the composer
- Pluggable providers: **OpenAI**, **Anthropic**, **Cursor**, plus a built-in **Demo**
- API keys in the **macOS Keychain** (`service = com.boltbar.keys`) — never in `settings.json`
- Menu-bar extra to show, hide, open Settings, or quit

## Install

After a GitHub Release exists (CI builds a universal `Boltbar-*-universal.zip`):

```bash
curl -fsSL https://raw.githubusercontent.com/juanluisrto/boltbar/main/install.sh | sh
```

From a clone, on a Mac with Xcode CLT, Rust, and Node:

```bash
chmod +x install.sh
./install.sh
```

Homebrew (after you publish a tap or fill in `homebrew/Casks/boltbar.rb`):

```bash
brew install --cask boltbar
```

The first launch may require **Accessibility** permission so the global hotkey can fire while other apps are focused. Grant it under System Settings → Privacy & Security → Accessibility.

## Usage

1. Launch **Boltbar**. It lives in the menu bar and does not stay in the Dock.
2. Press **Opt+Space**. Type. Enter sends; Shift+Enter inserts a newline; Esc hides.
3. Drag the thin handle to grow or shrink the input. The box also grows upward as you type.
4. Drop, paste, or attach files. Thumbnails appear above the text; click ✕ to remove. Images go to vision-capable models; text files are inlined.
5. Use the compact chip to change thinking effort and model. Open **Settings** with **⌘,** (or the menu-bar extra) to save API keys and defaults.

The Demo provider works with no login so you can confirm the overlay, streaming, and markdown.

## Provider setup — what actually works

Be skeptical of “just reuse my ChatGPT/Claude/Cursor subscription” claims. Here is the real matrix.

| Provider | API key in Keychain | Env var | Official CLI login | Notes |
|---|---|---|---|---|
| **OpenAI** | Yes, `api.openai.com` Chat Completions | `OPENAI_API_KEY` | Codex CLI `~/.codex/auth.json` | **API key path is first-class and official.** If Codex stored an API key, Boltbar reuses it. If Codex is logged into ChatGPT, Boltbar prefers `codex exec --json` so Codex itself refreshes tokens. A last-resort unofficial call to `chatgpt.com/backend-api/codex/responses` exists; it is **not** a documented third-party API and may break. Boltbar will not refresh ChatGPT tokens itself. |
| **Anthropic** | Yes, Messages API | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code Keychain / `~/.claude/.credentials.json`, or `claude -p` | **API key path is official.** Claude Code OAuth against `api.anthropic.com` with `anthropic-beta: oauth-2025-04-20` is the same contract Claude Code uses. Boltbar **reads** those tokens and **does not refresh** them (Claude refresh tokens are single-use; writing them back can log Claude Code out). If the token is stale, run `claude` once or use `claude setup-token`. |
| **Cursor** | Only with a custom OpenAI-compatible base URL | `CURSOR_API_KEY` | `agent` / `cursor-agent` CLI (`agent -p --output-format stream-json --stream-partial-output`) | **There is no public Cursor chat-completions API.** Cloud Agents (`api.cursor.com/agents`) is a repo-agent product, not a chat bar. Subscription reuse works when the official Cursor CLI is installed and logged in. A dashboard API key alone is not enough unless you point Settings at an OpenAI-compatible proxy. `~/.config/cursor/auth.json` is detected so we can tell you why chat still will not start. |
| **Demo** | Not needed | — | — | Always available. Streams a canned markdown reply. |

Priority for credentials: Keychain API key → environment variable → official CLI auth/binary → (OpenAI only) unofficial ChatGPT Responses call.

## Develop

```bash
# Rust provider/auth tests (Linux and macOS)
cargo test -p boltbar-core

# Frontend unit tests + typecheck
npm install
npm test
npm run build

# Overlay UI in a browser (no Keychain, Demo provider)
npm run dev:web

# Full macOS app
npm run tauri -- dev
```

`npm run dev:web` is a preview of the overlay. Global hotkey, Keychain, and CLI reuse need the Tauri build on a Mac.

## Architecture

```
crates/boltbar-core   providers, SSE, CLI NDJSON, auth parsers, Keychain trait
src-tauri             Tauri v2 window, tray, Opt+Space, commands
src                   React overlay: composer, markdown, attachments, settings
```

Release CI (`.github/workflows/ci.yml`) runs Linux tests and, on `macos-latest`, `tauri build --target universal-apple-darwin`. Tag a version (for example `v0.1.2`) to attach the zip to a GitHub Release.

## License

[MIT](LICENSE)
