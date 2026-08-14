import type { LfoParams, LfoState, LfoTarget, LfoWave, LfoWaveTag } from "./types.ts";
import { ParamField } from "./ParamField.tsx";
import classes from "./LfoPanel.module.css";

// LfoPanel lets the user test the effect of the 4 user LFOs on the patch
// being edited, while playing it with the keyboard.
//
// Each LFO modulates a voice parameter (its target): its output,
// `scale * wave(t) + offset`, is added to the target. For "freq" that is the
// voice frequency in Hz (e.g. a sine at 5 Hz with scale 5 is a ±5 Hz
// vibrato; a constant wave with scale -2 is a 2 Hz pitch drop). For "pan" it
// is the voice pan, where -1 is full left and +1 is full right.
//
// The panel edits the LFO state stored on the patch (which also carries it
// into the MML preview as `; LFO preset:` comments); usePatchSynth applies
// it to all 8 keyboard voices with the same staging discipline as patch
// edits (nothing touches the synth until audio is live, and edits are staged
// while the track player owns the synth).

export interface LfoPanelProps {
  lfos: LfoState[];
  /** Functional-updater-only so the parent can write back into the patch. */
  onChange: (f: (lfos: LfoState[]) => LfoState[]) => void;
}

const WAVE_DEFAULTS: Record<LfoWaveTag, () => LfoWave> = {
  con: () => ({ con: {} }),
  sin: () => ({ sin: { freq: 5 } }),
  exp: () => ({ exp: { mul: -1 } }),
};

/** Per-target config for the output group: the unit shown in the group label
 *  and the scale/offset field constraints. The LFO output is added to the
 *  target, so the sensible ranges differ (Hz for freq, [-1, 1] for pan). */
const OUTPUT_CFG: Record<
  LfoTarget,
  {
    unit: string;
    min: number;
    max: number;
    step: number;
    scaleTitle: string;
    offsetTitle: string;
  }
> = {
  freq: {
    unit: "Hz",
    min: -50,
    max: 50,
    step: 0.1,
    scaleTitle: "Amount the wave output is scaled by (Hz); e.g. vibrato depth",
    offsetTitle: "Constant added to the wave output (Hz)",
  },
  pan: {
    unit: "pan",
    min: -1,
    max: 1,
    step: 0.01,
    scaleTitle: "Amount the wave output is scaled by (pan; -1 = left, +1 = right)",
    offsetTitle: "Constant added to the wave output (pan; -1 = left, +1 = right)",
  },
  vol: {
    unit: "vol",
    min: 0,
    max: 1,
    step: 0.01,
    scaleTitle: "Amount the wave output is scaled by (volume)",
    offsetTitle: "Constant added to the wave output (volume)",
  },
};

function waveTag(wave: LfoWave): LfoWaveTag {
  if ("con" in wave) return "con";
  if ("sin" in wave) return "sin";
  return "exp";
}

interface LfoCardProps {
  index: number;
  lfo: LfoState;
  onChange: (f: (lfo: LfoState) => LfoState) => void;
}

function LfoCard({ index, lfo, onChange }: LfoCardProps) {
  const setParams = (f: (p: LfoParams) => LfoParams) => {
    onChange((l) => ({ ...l, params: f(l.params) }));
  };

  const tag = waveTag(lfo.params.wave);
  const out = OUTPUT_CFG[lfo.params.target];

  return (
    <div class={classes.card}>
      <div class={classes.header}>
        <span>LFO {index}</span>
        <label class={classes.enable}>
          <input
            type="checkbox"
            checked={lfo.enabled}
            onChange={(e) => onChange((l) => ({ ...l, enabled: e.currentTarget.checked }))}
          />
          on
        </label>
      </div>
      <div class={classes.body}>
        <div class={classes.group}>
          <div class={classes.groupLabel}>Wave</div>
          <label class={classes.selectRow}>
            <span>shape</span>
            <select
              value={tag}
              onChange={(e) =>
                setParams((p) => ({
                  ...p,
                  wave: WAVE_DEFAULTS[e.currentTarget.value as LfoWaveTag](),
                }))
              }
            >
              <option value="con">con</option>
              <option value="sin">sin</option>
              <option value="exp">exp</option>
            </select>
          </label>
          {"sin" in lfo.params.wave && (
            <ParamField
              label="freq"
              value={lfo.params.wave.sin.freq}
              onChange={(v) => setParams((p) => ({ ...p, wave: { sin: { freq: v } } }))}
              min={0.01}
              max={20}
              log
              title="Sine frequency (Hz)"
            />
          )}
          {"exp" in lfo.params.wave && (
            <ParamField
              label="mul"
              value={lfo.params.wave.exp.mul}
              onChange={(v) => setParams((p) => ({ ...p, wave: { exp: { mul: v } } }))}
              min={-20}
              max={20}
              step={0.1}
              title="Exponential rate (wave output is 2^(mul * t); negative decays)"
            />
          )}
        </div>
        <div class={classes.group}>
          <div class={classes.groupLabel}>Output ({out.unit})</div>
          <label class={classes.selectRow}>
            <span>target</span>
            <select
              value={lfo.params.target}
              onChange={(e) =>
                setParams((p) => ({ ...p, target: e.currentTarget.value as LfoTarget }))
              }
            >
              {Object.keys(OUTPUT_CFG).map((target) => (
                <option key={target} value={target}>
                  {target}
                </option>
              ))}
            </select>
          </label>
          <ParamField
            label="scale"
            value={lfo.params.size.scale}
            onChange={(v) => setParams((p) => ({ ...p, size: { ...p.size, scale: v } }))}
            min={out.min}
            max={out.max}
            step={out.step}
            title={out.scaleTitle}
          />
          <ParamField
            label="offset"
            value={lfo.params.size.offset}
            onChange={(v) => setParams((p) => ({ ...p, size: { ...p.size, offset: v } }))}
            min={out.min}
            max={out.max}
            step={out.step}
            title={out.offsetTitle}
          />
        </div>
        <label class={classes.check}>
          <input
            type="checkbox"
            checked={lfo.params.trigger === "key_on"}
            onChange={(e) =>
              setParams((p) => ({ ...p, trigger: e.currentTarget.checked ? "key_on" : "none" }))
            }
          />
          retrigger on key on
        </label>
        <label class={classes.check}>
          <input
            type="checkbox"
            checked={lfo.params.adjust}
            onChange={(e) => setParams((p) => ({ ...p, adjust: e.currentTarget.checked }))}
          />
          adjust scale/offset proportionally to 440Hz base
        </label>
      </div>
    </div>
  );
}

export function LfoPanel({ lfos, onChange }: LfoPanelProps) {
  return (
    <section class={classes.root}>
      <div class={classes.title}>LFO previews</div>
      <div class={classes.grid}>
        {lfos.map((lfo, i) => (
          <LfoCard
            key={i}
            index={i}
            lfo={lfo}
            onChange={(f) => onChange((cur) => cur.map((l, j) => (j === i ? f(l) : l)))}
          />
        ))}
      </div>
    </section>
  );
}
