import type { EnvParams } from "./types.ts";
import classes from "./EnvelopeGraph.module.css";

// A small, read-only SVG depiction of an ADSR envelope derived from the
// Synth.Envelope.TimeParams (ar/dr/sr/rr are times in seconds; sl is a level
// in [0,1]). The graph is schematic: the four phases are sized
// proportionally to their *durations* on a log scale so that both very fast
// and very slow phases stay visible, while the vertical levels (peak 1,
// sustain sl, end 0) are drawn to scale. Decay, sustain and release are
// drawn as the exponential curves the synth produces.
//
// This mirrors the envelope state machine in core/src/Synth.Envelope.update:
//   attack  : 0 -> 1   linearly over ar seconds
//   decay   : 1 -> sl  exponentially over dr seconds
//   sustain : sl held, falling exponentially by 80 dB per sr seconds
//   release : current level -> 0, falling exponentially by 80 dB per rr
//             seconds
// A time of 0 means the phase never advances: the envelope holds at the
// phase's starting level and never reaches later phases.
// Release always occurs on key-off from whatever level the envelope is
// currently at, so it is always drawn (dashed) even when an earlier phase
// holds (e.g. dr = 0 still shows the release curve from level 1).

export interface EnvelopeGraphProps {
  env: EnvParams;
  accent: string;
  soft: string;
  width?: number;
  height?: number;
}

const VB_W = 100;
const VB_H = 40;

// Core Synth.Envelope.silence: the -80 dB level below which an
// exponentially-decaying envelope snaps to zero.
const SILENCE = 1e-4;

// Schematic duration in seconds of the held sustain window: the time between
// the decay phase completing and key-off. The sustain decline is drawn over
// this window.
const T_HOLD = 2;

// Schematic width assigned to the held phases (sustain, and any phase that
// holds because its time is 0). These have no natural finite duration, so we
// give them a fixed representative width on the log scale.
const HELD_W = Math.log1p(T_HOLD * 1000);

// Polyline samples per segment: enough to make the exponential curves read
// as curves rather than straight ramps.
const SAMPLES = 8;

function yOf(level: number): number {
  return (1 - level) * VB_H;
}

// Width (log-scaled) of a phase lasting `t` seconds. Returns null when the
// phase never advances (time 0: the envelope holds).
function timeWidth(t: number): number | null {
  if (t <= 0) return null;
  return Math.log1p(t * 1000);
}

// Exponential fall by a factor of SILENCE (80 dB) per `time` seconds,
// evaluated at fraction t in [0, 1] of a `duration`-seconds window from
// level `from`. Mirrors the synth's snap-to-zero at the silence threshold.
function expFall(from: number, time: number, duration: number, t: number): number {
  const v = from * Math.pow(SILENCE, (t * duration) / time);
  return v < SILENCE ? 0 : v;
}

interface Seg {
  w: number;
  /** Level over the segment, t in [0, 1]. The start level is the previous
   *  segment's end level. */
  level: (t: number) => number;
}

export function EnvelopeGraph({ env, accent, soft, width = 120, height = 48 }: EnvelopeGraphProps) {
  const { ar, dr, sl, sr, rr } = env;

  // Build the pre-release segments in order. If a phase's time is 0 the
  // envelope holds at that phase's starting level: later ramp phases are
  // skipped and the envelope holds at the stuck level until key-off.
  const pre: Seg[] = [];
  let stuckLevel: number | null = null;

  {
    const w = timeWidth(ar);
    if (w === null) stuckLevel = 0;
    else pre.push({ w, level: (t) => t });
  }
  if (stuckLevel === null) {
    const w = timeWidth(dr);
    if (w === null) stuckLevel = 1;
    // Exponential fall from 1 to sl over dr seconds (to the silence
    // threshold when sl is 0, which is visually indistinguishable).
    else pre.push({ w, level: (t) => Math.max(Math.pow(Math.max(sl, SILENCE), t), sl) });
  }

  // A held window representing the time before key-off: the sustain decline
  // when the envelope reached sustain, or a flat hold at the stuck level
  // when an earlier phase never completed.
  const sustainEnd = stuckLevel ?? (sr > 0 ? expFall(sl, sr, T_HOLD, 1) : sl);
  pre.push({
    w: HELD_W,
    level:
      stuckLevel === null && sr > 0 ? (t) => expFall(sl, sr, T_HOLD, t) : () => stuckLevel ?? sl,
  });

  // Release always occurs on key-off, starting from whatever level the
  // envelope is at: the stuck level if it never reached sustain, otherwise
  // the sustain-end level. So even a 0 decay time (stuck at 1) still shows
  // the release curve when rr > 0. The release segment is always present and
  // drawn last with a dashed stroke, so there is always space at the end of
  // the graph for it.
  const keyOffLevel = stuckLevel ?? sustainEnd;
  const rw = timeWidth(rr);
  const releaseSeg: Seg =
    rw === null
      ? { w: HELD_W, level: () => keyOffLevel }
      : { w: rw, level: (t) => expFall(keyOffLevel, rr, rr, t) };
  const releaseSegIdx = pre.length;
  const segs = [...pre, releaseSeg];

  const total = segs.reduce((s, sg) => s + sg.w, 0) || 1;
  const scale = VB_W / total;

  // Sample every segment into a polyline. pts[0] is the origin (level 0);
  // each segment appends SAMPLES points, so segment i ends at index
  // (i + 1) * SAMPLES.
  const pts: Array<[number, number]> = [[0, yOf(0)]];
  let x = 0;
  for (const sg of segs) {
    for (let k = 1; k <= SAMPLES; k++) {
      pts.push([x + (sg.w * k * scale) / SAMPLES, yOf(sg.level(k / SAMPLES))]);
    }
    x += sg.w * scale;
  }
  const xEnd = pts[pts.length - 1]![0];

  const toPath = (ps: Array<[number, number]>) =>
    ps.map((p, i) => `${i === 0 ? "M" : "L"}${p[0].toFixed(2)} ${p[1].toFixed(2)}`).join(" ");

  // The solid outline covers everything up to (and including) the start of
  // the release segment. The release segment itself is drawn separately as a
  // dashed stroke, so we exclude it from the solid path to avoid the solid
  // line bleeding through the dash gaps.
  const solidPts = pts.slice(0, releaseSegIdx * SAMPLES + 1);
  const solidPath = toPath(solidPts);
  const fillPath = `${toPath(pts)} L${xEnd.toFixed(2)} ${VB_H} L0 ${VB_H} Z`;

  const releasePath = toPath(pts.slice(releaseSegIdx * SAMPLES));

  return (
    <svg
      class={classes.root}
      viewBox={`0 0 ${VB_W} ${VB_H}`}
      width={width}
      height={height}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <path d={fillPath} style={{ fill: soft }} />
      <path
        d={solidPath}
        style={{
          fill: "none",
          stroke: accent,
          strokeWidth: 1.5,
          strokeLinejoin: "round",
          strokeLinecap: "round",
          vectorEffect: "non-scaling-stroke",
        }}
      />
      <path
        d={releasePath}
        style={{
          fill: "none",
          stroke: accent,
          strokeWidth: 1.5,
          strokeLinejoin: "round",
          strokeLinecap: "round",
          vectorEffect: "non-scaling-stroke",
          strokeDasharray: "3 2",
        }}
      />
    </svg>
  );
}
