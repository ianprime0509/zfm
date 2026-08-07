// Built-in patch and routing presets shown in the editor's header.

import type { Connections, EnvParams, Patch, SlotParams, SlotWave } from "./types.ts";
import { N_SLOTS, SLOT_WAVE_DEFAULT, defaultLfoStates, emptyConnections } from "./types.ts";

// --- Default patch: electric-piano from patches/patches.zfm ---
// @electric-piano 0 1, 2 3.
//   sine 0.7 11 3 0.00001 0 0 0 0.00001
//   sine 0.3 12 0 0.00001 0.5 0 0 0.00001
//   sine 0.7 1 0 0.00001 2 0.2 0 2
//   sine 1 1 0 0.00001 4 0 0 1

const electricPianoConnections: Connections = {
  edges: [
    [false, true, false, false, false, false, false, false], // 0 -> 1
    [false, false, false, false, false, false, false, false],
    [false, false, false, true, false, false, false, false], // 2 -> 3
    [false, false, false, false, false, false, false, false],
    [false, false, false, false, false, false, false, false],
    [false, false, false, false, false, false, false, false],
    [false, false, false, false, false, false, false, false],
    [false, false, false, false, false, false, false, false],
  ],
};

const electricPianoWaves: SlotWave[] = Array.from({ length: N_SLOTS }, () => SLOT_WAVE_DEFAULT);

const electricPianoSlots: SlotParams[] = [
  { tl: 0.7, ml: 11, fb: 3, ws: 0 },
  { tl: 0.3, ml: 12, fb: 0, ws: 0 },
  { tl: 0.7, ml: 1, fb: 0, ws: 0 },
  { tl: 1, ml: 1, fb: 0, ws: 0 },
  { tl: 0, ml: 0, fb: 0, ws: 0 },
  { tl: 0, ml: 0, fb: 0, ws: 0 },
  { tl: 0, ml: 0, fb: 0, ws: 0 },
  { tl: 0, ml: 0, fb: 0, ws: 0 },
];

const electricPianoEnvs: EnvParams[] = [
  { ar: 0.00001, dr: 0, sl: 0, sr: 0, rr: 0.00001 },
  { ar: 0.00001, dr: 0.5, sl: 0, sr: 0, rr: 0.00001 },
  { ar: 0.00001, dr: 2, sl: 0.2, sr: 0, rr: 2 },
  { ar: 0.00001, dr: 4, sl: 0, sr: 0, rr: 1 },
  { ar: 0, dr: 0, sl: 0, sr: 0, rr: 0 },
  { ar: 0, dr: 0, sl: 0, sr: 0, rr: 0 },
  { ar: 0, dr: 0, sl: 0, sr: 0, rr: 0 },
  { ar: 0, dr: 0, sl: 0, sr: 0, rr: 0 },
];

export const ELECTRIC_PIANO: Patch = {
  name: "electric-piano",
  connections: electricPianoConnections,
  slotWaves: electricPianoWaves,
  slotParams: electricPianoSlots,
  envParams: electricPianoEnvs,
  lfos: defaultLfoStates(),
};

// --- Routing presets (algorithm shapes only; slot params are preserved
//     when the user selects one). Names echo how the patch format reads. ---

export interface RoutingPreset {
  name: string;
  description: string;
  edges: boolean[][];
}

/** Build a blank edge matrix with the given `[from, to]` pairs set. */
function edgesFrom(pairs: ReadonlyArray<readonly [number, number]>): boolean[][] {
  const edges = emptyConnections().edges;
  for (const [from, to] of pairs) edges[from]![to] = true;
  return edges;
}

export const ROUTING_PRESETS: RoutingPreset[] = [
  {
    name: "None",
    description: "All slots are independent carriers.",
    edges: edgesFrom([]),
  },
  {
    name: "2-op (0→1)",
    description: "One modulator into one carrier.",
    edges: edgesFrom([[0, 1]]),
  },
  {
    name: "4-op chain (0→1→2→3)",
    description: "A single linear modulator stack.",
    edges: edgesFrom([
      [0, 1],
      [1, 2],
      [2, 3],
    ]),
  },
  {
    name: "Two stacks (0→1, 2→3)",
    description: "Two independent 2-op stacks.",
    edges: edgesFrom([
      [0, 1],
      [2, 3],
    ]),
  },
  {
    name: "Stacked carriers (0→1, 0→2)",
    description: "One modulator feeding two carriers.",
    edges: edgesFrom([
      [0, 1],
      [0, 2],
    ]),
  },
];
