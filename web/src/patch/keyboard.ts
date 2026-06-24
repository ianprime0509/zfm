// Musical-typing keyboard mapping.
//
// We map physical key positions (KeyboardEvent.code, e.g. "KeyZ") to MIDI
// notes so the same layout works on any key layout (QWERTY, Dvorak, AZERTY,
// etc.). The layout is the standard "tracker"/musical-typing arrangement:
//
//   lower octave (C3-B3) on the two lower letter rows:
//     Z S X D C V G B H N J M   (Z=C3, S=C#3, X=D3, ..., M=B3)
//   upper octave (C4-E5) on the upper letter row and the number row:
//     Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P   (Q=C4, ..., P=E5)
//
// C4 (MIDI 60) is reachable both via "," and "Q".

export const N_VOICES = 8;

// A4 (MIDI 69) = 440 Hz, 12-tone equal temperament.
export function midiToFreq(midi: number): number {
  return 440 * Math.pow(2, (midi - 69) / 12);
}

export const KEY_TO_MIDI: Readonly<Record<string, number>> = {
  // lower octave (C3 = MIDI 48)
  KeyZ: 48,
  KeyS: 49,
  KeyX: 50,
  KeyD: 51,
  KeyC: 52,
  KeyV: 53,
  KeyG: 54,
  KeyB: 55,
  KeyH: 56,
  KeyN: 57,
  KeyJ: 58,
  KeyM: 59,
  Comma: 60,
  // upper octave (C4 = MIDI 60)
  KeyQ: 60,
  Digit2: 61,
  KeyW: 62,
  Digit3: 63,
  KeyE: 64,
  KeyR: 65,
  Digit5: 66,
  KeyT: 67,
  Digit6: 68,
  KeyY: 69,
  Digit7: 70,
  KeyU: 71,
  KeyI: 72,
  Digit9: 73,
  KeyO: 74,
  Digit0: 75,
  KeyP: 76,
};
