import { useEffect, useMemo, useState, type Dispatch, type StateUpdater } from "preact/hooks";
import type { LfoState, Patch, SlotIndex } from "./types.ts";
import { defaultLfoStates, N_SLOTS } from "./types.ts";
import { ELECTRIC_PIANO, ROUTING_PRESETS } from "./presets.ts";
import { edgesEqual } from "./connections.ts";
import { slotColor } from "./colors.ts";
import { RoutingGraph } from "./RoutingGraph.tsx";
import { SlotCard } from "./SlotCard.tsx";
import { SlotOverview } from "./SlotOverview.tsx";
import { LfoPanel } from "./LfoPanel.tsx";
import { formatPatch } from "./format.ts";
import { CopyButton } from "../components/CopyButton.tsx";
import { usePatchSynth } from "./usePatchSynth.ts";
import { useSynthKeyboard } from "./useSynthKeyboard.ts";
import type { Synth } from "../synth.ts";
import classes from "./PatchEditor.module.css";

const PATCH_NAME_RE = /^[a-zA-Z0-9_-]*$/;

const isValidName = (v: string) => v.length > 0 && PATCH_NAME_RE.test(v);

// PatchEditor is the top-level component for editing a single synth voice
// algorithm (a Module.Patch). It pairs a routing graph (the "algorithm") with
// a strip of per-slot detail cards (the parameters).
//
// Design summary:
//   - Top: an overview strip of 8 compact SlotOverview cards (number, role,
//     envelope graph, osc values) giving an at-a-glance view of every slot;
//     clicking one selects it.
//   - Body: on wide views, the routing diagram (left) and the selected slot's
//     detail panel (right) are shown side by side. On narrow views the routing
//     diagram is hidden by default behind an expandable toggle, above the
//     slot details.
//   - The routing diagram is an 8x8 directed-edge grid that fully describes
//     the routing and makes the no-cycles constraint visible/enforced.
//   - A header offers routing presets.
//   - Below the body, an LfoPanel lets the user test the 4 user LFOs on the
//     patch while playing it with the keyboard.

export interface PatchEditorProps {
  initialPatch?: Patch;
  onChange?: Dispatch<StateUpdater<Patch>>;
  synth: Synth;
  disabled?: boolean;
}

export function PatchEditor({
  initialPatch = ELECTRIC_PIANO,
  onChange,
  synth,
  disabled = false,
}: PatchEditorProps) {
  const [patch, setPatch] = useState<Patch>(initialPatch);
  const [activeSlot, setActiveSlot] = useState<SlotIndex>(0);
  const [routingOpen, setRoutingOpen] = useState(false);
  const [lfos, setLfos] = useState<LfoState[]>(defaultLfoStates);

  // Keep the synth's voices in sync with the patch (and the test LFOs) and
  // let the physical keyboard play notes polyphonically (8 voices).
  const { noteOn, noteOff } = usePatchSynth(patch, synth, { disabled, lfos });
  useSynthKeyboard(noteOn, noteOff);

  // Keep the parent's copy of the patch in sync. We lift via an effect
  // rather than inside the `setPatch` updater, because the updater runs
  // during this component's render and re-entering a parent's setter from
  // there is unsafe.
  useEffect(() => {
    onChange?.(patch);
  }, [patch, onChange]);

  const matchingPreset = ROUTING_PRESETS.find((pr) =>
    edgesEqual(pr.edges, patch.connections.edges),
  );

  // Live MML source for the patch being edited, so the user can see (and
  // copy) exactly what the compiler would parse.
  const mml = useMemo(() => formatPatch(patch), [patch]);

  const applyPreset = (edges: boolean[][]) => {
    setPatch((p) => ({ ...p, connections: { edges: edges.map((r) => [...r]) } }));
  };

  const [nameDraft, setNameDraft] = useState<string>(initialPatch.name);
  const nameValid = isValidName(nameDraft);

  const handleNameChange = (value: string) => {
    setNameDraft(value);
    if (isValidName(value)) {
      setPatch((p) => ({ ...p, name: value }));
    }
  };

  return (
    <div class={classes.root}>
      <header class={classes.header}>
        <div class={classes.titleGroup}>
          <input
            class={`${classes.nameInput}${nameValid ? "" : ` ${classes.nameInputInvalid}`}`}
            type="text"
            value={nameDraft}
            onChange={(e) => handleNameChange(e.currentTarget.value)}
            title="Patch name (alphanumeric, hyphens, and underscores only)"
          />
        </div>
        <div class={classes.actions}>
          <label class={classes.preset}>
            <span class={classes.presetLabel}>algorithm</span>
            <select
              value={matchingPreset?.name ?? "custom"}
              onChange={(e) => {
                const pr = ROUTING_PRESETS.find((p) => p.name === e.currentTarget.value);
                if (pr) applyPreset(pr.edges);
              }}
            >
              {ROUTING_PRESETS.map((p) => (
                <option key={p.name} value={p.name}>
                  {p.name}
                </option>
              ))}
              {!matchingPreset && <option value="custom">custom</option>}
            </select>
          </label>
        </div>
      </header>

      <div class={classes.overview}>
        {Array.from({ length: N_SLOTS }, (_, i) => (
          <SlotOverview
            key={i}
            slot={i as SlotIndex}
            patch={patch}
            active={i === activeSlot}
            onSelect={setActiveSlot}
          />
        ))}
      </div>

      <div class={classes.body}>
        <section class={`${classes.routing}${routingOpen ? ` ${classes.open}` : ""}`}>
          <button
            type="button"
            class={classes.routingToggle}
            aria-expanded={routingOpen}
            onClick={() => setRoutingOpen((o) => !o)}
          >
            <span>Routing</span>
            <span class={classes.routingChevron}>{routingOpen ? "▾" : "▸"}</span>
          </button>
          <div class={classes.routingInner}>
            <RoutingGraph
              patch={patch}
              onChange={setPatch}
              activeSlot={activeSlot}
              onActiveSlot={setActiveSlot}
            />
          </div>
        </section>

        <section style={{ ["--active-accent" as string]: slotColor(activeSlot).accent }}>
          <SlotCard slot={activeSlot} patch={patch} onChange={setPatch} />
        </section>
      </div>

      <section class={classes.preview}>
        <div class={classes.previewHeader}>
          <span class={classes.previewTitle}>MML preview</span>
          <CopyButton text={mml} title="Copy MML to clipboard" />
        </div>
        <pre class={classes.previewMml}>{mml}</pre>
      </section>

      <LfoPanel lfos={lfos} onChange={setLfos} />
    </div>
  );
}
