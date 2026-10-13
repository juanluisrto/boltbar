import { useCallback, useEffect, useState } from "react";
import {
  bootstrap,
  closeSettings,
  isTauri,
  refreshModels,
  saveUserSettings,
  setApiKey,
} from "./lib/api";
import { modelDisplayName } from "./lib/models";
import {
  EFFORTS,
  effortLabel,
  type ProviderInfo,
  type ProviderKind,
  type Settings,
  type ThinkingEffort,
} from "./types";

export default function SettingsApp() {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [keychainNative, setKeychainNative] = useState(false);
  const [keyDrafts, setKeyDrafts] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    bootstrap()
      .then((data) => {
        setSettings(data.settings);
        setProviders(data.providers);
        setKeychainNative(data.keychain_native);
        setLoading(false);
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : String(err));
        setLoading(false);
      });
  }, []);

  const persist = useCallback(async (next: Settings) => {
    setSettings(next);
    const updated = await saveUserSettings(next);
    setProviders(updated);
  }, []);

  return (
    <div className={isTauri() ? "settings-native" : "web-settings"}>
      <div className={isTauri() ? "settings-page" : "settings-window"}>
        <header className="mb-4 flex items-start justify-between gap-3">
          <div>
            <h1 className="text-[17px] font-medium tracking-tight">Settings</h1>
            <p className="mt-1 text-xs leading-relaxed text-[var(--muted)]">
              Provider keys, defaults, and login live here — not in the chat bar.
              On macOS, open this window with ⌘, or from the menu-bar extra.
            </p>
          </div>
          {!isTauri() && (
            <button
              type="button"
              className="rounded-full border border-white/10 px-3 py-1 text-xs text-[var(--muted)]"
              onClick={() => void closeSettings()}
            >
              Back
            </button>
          )}
        </header>

        {loading && <p className="text-sm text-[var(--muted)]">Loading settings…</p>}
        {error && (
          <div className="mb-3 rounded-lg bg-red-950/70 px-3 py-2 text-sm text-red-200">{error}</div>
        )}
        {notice && (
          <div className="mb-3 rounded-lg bg-[var(--gold-dim)] px-3 py-2 text-sm text-[var(--gold)]">
            {notice}
          </div>
        )}

        {settings && (
          <div className="space-y-5">
            <section>
              <h2 className="mb-2 text-xs uppercase tracking-[0.12em] text-[var(--muted)]">
                Defaults
              </h2>
              <label className="mb-3 block text-xs text-[var(--muted)]">
                Default provider
                <select
                  value={settings.provider}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm text-[var(--text)]"
                  onChange={(event) =>
                    void persist({
                      ...settings,
                      provider: event.target.value as ProviderKind,
                    })
                  }
                >
                  {providers.map((item) => (
                    <option key={item.id} value={item.id}>
                      {item.name}
                      {item.auth.ready ? "" : " · not ready"}
                    </option>
                  ))}
                </select>
              </label>
              <label className="mb-3 block text-xs text-[var(--muted)]">
                Default thinking effort
                <select
                  value={settings.thinking_effort}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm text-[var(--text)]"
                  onChange={(event) =>
                    void persist({
                      ...settings,
                      thinking_effort: event.target.value as ThinkingEffort,
                    })
                  }
                >
                  {EFFORTS.map((item) => (
                    <option key={item} value={item}>
                      {effortLabel(item)}
                    </option>
                  ))}
                </select>
              </label>
              <label className="mb-3 block text-xs text-[var(--muted)]">
                Hotkey
                <input
                  value={settings.hotkey}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm text-[var(--text)]"
                  onChange={(event) => void persist({ ...settings, hotkey: event.target.value })}
                />
              </label>
              <label className="block text-xs text-[var(--muted)]">
                Cursor OpenAI-compatible base URL (optional)
                <input
                  value={settings.cursor_base_url ?? ""}
                  placeholder="https://proxy.example/v1"
                  className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm text-[var(--text)]"
                  onChange={(event) =>
                    void persist({
                      ...settings,
                      cursor_base_url: event.target.value.trim() || null,
                    })
                  }
                />
              </label>
            </section>

            <section>
              <div className="mb-2 flex items-center justify-between">
                <h2 className="text-xs uppercase tracking-[0.12em] text-[var(--muted)]">
                  Providers
                </h2>
                <button
                  type="button"
                  className="rounded-full border border-white/10 px-2.5 py-1 text-[11px] text-[var(--muted)]"
                  onClick={() => {
                    void refreshModels()
                      .then((next) => {
                        setProviders(next);
                        setNotice("Model lists refreshed from providers");
                        setError(null);
                      })
                      .catch((err: unknown) => {
                        setError(err instanceof Error ? err.message : String(err));
                      });
                  }}
                >
                  Refresh models
                </button>
              </div>
              <p className="mb-3 text-xs leading-relaxed text-[var(--muted)]">
                API keys are written to the macOS Keychain
                {keychainNative ? "" : " when running as the Mac app"}. They are
                never stored in settings.json. Subscription reuse reads the official
                Codex, Claude Code, or Cursor CLI login — Boltbar does not refresh
                those tokens itself. Model lists come from each provider’s models
                endpoint when a key or CLI is available; otherwise October 2026
                fallbacks are shown.
              </p>
              <div className="space-y-3">
                {providers
                  .filter((p) => p.id !== "demo")
                  .map((item) => (
                    <div key={item.id} className="rounded-xl border border-white/8 bg-white/3 p-3">
                      <div className="mb-1 flex items-center justify-between text-xs">
                        <strong className="text-[var(--text)]">{item.name}</strong>
                        <span className={item.auth.ready ? "text-emerald-300" : "text-amber-200"}>
                          {item.auth.ready ? "Ready" : "Needs setup"}
                        </span>
                      </div>
                      <p className="mb-2 text-[11px] leading-relaxed text-[var(--muted)]">
                        {item.auth.label}
                      </p>
                      <label className="mb-2 block text-[11px] text-[var(--muted)]">
                        Default model
                        <select
                          value={settings.models[item.id] ?? item.default_model}
                          className="mt-1 w-full rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm text-[var(--text)]"
                          onChange={(event) =>
                            void persist({
                              ...settings,
                              models: { ...settings.models, [item.id]: event.target.value },
                            })
                          }
                        >
                          {item.models.map((id) => (
                            <option key={id} value={id}>
                              {modelDisplayName(id)}
                            </option>
                          ))}
                        </select>
                      </label>
                      <div className="flex gap-2">
                        <input
                          type="password"
                          autoComplete="off"
                          placeholder={`${item.name} API key`}
                          value={keyDrafts[item.id] ?? ""}
                          className="min-w-0 flex-1 rounded-lg border border-white/10 bg-[#1b1b1d] px-2 py-1.5 text-sm"
                          onChange={(event) =>
                            setKeyDrafts({ ...keyDrafts, [item.id]: event.target.value })
                          }
                        />
                        <button
                          type="button"
                          className="rounded-lg bg-white/10 px-2.5 py-1 text-xs"
                          onClick={() => {
                            void setApiKey(item.id, keyDrafts[item.id] ?? "")
                              .then((auth) => {
                                setProviders(
                                  providers.map((p) => (p.id === item.id ? { ...p, auth } : p)),
                                );
                                setNotice(
                                  auth.ready
                                    ? `${item.name} key saved`
                                    : `${item.name} key cleared`,
                                );
                                setError(null);
                                return refreshModels();
                              })
                              .then((next) => {
                                if (next) {
                                  setProviders(next);
                                }
                              })
                              .catch((err: unknown) => {
                                setError(err instanceof Error ? err.message : String(err));
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
          </div>
        )}
      </div>
    </div>
  );
}
