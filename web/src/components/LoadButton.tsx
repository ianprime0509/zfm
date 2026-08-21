import { useRef } from "preact/hooks";
import type { TargetedEvent } from "preact";
import { FolderOpen } from "lucide-preact";
import { Button } from "./Button.tsx";
import classes from "./LoadButton.module.css";

export interface LoadButtonProps {
  title: string;
  /** Called with the chosen file after it is picked. */
  onFile: (file: File) => void;
  /** Value for the input's `accept` attribute. */
  accept?: string;
}

export function LoadButton({ title, onFile, accept = ".zfm" }: LoadButtonProps) {
  const fileInputRef = useRef<HTMLInputElement>(null);

  const onChange = (e: TargetedEvent<HTMLInputElement>) => {
    const input = e.currentTarget;
    const file = input.files?.[0];
    // Reset the input so selecting the same file again re-fires change.
    input.value = "";
    if (!file) return;
    onFile(file);
  };

  return (
    <>
      <Button title={title} onClick={() => fileInputRef.current?.click()}>
        <FolderOpen />
      </Button>
      <input
        ref={fileInputRef}
        type="file"
        accept={accept}
        onChange={onChange}
        class={classes.fileInput}
      />
    </>
  );
}
