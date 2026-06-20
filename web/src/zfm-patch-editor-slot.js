import { css, html, LitElement } from "lit";
import { classMap } from "lit/directives/class-map.js";

export class ZfmPatchEditorSlot extends LitElement {
  static properties = {
    slot: {},
    tl: {},
    ml: {},
    fb: {},
    ar: {},
    dr: {},
    sl: {},
    sr: {},
    rr: {},
  };

  _invalid = new Set();

  _inputValue(e, name) {
    const val = parseFloat(e.target.value);
    const valid = Number.isFinite(val);
    if (valid) {
      this._invalid.delete(name);
    } else {
      this._invalid.add(name);
    }
    this.requestUpdate();
    return valid ? val : null;
  }

  _onTlInput(e) {
    const val = this._inputValue(e, "tl");
    if (val === null) return;
    this.tl = val;
    this._dispatchParamsUpdated();
  }
  _onMlInput(e) {
    const val = this._inputValue(e, "ml");
    if (val === null) return;
    this.ml = val;
    this._dispatchParamsUpdated();
  }
  _onFbInput(e) {
    const val = this._inputValue(e, "fb");
    if (val === null) return;
    this.fb = val;
    this._dispatchParamsUpdated();
  }
  _onArInput(e) {
    const val = this._inputValue(e, "ar");
    if (val === null) return;
    this.ar = val;
    this._dispatchEnvParamsUpdated();
  }
  _onDrInput(e) {
    const val = this._inputValue(e, "dr");
    if (val === null) return;
    this.dr = val;
    this._dispatchEnvParamsUpdated();
  }
  _onSlInput(e) {
    const val = this._inputValue(e, "sl");
    if (val === null) return;
    this.sl = val;
    this._dispatchEnvParamsUpdated();
  }
  _onSrInput(e) {
    const val = this._inputValue(e, "sr");
    if (val === null) return;
    this.sr = val;
    this._dispatchEnvParamsUpdated();
  }
  _onRrInput(e) {
    const val = this._inputValue(e, "rr");
    if (val === null) return;
    this.rr = val;
    this._dispatchEnvParamsUpdated();
  }

  _dispatchParamsUpdated() {
    this.dispatchEvent(
      new CustomEvent("paramsUpdated", {
        detail: { tl: this.tl, ml: this.ml, fb: this.fb, slot: this.slot },
      }),
    );
  }

  _dispatchEnvParamsUpdated() {
    this.dispatchEvent(
      new CustomEvent("envParamsUpdated", {
        detail: {
          ar: this.ar,
          dr: this.dr,
          sl: this.sl,
          sr: this.sr,
          rr: this.rr,
          slot: this.slot,
        },
      }),
    );
  }

  static styles = css`
    :host {
      display: block;
    }

    .slot {
      background: #e0e0e0;
      color: #333;
      padding: 0.5em;
      font-family: monospace;
    }

    .top-row {
      display: flex;
      align-items: center;
      gap: 0.5em;
    }

    .slot-num {
      font-weight: bold;
      margin-right: auto;
    }

    .env-rows {
      display: grid;
      grid-template-columns: repeat(2, auto);
      gap: 0.25em 0.5em;
      justify-content: start;
    }

    .env-rows label {
      display: contents;
    }

    .env-rows span {
      text-align: right;
    }

    input[type="number"]::-webkit-inner-spin-button,
    input[type="number"]::-webkit-outer-spin-button {
      -webkit-appearance: none;
      margin: 0;
    }

    input[type="number"] {
      -moz-appearance: textfield;
    }

    input {
      background: none;
      border: none;
      color: #333;
      font-family: monospace;
      font-size: inherit;
      outline: none;
      width: 5em;
    }

    input.invalid {
      background: #ffcccc;
    }

    input:focus {
      outline: 1px dotted #333;
    }
  `;

  render() {
    return html`
      <div class="slot">
        <div class="top-row">
          <span class="slot-num">${this.slot}</span>
          <label
            ><span>tl</span>
            <input
              type="number"
              step="any"
              .value=${this.tl}
              class=${classMap({ invalid: this._invalid.has("tl") })}
              @input=${this._onTlInput}
          /></label>
          <label
            ><span>ml</span>
            <input
              type="number"
              step="any"
              .value=${this.ml}
              class=${classMap({ invalid: this._invalid.has("ml") })}
              @input=${this._onMlInput}
          /></label>
          <label
            ><span>fb</span>
            <input
              type="number"
              step="any"
              .value=${this.fb}
              class=${classMap({ invalid: this._invalid.has("fb") })}
              @input=${this._onFbInput}
          /></label>
        </div>
        <hr />
        <div class="env-rows">
          <label
            ><span>ar</span>
            <input
              type="number"
              step="any"
              .value=${this.ar}
              class=${classMap({ invalid: this._invalid.has("ar") })}
              @input=${this._onArInput}
          /></label>
          <label
            ><span>dr</span>
            <input
              type="number"
              step="any"
              .value=${this.dr}
              class=${classMap({ invalid: this._invalid.has("dr") })}
              @input=${this._onDrInput}
          /></label>
          <label
            ><span>sl</span>
            <input
              type="number"
              step="any"
              .value=${this.sl}
              class=${classMap({ invalid: this._invalid.has("sl") })}
              @input=${this._onSlInput}
          /></label>
          <label
            ><span>sr</span>
            <input
              type="number"
              step="any"
              .value=${this.sr}
              class=${classMap({ invalid: this._invalid.has("sr") })}
              @input=${this._onSrInput}
          /></label>
          <label
            ><span>rr</span>
            <input
              type="number"
              step="any"
              .value=${this.rr}
              class=${classMap({ invalid: this._invalid.has("rr") })}
              @input=${this._onRrInput}
          /></label>
        </div>
      </div>
    `;
  }
}

customElements.define("zfm-patch-editor-slot", ZfmPatchEditorSlot);
