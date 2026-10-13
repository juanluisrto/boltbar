import { type ButtonHTMLAttributes, forwardRef } from "react";
import { cn } from "../../lib/utils";

const variants = {
  outline:
    "border border-white/12 bg-white/6 text-[var(--text)] hover:bg-white/10",
  gold: "border-0 bg-[var(--gold)] text-[#1a1408] hover:bg-[#f7c45a]",
  ghost: "border-0 bg-transparent text-[var(--muted)] hover:bg-white/8 hover:text-[var(--text)]",
} as const;

export type IconButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: keyof typeof variants;
};

export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(
  ({ className, variant = "outline", type = "button", ...props }, ref) => (
    <button
      ref={ref}
      type={type}
      className={cn(
        "inline-flex size-9 shrink-0 items-center justify-center rounded-full p-0 leading-[0]",
        "text-[0px] [font-size:0] [line-height:0]",
        "transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/25",
        "disabled:pointer-events-none disabled:opacity-40",
        "[&>svg]:block [&>svg]:shrink-0",
        variants[variant],
        className,
      )}
      {...props}
    />
  ),
);
IconButton.displayName = "IconButton";
