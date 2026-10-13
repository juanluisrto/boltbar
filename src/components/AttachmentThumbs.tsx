import { fileKindLabel } from "../lib/models";
import { attachmentPreviewUrl, isImageAttachment } from "../lib/attachments";
import type { Attachment } from "../types";

export function AttachmentThumbs({
  attachments,
  onRemove,
}: {
  attachments: Attachment[];
  onRemove: (index: number) => void;
}) {
  if (attachments.length === 0) {
    return null;
  }
  return (
    <div className="flex flex-wrap gap-2 px-4 pb-2">
      {attachments.map((att, idx) => {
        const image = isImageAttachment(att);
        const preview = image ? attachmentPreviewUrl(att) : null;
        return (
          <div
            key={`${att.name}-${idx}`}
            className="group relative"
          >
            {image && preview ? (
              <div className="h-[72px] w-[72px] overflow-hidden rounded-xl border border-white/10 bg-black/40">
                <img src={preview} alt={att.name} className="h-full w-full object-cover" />
              </div>
            ) : (
              <div className="flex h-[72px] min-w-[132px] max-w-[200px] items-center gap-2 rounded-xl border border-white/10 bg-white/5 px-3">
                <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-[var(--gold-dim)] text-[10px] font-semibold tracking-wide text-[var(--gold)]">
                  {fileKindLabel(att.name, att.mime)}
                </span>
                <span className="min-w-0 truncate text-xs text-[var(--text)]">{att.name}</span>
              </div>
            )}
            <button
              type="button"
              aria-label={`Remove ${att.name}`}
              className="absolute -right-1.5 -top-1.5 flex h-5 w-5 items-center justify-center rounded-full border border-white/15 bg-[#1a1a1c] text-[11px] text-[var(--text)] shadow"
              onClick={() => onRemove(idx)}
            >
              ×
            </button>
          </div>
        );
      })}
    </div>
  );
}
