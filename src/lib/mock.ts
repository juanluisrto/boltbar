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

export const FALLBACK_MODELS = {
  openai: ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.2", "gpt-4.1", "gpt-4o"],
  anthropic: [
    "claude-sonnet-5-5",
    "claude-opus-5-5",
    "claude-fable-5-1",
    "claude-haiku-5-5",
    "claude-sonnet-4-6",
    "claude-opus-4-6",
  ],
  cursor: [
    "auto",
    "composer-2.5",
    "composer-2.5-fast",
    "gpt-6-astra",
    "claude-sonnet-5-5",
    "claude-opus-5-5",
  ],
  demo: ["boltbar-demo"],
} as const;

function freshSettings(): Settings {
  return {
    provider: "demo",
    models: {
      openai: "gpt-6-astra",
      anthropic: "claude-sonnet-5-5",
      cursor: "auto",
      demo: "boltbar-demo",
    },
    hotkey: "alt+space",
    input_height: 120,
    cursor_base_url: null,
    thinking_effort: "medium",
  };
}

export function defaultSettings(): Settings {
  const stored = localStorage.getItem("boltbar.settings");
  if (stored) {
    try {
      const parsed = JSON.parse(stored) as Partial<Settings>;
      const base = freshSettings();
      return {
        ...base,
        ...parsed,
        models: { ...base.models, ...parsed.models },
        thinking_effort: parsed.thinking_effort ?? "medium",
      };
    } catch {
      // fall through
    }
  }
  return freshSettings();
}

export function mockProviders(): ProviderInfo[] {
  return [
    provider(
      "openai",
      "OpenAI",
      [...FALLBACK_MODELS.openai],
      false,
      "Add an API key or log in with Codex CLI on macOS",
    ),
    provider(
      "anthropic",
      "Anthropic",
      [...FALLBACK_MODELS.anthropic],
      false,
      "Add an API key or log in with Claude Code on macOS",
    ),
    provider(
      "cursor",
      "Cursor",
      [...FALLBACK_MODELS.cursor],
      false,
      "Install the Cursor CLI (`agent`) or set a custom base URL",
    ),
    provider("demo", "Demo", [...FALLBACK_MODELS.demo], true, "Built-in demo (no login required)"),
  ];
}

export function mockBootstrap(): Bootstrap {
  return {
    settings: defaultSettings(),
    providers: mockProviders(),
    keychain_native: false,
  };
}
