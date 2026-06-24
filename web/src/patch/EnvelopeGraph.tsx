import type { EnvParams } from "./types.ts";
import classes from "./EnvelopeGraph.module.css";

// A small, read-only SVG depiction of an ADSR envelope derived from the
// Synth.Envelope.Params (ar/dr/sr/rr are per-sample deltas; sl is a level in
// [0,1]). The graph is schematic: the four segments are sized proportionally
// to their *durations* on a log scale so that both very fast and very slow
// phases stay visible, and the vertical levels (peak 1, sustain sl, end 0)
// are drawn to scale.
//
// This mirrors the envelope state machine in core/src/Synth.Envelope.update:
//   attack  : 0 -> 1   at rate ar
//   decay   : 1 -> sl  at rate dr
//   sustain : sl held, slowly declining at rate sr
//   release : sl -> 0  at rate rr
// Rates are per-sample deltas with levels in [0,1], so:
//   - a rate of 0 means the phase never advances: the envelope holds at the
//     phase's starting level and never reaches later phases;
//   - a rate of 1 (or more) means a full-level delta in a single sample,
//     i.e. an instantaneous transition drawn as a vertical segment.
// Release always occurs on key-off from whatever level the envelope is
// currently at, so it is always drawn (dashed) even when an earlier phase is
// stuck (e.g. dr = 0 still shows the release decay from level 1).

export interface EnvelopeGraphProps {
  env: EnvParams;
  accent: string;
  soft: string;
  width?: number;
  height?: number;
}

const VB_W = 100;
const VB_H = 40;

// Schematic width assigned to the "held" phases (sustain, and any phase that
// is stuck because its rate is 0). These have no natural finite duration, so
// we give them a fixed representative width on the log scale.
const HELD_W = Math.log1p(4);

function yOf(level: number): number {
  return (1 - level) * VB_H;
}

// Width (log-scaled) of a rate-limited ramp over `delta` levels.
// Returns null when the phase never advances (rate 0), or 0 when it is
// instantaneous (rate >= 1).
function rampWidth(delta: number, rate: number): number | null {
  if (rate <= 0) return null;
  if (rate >= 1) return 0;
  return Math.log1p(delta / rate);
}

interface Seg {
  w: number;
  level: number;
}

export function EnvelopeGraph({ env, accent, soft, width = 120, height = 48 }: EnvelopeGraphProps) {
  const { ar, dr, sl, sr, rr } = env;

  // Sustain declines slowly over the schematic sustain window. sr of 0 is the
  // normal "held sustain" case (no decline).
  const tSustain = 4;
  const sustainEnd = Math.max(0, sl - sr * tSustain);

  // Build the pre-release segments in order. If a phase's rate is 0 the
  // envelope gets stuck at that phase's starting level: later ramp phases are
  // skipped and the envelope holds at the stuck level until key-off.
  const pre: Seg[] = [];
  let stuckLevel: number | null = null;

  {
    const w = rampWidth(1, ar);
    if (w === null) stuckLevel = 0;
    else pre.push({ w, level: 1 });
  }
  if (stuckLevel === null) {
    const w = rampWidth(1 - sl, dr);
    if (w === null) stuckLevel = 1;
    else pre.push({ w, level: sl });
  }
  // A held window representing the time before key-off: the sustain decline
  // (sl -> sustainEnd) when the envelope reached sustain, or a flat hold at
  // the stuck level when an earlier phase never completed.
  pre.push({ w: HELD_W, level: stuckLevel ?? sustainEnd });

  // Release always occurs on key-off, starting from whatever level the
  // envelope is at: the stuck level if it never reached sustain, otherwise the
  // sustain-end level. So even a 0 decay rate (stuck at 1) still shows the
  // release decay when rr > 0. The release segment is always present and
  // drawn last with a dashed stroke, so there is always space at the end of
  // the graph for it.
  const keyOffLevel = stuckLevel ?? sustainEnd;
  const rw = rampWidth(keyOffLevel, rr);
  const releaseW = rw ?? HELD_W;
  const releaseLevel = rw === null ? keyOffLevel : 0;
  const releaseSegIdx = pre.length;
  const segs = [...pre, { w: releaseW, level: releaseLevel }];

  const total = segs.reduce((s, sg) => s + sg.w, 0) || 1;
  const scale = VB_W / total;

  // Cumulative x positions. pts[i+1] is the end point of segs[i]; pts[0] is
  // the start (level 0).
  const pts: Array<[number, number]> = [[0, yOf(0)]];
  let x = 0;
  for (const sg of segs) {
    x += sg.w * scale;
    pts.push([x, yOf(sg.level)]);
  }
  const xEnd = pts[pts.length - 1][0];

  const toPath = (ps: Array<[number, number]>) =>
    ps.map((p, i) => `${i === 0 ? "M" : "L"}${p[0].toFixed(2)} ${p[1].toFixed(2)}`).join(" ");

  // The solid outline covers everything up to (and including) the start of the
  // release segment. The release segment itself is drawn separately as a
  // dashed stroke, so we exclude it from the solid path to avoid the solid
  // line bleeding through the dash gaps.
  const solidPts = pts.slice(0, releaseSegIdx + 1);
  const solidPath = toPath(solidPts);
  const fillPath = `${toPath(pts)} L${xEnd.toFixed(2)} ${VB_H} L0 ${VB_H} Z`;

  const releasePath = toPath(pts.slice(releaseSegIdx, releaseSegIdx + 2));

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
