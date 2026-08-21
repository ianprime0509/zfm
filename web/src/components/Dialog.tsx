import { useEffect, useRef } from "preact/hooks";
import type { ComponentChild, TargetedMouseEvent } from "preact";
import { X } from "lucide-preact";
import { Button } from "./Button.tsx";
import classes from "./Dialog.module.css";

export interface DialogProps {
  /** Whether the dialog is currently open. */
  open: boolean;
  /** Called for every close path (button, backdrop click, Escape). */
  onClose: () => void;
  /** Title shown in the modal header. */
  title: ComponentChild;
  /** `title` attribute for the close button. */
  closeTitle?: string;
  /** Body content rendered inside the modal. */
  children: ComponentChild;
}

export function Dialog({ open, onClose, title, closeTitle = "Close", children }: DialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open) {
      if (!dialog.open) dialog.showModal();
    } else {
      if (dialog.open) dialog.close();
    }
  }, [open]);

  // Backdrop click: a click on a <dialog> (showModal backdrop) has the
  // dialog itself as the target. Ignore clicks that land on descendant
  // content.
  const onClick = (e: TargetedMouseEvent<HTMLDialogElement>) => {
    if (e.target === dialogRef.current) onClose();
  };

  // Escape: prevent the native close so our state-driven close takes over,
  // keeping state in sync.
  const onCancel = (e: Event) => {
    e.preventDefault();
    onClose();
  };

  return (
    <dialog ref={dialogRef} class={classes.modal} onClick={onClick} onCancel={onCancel}>
      {open && (
        <div class={classes.modalInner}>
          <div class={classes.modalHeader}>
            <span class={classes.modalTitle}>{title}</span>
            <Button onClick={onClose} title={closeTitle}>
              <X />
            </Button>
          </div>
          <div class={classes.modalBody}>{children}</div>
        </div>
      )}
    </dialog>
  );
}
