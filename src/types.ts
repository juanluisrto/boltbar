export type ProviderKind = "openai" | "anthropic" | "cursor" | "demo";

export type Role = "system" | "user" | "assistant";

export type ThinkingEffort = "low" | "medium" | "high";

export type AuthKind =
  | "api_key"
  | "env"
  | "cli_api_key"
  | "cli_oauth"
  | "cli_binary"
  | "missing";

export interface ChatMessage {
  role: Role;
  content: string;
}

export interface Attachment {
  name: string;
  mime: string;
  data_base64: string;
}

export interface ChatRequest {
  provider: ProviderKind;
  model: string;
  messages: ChatMessage[];
  attachments: Attachment[];
  effort: ThinkingEffort;
}

export type StreamEvent =
  | { type: "delta"; text: string }
  | { type: "done" }
  | { type: "error"; message: string };

export interface AuthStatus {
  provider: ProviderKind;
  kind: AuthKind;
  label: string;
  ready: boolean;
}

export interface ProviderInfo {
  id: ProviderKind;
  name: string;
  models: string[];
  default_model: string;
  supports_attachments: boolean;
  auth: AuthStatus;
}

export interface Settings {
  provider: ProviderKind;
  models: Record<string, string>;
  hotkey: string;
  input_height: number;
  cursor_base_url: string | null;
  thinking_effort: ThinkingEffort;
}

export interface Bootstrap {
  settings: Settings;
  providers: ProviderInfo[];
  keychain_native: boolean;
}

export function providerLabel(kind: ProviderKind): string {
  switch (kind) {
    case "openai":
      return "OpenAI";
    case "anthropic":
      return "Anthropic";
    case "cursor":
      return "Cursor";
    case "demo":
      return "Demo";
    default: {
      const _never: never = kind;
      return _never;
    }
  }
}

export function authKindLabel(kind: AuthKind): string {
  switch (kind) {
    case "api_key":
      return "Keychain";
    case "env":
      return "Environment";
    case "cli_api_key":
      return "CLI API key";
    case "cli_oauth":
      return "CLI login";
    case "cli_binary":
      return "Official CLI";
    case "missing":
      return "Not connected";
    default: {
      const _never: never = kind;
      return _never;
    }
  }
}

export function effortLabel(effort: ThinkingEffort): string {
  switch (effort) {
    case "low":
      return "Low";
    case "medium":
      return "Medium";
    case "high":
      return "High";
    default: {
      const _never: never = effort;
      return _never;
    }
  }
}

export const EFFORTS: ThinkingEffort[] = ["low", "medium", "high"];
