import * as Comlink from "comlink";
import type {
  SynthProcessor,
  KeyOffArgs,
  KeyOnArgs,
  ReconnectArgs,
  ResetArgs,
  LoadArgs,
  SetLfoEnabledArgs,
  SetLfoParamsArgs,
  SetSlotEnvParamsArgs,
  SetSlotParamsArgs,
  SetSlotWaveArgs,
} from "./synth-worklet.ts";
import synthWorkletUrl from "./synth-worklet.ts?url";
import wasmUrl from "../zig-out/bin/audio.wasm?url";

const wasmModule = await WebAssembly.compileStreaming(fetch(wasmUrl));

type Port = Comlink.Remote<SynthProcessor>;
type State = { ctx: AudioContext; port: Port };

export class Synth {
  private _state?: State;

  private async state() {
    if (!this._state) {
      const ctx = new AudioContext({ sampleRate: 48_000 });
      await ctx.audioWorklet.addModule(synthWorkletUrl);
      const wasmNode = new AudioWorkletNode(ctx, "synth-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
        processorOptions: { wasmModule },
      });
      wasmNode.connect(ctx.destination);
      this._state = { ctx, port: Comlink.wrap(wasmNode.port) };
    }
    return this._state;
  }

  async close() {
    await this._state?.ctx?.close?.();
  }

  async reset({ voices }: ResetArgs) {
    await (await this.state()).port.reset({ voices });
  }

  async load({ mod }: LoadArgs) {
    await (await this.state()).port.load({ mod });
  }

  async keyOn({ voice, freq }: KeyOnArgs) {
    await (await this.state()).port.keyOn({ voice, freq });
  }

  async keyOff({ voice }: KeyOffArgs) {
    await (await this.state()).port.keyOff({ voice });
  }

  async reconnect({ voice, connections }: ReconnectArgs): Promise<boolean> {
    return await (await this.state()).port.reconnect({ voice, connections });
  }

  async setSlotParams({ voice, slot, tl, ml, fb, ws }: SetSlotParamsArgs) {
    await (await this.state()).port.setSlotParams({ voice, slot, tl, ml, fb, ws });
  }

  async setSlotWave({ voice, slot, wave }: SetSlotWaveArgs) {
    await (await this.state()).port.setSlotWave({ voice, slot, wave });
  }

  async setSlotEnvParams({ voice, slot, ar, dr, sl, sr, rr }: SetSlotEnvParamsArgs) {
    await (await this.state()).port.setSlotEnvParams({ voice, slot, ar, dr, sl, sr, rr });
  }

  async setLfoEnabled({ voice, index, enabled }: SetLfoEnabledArgs) {
    await (await this.state()).port.setLfoEnabled({ voice, index, enabled });
  }

  async setLfoParams({ voice, index, params }: SetLfoParamsArgs) {
    await (await this.state()).port.setLfoParams({ voice, index, params });
  }
}
