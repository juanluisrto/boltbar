import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { type ButtonHTMLAttributes, forwardRef } from "react";
import { cn } from "../../lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/20 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg]:size-4",
  {
    variants: {
      variant: {
        default: "bg-white/10 text-[var(--text)] hover:bg-white/15",
        gold: "bg-[var(--gold)] text-black hover:bg-[var(--gold)]",
        outline: "border border-white/10 bg-white/5 text-[var(--text)] hover:bg-white/10",
        ghost: "text-[var(--muted)] hover:bg-white/8 hover:text-[var(--text)]",
        chip: "border border-white/10 bg-white/6 text-xs text-[var(--text)] hover:bg-white/10",
      },
      size: {
        default: "h-9 px-3",
        sm: "h-8 rounded-lg px-2.5 text-xs",
        icon: "size-9 p-0 leading-none [&>svg]:block",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    return (
      <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
    );
  },
);
Button.displayName = "Button";

export { buttonVariants };
