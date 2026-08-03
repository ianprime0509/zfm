import { useCallback, useEffect, useRef } from "preact/hooks";
import type { Synth } from "../synth.ts";
import type { EnvParams, LfoParams, LfoState, LfoWave, Patch, SlotParams } from "./types.ts";
import { N_SLOTS } from "./types.ts";
import { edgesEqual } from "./connections.ts";
import { N_VOICES, midiToFreq } from "./keyboard.ts";
import { VoiceAllocator } from "./voiceAllocator.ts";

// Bridges the editor's `Patch` state to the WebAssembly synth, and exposes
// note on/off callbacks for the keyboard.
//
// Audio-init discipline (the important part):
//   - The AudioContext is created lazily on the *first user gesture* (a key
//     press via `noteOn`), never at mount time. Browsers block autoplay, so
//     constructing/resuming an AudioContext outside a gesture just produces a
//     "prevented from starting" warning and leaves the context suspended.
//   - Until audio is live, the patch-sync effect merely stages the latest
//     patch; on the first key press the staged patch is applied in full,
//     after which subsequent edits are diffed and applied immediately.
//
// All 8 synth voices share the same patch, so every patch change is applied
// to every voice. We diff against the previously-applied patch and only send
// the minimal set of updates (the routing, the changed slot's oscillator
// params, or its envelope params) to keep live slider-dragging responsive.
//
// Synth calls are *fire-and-forget*: AudioWorklet MessagePorts preserve FIFO
// ordering, so messages are applied in the order issued. Each call does
// resolve the (memoized) AudioContext once it's live, but constructing it is
// gated behind the first gesture.
//
// LFO states (stored on the patch, edited via the LfoPanel) are synced the
// same way: staged until audio is live, diffed on change, and re-applied in
// full whenever the staged state is forced to re-apply.
//
// Ownership: the `synth` is shared with the rest of the app. While `disabled`
// is true (the track editor is playing back a compiled module), this hook is
// completely inert — it stages patch edits but sends nothing to the synth,
// and note on/off are no-ops. When `disabled` transitions back to false the
// synth has just been `reset` by the player, so the staged patch is forced to
// re-apply in full (rather than diffing against a stale pre-play state).

function slotParamsEqual(a: SlotParams, b: SlotParams): boolean {
  return a.tl === b.tl && a.ml === b.ml && a.fb === b.fb && a.ws === b.ws;
}

function envParamsEqual(a: EnvParams, b: EnvParams): boolean {
  return a.ar === b.ar && a.dr === b.dr && a.sl === b.sl && a.sr === b.sr && a.rr === b.rr;
}

function lfoWaveEqual(a: LfoWave, b: LfoWave): boolean {
  if ("constant" in a) return "constant" in b;
  if ("sine" in a) return "sine" in b && a.sine.freq === b.sine.freq;
  return "exp" in b && a.exp.mul === b.exp.mul;
}

function lfoParamsEqual(a: LfoParams, b: LfoParams): boolean {
  return (
    a.target === b.target &&
    a.trigger === b.trigger &&
    a.time_unit === b.time_unit &&
    a.adjust === b.adjust &&
    a.size.scale === b.size.scale &&
    a.size.offset === b.size.offset &&
    lfoWaveEqual(a.wave, b.wave)
  );
}

/** Fire the minimal set of synth messages to move `prev` -> `next` on all
 *  voices. Fire-and-forget: callers need not await. */
function applyPatch(synth: Synth, prev: Patch | undefined, next: Patch): void {
  if (!prev) {
    for (let v = 0; v < N_VOICES; v++) {
      void synth.reconnect({ voice: v, connections: next.connections.edges });
      for (let s = 0; s < N_SLOTS; s++) {
        const wave = next.slotWaves[s]!;
        const sp = next.slotParams[s]!;
        void synth.setSlotWave({ voice: v, slot: s, wave });
        void synth.setSlotParams({ voice: v, slot: s, ...sp });
        const env = next.envParams[s]!;
        void synth.setSlotEnvParams({ voice: v, slot: s, ...env });
      }
    }
    return;
  }

  if (!edgesEqual(prev.connections.edges, next.connections.edges)) {
    for (let v = 0; v < N_VOICES; v++) {
      void synth.reconnect({ voice: v, connections: next.connections.edges });
    }
  }

  for (let s = 0; s < N_SLOTS; s++) {
    if (prev.slotWaves[s] !== next.slotWaves[s]) {
      const wave = next.slotWaves[s]!;
      for (let v = 0; v < N_VOICES; v++) {
        void synth.setSlotWave({ voice: v, slot: s, wave });
      }
    }
    if (!slotParamsEqual(prev.slotParams[s]!, next.slotParams[s]!)) {
      const sp = next.slotParams[s]!;
      for (let v = 0; v < N_VOICES; v++) {
        void synth.setSlotParams({ voice: v, slot: s, ...sp });
      }
    }
    if (!envParamsEqual(prev.envParams[s]!, next.envParams[s]!)) {
      const env = next.envParams[s]!;
      for (let v = 0; v < N_VOICES; v++) {
        void synth.setSlotEnvParams({ voice: v, slot: s, ...env });
      }
    }
  }
}

