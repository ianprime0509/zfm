import { useEffect, useRef, useState } from "preact/hooks";
import type { JSX } from "preact";
import { FolderOpen, Minus, Plus, Download } from "lucide-preact";
import { PatchEditor } from "../patch/PatchEditor.tsx";
import { ELECTRIC_PIANO } from "../patch/presets.ts";
import { usePatchSynth } from "../patch/usePatchSynth.ts";
import { useSynthKeyboard } from "../patch/useSynthKeyboard.ts";
import { type Patch } from "../patch/types.ts";
import type { Compiler } from "../compiler.ts";
import type { Synth } from "../synth.ts";
import { Dialog } from "../components/Dialog.tsx";
import { Button } from "../components/Button.tsx";
import { downloadText } from "../download.ts";
import { formatBank } from "../patch/format.ts";
import classes from "./BankEditor.module.css";

// A BankEditor manages a collection of patches (a "bank"). It shows a
// selectable list of patches; the selected patch is playable via the
// physical keyboard (the same mechanism used by PatchEditor). Each row has
// an "edit" button that opens PatchEditor in a native <dialog> modal;
// closing the modal writes the edited patch back into the bank. The header
// offers add/remove controls. Adding a new patch appends an
// electric-piano-prefilled patch named "new-patch".

export type Bank = Patch[];

/** Deep-clone a patch so bank entries are independent of their source. */
function clonePatch(p: Patch): Patch {
  return {
    name: p.name,
    connections: { edges: p.connections.edges.map((r) => [...r]) },
    slotWaves: [...p.slotWaves],
    slotParams: p.slotParams.map((s) => ({ ...s })),
    envParams: p.envParams.map((e) => ({ ...e })),
  };
}

/** Build a fresh "new-patch": electric-piano parameters, renamed. */
function newPatch(): Patch {
  return { ...clonePatch(ELECTRIC_PIANO), name: "new-patch" };
}

/**
 * Invisible mount that wires the keyboard to the synth for a single patch.
 * Mounted only while no PatchEditor modal is open, so the keyboard drives
 * exactly one patch at a time (the modal's PatchEditor attaches its own
 * listeners while it is mounted).
 */
function PatchKeyboard({
  patch,
  synth,
  disabled,
}: {
  patch: Patch;
  synth: Synth;
  disabled: boolean;
}) {
  const { noteOn, noteOff } = usePatchSynth(patch, synth, { disabled });
  useSynthKeyboard(noteOn, noteOff);
  return null;
}

export interface BankEditorProps {
  initialBank?: Bank;
  compiler: Compiler;
  synth: Synth;
  disabled?: boolean;
  /** Called when a patch is double-clicked; receives the clicked patch. */
  onInsertPatch?: (patch: Patch) => void;
  /** Called with the current bank whenever it changes. */
  onChange?: (bank: Bank) => void;
}

