import * as Comlink from "comlink";
import type { LfoParams } from "./patch/types.ts";
import { SLOT_WAVE_VALUES, type SlotWave } from "./patch/types.ts";
import { consoleLogFactory } from "./wasm-interface.ts";

interface WasmExports {
  readonly memory: WebAssembly.Memory;
  transferPtr(): number;
  transferLen(): number;
  transferSetLen(len: number): void;
  reset(n_voices: number): void;
  load(): void;
  keyOn(voice: number, freq: number): void;
  keyOff(voice: number): void;
  reconnect(voice: number, connections: bigint): number;
  setSlotWave(voice: number, slot: number, wave: number): void;
  setSlotParams(voice: number, slot: number, tl: number, ml: number, fb: number, ws: number): void;
  setSlotEnvParams(
    voice: number,
    slot: number,
    ar: number,
    dr: number,
    sl: number,
    sr: number,
    rr: number,
  ): void;
  enableLfo(voice: number, index: number): void;
  disableLfo(voice: number, index: number): void;
  setLfoParams(voice: number, index: number): void;
  ptrRenderBuf(): number;
  render(n: number): void;
}

export interface ResetArgs {
  voices: number;
}

export interface LoadArgs {
  mod: Uint8Array;
}

export interface KeyOnArgs {
  voice: number;
  freq: number;
}

export interface KeyOffArgs {
  voice: number;
}

export interface ReconnectArgs {
  voice: number;
  connections: boolean[][];
}

export interface SetSlotParamsArgs {
  voice: number;
  slot: number;
  tl: number;
  ml: number;
  fb: number;
  ws: number;
}

export interface SetSlotWaveArgs {
  voice: number;
  slot: number;
  /** Waveform name ("sine" | "square" | "noise"). Converted to its
   *  numeric enum value when passed to the wasm layer. */
  wave: SlotWave;
}

export interface SetSlotEnvParamsArgs {
  voice: number;
  slot: number;
  ar: number;
  dr: number;
  sl: number;
  sr: number;
  rr: number;
}

export interface SetLfoEnabledArgs {
  voice: number;
  index: number;
  enabled: boolean;
}

export interface SetLfoParamsArgs {
  voice: number;
  index: number;
  params: LfoParams;
}

// Encode `str` as UTF-8 bytes. `TextEncoder` is unavailable in an
// AudioWorkletGlobalScope, so this is a minimal hand-rolled equivalent,
// correct for all of UTF-8 (including surrogate pairs). For our JSON
// output the ASCII fast path is always taken.
function encodeUtf8(str: string): Uint8Array {
  const len = str.length;
  let ascii = true;
  for (let i = 0; i < len; i++) {
    if (str.charCodeAt(i) > 0x7f) {
      ascii = false;
      break;
    }
  }
  if (ascii) {
    const out = new Uint8Array(len);
    for (let i = 0; i < len; i++) out[i] = str.charCodeAt(i);
    return out;
  }

  // Size the buffer from the UTF-8 byte length, then fill it.
  let size = 0;
  for (let i = 0; i < len; i++) {
    const c = str.charCodeAt(i);
    if (c < 0x80) size += 1;
    else if (c < 0x800) size += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      // High surrogate: one code point with the following low surrogate,
      // encoded as 4 bytes (and consume the next char).
      size += 4;
      i += 1;
    } else size += 3;
  }

  const out = new Uint8Array(size);
  let o = 0;
  for (let i = 0; i < len; i++) {
    const c = str.charCodeAt(i);
    if (c < 0x80) {
      out[o++] = c;
    } else if (c < 0x800) {
      out[o++] = 0xc0 | (c >> 6);
      out[o++] = 0x80 | (c & 0x3f);
    } else if (c >= 0xd800 && c <= 0xdbff) {
      const next = str.charCodeAt(i + 1);
      const cp = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00);
      out[o++] = 0xf0 | (cp >> 18);
      out[o++] = 0x80 | ((cp >> 12) & 0x3f);
      out[o++] = 0x80 | ((cp >> 6) & 0x3f);
      out[o++] = 0x80 | (cp & 0x3f);
      i += 1;
    } else {
      out[o++] = 0xe0 | (c >> 12);
      out[o++] = 0x80 | ((c >> 6) & 0x3f);
      out[o++] = 0x80 | (c & 0x3f);
    }
  }
  return out;
}