/** Fire the minimal set of synth messages to move `prev` -> `next` for each
 *  LFO, on all voices. Fire-and-forget, like `applyPatch`. */
function applyLfos(synth: Synth, prev: LfoState[] | undefined, next: LfoState[]): void {
  for (let i = 0; i < next.length; i++) {
    const n = next[i]!;
    const p = prev?.[i];
    const paramsChanged = !p || !lfoParamsEqual(p.params, n.params);
    const enabledChanged = !p || p.enabled !== n.enabled;
    if (!paramsChanged && !enabledChanged) continue;
    for (let v = 0; v < N_VOICES; v++) {
      if (paramsChanged) void synth.setLfoParams({ voice: v, index: i, params: n.params });
      if (enabledChanged) void synth.setLfoEnabled({ voice: v, index: i, enabled: n.enabled });
    }
  }
}

export interface PatchSynth {
  noteOn: (midi: number) => void;
  noteOff: (midi: number) => void;
}

export interface UsePatchSynthOptions {
  /** When true, this hook neither touches the synth nor triggers notes. Used
   *  to yield the synth to track playback so the two never collide. */
  disabled?: boolean;
}

export function usePatchSynth(
  patch: Patch,
  synth: Synth,
  options?: UsePatchSynthOptions,
): PatchSynth {
  const disabled = options?.disabled ?? false;

  const allocatorRef = useRef<VoiceAllocator | null>(null);
  if (allocatorRef.current === null) allocatorRef.current = new VoiceAllocator();
  const allocator = allocatorRef.current;

  // `audioLive` flips true once the AudioContext has been created (on first
  // gesture) and the staged patch has been applied. `lastApplied` tracks what
  // was last sent to the synth so we can diff subsequent edits. `staged`
  // holds the latest patch the user wants; if audio isn't live yet it will
  // be applied in full on the first key press.
  const audioLiveRef = useRef(false);
  const lastAppliedRef = useRef<Patch | undefined>(undefined);
  const stagedRef = useRef<Patch>(patch);
  const lastAppliedLfosRef = useRef<LfoState[] | undefined>(undefined);
  const stagedLfosRef = useRef<LfoState[] | undefined>(patch.lfos);

  // `disabled` as a ref so the memoized note callbacks read the latest value
  // without being recreated on every toggle.
  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;

  // Memoized one-time `reset({voices: 8})`. This is the call that constructs
  // (and resumes) the AudioContext, so it must originate from a user gesture
  // — which it does, since it's only ever triggered by `noteOn`.
  const readyRef = useRef<Promise<void> | null>(null);
  const ensureReady = useCallback(() => {
    if (readyRef.current === null) {
      readyRef.current = synth.reset({ voices: N_VOICES });
    }
    return readyRef.current;
  }, [synth]);

  // Stage every patch change and keep the synth in sync while we own it.
  // While disabled we only stage (the player owns the synth). On the
  // disabled -> enabled transition the synth was just `reset`, so force a
  // full re-apply by clearing `lastApplied` instead of diffing against the
  // stale pre-play patch.
  const prevDisabledRef = useRef(disabled);
  useEffect(() => {
    const justEnabled = prevDisabledRef.current && !disabled;
    prevDisabledRef.current = disabled;

    stagedRef.current = patch;
    stagedLfosRef.current = patch.lfos;
    if (disabled) return;

    if (justEnabled) {
      lastAppliedRef.current = undefined;
      lastAppliedLfosRef.current = undefined;
    }

    if (audioLiveRef.current) {
      applyPatch(synth, lastAppliedRef.current, patch);
      lastAppliedRef.current = patch;
      if (patch.lfos) {
        applyLfos(synth, lastAppliedLfosRef.current, patch.lfos);
        lastAppliedLfosRef.current = patch.lfos;
      }
    }
  }, [patch, synth, disabled]);

  const noteOn = useCallback(
    (midi: number) => {
      if (disabledRef.current) return;
      const { voice, held } = allocator.noteOn(midi);
      const freq = midiToFreq(midi);
      // ensureReady() runs synchronously up to the first await, so the
      // AudioContext is *constructed* within this user-gesture call frame.
      void ensureReady().then(() => {
        if (!audioLiveRef.current) {
          applyPatch(synth, undefined, stagedRef.current);
          lastAppliedRef.current = stagedRef.current;
          if (stagedLfosRef.current) {
            applyLfos(synth, undefined, stagedLfosRef.current);
            lastAppliedLfosRef.current = stagedLfosRef.current;
          }
          audioLiveRef.current = true;
        }
        if (held) void synth.keyOff({ voice });
        void synth.keyOn({ voice, freq });
      });
    },
    [allocator, synth, ensureReady],
  );

  const noteOff = useCallback(
    (midi: number) => {
      if (disabledRef.current) return;
      const voice = allocator.noteOff(midi);
      if (voice === null) return;
      // Audio is live if a note was ever pressed (noteOn always precedes the
      // matching noteOff), so ensureReady is already resolved.
      void ensureReady().then(() => {
        void synth.keyOff({ voice });
      });
    },
    [allocator, synth, ensureReady],
  );

  return { noteOn, noteOff };
}
