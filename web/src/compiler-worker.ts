import * as Comlink from "comlink";
import { consoleLogFactory } from "./wasm-interface.ts";
import wasmUrl from "../zig-out/bin/compiler.wasm?url";
import type { Patch } from "./patch/types.ts";

const wasmModule = await WebAssembly.compileStreaming(fetch(wasmUrl));

interface WasmExports {
  readonly memory: WebAssembly.Memory;
  transferPtr(): number;
  transferLen(): number;
  transferSetLen(len: number): void;
  compile(): number;
  transferErrors(): void;
  transferPatches(): void;
  transferModule(): void;
}

export interface CompileError {
  message: string;
  span: { start: number; end: number };
  part?: string;
}

export class CompilerState {
  private wasm: WasmExports;

  constructor(wasmModule: WebAssembly.Module) {
    const instance = new WebAssembly.Instance(wasmModule, {
      env: {
        consoleLog: consoleLogFactory(() => this.wasm.memory),
      },
    });
    this.wasm = instance.exports as unknown as WasmExports;
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

  compile(src: string): boolean {
    this.transferWrite(new TextEncoder().encode(src));
    return this.wasm.compile() !== 0;
  }

  errors(): CompileError[] {
    this.wasm.transferErrors();
    const buf = this.transferRead();
    return JSON.parse(new TextDecoder().decode(buf)) as CompileError[];
  }

  patches(): Patch[] {
    this.wasm.transferPatches();
    const buf = this.transferRead();
    return JSON.parse(new TextDecoder().decode(buf)) as Patch[];
  }

  module(): Uint8Array {
    this.wasm.transferModule();
    // Copy out of wasm memory: the underlying buffer is reused for the
    // next transfer, so callers must not retain a view into it.
    return this.transferRead().slice();
  }
}

Comlink.expose(new CompilerState(wasmModule));
