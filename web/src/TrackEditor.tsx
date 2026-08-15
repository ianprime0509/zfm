import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import { linter } from "@codemirror/lint";
import CodeMirror, {
  Decoration,
  EditorView,
  ExternalChange,
  RangeSetBuilder,
  StateEffect,
  StateField,
  type DecorationSet,
} from "@uiw/react-codemirror";
import type { Compiler } from "./compiler.ts";
import { zfm } from "./mml.ts";
import { textDiff } from "./textDiff.ts";
import classes from "./TrackEditor.module.css";

export interface TrackEditorProps {
  compiler: Compiler;
  value: string;
  onChange: (value: string) => void;
  readOnly?: boolean;
  currentCommandSpans?: (number[] | null)[] | null;
}

// One distinct highlight color per part (parts cycle through these when there
// are more parts than colors). Low-alpha so the code underneath stays legible.
const PART_COLORS = [
  "rgba(255, 99, 132, 0.35)",
  "rgba(54, 162, 235, 0.35)",
  "rgba(75, 192, 192, 0.35)",
  "rgba(255, 159, 64, 0.35)",
  "rgba(153, 102, 255, 0.35)",
  "rgba(255, 205, 86, 0.35)",
  "rgba(255, 182, 193, 0.45)",
  "rgba(0, 200, 150, 0.35)",
];

// Effect carrying the latest set of per-part command spans (or null when
// nothing is playing). `(number[] | null)[] | null`.
const setCommandSpans = StateEffect.define<(number[] | null)[] | null>();

// Highlights the range of source positions of the currently executing command
// of each part. `null` (no running command) for a part yields no decoration.
const commandSpanField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(decorations, tr) {
    let spans: (number[] | null)[] | null = undefined as never;
    for (const effect of tr.effects) {
      if (effect.is(setCommandSpans)) spans = effect.value;
    }
    if (spans === undefined) return decorations;

    const builder = new RangeSetBuilder<Decoration>();
    if (spans) {
      spans.forEach((span, part) => {
        if (!span) return;
        const color = PART_COLORS[part % PART_COLORS.length];
        builder.add(
          span[0],
          span[1],
          Decoration.mark({ attributes: { style: `background: ${color}` } }),
        );
      });
    }
    return builder.finish();
  },
  provide: (f) => EditorView.decorations.from(f),
});

export function TrackEditor({
  compiler,
  value,
  onChange,
  readOnly = false,
  currentCommandSpans = null,
}: TrackEditorProps) {
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

  const viewRef = useRef<EditorView | null>(null);
  useEffect(() => {
    viewRef.current?.dispatch({ effects: setCommandSpans.of(currentCommandSpans) });
  }, [currentCommandSpans]);

  // The editor's document is authoritative for text the user types: those
  // changes flow out through `onChange` and must never be pushed back in, or a
  // stale parent snapshot can overwrite keystrokes that landed after it was
  // taken (the parent's render plus its post-paint effects span frames, while
  // typing happens between them). `value` is therefore only written into the
  // editor when it differs from the current document — an external replacement
  // such as loading a track or inserting a patch — and it is applied
  // synchronously during commit (layout effect) so no keystroke can slip in
  // between the parent render and the write-back. The `value` handed to
  // CodeMirror itself stays fixed at the mount-time content, which keeps the
  // wrapper's own post-paint value-sync effect dormant.
  const [initialValue] = useState(value);
  useLayoutEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const doc = view.state.doc.toString();
    if (value === doc) return;
    view.dispatch({
      changes: textDiff(doc, value),
      annotations: [ExternalChange.of(true)],
    });
  }, [value]);

  // Keep the extension list stable across renders; a fresh array every render
  // makes the wrapper reconfigure the whole editor state on each keystroke.
  const extensions = useMemo(() => [zfmLinter, commandSpanField, zfm], [zfmLinter]);

  return (
    <CodeMirror
      className={classes.root}
      theme={editorTheme}
      width="100%"
      height="100%"
      value={initialValue}
      onChange={onChange}
      editable={!readOnly}
      extensions={extensions}
      onCreateEditor={(view) => {
        viewRef.current = view;
      }}
    />
  );
}
