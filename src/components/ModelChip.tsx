import { modelDisplayName } from "../lib/models";
import {
  EFFORTS,
  effortLabel,
  providerLabel,
  type ProviderInfo,
  type ProviderKind,
  type ThinkingEffort,
} from "../types";
import { Button } from "./ui/button";
import { CheckIcon, ChevronDownIcon } from "./ui/icon";
import { Popover, PopoverContent, PopoverTrigger } from "./ui/popover";
import { Slider } from "./ui/slider";

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
  const effortIndex = Math.max(0, EFFORTS.indexOf(effort));

  return (
    <Popover open={open} onOpenChange={onOpenChange}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="chip"
          size="sm"
          className="h-9 max-w-full rounded-full px-3"
          aria-expanded={open}
        >
          <span className="text-[var(--muted)]">{effortLabel(effort)}</span>
          <span className="text-white/20">·</span>
          <span className="max-w-[160px] truncate">{modelDisplayName(model)}</span>
          <ChevronDownIcon size={12} className="text-[var(--muted)]" />
        </Button>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" collisionPadding={14}
        onEscapeKeyDown={(event) => { event.preventDefault(); onOpenChange(false); }}>
        <div className="mb-2 flex items-center justify-between text-xs">
          <span className="text-[var(--muted)]">Thinking effort</span>
          <span className="text-[var(--text)]">{effortLabel(effort)}</span>
        </div>
        <Slider
          min={0}
          max={2}
          step={1}
          value={[effortIndex]}
          aria-label="Thinking effort"
          className="mb-1"
          onValueChange={(value) => {
            const next = EFFORTS[value[0] ?? 1] ?? "medium";
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
                    <Button
                      key={`${item.id}-${id}`}
                      type="button"
                      variant="ghost"
                      className={`h-auto w-full justify-between rounded-lg px-2 py-1.5 text-xs font-normal ${
                        selected ? "bg-white/10 text-[var(--text)]" : ""
                      }`}
                      onClick={() => {
                        onSelect(item.id, id);
                        onOpenChange(false);
                      }}
                    >
                      <span className="truncate">{modelDisplayName(id)}</span>
                      {selected ? <CheckIcon size={14} className="text-[var(--gold)]" /> : null}
                    </Button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}
