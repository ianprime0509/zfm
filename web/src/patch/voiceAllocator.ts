import { N_VOICES } from "./keyboard.ts";

// Polyphonic voice allocator for the N_VOICES synth voices.
//
// Allocation precedence for a new note:
//   1. Prefer voices that are not currently held over ones that are.
//   2. Within the chosen group, pick the least-recently-played voice.
// If every voice is held, the least-recently-played voice is stolen (its
// previous note is silently cut off).
//
// `lastPlayed` is a monotonically increasing logical clock (updated on every
// noteOn) so that "least recently played" is well-defined without depending
// on wall-clock time. Voices that have never been played start at -Infinity
// and are therefore preferred first, giving a fair round-robin on startup.

export class VoiceAllocator {
  private readonly voiceForNote = new Map<number, number>();
  private readonly lastPlayed: number[] = Array.from(
    { length: N_VOICES },
    () => Number.NEGATIVE_INFINITY,
  );
  private clock = 0;

  /** Allocate a voice for `note` (a MIDI note number).
   *  Returns the voice and whether it's currently held. */
  noteOn(note: number): { voice: number; held: boolean } {
    this.clock++;

    // Re-trigger of an already-held note reuses its voice (and refreshes LRU).
    const heldVoice = this.voiceForNote.get(note);
    if (heldVoice !== undefined) {
      this.lastPlayed[heldVoice] = this.clock;
      return { voice: heldVoice, held: true };
    }

    const free = this.pickByLRU((v) => !this.isHeld(v));
    const voice = free ?? this.pickByLRU(() => true)!;
    const held = this.isHeld(voice);
    // Stealing: forget the note that previously owned this voice.
    if (held) {
      for (const [n, v] of this.voiceForNote) {
        if (v === voice) {
          this.voiceForNote.delete(n);
          break;
        }
      }
    }

    this.voiceForNote.set(note, voice);
    this.lastPlayed[voice] = this.clock;
    return { voice, held };
  }

  /** Release a held note. Returns the voice that was released, or null if the
   *  note wasn't held. */
  noteOff(note: number): number | null {
    const voice = this.voiceForNote.get(note);
    if (voice === undefined) return null;
    this.voiceForNote.delete(note);
    return voice;
  }

  private isHeld(voice: number): boolean {
    for (const v of this.voiceForNote.values()) if (v === voice) return true;
    return false;
  }

  private pickByLRU(pred: (v: number) => boolean): number | null {
    let best: number | null = null;
    let bestTime = Number.POSITIVE_INFINITY;
    for (let v = 0; v < N_VOICES; v++) {
      if (!pred(v)) continue;
      if (this.lastPlayed[v] < bestTime) {
        bestTime = this.lastPlayed[v];
        best = v;
      }
    }
    return best;
  }
}
