import * as Comlink from "comlink";
import type { CompileError, CompilerState } from "./compiler-worker.ts";
import type { Patch } from "./patch/types.ts";

type Port = Comlink.Remote<CompilerState>;

export class Compiler {
  private worker: Worker;
  private port: Port;

  constructor() {
    this.worker = new Worker(new URL("./compiler-worker.ts", import.meta.url), { type: "module" });
    this.port = Comlink.wrap(this.worker);
  }

  close(): void {
    this.worker.terminate();
  }

  async compile(src: string): Promise<boolean> {
    return await this.port.compile(src);
  }

  async errors(): Promise<CompileError[]> {
    return await this.port.errors();
  }

  async patches(): Promise<Patch[]> {
    return await this.port.patches();
  }

  async module(): Promise<Uint8Array> {
    return await this.port.module();
  }
}