export class SynthProcessor extends AudioWorkletProcessor {
  private wasm: WasmExports;

  constructor(options?: AudioWorkletNodeOptions) {
    super(options);

    const wasmModule = options?.processorOptions?.wasmModule;
    if (!wasmModule) throw new Error("Missing wasmModule option");
    const instance = new WebAssembly.Instance(wasmModule, {
      env: {
        consoleLog: consoleLogFactory(() => this.wasm.memory),
      },
    });
    this.wasm = instance.exports as unknown as WasmExports;

    Comlink.expose(this, this.port);
  }

  private transferWrite(data: Uint8Array): void {
    this.wasm.transferSetLen(data.byteLength);
    const ptr = this.wasm.transferPtr();
    new Uint8Array(this.wasm.memory.buffer, ptr, data.byteLength).set(data);
  }

  reset({ voices }: ResetArgs) {
    this.wasm.reset(voices);
  }

  load({ mod }: LoadArgs) {
    this.transferWrite(mod);
    this.wasm.load();
  }

  keyOn({ voice, freq }: KeyOnArgs) {
    this.wasm.keyOn(voice, freq);
  }

  keyOff({ voice }: KeyOffArgs) {
    this.wasm.keyOff(voice);
  }

  reconnect({ voice, connections }: ReconnectArgs) {
    // connections[from][to] === true means `from` modulates `to`. The core
    // stores this as Connections.deps[to] (a bitset with bit `from` set),
    // bit-packed as a u64 where bit (to*8 + from) is set (wasm = little-endian).
    let packed = 0n;
    connections.forEach((from, fromIndex) => {
      from.forEach((to, toIndex) => {
        if (to) {
          const bitIndex = 8 * toIndex + fromIndex;
          packed |= 1n << BigInt(bitIndex);
        }
      });
    });
    return this.wasm.reconnect(voice, packed) !== 0;
  }

  setSlotParams({ voice, slot, tl, ml, fb, ws }: SetSlotParamsArgs) {
    this.wasm.setSlotParams(voice, slot, tl, ml, fb, ws);
  }

  setSlotWave({ voice, slot, wave }: SetSlotWaveArgs) {
    this.wasm.setSlotWave(voice, slot, SLOT_WAVE_VALUES[wave]);
  }

  setSlotEnvParams({ voice, slot, ar, dr, sl, sr, rr }: SetSlotEnvParamsArgs) {
    this.wasm.setSlotEnvParams(voice, slot, ar, dr, sl, sr, rr);
  }

  setLfoEnabled({ voice, index, enabled }: SetLfoEnabledArgs) {
    if (enabled) {
      this.wasm.enableLfo(voice, index);
    } else {
      this.wasm.disableLfo(voice, index);
    }
  }

  setLfoParams({ voice, index, params }: SetLfoParamsArgs) {
    // The wasm side decodes the params as JSON from the transfer buffer.
    this.transferWrite(encodeUtf8(JSON.stringify(params)));
    this.wasm.setLfoParams(voice, index);
  }

  override process(_inputs: Float32Array[][], outputs: Float32Array[][]) {
    const output = outputs[0];
    const left = output[0];
    const right = output[1];
    const n = left.length;
    const maxFrames = 256;

    const offset = this.wasm.ptrRenderBuf();
    const buf = new Float32Array(this.wasm.memory.buffer, offset, maxFrames * 2);

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

registerProcessor("synth-processor", SynthProcessor);

// See https://github.com/microsoft/TypeScript/issues/28308#issuecomment-650802278

declare class AudioWorkletProcessor {
  readonly port: MessagePort;

  constructor(options?: AudioWorkletNodeOptions);
  process(
    inputs: Float32Array[][],
    outputs: Float32Array[][],
    parameters: Record<string, Float32Array>,
  ): boolean;
}

declare function registerProcessor(
  name: string,
  processorCtor: new (options?: AudioWorkletNodeOptions) => AudioWorkletProcessor,
): void;
