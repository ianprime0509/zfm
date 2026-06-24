import { useEffect, useMemo, useState } from "preact/hooks";
import { linter } from "@codemirror/lint";
import CodeMirror from "@uiw/react-codemirror";
import type { Compiler } from "./compiler.ts";
import classes from "./TrackEditor.module.css";

export interface TrackEditorProps {
  compiler: Compiler;
  value: string;
  onChange: (value: string) => void;
}

export function TrackEditor({ compiler, value, onChange }: TrackEditorProps) {
  const zfmLinter = useMemo(
    () =>
      linter(async (view) => {
        const valid = await compiler.compile(view.state.doc.toString());
        if (valid) return [];
        const errors = await compiler.errors();
        return errors.map((err) => ({
          // TODO: units returned by the compiler are UTF-8 code units (bytes), but CodeMirror expects UTF-16 code units
          from: err.span.start,
          to: err.span.end,
          severity: "error",
          message: err.part ? `part ${err.part}: ${err.message}` : err.message,
        }));
      }),
    [compiler],
  );

  // CodeMirror has its own theme system separate from our CSS, so drive it from
  // the same prefers-color-scheme media query that our `light-dark()` tokens
  // resolve against.
  const prefersDark =
    typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches;
  const [editorTheme, setEditorTheme] = useState<"light" | "dark">(prefersDark ? "dark" : "light");

  useEffect(() => {
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setEditorTheme(mq.matches ? "dark" : "light");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  return (
    <CodeMirror
      className={classes.root}
      theme={editorTheme}
      width="100%"
      height="100%"
      value={value}
      onChange={onChange}
      extensions={[zfmLinter]}
    />
  );
}
