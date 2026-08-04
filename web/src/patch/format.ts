// Formatting a patch back into MML source text, and inserting that text into a
// track at a sensible position.
//
// A patch reads as:
//
//   @<name> <connections>.
//     <wave> <tl> <ml> <fb> [<ws>] <ar> <dr> <sl> <sr> <rr>
//     ...one continuation line per slot...
//
// The wave-specific (WS) parameter is emitted only for waveforms that use
// it (`square`, `noise`), matching how core Compiler.zig parses slots: WS
// is skipped entirely for `sine`, `triangle`, and `saw`.
//
// The connections part is a whitespace-separated list of slot-index chains
// (`0 1 2` connects 0->1->2), with `,` starting a fresh chain and `.` ending
// the line. Any edge set can be serialized as `from to` pairs joined by `,`
// (`0 1, 1 2` is equivalent to the chain `0 1 2`), so that is the form we
// emit: simple, always valid, and reads naturally for the common two-stack
// and chain shapes.

import {
  N_LFOS,
  N_SLOTS,
  type EnvParams,
  type LfoParams,
  type Patch,
  type SlotParams,
  type SlotWave,
  usesWs,
} from "./types.ts";

/**
 * Format a single numeric parameter for MML output.
 *
 * Patch values originate either from JS literals (clean numbers like `0.7`)
 * or from the compiler, which emits f32 values as their exact f64 expansion
 * (e.g. `0.7` comes back as `0.699999988079071`). The MML float parser
 * (core `Compiler.takeNumber`) accepts only digits, sign, and `.` — no
 * scientific notation — and parses to f32, so we emit the shortest decimal
 * that round-trips through f32, in fixed-point form.
 */
export function formatNumber(n: number): string {
  if (!Number.isFinite(n)) return "0";
  const target = new Float32Array([n])[0];
  for (let p = 1; p <= 9; p++) {
    const s = toFixedForm(n.toPrecision(p));
    if (new Float32Array([Number.parseFloat(s)])[0] === target) return s;
  }
  return toFixedForm(n.toPrecision(9));
}

/**
 * Render a number string in plain fixed-point form (no `e`/`E`) with no
 * trailing zeros or trailing decimal point. `toPrecision` uses scientific
 * notation for very small/large magnitudes, which the MML parser rejects, so
 * those are converted via `toFixed`.
 */
function toFixedForm(s: string): string {
  if (s.includes("e") || s.includes("E")) {
    const v = Number.parseFloat(s);
    if (!Number.isFinite(v)) return "0";
    try {
      s = v.toFixed(20);
    } catch {
      // toFixed throws for |v| >= 1e21; patch parameters never reach that
      // magnitude, but fall back defensively.
      s = String(v);
    }
  }
  if (s.includes(".")) {
    s = s.replace(/0+$/, "").replace(/\.$/, "");
  }
  return s;
}

/** Serialize a patch's edge matrix as `from to` pairs joined by `, `. */
function formatConnections(edges: boolean[][]): string {
  const parts: string[] = [];
  for (let from = 0; from < N_SLOTS; from++) {
    for (let to = 0; to < N_SLOTS; to++) {
      if (edges[from]![to]!) parts.push(`${from} ${to}`);
    }
  }
  return parts.join(", ");
}

/**
 * The index of the last slot that should be emitted: the highest slot with
 * any non-zero parameter, or any slot referenced by the routing graph. This
 * mirrors how hand-written patches omit trailing all-zero slots while still
 * emitting the slots a connection touches (e.g. `@x 0 1.` with two all-zero
 * slot lines).
 */
function lastRelevantSlot(patch: Patch): number {
  let last = -1;
  for (let i = 0; i < N_SLOTS; i++) {
    const sp = patch.slotParams[i]!;
    const ep = patch.envParams[i]!;
    const wave = patch.slotWaves[i]!;
    if (
      sp.tl !== 0 ||
      sp.ml !== 0 ||
      sp.fb !== 0 ||
      ep.ar !== 0 ||
      ep.dr !== 0 ||
      ep.sl !== 0 ||
      ep.sr !== 0 ||
      ep.rr !== 0 ||
      wave !== "sine"
    ) {
      last = i;
    }
  }
  for (let from = 0; from < N_SLOTS; from++) {
    for (let to = 0; to < N_SLOTS; to++) {
      if (patch.connections.edges[from]![to]!) {
        last = Math.max(last, from, to);
      }
    }
  }
  return last;
}

