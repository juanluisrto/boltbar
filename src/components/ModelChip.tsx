import { useEffect, useRef } from "react";
import { modelDisplayName } from "../lib/models";
import {
  EFFORTS,
  effortLabel,
  providerLabel,
  type ProviderInfo,
  type ProviderKind,
  type ThinkingEffort,
} from "../types";

export function ModelChip({
  open,
  onOpenChange,
  provider,
  model,
  effort,
  providers,
  onEffort,
  onSelect,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  provider: ProviderKind;
  model: string;
  effort: ThinkingEffort;
  providers: ProviderInfo[];
  onEffort: (effort: ThinkingEffort) => void;
  onSelect: (provider: ProviderKind, model: string) => void;
}) {
  const root = useRef<HTMLDivElement>(null);
  const effortIndex = Math.max(0, EFFORTS.indexOf(effort));

  useEffect(() => {
    if (!open) {
      return;
    }
    const onDoc = (event: MouseEvent) => {
      if (root.current && !root.current.contains(event.target as Node)) {
        onOpenChange(false);
      }
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open, onOpenChange]);

  return (
    <div ref={root} className="relative">
      <button
        type="button"
        className="flex items-center gap-2 rounded-full border border-white/10 bg-white/6 px-3 py-1.5 text-xs text-[var(--text)]"
        aria-expanded={open}
        onClick={() => onOpenChange(!open)}
      >
        <span className="text-[var(--muted)]">{effortLabel(effort)}</span>
        <span className="text-white/20">·</span>
        <span className="max-w-[160px] truncate">{modelDisplayName(model)}</span>
        <span className="text-[10px] text-[var(--muted)]">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="absolute bottom-[calc(100%+10px)] left-0 z-30 w-[320px] rounded-2xl border border-white/10 bg-[#1c1c1e] p-3 shadow-[0_18px_50px_rgba(0,0,0,0.45)]">
          <div className="mb-2 flex items-center justify-between text-xs">
            <span className="text-[var(--muted)]">Thinking effort</span>
            <span className="text-[var(--text)]">{effortLabel(effort)}</span>
          </div>
          <input
            type="range"
            min={0}
            max={2}
            step={1}
            value={effortIndex}
            className="effort-slider mb-1 w-full"
            style={{ ["--effort" as string]: `${(effortIndex / 2) * 100}%` }}
            aria-label="Thinking effort"
            onChange={(event) => {
              const next = EFFORTS[Number(event.target.value)] ?? "medium";
              onEffort(next);
            }}
          />
          <div className="mb-3 flex justify-between text-[10px] uppercase tracking-[0.08em] text-[var(--muted)]">
            {EFFORTS.map((item) => (
              <span key={item} className={item === effort ? "text-[var(--text)]" : ""}>
                {effortLabel(item)}
              </span>
            ))}
          </div>
          <div className="mb-2 text-xs text-[var(--muted)]">Model</div>
          <div className="max-h-[240px] space-y-3 overflow-auto pr-1">
            {providers.map((item) => (
              <div key={item.id}>
                <div className="mb-1 flex items-center justify-between text-[10px] uppercase tracking-[0.1em] text-[var(--muted)]">
                  <span>{providerLabel(item.id)}</span>
                  <span className={item.auth.ready ? "text-emerald-300" : "text-amber-200/80"}>
                    {item.auth.ready ? "Ready" : "Setup"}
                  </span>
                </div>
                <div className="space-y-0.5">
                  {item.models.map((id) => {
                    const selected = item.id === provider && id === model;
                    return (
                      <button
                        key={`${item.id}-${id}`}
                        type="button"
                        className={`flex w-full items-center justify-between rounded-lg px-2 py-1.5 text-left text-xs ${
                          selected ? "bg-white/10 text-[var(--text)]" : "text-[var(--muted)] hover:bg-white/5 hover:text-[var(--text)]"
                        }`}
                        onClick={() => {
                          onSelect(item.id, id);
                          onOpenChange(false);
                        }}
                      >
                        <span className="truncate">{modelDisplayName(id)}</span>
                        {selected ? <span className="text-[var(--gold)]">✓</span> : null}
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
