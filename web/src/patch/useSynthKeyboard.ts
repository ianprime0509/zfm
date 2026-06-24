import { useEffect, useRef } from "preact/hooks";
import { KEY_TO_MIDI } from "./keyboard.ts";

// Attaches window-level keyboard listeners that play notes via the provided
// noteOn/noteOff callbacks. Uses KeyboardEvent.code (physical key position),
// so the layout is independent of the active keyboard layout (QWERTY,
// Dvorak, AZERTY, ...).
//
// - Key repeat (auto-repeat) is ignored; a held key triggers one note.
// - Notes are suppressed while focus is in a text-entry control (so typing
//   into the param number inputs still works).
// - Modifier chords (Ctrl/Cmd/Alt) are ignored so shortcuts stay available.
// - On window blur all held notes are released (keyups may otherwise be lost).

const TEXT_INPUT_TYPES = new Set(["text", "number", "search", "tel", "url", "email", "password"]);

function isTextEntryTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el) return false;
  const tag = el.tagName;
  if (tag === "TEXTAREA" || tag === "SELECT") return true;
  if (tag === "INPUT") {
    const type = (el as HTMLInputElement).type;
    // Range/checkbox/button inputs are fine to play through.
    return TEXT_INPUT_TYPES.has(type);
  }
  return (el as HTMLElement).isContentEditable;
}

export function useSynthKeyboard(
  noteOn: (midi: number) => void,
  noteOff: (midi: number) => void,
): void {
  const held = useRef<Set<number>>(new Set());

  useEffect(() => {
    const onDown = (e: KeyboardEvent) => {
      if (e.repeat) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (isTextEntryTarget(e.target)) return;
      const midi = KEY_TO_MIDI[e.code];
      if (midi === undefined) return;
      e.preventDefault();
      if (held.current.has(midi)) return;
      held.current.add(midi);
      noteOn(midi);
    };

    const onUp = (e: KeyboardEvent) => {
      const midi = KEY_TO_MIDI[e.code];
      if (midi === undefined) return;
      if (!held.current.delete(midi)) return;
      noteOff(midi);
    };

    const releaseAll = () => {
      for (const midi of held.current) noteOff(midi);
      held.current.clear();
    };

    window.addEventListener("keydown", onDown);
    window.addEventListener("keyup", onUp);
    window.addEventListener("blur", releaseAll);
    return () => {
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("keyup", onUp);
      window.removeEventListener("blur", releaseAll);
    };
  }, [noteOn, noteOff]);
}
