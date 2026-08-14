export const N_SLOTS = 8;

export type SlotIndex = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

/** Waveform of a slot oscillator, mirroring core Synth.Slot.Wave.
 *  The string names match the Zig enum tags, which is how the wave is
 *  spelled in MML and how the compiler serializes it to JSON. */
export type SlotWave = "sin" | "squ" | "tri" | "saw" | "noi";

export const SLOT_WAVES: SlotWave[] = ["sin", "squ", "tri", "saw", "noi"];

/** Whether a waveform uses the wave-specific (WS) parameter. Mirrors core
 *  `Synth.Slot.Wave.usesWs`: `squ` (duty cycle) and `noi` (band-pass Q)
 *  use it; `sin`, `tri`, and `saw` do not. */
export function usesWs(wave: SlotWave): boolean {
  return wave === "squ" || wave === "noi";
}

/** Valid slider range for the WS parameter on a given waveform. `squ`:
 *  duty cycle in [0.01, 0.99] — 0 and 1 produce a constant DC offset
 *  rather than a wave, so they are excluded. `noi`: band-pass filter
 *  quality factor (Q) in [1, 50] (Q must be > 0 to avoid division by zero
 *  in the bi-quad filter). The range for `sin`, `tri`, and `saw` is
 *  unused (WS is not displayed). */
export function wsRange(wave: SlotWave): { min: number; max: number } {
  if (wave === "noi") return { min: 1, max: 50 };
  return { min: 0.01, max: 0.99 };
}

/** Normalize a WS value to be valid for `wave`, used when a slot switches to
 *  a waveform that uses WS. Values already in range are kept. For `squ`,
 *  an out-of-range value resets to 0.5 (a standard 50% duty cycle) rather
 *  than clamping to a bound, since clamping to [0.01, 0.99] would yield a
 *  near-degenerate duty cycle. For `noi`, out-of-range values clamp to
 *  [1, 50]. */
export function normalizeWs(wave: SlotWave, ws: number): number {
  const { min, max } = wsRange(wave);
  if (ws >= min && ws <= max) return ws;
  if (wave === "squ") return 0.5;
  return Math.min(Math.max(ws, min), max);
}

/** Oscillator parameters for a single slot (core Synth.Slot.UserParams). */
export interface SlotParams {
  /** Total level (output amplitude). >= 0. */
  tl: number;
  /** Frequency multiplier (ratio to the voice's base frequency). >= 0. */
  ml: number;
  /** Feedback (self-modulation amount). >= 0. */
  fb: number;
  /** Wave-specific parameter (core `Synth.Slot.UserParams.ws`). Only
   *  meaningful for waveforms that use it (see `usesWs`): duty cycle for
   *  `squ` ([0.01, 0.99]) and band-pass filter quality factor (Q) for
   *  `noi` ([1, 50]). Ignored for `sin`, `tri`, and `saw`. */
  ws: number;
}

/** Envelope parameters for a single slot (core Synth.Envelope.UserParams).
 *  ar/dr/sr/rr are times in seconds: how long the phase takes to reach the
 *  next envelope state (ar: linear rise 0 -> 1; dr: exponential fall
 *  1 -> sl; sr/rr: exponential fall by 80 dB). A time of 0 means the phase
 *  never advances (the envelope holds until key-off). sl is a level in
 *  [0, 1]. */
export interface EnvParams {
  ar: number;
  dr: number;
  /** Sustain level, [0, 1] (linear scale, not log). */
  sl: number;
  sr: number;
  rr: number;
}

/** Routing of the 8 slots as an edge matrix.
 *  edges[from][to] === true  <=>  slot `from` modulates slot `to`.
 *  This is the transpose of the core's `Connections.deps[to]` bitset
 *  (where deps[to].isSet(from) means the same thing); we keep the
 *  from->to orientation because it is far more natural to read in a UI. */
export interface Connections {
  edges: boolean[][];
}

export interface Patch {
  name: string;
  connections: Connections;
  slotWaves: SlotWave[];
  slotParams: SlotParams[];
  envParams: EnvParams[];
  /** Per-LFO editor state (enabled flag + parameters), stored with the
   *  patch so it round-trips through MML as `; LFO preset:` comments. */
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

// ---------- LFOs ----------

/** Number of user LFOs (core Module.Lfo.Index user_0 .. user_3). */
export const N_LFOS = 4;

/** Wave shape of an LFO, mirroring core Module.Lfo.Wave (a tagged union).
 *  In JSON each variant is `{"<tag>": <payload>}`, e.g. `{"con": {}}`
 *  or `{"sin": {"freq": 10}}`. */
export type LfoWave =
  | { con: Record<string, never> }
  | { sin: { freq: number } }
  | { exp: { mul: number } };

export type LfoWaveTag = "con" | "sin" | "exp";

/** What an LFO modulates. */
export type LfoTarget = "freq" | "pan" | "vol";

/** LFO parameters, mirroring core Module.Lfo. The LFO output is
 *  `size.scale * wave(t) + size.offset`, applied to `target`. */
export interface LfoParams {
  target: LfoTarget;
  size: { scale: number; offset: number };
  wave: LfoWave;
  trigger: "none" | "key_on";
  time_unit: "seconds" | "ticks";
  adjust: boolean;
}

/** Editor-side state of one user LFO: its parameters plus whether it is
 *  enabled on the synth. */
export interface LfoState {
  enabled: boolean;
  params: LfoParams;
}

/** Default per-LFO state: disabled, a gentle 5 Hz vibrato (±5 Hz). */
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
