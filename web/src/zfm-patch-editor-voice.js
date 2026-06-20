import { css, html, LitElement } from "lit";
import { classMap } from "lit/directives/class-map.js";
import { consoleLogFactory } from "./wasm-interface.js";
import "./zfm-patch-editor-slot.js";
import wasmUrl from "../zig-out/bin/compiler.wasm?url";

const wasm = await WebAssembly.instantiateStreaming(fetch(wasmUrl), {
  env: {
    consoleLog: consoleLogFactory(() => wasm.memory),
  },
}).then(({ instance }) => instance.exports);

/**
 * @param {string} source
 * @returns {{connections: Array<[number, number]>, slots: Array<Record<"tl" | "ml" | "fb" | "ar" | "dr" | "sl" | "sr" | "rr">, number>}}
 */
function parsePatch(source) {
  const encoded = new TextEncoder().encode(source);
  wasm.transferBufReserve(encoded.length);
  const ptr = wasm.transferBufPtr();
  new Uint8Array(wasm.memory.buffer, ptr, encoded.length).set(encoded);
  const resultLen = wasm.compilePatch();
  if (resultLen === 0) throw new Error("Compilation failed");
  const resultPtr = wasm.transferBufPtr();
  const resultBytes = new Uint8Array(wasm.memory.buffer, resultPtr, resultLen);
  return JSON.parse(new TextDecoder().decode(resultBytes));
}

export class ZfmPatchEditorVoice extends LitElement {
  static properties = {
    connections: { type: Array },
    slots: { type: Array },
    _columns: { state: true },
    _invalidConnections: { state: true },
    _invalidPatch: { state: true },
  };

  constructor() {
    super();
    this._columns = 4;
    this._invalidConnections = false;
    this.slots = [];
    this._observer = new ResizeObserver(([entry]) => {
      const w = entry.contentRect.width;
      if (w < 30 * 16) {
        this._columns = 1;
      } else if (w < 56 * 16) {
        this._columns = 2;
      } else {
        this._columns = 4;
      }
    });
  }

  connectedCallback() {
    super.connectedCallback();
    this._observer.observe(this);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._observer.disconnect();
  }

  _onConnectionsInput(e) {
    try {
      this.connections = JSON.parse(e.target.value);
    } catch {
      this._invalidConnections = true;
      return;
    }
    this._invalidConnections = false;
    this.dispatchEvent(
      new CustomEvent("connectionsUpdated", {
        detail: { connections: this.connections },
      }),
    );
  }

  _onSlotParamsUpdated(e) {
    const { tl, ml, fb, slot } = e.detail;
    Object.assign(this.slots[slot], { tl, ml, fb });
    this.slots = [...this.slots];
    this.dispatchEvent(
      new CustomEvent("slotParamsUpdated", {
        detail: { tl, ml, fb, slot },
      }),
    );
  }

  _onSlotEnvParamsUpdated(e) {
    const { ar, dr, sl, sr, rr, slot } = e.detail;
    Object.assign(this.slots[slot], { ar, dr, sl, sr, rr });
    this.slots = [...this.slots];
    this.dispatchEvent(
      new CustomEvent("slotEnvParamsUpdated", {
        detail: { ar, dr, sl, sr, rr, slot },
      }),
    );
  }

  _parsePatch(text) {
    let result;
    try {
      result = parsePatch(text);
    } catch {
      this._invalidPatch = true;
      return;
    }

    this.connections = result.connections;
    this._invalidConnections = false;
    this._invalidPatch = false;
    this.slots = result.slots;
    this.dispatchEvent(
      new CustomEvent("connectionsUpdated", {
        detail: { connections: this.connections },
      }),
    );
    for (let i = 0; i < this.slots.length; i++) {
      const { tl, ml, fb, ar, dr, sl, sr, rr } = this.slots[i];
      this.dispatchEvent(
        new CustomEvent("slotParamsUpdated", {
          detail: { tl, ml, fb, slot: i },
        }),
      );
      this.dispatchEvent(
        new CustomEvent("slotEnvParamsUpdated", {
          detail: { ar, dr, sl, sr, rr, slot: i },
        }),
      );
    }
  }

  _onPatchInput(e) {
    this._parsePatch(e.target.value);
  }

  _formatPatch() {
    const conns = (this.connections ?? [])
      .map(([a, b]) => `${a} ${b}`)
      .join(", ");
    const slots = this.slots ?? [];
    const lastIdx = slots
      .map((s, i) => (Object.values(s).find((v) => v !== 0) != null ? i : -1))
      .reduce((a, b) => Math.max(a, b), -1);
    const lines = slots
      .slice(0, lastIdx + 1)
      .map(
        (s) =>
          `  ${s.tl ?? 0} ${s.ml ?? 0} ${s.fb ?? 0} ${s.ar ?? 0} ${s.dr ?? 0} ${s.sl ?? 0} ${s.sr ?? 0} ${s.rr ?? 0}`,
      );
    return `@patch ${conns}.\n${lines.join("\n")}`;
  }

  static styles = css`
    :host {
      display: block;
    }

    .connections-row {
      font-family: monospace;
      background: #e0e0e0;
      color: #333;
      padding: 0.5em;
      margin-bottom: 0.5em;
    }

    .connections-row label {
      display: flex;
      align-items: center;
      gap: 0.3em;
    }

    .connections-row span {
      font-weight: bold;
    }

    .connections-row input {
      background: none;
      border: none;
      color: #333;
      font-family: monospace;
      font-size: inherit;
      outline: none;
      width: 20em;
    }

    .connections-row input:focus {
      outline: 1px dotted #333;
    }

    .invalid {
      background: #ffcccc;
    }

    .slots-grid {
      display: grid;
      gap: 0.5em;
    }
  `;

  render() {
    return html`
      <div class="connections-row">
        <label>
          <span>Connections</span>
          <input
            type="text"
            class=${classMap({ invalid: this._invalidConnections })}
            .value=${JSON.stringify(this.connections ?? [])}
            @input=${this._onConnectionsInput}
          />
        </label>
      </div>
      <div
        class="slots-grid"
        style="grid-template-columns:repeat(${this._columns},1fr)"
      >
        ${this.slots.map((s, i) => {
          return html`<zfm-patch-editor-slot
            .slot=${i}
            .ml=${s.ml ?? 0}
            .fb=${s.fb ?? 0}
            .tl=${s.tl ?? 0}
            .ar=${s.ar ?? 0}
            .dr=${s.dr ?? 0}
            .sl=${s.sl ?? 0}
            .sr=${s.sr ?? 0}
            .rr=${s.rr ?? 0}
            @paramsUpdated=${this._onSlotParamsUpdated}
            @envParamsUpdated=${this._onSlotEnvParamsUpdated}
          ></zfm-patch-editor-slot>`;
        })}
      </div>
      <textarea
        .value=${this._formatPatch()}
        class=${classMap({ invalid: this._invalidPatch })}
        style="width:100%;font-family:monospace;margin-top:0.5em;resize:vertical"
        rows="10"
        @change=${this._onPatchInput}
      ></textarea>
    `;
  }
}

customElements.define("zfm-patch-editor-voice", ZfmPatchEditorVoice);
