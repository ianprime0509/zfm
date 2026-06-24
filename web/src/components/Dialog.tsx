import { useEffect, useRef } from "preact/hooks";
import type { ComponentChild, JSX } from "preact";
import { X } from "lucide-preact";
import { Button } from "./Button.tsx";
import classes from "./Dialog.module.css";

// A thin wrapper around the native <dialog> element that consolidates the
// open/close wiring, backdrop-click, and Escape handling that the app
// repeats across every modal. The <dialog> is always mounted so its ref is
// stable; an effect drives `showModal`/`close` from the `open` prop, keeping
// component state the single source of truth and avoiding native desync.
//
// All close paths (the close button, a backdrop click, and Escape) funnel
// through `onClose`, so the caller only needs to handle that single event.

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
  const onClick = (e: JSX.TargetedMouseEvent<HTMLDialogElement>) => {
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
