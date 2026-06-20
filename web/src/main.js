import * as Comlink from "comlink";
import wasmUrl from "../zig-out/bin/audio.wasm?url";
import processorUrl from "./processor.js?url";
import "./zfm-patch-editor-voice.js";

const ctx = new AudioContext({ sampleRate: 48000 });
await ctx.audioWorklet.addModule(processorUrl);
const wasmModule = await WebAssembly.compileStreaming(fetch(wasmUrl));
const wasmNode = new AudioWorkletNode(ctx, "audio-processor", {
  numberOfInputs: 0,
  numberOfOutputs: 1,
  outputChannelCount: [2],
  processorOptions: { wasmModule },
});
wasmNode.connect(ctx.destination);
const audio = Comlink.wrap(wasmNode.port);

const voiceEl = document.querySelector("zfm-patch-editor-voice");
voiceEl.voice = 0;
voiceEl.connections = [[0, 1]];
voiceEl.slots = Array.from({ length: 8 }, () => ({
  tl: 0,
  ml: 1,
  fb: 0,
  ar: 1,
  dr: 0,
  sl: 0,
  sr: 0,
  rr: 1,
}));

const maxPolyphony = 8;

async function reconnectAll({ connections }) {
  for (let i = 0; i < maxPolyphony; i++) {
    await audio.reconnect({ voice: i, connections });
  }
}

async function setSlotParamsAll({ slot, tl, ml, fb }) {
  for (let i = 0; i < maxPolyphony; i++) {
    await audio.setSlotParams({ voice: i, slot, tl, ml, fb });
  }
}

async function setSlotEnvParamsAll({ slot, ar, dr, sl, sr, rr }) {
  for (let i = 0; i < maxPolyphony; i++) {
    await audio.setSlotEnvParams({ voice: i, slot, ar, dr, sl, sr, rr });
  }
}

async function resetAll() {
  await reconnectAll({ connections: voiceEl.connections });
  for (let i = 0; i < voiceEl.slots.length; i++) {
    const slot = voiceEl.slots[i];
    await setSlotParamsAll({
      slot: i,
      tl: slot.tl,
      ml: slot.ml,
      fb: slot.fb,
    });
    await setSlotEnvParamsAll({
      slot: i,
      ar: slot.ar,
      dr: slot.dr,
      sl: slot.sl,
      sr: slot.sr,
      rr: slot.rr,
    });
  }
}

voiceEl.addEventListener("connectionsUpdated", async (e) => {
  await reconnectAll(e.detail);
});

voiceEl.addEventListener("slotParamsUpdated", async (e) => {
  await setSlotParamsAll(e.detail);
});

voiceEl.addEventListener("slotEnvParamsUpdated", async (e) => {
  await setSlotEnvParamsAll(e.detail);
});

await audio.init({ voices: maxPolyphony });
await resetAll();

const noteFreq = (midi) => 440 * 2 ** ((midi - 69) / 12);

const KEY_MAP = {
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

const voiceForKey = new Map();
const voiceLru = Array.from({ length: maxPolyphony }, (_, i) => i);

document.body.addEventListener("keydown", async (e) => {
  if (e.repeat || e.target !== document.body) return;
  const midi = KEY_MAP[e.code];
  if (midi == null || voiceForKey.has(e.code)) return;

  const heldVoices = new Map(
    voiceForKey.entries().map(([key, voice]) => [voice, key]),
  );
  let voice;
  let selectedIdx = -1;
  for (let i = 0; i < voiceLru.length; i++) {
    const candidate = voiceLru[i];
    if (!heldVoices.has(candidate)) {
      voice = candidate;
      selectedIdx = i;
      break;
    }
  }
  if (voice == null) {
    voice = voiceLru[0];
    selectedIdx = 0;
    voiceForKey.delete(heldVoices.get(voice));
    await audio.keyOff({ voice });
  }

  voiceLru.splice(selectedIdx, 1);
  voiceLru.push(voice);

  ctx.resume();
  voiceForKey.set(e.code, voice);
  await audio.setFreq({ voice, freq: noteFreq(midi) });
  await audio.keyOn({ voice });
});

document.body.addEventListener("keyup", async (e) => {
  if (e.target !== document.body) return;
  const voice = voiceForKey.get(e.code);
  if (voice == null) return;
  voiceForKey.delete(e.code);
  await audio.keyOff({ voice });
});
