import * as Comlink from "comlink";
import { consoleLogFactory } from "./wasm-interface.js";

class AudioProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super(options);

    const wasmModule = options.processorOptions.wasmModule;
    const instance = new WebAssembly.Instance(wasmModule, {
      env: {
        consoleLog: consoleLogFactory(() => this.wasm.memory),
      },
    });
    this.wasm = instance.exports;

    Comlink.expose(this, this.port);
  }

  init({ voices }) {
    this.wasm.init(voices);
  }

  reconnect({ voice, connections }) {
    const n = connections.length;
    const offset = this.wasm.ptrConnectionsBuf();
    const buf = new Uint8Array(this.wasm.memory.buffer, offset, n * 2);
    for (let i = 0; i < n; i++) {
      buf[i * 2] = connections[i][0];
      buf[i * 2 + 1] = connections[i][1];
    }
    return this.wasm.reconnect(voice, n);
  }

  setFreq({ voice, freq }) {
    this.wasm.setFreq(voice, freq);
  }

  setSlotParams({ voice, slot, tl, ml, fb }) {
    this.wasm.setSlotParams(voice, slot, tl, ml, fb);
  }

  setSlotEnvParams({ voice, slot, ar, dr, sl, sr, rr }) {
    this.wasm.setSlotEnvParams(voice, slot, ar, dr, sl, sr, rr);
  }

  keyOn({ voice }) {
    this.wasm.keyOn(voice);
  }

  keyOff({ voice }) {
    this.wasm.keyOff(voice);
  }

  process(_, outputs) {
    const output = outputs[0];
    const left = output[0];
    const right = output[1];
    const n = left.length;
    const maxFrames = 256;

    const offset = this.wasm.ptrRenderBuf();
    const buf = new Float32Array(
      this.wasm.memory.buffer,
      offset,
      maxFrames * 2,
    );

    let written = 0;
    while (written < n) {
      const todo = Math.min(n - written, maxFrames);
      this.wasm.render(todo);
      for (let i = 0; i < todo; i++) {
        left[written + i] = buf[i * 2];
        right[written + i] = buf[i * 2 + 1];
      }
      written += todo;
    }

    return true;
  }
}

registerProcessor("audio-processor", AudioProcessor);
