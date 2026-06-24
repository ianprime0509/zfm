import type { ComponentChild } from "preact";
import type { Dispatch, StateUpdater } from "preact/hooks";
import type { Patch, SlotIndex } from "./types.ts";
import { N_SLOTS } from "./types.ts";
import { slotColor } from "./colors.ts";
import { isCarrier, toggleEdge, wouldCycle } from "./connections.ts";
import classes from "./RoutingGraph.module.css";

// The RoutingGraph is the centerpiece of the editor: an 8x8 grid where each
// cell is a directed edge button (row `from` modulates column `to`).
//
// We deliberately use a grid rather than a free-form node canvas:
//   - It makes the "no cycles" constraint trivially enforceable (we can show
//     which cells are illegal), and the whole topology is visible at once.
//   - With only 8 slots, a node canvas would be cluttered for little gain.
//
// Rows/columns are colored by slot so the user can correlate a cell with the
// detail cards. The diagonal (self-loops) is permanently disabled, as is any
// cell that would introduce a cycle.
//
// The grid is laid out with CSS grid: a single (N_SLOTS + 1) x (N_SLOTS + 1)
// grid holding the corner label, column headers, row headers, and cells in
// document order.

export interface RoutingGraphProps {
  patch: Patch;
  onChange: Dispatch<StateUpdater<Patch>>;
  activeSlot: SlotIndex;
  onActiveSlot: (s: SlotIndex) => void;
}

export function RoutingGraph({ patch, onChange, activeSlot, onActiveSlot }: RoutingGraphProps) {
  const { edges } = patch.connections;

  const headerCell = (axis: "col" | "row", i: number) => (
    <div
      key={`${axis}-${i}`}
      class={`${classes.head}${i === activeSlot ? ` ${classes.active}` : ""}`}
      style={{ color: slotColor(i).accent }}
      onClick={() => onActiveSlot(i as SlotIndex)}
      title={`Slot ${i}${isCarrier(edges, i as SlotIndex) ? " (carrier)" : " (modulator)"}`}
      role={axis === "col" ? "columnheader" : "rowheader"}
    >
      {i}
    </div>
  );

  const colHeaders: ComponentChild[] = [];
  for (let to = 0; to < N_SLOTS; to++) {
    colHeaders.push(headerCell("col", to));
  }

  const rows: ComponentChild[] = [];
  for (let from = 0; from < N_SLOTS; from++) {
    const c = slotColor(from);

    rows.push(headerCell("row", from));

    for (let to = 0; to < N_SLOTS; to++) {
      if (from === to) {
        rows.push(<div key={`${from}-${to}`} class={classes.diag} role="gridcell" />);
        continue;
      }
      const on = edges[from]![to];
      const illegal = wouldCycle(edges, from as SlotIndex, to as SlotIndex);
      const disabled = illegal && !on;
      rows.push(
        <div key={`${from}-${to}`} class={classes.cell} role="gridcell">
          <button
            type="button"
            class={`${classes.btn}${disabled ? ` ${classes.illegal}` : ""}`}
            style={
              on
                ? { background: c.accent, borderColor: c.accent }
                : disabled
                  ? undefined
                  : { borderColor: c.accent }
            }
            disabled={disabled}
            aria-label={`${from} modulates ${to}`}
            aria-pressed={on}
            onClick={() =>
              onChange((p) => ({
                ...p,
                connections: toggleEdge(p.connections, from as SlotIndex, to as SlotIndex),
              }))
            }
            title={
              disabled
                ? `Cannot connect ${from} → ${to} (would create a cycle)`
                : on
                  ? `${from} → ${to} (click to remove)`
                  : `${from} → ${to} (click to add)`
            }
          />
        </div>,
      );
    }
  }

  return (
    <div class={classes.grid} role="grid" aria-rowcount={N_SLOTS + 1} aria-colcount={N_SLOTS + 1}>
      <div class={classes.corner} role="rowheader">
        from \ to
      </div>
      {colHeaders}
      {rows}
    </div>
  );
}
