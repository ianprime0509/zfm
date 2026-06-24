import { useEffect, useRef, useState } from "preact/hooks";
import { ClipboardCheck, ClipboardCopy } from "lucide-preact";
import { Button } from "./Button.tsx";

// A compact icon button that copies `text` to the clipboard and briefly
// swaps to a check icon on success, so the user gets feedback that the copy
// happened. Encapsulates the clipboard call, the icon swap, and the reset
// timer (including cleanup on unmount) so call sites don't repeat it.
//
// Repeated clicks while the check is showing reset the timer, keeping the
// confirmation visible for a full interval after the most recent copy.

export interface CopyButtonProps {
  text: string;
  title?: string;
  /** Lucide icon size in pixels. */
  size?: number;
}

/** How long the confirmation (check) icon stays visible after a copy. */
const CONFIRM_MS = 1000;

export function CopyButton({ text, title = "Copy to clipboard", size = 14 }: CopyButtonProps) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => () => clearTimeout(timer.current), []);

  const onClick = () => {
    navigator.clipboard.writeText(text).then(
      () => {
        setCopied(true);
        clearTimeout(timer.current);
        timer.current = setTimeout(() => setCopied(false), CONFIRM_MS);
      },
      () => {
        // Ignore clipboard failures (e.g. non-secure context); leave the
        // copy icon in place so there's no false confirmation.
      },
    );
  };

  return (
    <Button variant="icon" title={title} onClick={onClick}>
      {copied ? <ClipboardCheck size={size} /> : <ClipboardCopy size={size} />}
    </Button>
  );
}
