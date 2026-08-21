import { useCallback, useEffect, useRef } from "preact/hooks";
import type { Synth } from "../synth.ts";
import type { LfoState, Patch } from "./types.ts";
import { N_VOICES, midiToFreq } from "./keyboard.ts";
import { VoiceAllocator } from "./voiceAllocator.ts";

/** Apply a full patch to every voice. Fire-and-forget: callers need not await. */
function applyPatch(synth: Synth, patch: Patch): void {
  for (let v = 0; v < N_VOICES; v++) {
    void synth.setPatch({ voice: v, patch });
  }
}

/** (Re)apply every LFO, on all voices. Fire-and-forget, like `applyPatch`. */
function applyLfos(synth: Synth, lfos: LfoState[]): void {
  for (let i = 0; i < lfos.length; i++) {
    const lfo = lfos[i]!;
    for (let v = 0; v < N_VOICES; v++) {
      void synth.setLfoEnabled({ voice: v, index: i, enabled: lfo.enabled });
      void synth.setLfoParams({ voice: v, index: i, params: lfo.params });
    }
  }
}

export interface PatchSynth {
  noteOn: (midi: number) => void;
  noteOff: (midi: number) => void;
}

export interface UsePatchSynthOptions {
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

  // Changes to patch or LFO state are staged until the audio becomes live.
  const audioLiveRef = useRef(false);
  const stagedRef = useRef<Patch>(patch);
  const stagedLfosRef = useRef<LfoState[] | undefined>(patch.lfos);

  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;

  // The `AudioContext` must be created only in response to a user gesture.
  const readyRef = useRef<Promise<void> | null>(null);
  const ensureReady = useCallback(() => {
    if (readyRef.current === null) {
      readyRef.current = synth.reset({ voices: N_VOICES });
    }
    return readyRef.current;
  }, [synth]);

  const prevDisabledRef = useRef(disabled);
  useEffect(() => {
    prevDisabledRef.current = disabled;

    stagedRef.current = patch;
    stagedLfosRef.current = patch.lfos;
    if (disabled) return;

    if (audioLiveRef.current) {
      applyPatch(synth, patch);
      applyLfos(synth, patch.lfos);
    }
  }, [patch, synth, disabled]);

  const noteOn = useCallback(
    (midi: number) => {
      if (disabledRef.current) return;
      const { voice, held } = allocator.noteOn(midi);
      const freq = midiToFreq(midi);
      void ensureReady().then(() => {
        if (!audioLiveRef.current) {
          applyPatch(synth, stagedRef.current);
          if (stagedLfosRef.current) applyLfos(synth, stagedLfosRef.current);
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
      void ensureReady().then(() => {
        void synth.keyOff({ voice });
      });
    },
    [allocator, synth, ensureReady],
  );

  return { noteOn, noteOff };
}
