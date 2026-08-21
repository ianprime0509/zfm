import * as Comlink from "comlink";
import type { LfoParams, Patch } from "./patch/types.ts";
import { encodeBytes, decodeBytes } from "./worklet-shims.ts";
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
  setPatch(voice: number): void;
  setLfoEnabled(voice: number, index: number, enabled: number): void;
  setLfoParams(voice: number, index: number): void;
  ptrRenderBuf(): number;
  render(n: number): void;
  transferCurrentCommandSpans(): void;
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

export interface SetPatchArgs {
  voice: number;
  patch: Patch;
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

  private transferRead(): Uint8Array {
    const ptr = this.wasm.transferPtr();
    const len = this.wasm.transferLen();
    return new Uint8Array(this.wasm.memory.buffer, ptr, len);
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

  setPatch({ voice, patch }: SetPatchArgs) {
    this.transferWrite(
      encodeBytes(
        JSON.stringify({
          connections: patch.connections.edges,
          slot_waves: patch.slotWaves,
          slot_params: patch.slotParams,
          slot_env_params: patch.envParams,
        }),
      ),
    );
    this.wasm.setPatch(voice);
  }

  setLfoEnabled({ voice, index, enabled }: SetLfoEnabledArgs) {
    this.wasm.setLfoEnabled(voice, index, enabled ? 1 : 0);
  }

  setLfoParams({ voice, index, params }: SetLfoParamsArgs) {
    this.transferWrite(encodeBytes(JSON.stringify(params)));
    this.wasm.setLfoParams(voice, index);
  }

  currentCommandSpans() {
    this.wasm.transferCurrentCommandSpans();
    const buf = this.transferRead();
    return JSON.parse(decodeBytes(buf)) as ([number, number] | null)[];
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
