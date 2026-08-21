export const N_SLOTS = 8;

export type SlotIndex = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

/** See `Synth.Slot.Wave`. */
export type SlotWave = "sin" | "squ" | "tri" | "saw" | "noi";

export const SLOT_WAVES: SlotWave[] = ["sin", "squ", "tri", "saw", "noi"];

export function usesWs(wave: SlotWave): boolean {
  return wave === "squ" || wave === "noi";
}

export function wsRange(wave: SlotWave): { min: number; max: number } {
  if (wave === "noi") return { min: 1, max: 50 };
  return { min: 0.01, max: 0.99 };
}

export function normalizeWs(wave: SlotWave, ws: number): number {
  const { min, max } = wsRange(wave);
  if (ws >= min && ws <= max) return ws;
  if (wave === "squ") return 0.5;
  return Math.min(Math.max(ws, min), max);
}

/** See `Synth.Slot.UserParams`. */
export interface SlotParams {
  tl: number;
  ml: number;
  fb: number;
  ws: number;
}

/** See `Synth.Envelope.UserParams`. */
export interface EnvParams {
  ar: number;
  dr: number;
  sl: number;
  sr: number;
  rr: number;
}

/** Routing of the 8 slots as an edge matrix (`edges[from][to]`). */
export interface Connections {
  edges: boolean[][];
}

export interface Patch {
  name: string;
  connections: Connections;
  slotWaves: SlotWave[];
  slotParams: SlotParams[];
  envParams: EnvParams[];
  lfos: LfoState[];
}

export const SLOT_PARAMS_ZERO: SlotParams = { tl: 0, ml: 0, fb: 0, ws: 0 };
export const ENV_PARAMS_ZERO: EnvParams = { ar: 0, dr: 0, sl: 0, sr: 0, rr: 0 };
export const SLOT_WAVE_DEFAULT: SlotWave = "sin";

export function emptyConnections(): Connections {
  return { edges: Array.from({ length: N_SLOTS }, () => Array<boolean>(N_SLOTS).fill(false)) };
}

export function emptyPatch(): Patch {
  return {
    name: "",
    connections: emptyConnections(),
    slotWaves: Array.from({ length: N_SLOTS }, () => SLOT_WAVE_DEFAULT),
    slotParams: Array.from({ length: N_SLOTS }, () => ({ ...SLOT_PARAMS_ZERO })),
    envParams: Array.from({ length: N_SLOTS }, () => ({ ...ENV_PARAMS_ZERO })),
    lfos: defaultLfoStates(),
  };
}

export function clonePatch(p: Patch): Patch {
  return {
    name: p.name,
    connections: { edges: p.connections.edges.map((r) => [...r]) },
    slotWaves: [...p.slotWaves],
    slotParams: p.slotParams.map((s) => ({ ...s })),
    envParams: p.envParams.map((e) => ({ ...e })),
    lfos: p.lfos
      ? p.lfos.map((l) => ({
          ...l,
          params: { ...l.params, size: { ...l.params.size }, wave: { ...l.params.wave } },
        }))
      : defaultLfoStates(),
  };
}

/** Number of user-defined LFOs. */
export const N_LFOS = 4;

/** See `Module.Lfo.Wave`. */
export type LfoWave =
  | { con: Record<string, never> }
  | { sin: { freq: number } }
  | { exp: { mul: number } };

export type LfoWaveTag = "con" | "sin" | "exp";

/** What an LFO modulates. */
export type LfoTarget = "freq" | "pan" | "vol";

/** See `Module.Lfo`. */
export interface LfoParams {
  target: LfoTarget;
  size: { scale: number; offset: number };
  wave: LfoWave;
  trigger: "none" | "key_on";
  time_unit: "seconds" | "ticks";
  adjust: boolean;
}

export interface LfoState {
  enabled: boolean;
  params: LfoParams;
}

export function defaultLfoStates(): LfoState[] {
  return Array.from({ length: N_LFOS }, () => ({
    enabled: false,
    params: {
      target: "freq",
      size: { scale: 5, offset: 0 },
      wave: { sin: { freq: 5 } },
      trigger: "key_on",
      time_unit: "seconds",
      adjust: true,
    },
  }));
}
