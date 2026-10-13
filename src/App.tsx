import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type ReactNode,
} from "react";
import { AttachmentThumbs } from "./components/AttachmentThumbs";
import { MarkdownView } from "./components/MarkdownView";
import { ModelChip } from "./components/ModelChip";
import { ResizeHandle } from "./components/ResizeHandle";
import {
  bootstrap,
  hideBar,
  isTauri,
  onChatEvent,
  onConversationReset,
  openSettings,
  pickFilePaths,
  readFiles,
  resizeBar,
  saveUserSettings,
  startChat,
  stopChat,
} from "./lib/api";
import { fileToAttachment } from "./lib/attachments";
import type {
  Attachment,
  Bootstrap,
  ChatMessage,
  ProviderInfo,
  Settings,
} from "./types";
import { providerLabel } from "./types";

type LoadState = "loading" | "ready" | "error";

const MIN_INPUT = 96;
const MAX_INPUT = 280;

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
  const [chipOpen, setChipOpen] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const picking = useRef(false);
  const [contentHeight, setContentHeight] = useState(MIN_INPUT);
  const [liveHeight, setLiveHeight] = useState<number | null>(null);

  const floorHeight = liveHeight ?? settings?.input_height ?? 120;
  const inputHeight = Math.min(MAX_INPUT, Math.max(MIN_INPUT, Math.max(floorHeight, contentHeight)));
  const provider = settings?.provider ?? "demo";
  const current = providers.find((p) => p.id === provider);
  const model = settings?.models[provider] ?? current?.default_model ?? "";
  const effort = settings?.thinking_effort ?? "medium";

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
    setChipOpen(false);
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
    const el = inputRef.current;
    if (!el) {
      return;
    }
    const previous = el.style.height;
    el.style.height = "0px";
    const next = Math.min(MAX_INPUT, Math.max(MIN_INPUT, el.scrollHeight));
    el.style.height = previous;
    setContentHeight(next);
  }, [draft]);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      const height = rootRef.current?.scrollHeight ?? 248;
      void resizeBar(880, height);
    });
    return () => window.cancelAnimationFrame(frame);
  }, [messages, assistant, attachments, chipOpen, inputHeight, error, notice, draft]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key === ",") {
        event.preventDefault();
        setChipOpen(false);
        void openSettings();
        return;
      }
      if (event.key === "Escape") {
        if (chipOpen) {
          setChipOpen(false);
          return;
        }
        void hideBar();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [chipOpen]);

  useEffect(() => {
    const onBlur = () => {
      if (!isTauri() || picking.current || chipOpen) {
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
  }, [chipOpen]);

  const persist = useCallback(async (next: Settings) => {
    setSettings(next);
    const updated = await saveUserSettings(next);
    setProviders(updated);
  }, []);

  const addFiles = useCallback(async (files: File[]) => {
    try {
      const next = await Promise.all(files.map((file) => fileToAttachment(file)));
      setAttachments((prev) => [...prev, ...next].slice(0, 6));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  useEffect(() => {
    if (isTauri()) {
      return;
    }
    const handler = (event: Event) => {
      const files = (event as CustomEvent<File[]>).detail;
      if (Array.isArray(files) && files.length) {
        void addFiles(files);
      }
    };
    window.addEventListener("boltbar-add-files", handler);
    return () => window.removeEventListener("boltbar-add-files", handler);
  }, [addFiles]);

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
    setChipOpen(false);
    try {
      await startChat({
        provider,
        model,
        messages: history,
        attachments,
        effort,
      });
      setAttachments([]);
    } catch (err) {
      setStreaming(false);
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [attachments, draft, effort, messages, model, provider, settings, streaming]);

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
  const hasThread = messages.length > 0 || Boolean(assistant);

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
        className={`glass overflow-visible rounded-[18px] ${dragOver ? "outline outline-2 outline-[var(--gold)]" : ""}`}
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
          <span data-tauri-drag-region>{web ? "Web preview · ⌘," : "Opt+Space · ⌘, settings"}</span>
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

        <ResizeHandle
          value={inputHeight}
          min={MIN_INPUT}
          max={MAX_INPUT}
          invert
          onChange={setLiveHeight}
          onCommit={(height) => {
            setLiveHeight(null);
            void persist({ ...settings, input_height: Math.round(height) });
          }}
        />

        <AttachmentThumbs
          attachments={attachments}
          onRemove={(idx) => setAttachments((prev) => prev.filter((_, i) => i !== idx))}
        />

        <div className="px-4">
          <textarea
            ref={inputRef}
            value={draft}
            autoFocus
            placeholder={
              current?.auth.ready
                ? "Ask anything — a new conversation starts each time this bar opens"
                : "This provider is not connected. Open Settings (⌘,) or switch to Demo."
            }
            style={{ height: inputHeight }}
            className={`w-full resize-none border-0 bg-transparent px-1 py-1 text-[15px] text-[var(--text)] outline-none placeholder:text-[var(--muted)] ${
              inputHeight >= MAX_INPUT ? "overflow-y-auto" : "overflow-hidden"
            }`}
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

        <footer className="flex items-center gap-2 px-5 pb-5 pt-1">
          <button
            type="button"
            aria-label="Attach files"
            className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/5 text-lg leading-none text-[var(--text)]"
            onClick={() => void onPick()}
          >
            +
          </button>
          <ModelChip
            open={chipOpen}
            onOpenChange={setChipOpen}
            provider={provider}
            model={model}
            effort={effort}
            providers={providers}
            onEffort={(next) => void persist({ ...settings, thinking_effort: next })}
            onSelect={(nextProvider, nextModel) =>
              void persist({
                ...settings,
                provider: nextProvider,
                models: { ...settings.models, [nextProvider]: nextModel },
              })
            }
          />
          <span className="ml-auto" />
          {streaming ? (
            <button
              type="button"
              aria-label="Stop"
              className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/8"
              onClick={() => void stopChat()}
            >
              <span className="block h-2.5 w-2.5 rounded-[2px] bg-[var(--text)]" />
            </button>
          ) : (
            <button
              type="button"
              aria-label="Send"
              className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[var(--gold)] text-black"
              onClick={() => void send()}
            >
              <SendIcon />
            </button>
          )}
        </footer>
      </div>
    </Shell>
  );
}

function SendIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M8 12.5V3.5M8 3.5 3.5 8M8 3.5 12.5 8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function Shell({ web, children }: { web: boolean; children: ReactNode }) {
  if (!web) {
    return children;
  }
  return (
    <div className="web-preview">
      <div className="mx-auto w-full max-w-[880px]">
        <p className="mb-4 text-center text-sm text-[#c9c2b4]">
          Browser preview of the Boltbar overlay. On macOS the same UI floats
          over every app and opens with Opt+Space. Settings open with ⌘,.
        </p>
        {children}
      </div>
    </div>
  );
}
