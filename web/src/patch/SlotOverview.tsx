import type { Patch, SlotIndex } from "./types.ts";
import { SLOT_WAVE_ABBR } from "./types.ts";
import { slotColor } from "./colors.ts";
import { isCarrier } from "./connections.ts";
import { EnvelopeGraph } from "./EnvelopeGraph.tsx";
import classes from "./SlotOverview.module.css";

// A SlotOverview is a compact, clickable card in the overview strip. It shows
// just enough to recognize a slot at a glance — its number, role in the
// routing, a schematic envelope graph, and the three oscillator values —
// without the full parameter editor. Selecting it (click) promotes it to the
// detail panel.

export interface SlotOverviewProps {
  slot: SlotIndex;
  patch: Patch;
  active: boolean;
  onSelect: (s: SlotIndex) => void;
}

function fmt(n: number, decimals = 2): string {
  if (Number.isInteger(n)) return String(n);
  return n.toFixed(decimals);
}

export function SlotOverview({ slot, patch, active, onSelect }: SlotOverviewProps) {
  const color = slotColor(slot);
  const sp = patch.slotParams[slot]!;
  const env = patch.envParams[slot]!;
  const wave = patch.slotWaves[slot]!;

  const role = isCarrier(patch.connections.edges, slot) ? "car" : "mod";

  return (
    <button
      type="button"
      class={`${classes.root}${active ? ` ${classes.active}` : ""}`}
      style={{
        borderColor: color.accent,
        background: color.soft,
        ["--slot-accent" as string]: color.accent,
      }}
      onClick={() => onSelect(slot)}
      aria-pressed={active}
      title={`Slot ${slot} — click to edit`}
    >
      <div class={classes.head} style={{ color: color.text }}>
        <span class={classes.num}>{slot}</span>
        <span class={classes.headRight}>
          <span class={classes.wave}>{SLOT_WAVE_ABBR[wave]}</span>
          <span class={classes.role}>{role}</span>
        </span>
      </div>
      <EnvelopeGraph
        env={env}
        accent={color.accent}
        soft="var(--color-bg)"
        width={104}
        height={40}
      />
      <div class={classes.osc} style={{ color: color.text }}>
        <span title="Total level">TL {fmt(sp.tl)}</span>
        <span title="Frequency multiplier">ML {fmt(sp.ml, 1)}</span>
        <span title="Feedback">FB {fmt(sp.fb)}</span>
      </div>
    </button>
  );
}
