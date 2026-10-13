import type { Bootstrap, ProviderInfo, Settings } from "../types";

export const DEMO_MARKDOWN =
  "Boltbar is ready.\n\nSummon this bar with **Opt+Space**. It starts a new conversation every time, streams tokens as they arrive, and renders markdown — including fenced code:\n\n```rust\nfn hello() {\n    println!(\"streaming, token by token\");\n}\n```\n\nDrop images or files onto the window, paste them, or pick from disk. Keys stay in the **macOS Keychain**, never in a settings file.\n";

export function tokenize(text: string): string[] {
  const out: string[] = [];
  let buf = "";
  for (const ch of text) {
    buf += ch;
    if (/\s/.test(ch)) {
      out.push(buf);
      buf = "";
    }
  }
  if (buf) {
    out.push(buf);
  }
  return out;
}

function provider(
  id: ProviderInfo["id"],
  name: string,
  models: string[],
  ready: boolean,
  label: string,
): ProviderInfo {
  return {
    id,
    name,
    models,
    default_model: models[0] ?? "",
    supports_attachments: id !== "demo",
    auth: {
      provider: id,
      kind: ready ? "api_key" : "missing",
      label,
      ready,
    },
  };
}

export function defaultSettings(): Settings {
  const stored = localStorage.getItem("boltbar.settings");
  if (stored) {
    try {
      return JSON.parse(stored) as Settings;
    } catch {
      // fall through
    }
  }
  return {
    provider: "demo",
    models: {
      openai: "gpt-4.1",
      anthropic: "claude-sonnet-4-6",
      cursor: "auto",
      demo: "boltbar-demo",
    },
    hotkey: "alt+space",
    input_height: 72,
    cursor_base_url: null,
  };
}

export function mockBootstrap(): Bootstrap {
  return {
    settings: defaultSettings(),
    providers: [
      provider("openai", "OpenAI", ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "o3"], false, "Add an API key or log in with Codex CLI on macOS"),
      provider("anthropic", "Anthropic", ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5"], false, "Add an API key or log in with Claude Code on macOS"),
      provider("cursor", "Cursor", ["auto"], false, "Install the Cursor CLI (`agent`) or set a custom base URL"),
      provider("demo", "Demo", ["boltbar-demo"], true, "Built-in demo (no login required)"),
    ],
    keychain_native: false,
  };
}
