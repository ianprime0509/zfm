import { useEffect, useId, useState } from "preact/hooks";
import classes from "./ParamField.module.css";

// A ParamField is a labeled numeric field with a slider and a text input that
// stay in sync. We keep them independent (no derived state) so typing a value
// and dragging the slider both feel responsive.
//
// `log` selects a logarithmic slider mapping, which is essential for the
// envelope times (ar/dr/sr/rr) — these range over many orders of magnitude
// (e.g. 0.0001 .. 10 seconds).
//
// `step` is shared by the linear slider and the numeric input: it sets both
// the slider's resolution and the numeric input's step increment (which
// drives the stepper buttons and arrow-key nudges). For the log rate fields
// we pass no `step` (numeric "any"), since fixed stepper increments are
// meaningless on a log-scale value.

export interface ParamFieldProps {
  label: string;
  value: number;
  onChange: (v: number) => void;
  min: number;
  max: number;
  step?: number;
  /** When true, the slider position is logarithmic between min and max.
   *  Requires min > 0. */
  log?: boolean;
  /** Optional CSS accent color (inherits slot color when provided). */
  accent?: string;
  title?: string;
}

export function ParamField({
  label,
  value,
  onChange,
  min,
  max,
  step,
  log = false,
  accent,
  title,
}: ParamFieldProps) {
  const id = useId();

  // Internal text state for the number input so the UI always reflects what
  // the user is typing (including an empty box while backspacing). We only
  // commit a parsed number back up via `onChange` when the text parses to a
  // finite value. We resync from the `value` prop whenever it changes from
  // elsewhere (slider drag, parent) and doesn't match what's already shown.
  const [text, setText] = useState(() => String(value));
  useEffect(() => {
    setText((cur) => {
      const parsed = parseFloat(cur);
      if (Number.isNaN(parsed) || parsed !== value) return String(value);
      return cur;
    });
  }, [value]);

  const onTextChange = (raw: string) => {
    setText(raw);
    const parsed = parseFloat(raw);
    if (Number.isFinite(parsed)) onChange(parsed);
  };

  const toSlider = (v: number): number => {
    if (!log) return v;
    const lo = Math.max(min, 1e-9);
    const clamped = Math.min(Math.max(v, lo), max);
    const t = Math.log(clamped / lo) / Math.log(max / lo);
    return t * 100;
  };

  const fromSlider = (s: number): number => {
    if (!log) return s;
    const lo = Math.max(min, 1e-9);
    const t = s / 100;
    return lo * Math.pow(max / lo, t);
  };

  return (
    <div class={classes.root} title={title ?? `${label}: ${value}`}>
      <label class={classes.label} htmlFor={id}>
        {label}
      </label>
      <input
        class={classes.slider}
        id={id}
        type="range"
        min={log ? 0 : min}
        max={log ? 100 : max}
        step={log ? 0.1 : step}
        value={toSlider(value)}
        onChange={(e) => onChange(fromSlider(parseFloat(e.currentTarget.value)))}
        style={accent ? { accentColor: accent } : undefined}
      />
      <input
        class={classes.number}
        type="number"
        min={min}
        max={max}
        step={step ?? "any"}
        value={text}
        onChange={(e) => onTextChange(e.currentTarget.value)}
        style={accent ? { borderColor: accent } : undefined}
      />
    </div>
  );
}