function formatSlotLine(wave: SlotWave, sp: SlotParams, ep: EnvParams): string {
  const parts: string[] = [wave, formatNumber(sp.tl), formatNumber(sp.ml), formatNumber(sp.fb)];
  // WS is only emitted for waveforms that use it (square, noise), matching
  // the compiler, which parses WS only when `Wave.usesWs()` is true.
  if (usesWs(wave)) parts.push(formatNumber(sp.ws));
  parts.push(
    formatNumber(ep.ar),
    formatNumber(ep.dr),
    formatNumber(ep.sl),
    formatNumber(ep.sr),
    formatNumber(ep.rr),
  );
  return "  " + parts.join(" ");
}

/** Serialize one user LFO's parameters as the four MML commands
 *  (MT/MS/MW/MO/MA) that fully describe it, matching core
 *  Compiler.compileLfoCommand. */
export function lfoToMml(index: number, p: LfoParams): string {
  let wave = `MW${index},constant`;
  if ("sine" in p.wave) wave = `MW${index},sine,${formatNumber(p.wave.sine.freq)}`;
  else if ("exp" in p.wave) wave = `MW${index},exp,${formatNumber(p.wave.exp.mul)}`;

  return [
    `MT${index},${p.target}`,
    `MS${index},${formatNumber(p.size.scale)},${formatNumber(p.size.offset)}`,
    wave,
    `MO${index},${p.trigger}`,
    `MA${index},${p.adjust ? "on" : "off"}`,
  ].join(" ");
}

/**
 * Render a patch as MML source text (no trailing newline). Enabled LFOs are
 * emitted as `; LFO preset:` comments directly above the `@` definition
 * (the compiler parses these back into the patch's LFO state); empty
 * routing produces `@<name> .`; slots beyond the last relevant one are
 * omitted.
 */
export function formatPatch(patch: Patch): string {
  const lines: string[] = [];
  for (let i = 0; i < N_LFOS; i++) {
    const lfo = patch.lfos?.[i];
    if (lfo?.enabled) lines.push(`; LFO preset: ${lfoToMml(i, lfo.params)}`);
  }
  lines.push(`@${patch.name} ${formatConnections(patch.connections.edges)}.`);
  const last = lastRelevantSlot(patch);
  for (let i = 0; i <= last; i++) {
    lines.push(formatSlotLine(patch.slotWaves[i]!, patch.slotParams[i]!, patch.envParams[i]!));
  }
  return lines.join("\n");
}

/** Serialize a bank (a list of patches) as MML source text. */
export function formatBank(bank: Patch[]): string {
  return bank.map(formatPatch).join("\n\n") + "\n";
}

/**
 * Insert a patch's source text into a track at the "best" position and return
 * the new source.
 *
 * Heuristic: find the last line beginning with `@` (a patch definition).
 * After it, find the first line that begins with a non-whitespace character
 * (the first non-continuation line), or the end of the document if there is
 * none. Insert the patch before that point, followed by a blank line. If the
 * document has no patch definition at all, append at the end.
 */
export function insertPatch(source: string, patch: Patch): string {
  const text = formatPatch(patch);
  const len = source.length;

  // Start offset of every line (position 0 plus each position after a `\n`).
  const lineStarts: number[] = [0];
  for (let i = 0; i < len; i++) {
    if (source[i] === "\n") lineStarts.push(i + 1);
  }

  // First character of the line starting at `start`, or null for an empty
  // line (a line start pointing at another `\n`, or past end of document).
  const firstChar = (start: number): string | null => {
    if (start >= len) return null;
    const ch = source[start]!;
    return ch === "\n" ? null : ch;
  };
  const isWhitespace = (ch: string): boolean => ch === " " || ch === "\t" || ch === "\r";

  let lastPatchLine = -1;
  for (let i = 0; i < lineStarts.length; i++) {
    if (firstChar(lineStarts[i]!) === "@") lastPatchLine = i;
  }

  let offset: number;
  if (lastPatchLine === -1) {
    offset = len;
  } else {
    offset = len; // default: end of document
    for (let i = lastPatchLine + 1; i < lineStarts.length; i++) {
      const start = lineStarts[i]!;
      const ch = firstChar(start);
      if (ch !== null && !isWhitespace(ch)) {
        offset = start;
        break;
      }
    }
  }

  const block = `${text}\n\n`;
  // When appending at the end of a line that isn't newline-terminated,
  // start the patch on its own line so the leading `@` isn't swallowed by
  // the preceding line (e.g. part content).
  if (offset === len && len > 0 && source[len - 1] !== "\n") {
    return `${source.slice(0, offset)}\n${block}${source.slice(offset)}`;
  }
  return source.slice(0, offset) + block + source.slice(offset);
}
