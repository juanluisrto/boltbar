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
import { IconButton } from "./components/ui/icon-button";
import { ArrowUpIcon, PlusIcon, StopIcon } from "./components/ui/icon";
import {
  bootstrap,
  hideBar,
  isTauri,
  onChatEvent,
  onConversationReset,
  newChat,
  onSettingsChanged,
  onNativeDrop,
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
  const activeRequest = useRef<string | null>(null);
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
    activeRequest.current = null;
    void stopChat();
    setMessages([]);
    setAssistant("");
    setDraft("");
    setContentHeight(MIN_INPUT);
    setAttachments([]);
    setStreaming(false);
    setChipOpen(false);
    setError(null);
    setNotice(null);
    window.setTimeout(() => inputRef.current?.focus(), 30);
  }, []);

  useEffect(() => {
    const unlistenChat = onChatEvent((event, requestId) => {
      if (requestId && requestId !== activeRequest.current) return;
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
      const el = rootRef.current;
      const width = el?.offsetWidth ?? 908;
      const height = el?.scrollHeight ?? 276;
      void resizeBar(width, height);
    });
    return () => window.cancelAnimationFrame(frame);
  }, [load, messages, assistant, attachments, chipOpen, inputHeight, error, notice, draft]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "n") {
        event.preventDefault();
        void newChat();
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key === ",") {
        event.preventDefault();
        setChipOpen(false);
        void openSettings();
        return;
      }
      if (event.defaultPrevented) return;
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
    const unlisten = onSettingsChanged((data) => {
      setSettings(data.settings);
      setProviders(data.providers);
    });
    return () => { void unlisten.then((fn) => fn()); };
  }, []);

  useEffect(() => {
    const unlisten = onNativeDrop((paths, hovering) => {
      setDragOver(hovering);
      if (paths.length) void readFiles(paths).then((atts) => {
        setAttachments((prev) => [...prev, ...atts].slice(0, 6));
      }).catch((err: unknown) => setError(String(err)));
    });
    return () => { void unlisten.then((fn) => fn()); };
  }, []);

  const persist = useCallback(async (next: Settings) => {
    setSettings(next);
    try {
      const updated = await saveUserSettings(next);
      setProviders(updated);
    } catch (err) { setError(String(err)); }
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
    } catch (err) {
      setError(String(err));
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
      const requestId = crypto.randomUUID();
      activeRequest.current = requestId;
      await startChat({
        provider,
        model,
        messages: history,
        attachments,
        effort,
      }, requestId);
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
        <div ref={rootRef} className="overlay-frame">
          <div className="glass rounded-[22px] px-5 py-4 text-sm text-[var(--muted)]">
            Waking Boltbar…
          </div>
        </div>
      </Shell>
    );
  }

  if (load === "error" || !settings || !boot) {
    return (
      <Shell web={web}>
        <div ref={rootRef} className="overlay-frame">
          <div className="glass rounded-[22px] px-5 py-4">
            <p className="text-sm text-red-300">{error ?? "Could not start Boltbar."}</p>
          </div>
        </div>
      </Shell>
    );
  }

  return (
    <Shell web={web}>
      <div ref={rootRef} className={`overlay-frame ${chipOpen ? "with-popover" : ""}`}>
      <div
        className={`glass overflow-hidden rounded-[22px] ${dragOver ? "outline outline-2 outline-[var(--gold)]" : ""}`}
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
          <div className="max-h-[340px] space-y-3 overflow-auto px-4 py-3">
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
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                void send();
              }
            }}
          />
        </div>

        <footer className="flex min-w-0 items-center gap-2 px-4 pb-4 pt-1">
          <IconButton aria-label="Attach files" onClick={() => void onPick()}>
            <PlusIcon />
          </IconButton>
          <div className="min-w-0 flex-1">
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
          </div>
          {streaming ? (
            <IconButton aria-label="Stop" onClick={() => void stopChat()}>
              <StopIcon />
            </IconButton>
          ) : (
            <IconButton variant="gold" aria-label="Send" onClick={() => void send()}>
              <ArrowUpIcon />
            </IconButton>
          )}
        </footer>
      </div>
      </div>
    </Shell>
  );
}

function Shell({ web, children }: { web: boolean; children: ReactNode }) {
  if (!web) {
    return children;
  }
  return (
    <div className="web-preview">
      <div className="mx-auto w-full max-w-[920px]">
        <p className="mb-4 px-4 text-center text-sm text-[#c9c2b4]">
          Browser preview of the Boltbar overlay. On macOS the same UI floats
          over every app and opens with Opt+Space. Settings open with ⌘,.
        </p>
        {children}
      </div>
    </div>
  );
}
