// Vite plugin that compiles patches/patches.zfm with the existing Wasm
// compiler binary at build time and exposes the resulting bank as an
// importable JSON virtual module (`virtual:zfm/initial-bank`). This lets the
// app ship the full maintained patch bank as its initial bank content without
// hand-maintaining a second copy of the patch data.

import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "vite";

const VIRTUAL_ID = "virtual:zfm/initial-bank";
const RESOLVED_ID = "\0" + VIRTUAL_ID;

const here = dirname(fileURLToPath(import.meta.url));
const patchesPath = resolve(here, "../patches/patches.zfm");
const wasmPath = resolve(here, "zig-out/bin/compiler.wasm");

interface WasmExports {
  memory: WebAssembly.Memory;
  transferPtr(): number;
  transferLen(): number;
  transferSetLen(len: number): void;
  compile(): number;
  transferErrors(): void;
  transferPatches(): void;
}

/** Compile the patch bank with the Wasm compiler and return the JSON blob
 *  produced by `transferPatches()` (an array of serialized patches). */
async function compileBank(): Promise<string> {
  const [src, wasmBytes] = await Promise.all([readFile(patchesPath, "utf8"), readFile(wasmPath)]);
  const module = await WebAssembly.compile(wasmBytes);
  const instance = await WebAssembly.instantiate(module, {
    env: { consoleLog: () => {} },
  });
  const wasm = instance.exports as unknown as WasmExports;

  const readTransfer = () =>
    new Uint8Array(wasm.memory.buffer, wasm.transferPtr(), wasm.transferLen());

  const input = new TextEncoder().encode(src);
  wasm.transferSetLen(input.byteLength);
  new Uint8Array(wasm.memory.buffer, wasm.transferPtr(), input.byteLength).set(input);
  if (wasm.compile() === 0) {
    wasm.transferErrors();
    const errors = new TextDecoder().decode(readTransfer());
    throw new Error(`initial bank failed to compile (${patchesPath}): ${errors}`);
  }
  wasm.transferPatches();
  return new TextDecoder().decode(readTransfer());
}

export function initialBankPlugin(): Plugin {
  let json: string | null = null;

  return {
    name: "zfm-initial-bank",
    enforce: "pre",
    async buildStart() {
      json = await compileBank();
    },
    resolveId(id) {
      if (id === VIRTUAL_ID) return RESOLVED_ID;
    },
    load(id) {
      if (id === RESOLVED_ID) {
        if (json === null) {
          throw new Error(`internal error: ${VIRTUAL_ID} loaded before buildStart`);
        }
        return `export default ${json};`;
      }
    },
  };
}
