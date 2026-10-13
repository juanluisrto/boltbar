import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type ReactNode,
} from "react";
import { MarkdownView } from "./components/MarkdownView";
import { ResizeHandle } from "./components/ResizeHandle";
import {
  bootstrap,
  hideBar,
  isTauri,
  onChatEvent,
  onConversationReset,
  pickFilePaths,
  readFiles,
  resizeBar,
  saveUserSettings,
  setApiKey,
  startChat,
  stopChat,
} from "./lib/api";
import {
  attachmentPreviewUrl,
  fileToAttachment,
  isImageAttachment,
} from "./lib/attachments";
import type {
  Attachment,
  Bootstrap,
  ChatMessage,
  ProviderInfo,
  ProviderKind,
  Settings,
} from "./types";
import { authKindLabel, providerLabel } from "./types";

type LoadState = "loading" | "ready" | "error";

export default function App() {
  const [load, setLoad] = useState<LoadState>("loading");
  const [error, setError] = useState<string | null>(null);
  const [boot, setBoot] = useState<Bootstrap | null>(null);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [draft, setDraft] = useState("");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [assistant, setAssistant] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const [keyDrafts, setKeyDrafts] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const picking = useRef(false);

  const [liveHeight, setLiveHeight] = useState<number | null>(null);
  const inputHeight = liveHeight ?? settings?.input_height ?? 72;
  const provider = settings?.provider ?? "demo";
  const current = providers.find((p) => p.id === provider);
  const model = settings?.models[provider] ?? current?.default_model ?? "";

  useEffect(() => {
    let cancelled = false;
    bootstrap()
      .then((data) => {
        if (cancelled) {
          return;
        }
        setBoot(data);
        setSettings(data.settings);
        setProviders(data.providers);
        setLoad("ready");
      })
      .catch((err: unknown) => {
        if (cancelled) {
          return;
        }
        setError(err instanceof Error ? err.message : String(err));
        setLoad("error");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const resetConversation = useCallback(() => {
    void stopChat();
    setMessages([]);
    setAssistant("");
    setDraft("");
    setAttachments([]);
    setStreaming(false);
    setSettingsOpen(false);
    setError(null);
    setNotice(null);
    window.setTimeout(() => inputRef.current?.focus(), 30);
  }, []);

  useEffect(() => {
    const unlistenChat = onChatEvent((event) => {
      switch (event.type) {
        case "delta":
          setAssistant((prev) => prev + event.text);
          setStreaming(true);
          break;
        case "done":
          setStreaming(false);
          setAssistant((prev) => {
            if (prev.trim()) {
              setMessages((msgs) => [...msgs, { role: "assistant", content: prev }]);
            }
            return "";
          });
          break;
        case "error":
          setStreaming(false);
          setError(event.message);
          break;
        default: {
          const _never: never = event;
          return _never;
        }
      }
    });
    const unlistenReset = onConversationReset(resetConversation);
    return () => {
      void unlistenChat.then((fn) => fn());
      void unlistenReset.then((fn) => fn());
    };
  }, [resetConversation]);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      const height = rootRef.current?.scrollHeight ?? 96;
      void resizeBar(720, height + 8);
    });
    return () => window.cancelAnimationFrame(frame);
  }, [messages, assistant, attachments, settingsOpen, inputHeight, error, notice, draft]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (settingsOpen) {
          setSettingsOpen(false);
          return;
        }
        void hideBar();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [settingsOpen]);

  useEffect(() => {
    const onBlur = () => {
      if (!isTauri() || picking.current || settingsOpen) {
        return;
      }
      window.setTimeout(() => {
        if (document.hasFocus() || picking.current) {
          return;
        }
        void hideBar();
      }, 180);
    };
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, [settingsOpen]);

  const persist = useCallback(
    async (next: Settings) => {
      setSettings(next);
      const updated = await saveUserSettings(next);
      setProviders(updated);
    },
    [],
  );

  const addFiles = useCallback(async (files: File[]) => {
    try {
      const next = await Promise.all(files.map((file) => fileToAttachment(file)));
      setAttachments((prev) => [...prev, ...next].slice(0, 6));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  const onPick = useCallback(async () => {
    picking.current = true;
    try {
      if (isTauri()) {
        const paths = await pickFilePaths();
        if (paths.length) {
          const atts = await readFiles(paths);
          setAttachments((prev) => [...prev, ...atts].slice(0, 6));
        }
      } else {
        const input = document.createElement("input");
        input.type = "file";
        input.multiple = true;
        input.accept = "image/*,.txt,.md,.json,.rs,.ts,.tsx,.js,.py,.pdf";
        input.onchange = () => {
          void addFiles(Array.from(input.files ?? []));
        };
        input.click();
      }
    } finally {
      window.setTimeout(() => {
        picking.current = false;
      }, 400);
    }
  }, [addFiles]);

  const send = useCallback(async () => {
    if (!settings || streaming) {
      return;
    }
    const text = draft.trim();
    if (!text && attachments.length === 0) {
      return;
    }
    const history: ChatMessage[] = [
      ...messages,
      { role: "user", content: text || "(attachment)" },
    ];
    setMessages(history);
    setDraft("");
    setAssistant("");
    setStreaming(true);
    setError(null);
    try {
      await startChat({
        provider,
        model,
        messages: history,
        attachments,
      });
      setAttachments([]);
    } catch (err) {
      setStreaming(false);
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [attachments, draft, messages, model, provider, settings, streaming]);

  const onPaste = useCallback(
    (event: ClipboardEvent) => {
      const files = Array.from(event.clipboardData.files);
      if (files.length) {
        event.preventDefault();
        void addFiles(files);
      }
    },
    [addFiles],
  );

  const web = !isTauri();
  const hasThread = messages.length > 0 || Boolean(assistant) || settingsOpen;

  const status = useMemo(() => {
    if (!current) {
      return "Choose a provider";
    }
    if (current.auth.ready) {
      return current.auth.label;
    }
    return current.auth.label;
  }, [current]);

  if (load === "loading") {
    return (
      <Shell web={web}>
        <div ref={rootRef} className="glass rounded-[18px] px-5 py-4 text-sm text-[var(--muted)]">
          Waking Boltbar…
        </div>
      </Shell>
    );
  }

  if (load === "error" || !settings || !boot) {
    return (
      <Shell web={web}>
        <div ref={rootRef} className="glass rounded-[18px] px-5 py-4">
          <p className="text-sm text-red-300">{error ?? "Could not start Boltbar."}</p>
        </div>
      </Shell>
    );
  }

  return (
    <Shell web={web}>
      <div
        ref={rootRef}
        className={`glass overflow-hidden rounded-[18px] ${dragOver ? "outline outline-2 outline-[var(--gold)]" : ""}`}
        onDragOver={(event) => {
          event.preventDefault();
          setDragOver(true);
        }}
        onDragLeave={() => setDragOver(false)}
        onDrop={(event) => {
          event.preventDefault();
          setDragOver(false);
          void addFiles(Array.from(event.dataTransfer.files));
        }}
      >
        <header
          className="flex items-center justify-between px-4 pt-3 text-[11px] uppercase tracking-[0.14em] text-[var(--muted)]"
          data-tauri-drag-region
        >
          <span data-tauri-drag-region>Boltbar</span>
          <span data-tauri-drag-region>{web ? "Web preview" : "Opt+Space · Esc hides"}</span>
        </header>

        {hasThread && (
          <div className="max-h-[48vh] space-y-3 overflow-auto px-4 py-3">
            {messages.map((msg, idx) => (
              <article key={`${msg.role}-${idx}`} className="text-sm">
                <div className="mb-1 text-[11px] uppercase tracking-[0.12em] text-[var(--muted)]">
                  {msg.role === "user" ? "You" : providerLabel(provider)}
                </div>
                {msg.role === "assistant" ? (
                  <MarkdownView text={msg.content} />
                ) : (
                  <p className="whitespace-pre-wrap text-[15px] leading-relaxed">{msg.content}</p>
                )}
              </article>
            ))}
            {(assistant || streaming) && (
              <article className="text-sm">
                <div className="mb-1 text-[11px] uppercase tracking-[0.12em] text-[var(--gold)]">
                  {providerLabel(provider)}
                  {streaming ? " · streaming" : ""}
                </div>
                {assistant ? (
                  <MarkdownView text={assistant} />
                ) : (
                  <p className="text-[var(--muted)]">Thinking…</p>
                )}
              </article>
            )}
            {settingsOpen && (
              <SettingsPanel
                settings={settings}
                providers={providers}
                keychainNative={boot.keychain_native}
                keyDrafts={keyDrafts}
                onKeyDrafts={setKeyDrafts}
                onNotice={setNotice}
                onError={setError}
                onProviders={setProviders}
                onChange={(next) => void persist(next)}
              />
            )}
          </div>
        )}

        {error && (
          <div className="mx-4 mb-2 rounded-lg bg-red-950/70 px-3 py-2 text-sm text-red-200">
            {error}
          </div>
        )}
        {notice && (
          <div className="mx-4 mb-2 rounded-lg bg-[var(--gold-dim)] px-3 py-2 text-sm text-[var(--gold)]">
            {notice}
          </div>
        )}

        {attachments.length > 0 && (
          <div className="flex flex-wrap gap-2 px-4 pb-1">
            {attachments.map((att, idx) => (
              <button
                key={`${att.name}-${idx}`}
                type="button"
                className="flex items-center gap-2 rounded-lg border border-white/10 bg-white/5 px-2 py-1 text-left text-xs"
                onClick={() => setAttachments((prev) => prev.filter((_, i) => i !== idx))}
              >
                {isImageAttachment(att) && attachmentPreviewUrl(att) ? (
                  <img
                    src={attachmentPreviewUrl(att) ?? ""}
                    alt=""
                    className="h-8 w-8 rounded object-cover"
                  />
                ) : (
                  <span className="text-[var(--gold)]">file</span>
                )}
                <span className="max-w-[140px] truncate">{att.name}</span>
              </button>
            ))}
          </div>
        )}

        {hasThread && (
          <ResizeHandle
            value={inputHeight}
            min={48}
            max={280}
            onChange={setLiveHeight}
            onCommit={(height) => {
              setLiveHeight(null);
              void persist({ ...settings, input_height: Math.round(height) });
            }}
          />
        )}

        <div className="px-3 pb-2">
          <textarea
            ref={inputRef}
            value={draft}
            autoFocus
            placeholder={
              current?.auth.ready
                ? "Ask anything — a new conversation starts each time this bar opens"
                : "This provider is not connected. Open settings or switch to Demo."
            }
            style={{ height: inputHeight }}
            className="w-full resize-none rounded-xl border-0 bg-white/5 px-3 py-3 text-[15px] text-[var(--text)] outline-none placeholder:text-[var(--muted)]"
            onChange={(event) => setDraft(event.target.value)}
            onPaste={onPaste}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void send();
              }
            }}
          />
        </div>

        <footer className="flex flex-wrap items-center gap-2 px-3 pb-3">
          <select
            value={provider}
            className="rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1 text-xs"
            onChange={(event) => {
              const next = event.target.value as ProviderKind;
              void persist({ ...settings, provider: next });
            }}
          >
            {providers.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
                {item.auth.ready ? "" : " · not ready"}
              </option>
            ))}
          </select>
          <select
            value={model}
            className="max-w-[180px] rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1 text-xs"
            onChange={(event) => {
              void persist({
                ...settings,
                models: { ...settings.models, [provider]: event.target.value },
              });
            }}
          >
            {(current?.models ?? [model]).map((item) => (
              <option key={item} value={item}>
                {item}
              </option>
            ))}
          </select>
          <button
            type="button"
            className="rounded-lg border border-white/10 bg-white/5 px-2 py-1 text-xs"
            onClick={() => void onPick()}
          >
            Attach
          </button>
          <button
            type="button"
            className="rounded-lg border border-white/10 bg-white/5 px-2 py-1 text-xs"
            onClick={() => setSettingsOpen((v) => !v)}
          >
            Settings
          </button>
          {streaming ? (
            <button
              type="button"
              className="rounded-lg border border-white/10 bg-white/5 px-2 py-1 text-xs"
              onClick={() => void stopChat()}
            >
              Stop
            </button>
          ) : (
            <button
              type="button"
              className="rounded-lg bg-[var(--gold)] px-3 py-1 text-xs font-medium text-black"
              onClick={() => void send()}
            >
              Send
            </button>
          )}
          <span className="ml-auto max-w-[46%] truncate text-[11px] text-[var(--muted)]">
            {authKindLabel(current?.auth.kind ?? "missing")} · {status}
          </span>
        </footer>
      </div>
    </Shell>
  );
}

function Shell({ web, children }: { web: boolean; children: ReactNode }) {
  if (!web) {
    return <div className="p-1">{children}</div>;
  }
  return (
    <div className="web-preview">
      <div className="mx-auto w-full max-w-[720px]">
        <p className="mb-4 text-center text-sm text-[#c9c2b4]">
          Browser preview of the Boltbar overlay. On macOS the same UI floats
          over every app and opens with Opt+Space.
        </p>
        {children}
      </div>
    </div>
  );
}

function SettingsPanel({
  settings,
  providers,
  keychainNative,
  keyDrafts,
  onKeyDrafts,
  onNotice,
  onError,
  onProviders,
  onChange,
}: {
  settings: Settings;
  providers: ProviderInfo[];
  keychainNative: boolean;
  keyDrafts: Record<string, string>;
  onKeyDrafts: (next: Record<string, string>) => void;
  onNotice: (text: string | null) => void;
  onError: (text: string | null) => void;
  onProviders: (next: ProviderInfo[]) => void;
  onChange: (next: Settings) => void;
}) {
  return (
    <section className="rounded-xl border border-white/10 bg-black/25 p-3">
      <h2 className="mb-2 text-sm font-medium">Settings</h2>
      <p className="mb-3 text-xs leading-relaxed text-[var(--muted)]">
        API keys are written to the macOS Keychain
        {keychainNative ? "" : " when running as the Mac app"}
        . They are never stored in settings.json. Subscription reuse reads the
        official Codex, Claude Code, or Cursor CLI login — Boltbar does not
        refresh those tokens itself.
      </p>
      <label className="mb-3 block text-xs text-[var(--muted)]">
        Hotkey
        <input
          value={settings.hotkey}
          className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1 text-sm text-[var(--text)]"
          onChange={(event) => onChange({ ...settings, hotkey: event.target.value })}
        />
      </label>
      <label className="mb-3 block text-xs text-[var(--muted)]">
        Cursor OpenAI-compatible base URL (optional)
        <input
          value={settings.cursor_base_url ?? ""}
          placeholder="https://proxy.example/v1"
          className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1 text-sm text-[var(--text)]"
          onChange={(event) =>
            onChange({
              ...settings,
              cursor_base_url: event.target.value.trim() || null,
            })
          }
        />
      </label>
      <div className="space-y-3">
        {providers
          .filter((p) => p.id !== "demo")
          .map((item) => (
            <div key={item.id} className="rounded-lg border border-white/8 bg-white/3 p-2">
              <div className="mb-1 flex items-center justify-between text-xs">
                <strong className="text-[var(--text)]">{item.name}</strong>
                <span className={item.auth.ready ? "text-emerald-300" : "text-amber-200"}>
                  {item.auth.ready ? "Ready" : "Needs setup"}
                </span>
              </div>
              <p className="mb-2 text-[11px] leading-relaxed text-[var(--muted)]">
                {item.auth.label}
              </p>
              <div className="flex gap-2">
                <input
                  type="password"
                  autoComplete="off"
                  placeholder={`${item.name} API key`}
                  value={keyDrafts[item.id] ?? ""}
                  className="min-w-0 flex-1 rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1 text-sm"
                  onChange={(event) =>
                    onKeyDrafts({ ...keyDrafts, [item.id]: event.target.value })
                  }
                />
                <button
                  type="button"
                  className="rounded-lg bg-white/10 px-2 py-1 text-xs"
                  onClick={() => {
                    void setApiKey(item.id, keyDrafts[item.id] ?? "")
                      .then((auth) => {
                        onProviders(
                          providers.map((p) => (p.id === item.id ? { ...p, auth } : p)),
                        );
                        onNotice(
                          auth.ready
                            ? `${item.name} key saved`
                            : `${item.name} key cleared`,
                        );
                        onError(null);
                      })
                      .catch((err: unknown) => {
                        onError(err instanceof Error ? err.message : String(err));
                      });
                  }}
                >
                  Save
                </button>
              </div>
            </div>
          ))}
      </div>
    </section>
  );
}
