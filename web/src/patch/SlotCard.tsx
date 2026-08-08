import type { Dispatch, StateUpdater } from "preact/hooks";
import type { EnvParams, Patch, SlotIndex, SlotParams, SlotWave } from "./types.ts";
import { SLOT_WAVES, normalizeWs, usesWs, wsRange } from "./types.ts";
import { slotColor } from "./colors.ts";
import { isCarrier } from "./connections.ts";
import { ParamField } from "./ParamField.tsx";
import classes from "./SlotCard.module.css";

// A SlotCard is the detail panel for a single slot. It exposes all 8
// parameters (TL, ML, FB + AR, DR, SL, SR, RR) and visually reflects the
// slot's role in the routing graph (carrier / modulator / both) via a
// header badge. The accent color matches the slot's node in the graph.

export interface SlotCardProps {
  slot: SlotIndex;
  patch: Patch;
  onChange: Dispatch<StateUpdater<Patch>>;
}

/** Glyph for each waveform: one cycle sketched left-to-right in a 40x18
 *  viewBox, drawn as a single `path` so it can be colored via `currentColor`. */
const WAVE_PATHS: Record<SlotWave, string> = {
  sine: "M0 9 Q5 -1 10 9 Q15 19 20 9 Q25 -1 30 9 Q35 19 40 9",
  square: "M0 9 L0 15 L20 15 L20 3 L40 3 L40 9",
  triangle: "M0 15 L20 3 L40 15",
  saw: "M0 15 L40 3 L40 15",
  noise: "M0 9 L4 6 L8 12 L12 4 L16 11 L20 7 L24 14 L28 5 L32 10 L36 8 L40 9",
};

function WaveGlyph({ wave }: { wave: SlotWave }) {
  return (
    <svg class={classes.waveGlyph} viewBox="0 0 40 18" aria-hidden="true">
      <path d={WAVE_PATHS[wave]} style={{ strokeWidth: wave === "sine" ? 1.5 : 1.25 }} />
    </svg>
  );
}

/** Compact waveform selector for a slot: one button per supported wave,
 *  each showing a small SVG glyph and the name. The active
 *  wave is highlighted in the slot's accent color. */
function WaveSelect({
  value,
  accent,
  onChange,
}: {
  value: SlotWave;
  accent: string;
  onChange: (w: SlotWave) => void;
}) {
  return (
    <div class={classes.wave} role="group" aria-label="Waveform">
      {SLOT_WAVES.map((w) => (
        <button
          key={w}
          type="button"
          class={`${classes.waveOption}${w === value ? ` ${classes.waveOptionActive}` : ""}`}
          style={w === value ? { borderColor: accent, color: accent } : undefined}
          onClick={() => onChange(w)}
          aria-pressed={w === value}
          title={`${w} wave`}
        >
          <WaveGlyph wave={w} />
          <span>{w}</span>
        </button>
      ))}
    </div>
  );
}

export function SlotCard({ slot, patch, onChange }: SlotCardProps) {
  const color = slotColor(slot);
  const sp = patch.slotParams[slot]!;
  const env = patch.envParams[slot]!;
  const wave = patch.slotWaves[slot]!;
  const wsBounds = usesWs(wave) ? wsRange(wave) : null;

  const setSlotWave = (w: SlotWave) => {
    onChange((p) => {
      const slotWaves = [...p.slotWaves];
      slotWaves[slot] = w;
      const slotParams = [...p.slotParams];
      const cur = slotParams[slot]!;
      // Bring WS into the new waveform's valid range. For `noise` this
      // clamps (the default 0 would otherwise divide by zero in the band-pass
      // filter); for `square` an out-of-range value resets to 0.5.
      if (usesWs(w)) {
        slotParams[slot] = { ...cur, ws: normalizeWs(w, cur.ws) };
      }
      return { ...p, slotWaves, slotParams };
    });
  };

  const setSlotParam = <K extends keyof SlotParams>(key: K, v: SlotParams[K]) => {
    onChange((p) => {
      const slotParams = [...p.slotParams];
      slotParams[slot] = { ...slotParams[slot]!, [key]: v };
      return { ...p, slotParams };
    });
  };

  const setEnvParam = <K extends keyof EnvParams>(key: K, v: EnvParams[K]) => {
    onChange((p) => {
      const envParams = [...p.envParams];
      envParams[slot] = { ...envParams[slot]!, [key]: v };
      return { ...p, envParams };
    });
  };

  const role = isCarrier(patch.connections.edges, slot) ? "carrier" : "modulator";

  return (
    <div class={classes.root} style={{ borderColor: color.accent, background: color.soft }}>
      <div class={classes.header} style={{ background: color.accent }}>
        <span>Slot {slot}</span>
        <span class={classes.role}>{role}</span>
      </div>
      <div class={classes.body}>
        <WaveSelect value={wave} accent={color.accent} onChange={setSlotWave} />
        <div class={classes.group}>
          <div class={classes.groupLabel}>Oscillator</div>
          <ParamField
            label="TL"
            value={sp.tl}
            onChange={(v) => setSlotParam("tl", v)}
            min={0}
            max={1}
            step={0.1}
            accent={color.accent}
            title="Total level (output amplitude)"
          />
          <ParamField
            label="ML"
            value={sp.ml}
            onChange={(v) => setSlotParam("ml", v)}
            min={0}
            max={32}
            step={1}
            accent={color.accent}
            title="Frequency multiplier (ratio to base frequency)"
          />
          <ParamField
            label="FB"
            value={sp.fb}
            onChange={(v) => setSlotParam("fb", v)}
            min={0}
            max={1}
            step={0.1}
            accent={color.accent}
            title="Feedback (self-modulation amount)"
          />
          {wsBounds && (
            <ParamField
              label="WS"
              value={sp.ws}
              onChange={(v) => setSlotParam("ws", v)}
              min={wsBounds.min}
              max={wsBounds.max}
              step={wave === "noise" ? 1 : 0.01}
              accent={color.accent}
              title={wave === "square" ? "Duty cycle" : "Band-pass filter quality factor (Q)"}
            />
          )}
        </div>
        <div class={classes.group}>
          <div class={classes.groupLabel}>Envelope</div>
          <ParamField
            label="AR"
            value={env.ar}
            onChange={(v) => setEnvParam("ar", v)}
            min={1e-4}
            max={10}
            log
            accent={color.accent}
            title="Attack time in seconds (0 = hold)"
          />
          <ParamField
            label="DR"
            value={env.dr}
            onChange={(v) => setEnvParam("dr", v)}
            min={1e-4}
            max={10}
            log
            accent={color.accent}
            title="Decay time in seconds (0 = hold)"
          />
          <ParamField
            label="SL"
            value={env.sl}
            onChange={(v) => setEnvParam("sl", v)}
            min={0}
            max={1}
            step={0.1}
            accent={color.accent}
            title="Sustain level (linear)"
          />
          <ParamField
            label="SR"
            value={env.sr}
            onChange={(v) => setEnvParam("sr", v)}
            min={1e-4}
            max={10}
            log
            accent={color.accent}
            title="Sustain decay time in seconds (0 = hold)"
          />
          <ParamField
            label="RR"
            value={env.rr}
            onChange={(v) => setEnvParam("rr", v)}
            min={1e-4}
            max={10}
            log
            accent={color.accent}
            title="Release time in seconds (0 = hold)"
          />
        </div>
      </div>
    </div>
  );
}
