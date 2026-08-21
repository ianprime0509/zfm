import { useEffect, useRef } from "preact/hooks";
import { KEY_TO_MIDI } from "./keyboard.ts";

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

/**
 * Sets up keyboard handlers so the user can play notes like a piano keyboard.
 *
 * @param noteOn called when a key is pressed
 * @param noteOff called when a key is released
 */
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
