import type { ButtonHTMLAttributes, ComponentChild } from "preact";
import classes from "./Button.module.css";

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
