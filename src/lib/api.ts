import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import type {
  Attachment,
  AuthStatus,
  Bootstrap,
  ChatRequest,
  ProviderInfo,
  ProviderKind,
  Settings,
  StreamEvent,
} from "../types";
import { DEMO_MARKDOWN, mockBootstrap, tokenize } from "./mock";

export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export async function bootstrap(): Promise<Bootstrap> {
  if (!isTauri()) {
    return mockBootstrap();
  }
  return invoke<Bootstrap>("bootstrap");
}

export async function saveUserSettings(settings: Settings): Promise<ProviderInfo[]> {
  if (!isTauri()) {
    localStorage.setItem("boltbar.settings", JSON.stringify(settings));
    const boot = mockBootstrap();
    boot.settings = settings;
    return boot.providers.map((p) => ({
      ...p,
      default_model: settings.models[p.id] ?? p.default_model,
    }));
  }
  return invoke<ProviderInfo[]>("save_user_settings", { settings });
}

export async function setApiKey(
  provider: ProviderKind,
  key: string,
): Promise<AuthStatus> {
  if (!isTauri()) {
    if (key.trim()) {
      sessionStorage.setItem(`boltbar.key.${provider}`, key.trim());
    } else {
      sessionStorage.removeItem(`boltbar.key.${provider}`);
    }
    const ready = Boolean(key.trim()) || provider === "demo";
    return {
      provider,
      kind: key.trim() ? "api_key" : "missing",
      label: key.trim()
        ? "Stored in this browser tab only (web preview)"
        : "Not connected",
      ready,
    };
  }
  return invoke<AuthStatus>("set_api_key", { provider, key });
}

export async function startChat(request: ChatRequest): Promise<void> {
  if (!isTauri()) {
    window.dispatchEvent(new CustomEvent("boltbar-mock-chat", { detail: request }));
    return;
  }
  await invoke("start_chat", { request });
}

export async function stopChat(): Promise<void> {
  if (!isTauri()) {
    window.dispatchEvent(new Event("boltbar-mock-stop"));
    return;
  }
  await invoke("stop_chat");
}

export async function hideBar(): Promise<void> {
  if (!isTauri()) {
    return;
  }
  await invoke("hide_bar");
}

export async function resizeBar(width: number, height: number): Promise<void> {
  if (!isTauri()) {
    return;
  }
  await invoke("resize_bar", { width, height });
}

export async function pickFilePaths(): Promise<string[]> {
  if (!isTauri()) {
    return [];
  }
  const selected = await open({
    multiple: true,
    directory: false,
  });
  if (Array.isArray(selected)) {
    return selected;
  }
  return selected ? [selected] : [];
}

export async function readFiles(paths: string[]): Promise<Attachment[]> {
  if (!isTauri()) {
    return [];
  }
  return invoke<Attachment[]>("read_files", { paths });
}

export async function onChatEvent(
  handler: (event: StreamEvent) => void,
): Promise<UnlistenFn> {
  if (!isTauri()) {
    let timer: number | null = null;
    let stopped = false;
    const start = () => {
      stopped = false;
      const tokens = tokenize(DEMO_MARKDOWN);
      let i = 0;
      const tick = () => {
        if (stopped) {
          handler({ type: "done" });
          return;
        }
        if (i >= tokens.length) {
          handler({ type: "done" });
          return;
        }
        handler({ type: "delta", text: tokens[i] ?? "" });
        i += 1;
        timer = window.setTimeout(tick, 18);
      };
      tick();
    };
    const onStart = () => {
      if (timer) {
        window.clearTimeout(timer);
      }
      start();
    };
    const onStop = () => {
      stopped = true;
    };
    window.addEventListener("boltbar-mock-chat", onStart);
    window.addEventListener("boltbar-mock-stop", onStop);
    return () => {
      stopped = true;
      if (timer) {
        window.clearTimeout(timer);
      }
      window.removeEventListener("boltbar-mock-chat", onStart);
      window.removeEventListener("boltbar-mock-stop", onStop);
    };
  }
  return listen<StreamEvent>("chat-event", (event) => handler(event.payload));
}

export async function onConversationReset(handler: () => void): Promise<UnlistenFn> {
  if (!isTauri()) {
    return () => undefined;
  }
  return listen("conversation-reset", () => handler());
}