export function BankEditor({
  initialBank = [clonePatch(ELECTRIC_PIANO)],
  compiler,
  synth,
  disabled = false,
  onInsertPatch,
  onChange,
}: BankEditorProps) {
  const [bank, setBank] = useState<Bank>(initialBank);
  const [selected, setSelected] = useState(0);
  // Index of the patch being edited in the modal, or null when closed.
  const [editingIndex, setEditingIndex] = useState<number | null>(null);
  // Draft of the patch under edit; the modal PatchEditor writes here via
  // onChange, and we commit it to the bank when the modal closes.
  const [editingDraft, setEditingDraft] = useState<Patch>(initialBank[0]!);

  // Notify the parent whenever the bank changes so it can persist it.
  useEffect(() => {
    onChange?.(bank);
  }, [bank, onChange]);

  const [loadError, setLoadError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const addPatch = () => {
    setBank((b) => {
      const next = [...b, newPatch()];
      setSelected(next.length - 1);
      return next;
    });
  };

  const removeSelected = () => {
    setBank((b) => {
      if (b.length === 0) return b;
      const idx = Math.min(selected, b.length - 1);
      const next = b.filter((_, i) => i !== idx);
      // Keep selection in range after removal.
      setSelected((s) => (next.length === 0 ? 0 : Math.min(s, next.length - 1)));
      return next;
    });
  };

  const openEdit = (i: number) => {
    setEditingDraft(clonePatch(bank[i]!));
    setEditingIndex(i);
  };

  // Load bank: prompt for a .zfm file, compile it, and (on success) replace
  // the bank with the module's patches. Compilation errors are surfaced in a
  // modal instead of clobbering the bank.
  const loadBank = async (e: JSX.TargetedEvent<HTMLInputElement>) => {
    const file = e.currentTarget.files?.[0];
    // Reset the input so selecting the same file again re-fires change.
    e.currentTarget.value = "";
    if (!file) return;
    const src = await file.text();
    const ok = await compiler.compile(src);
    if (!ok) {
      const errors = await compiler.errors();
      setLoadError(
        errors
          .map((err) => (err.part ? `part ${err.part}: ${err.message}` : err.message))
          .join("\n"),
      );
      return;
    }
    const patches = (await compiler.patches()).map(clonePatch);
    setBank(patches);
    setSelected(0);
  };

  const selectedPatch = bank[selected] ?? bank[0] ?? null;

  return (
    <div class={classes.root}>
      <header class={classes.header}>
        <h1 class={classes.title}>Bank</h1>
        <div class={classes.actions}>
          <Button title="Load bank" onClick={() => fileInputRef.current?.click()}>
            <FolderOpen />
          </Button>
          <Button
            title="Download bank"
            disabled={bank.length === 0}
            onClick={() => downloadText("bank.zfm", formatBank(bank))}
          >
            <Download />
          </Button>
          <input
            ref={fileInputRef}
            type="file"
            accept=".zfm"
            onChange={loadBank}
            class={classes.fileInput}
          />
          <Button onClick={addPatch} title="Add patch">
            <Plus />
          </Button>
          <Button onClick={removeSelected} disabled={bank.length === 0} title="Remove selected">
            <Minus />
          </Button>
        </div>
      </header>

      {bank.length === 0 ? (
        <p class={classes.empty}>The bank is empty. Use "Add patch" to create one.</p>
      ) : (
        <ul class={classes.list}>
          {bank.map((patch, i) => (
            <li key={i} class={`${classes.row}${i === selected ? ` ${classes.selected}` : ""}`}>
              <button
                type="button"
                class={classes.selectBtn}
                onClick={() => setSelected(i)}
                onDblClick={() => onInsertPatch?.(patch)}
                aria-pressed={i === selected}
              >
                <span class={classes.index}>{i}</span>
                <span class={classes.name}>{patch.name}</span>
              </button>
              <button type="button" class={classes.editBtn} onClick={() => openEdit(i)}>
                Edit
              </button>
            </li>
          ))}
        </ul>
      )}

      {/* Keyboard play wires up only while the modal is closed, so the
          modal's PatchEditor is the sole keyboard driver while editing. */}
      {editingIndex === null && selectedPatch && (
        <PatchKeyboard patch={selectedPatch} synth={synth} disabled={disabled} />
      )}

      {/* Commit the draft into the bank on close. All close paths (Done
          button, backdrop click, Escape) funnel through here. */}
      <Dialog
        open={editingIndex !== null}
        onClose={() => {
          setEditingIndex((idx) => {
            if (idx !== null) {
              const i = idx;
              const draft = editingDraft;
              setBank((b) => b.map((p, j) => (j === i ? draft : p)));
            }
            return null;
          });
        }}
        title={`Edit patch ${editingIndex ?? ""}`}
        closeTitle="Done"
      >
        {/* `key` remounts the editor per edit so it adopts the freshly cloned
            draft rather than carrying over internal state from a previously
            edited patch. */}
        <PatchEditor
          key={editingIndex ?? 0}
          initialPatch={editingDraft}
          onChange={setEditingDraft}
          synth={synth}
          disabled={disabled}
        />
      </Dialog>

      <Dialog
        open={loadError !== null}
        onClose={() => setLoadError(null)}
        title="Failed to load bank"
        closeTitle="Dismiss"
      >
        <pre class={classes.errorBody}>{loadError}</pre>
      </Dialog>
    </div>
  );
}
