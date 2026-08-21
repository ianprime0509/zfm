import { N_VOICES } from "./keyboard.ts";

export class VoiceAllocator {
  private readonly voiceForNote = new Map<number, number>();
  private readonly lastPlayed: number[] = Array.from(
    { length: N_VOICES },
    () => Number.NEGATIVE_INFINITY,
  );
  private clock = 0;

  /**
   * Allocates a voice for a note.
   *
   * @param note the MIDI note number to play
   * @returns the voice index to use and whether it was already being held for
   * another note
   */
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

  /**
   * Release a held note.
   *
   * @param note the MIDI note number being released
   * @returns the voice index that was being used, if any
   */
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
