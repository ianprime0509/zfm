import type { ButtonHTMLAttributes, ComponentChild } from "preact";
import classes from "./Button.module.css";

// A standard button used throughout the app. Consolidates the shared
// border/background/hover/disabled styling so call sites don't repeat it.
// Pass an icon, text, or both as children; choose a `variant` for a common
// shape, and layer on extra styles (e.g. a layout-specific modifier class)
// via `class`, which is composed after the base `.btn` class and any
// variant class.

export type ButtonVariant = "default" | "icon";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  children: ComponentChild;
  /** Visual shape. "icon" is a compact, muted button for standalone icons. */
  variant?: ButtonVariant;
}

export function Button({
  type = "button",
  class: className,
  variant = "default",
  children,
  ...rest
}: ButtonProps) {
  const variantClass = variant === "icon" ? classes.icon : undefined;
  const cls = [classes.btn, variantClass, className]
    .filter((c): c is string => Boolean(c))
    .join(" ");
  return (
    <button type={type} class={cls} {...rest}>
      {children}
    </button>
  );
}
