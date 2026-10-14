import { useEffect, useRef } from "react";

export function ResizeHandle({
  value,
  min,
  max,
  invert = false,
  onChange,
  onCommit,
}: {
  value: number;
  min: number;
  max: number;
  invert?: boolean;
  onChange: (next: number) => void;
  onCommit?: (next: number) => void;
}) {
  const start = useRef<{ y: number; height: number } | null>(null);
  const latest = useRef(value);
  latest.current = value;

  useEffect(() => {
    const move = (event: MouseEvent) => {
      if (!start.current) {
        return;
      }
      const delta = invert
        ? start.current.y - event.screenY
        : event.screenY - start.current.y;
      const next = Math.min(max, Math.max(min, start.current.height + delta));
      latest.current = next;
      onChange(next);
    };
    const up = () => {
      if (start.current) {
        onCommit?.(latest.current);
      }
      start.current = null;
      document.body.style.cursor = "";
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    return () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
  }, [invert, max, min, onChange, onCommit]);

  return (
    <button
      type="button"
      aria-label="Drag to resize the input"
      className="flex h-3 w-full cursor-row-resize items-center justify-center border-0 bg-transparent p-0"
      onMouseDown={(event) => {
        start.current = { y: event.screenY, height: value };
        document.body.style.cursor = "row-resize";
        event.preventDefault();
      }}
    >
      <span className="block h-1 w-12 rounded-full bg-white/15" />
    </button>
  );
}
