import { describe, expect, it } from "vite-plus/test";
import { ELECTRIC_PIANO } from "./presets.ts";
import { emptyPatch } from "./types.ts";
import { formatPatch, insertPatch } from "./format.ts";

describe("formatPatch", () => {
  it("formats electric-piano back to canonical source", () => {
    expect(formatPatch(ELECTRIC_PIANO)).toBe(
      [
        "@electric-piano 0 1, 2 3.",
        "  sine 0.7 11 3 1 0 0 0 1",
        "  sine 0.3 12 0 1 0.0001 0 0 1",
        "  sine 0.7 1 0 1 0.000025 0.2 0 0.00001",
        "  sine 1 1 0 1 0.00001 0 0 0.00005",
      ].join("\n"),
    );
  });

  it("cleans compiler-emitted f32 expansions to shortest round-trip", () => {
    // The compiler returns 0.7f32 as the exact f64 expansion 0.699999988079071.
    const p = {
      ...ELECTRIC_PIANO,
      slotParams: ELECTRIC_PIANO.slotParams.map((s, i) =>
        i === 0 ? { ...s, tl: 0.699999988079071 } : s,
      ),
    };
    expect(formatPatch(p).split("\n")[1]).toBe("  sine 0.7 11 3 1 0 0 0 1");
  });

  it("emits empty routing as `@name .`", () => {
    const p = { ...emptyPatch(), name: "rim" };
    p.slotParams[0]!.tl = 1;
    p.slotParams[0]!.ml = 50;
    p.slotParams[0]!.fb = 10;
    p.envParams[0]!.ar = 1;
    p.envParams[0]!.dr = 0.001;
    p.envParams[0]!.rr = 1;
    expect(formatPatch(p)).toBe("@rim .\n  sine 1 50 10 1 0.001 0 0 1");
  });

  it("emits slot lines for every slot a connection touches", () => {
    // All-zero patch with edge 0->1 should still emit two slot lines.
    const p = { ...emptyPatch(), name: "patch-3" };
    p.connections.edges[0][1] = true;
    expect(formatPatch(p)).toBe("@patch-3 0 1.\n  sine 0 0 0 0 0 0 0 0\n  sine 0 0 0 0 0 0 0 0");
  });

  it("emits WS after FB for square (duty cycle)", () => {
    const p = { ...emptyPatch(), name: "squ" };
    p.slotWaves[0] = "square";
    p.slotParams[0] = { tl: 0.5, ml: 1, fb: 0, ws: 0.5 };
    p.envParams[0] = { ar: 1, dr: 0, sl: 0, sr: 0, rr: 1 };
    expect(formatPatch(p)).toBe("@squ .\n  square 0.5 1 0 0.5 1 0 0 0 1");
  });

  it("emits WS after FB for noise (band-pass Q)", () => {
    const p = { ...emptyPatch(), name: "noi" };
    p.slotWaves[0] = "noise";
    p.slotParams[0] = { tl: 0.5, ml: 1, fb: 0, ws: 5 };
    p.envParams[0] = { ar: 1, dr: 0, sl: 0, sr: 0, rr: 1 };
    expect(formatPatch(p)).toBe("@noi .\n  noise 0.5 1 0 5 1 0 0 0 1");
  });

  it("omits WS for sine even when ws is non-zero", () => {
    // Sine does not use WS, so a stale non-zero value is not emitted.
    const p = { ...emptyPatch(), name: "sin" };
    p.slotParams[0] = { tl: 0.5, ml: 1, fb: 0, ws: 9 };
    p.envParams[0] = { ar: 1, dr: 0, sl: 0, sr: 0, rr: 1 };
    expect(formatPatch(p)).toBe("@sin .\n  sine 0.5 1 0 1 0 0 0 1");
  });

  it("omits WS for triangle even when ws is non-zero", () => {
    const p = { ...emptyPatch(), name: "tri" };
    p.slotWaves[0] = "triangle";
    p.slotParams[0] = { tl: 0.5, ml: 1, fb: 0, ws: 9 };
    p.envParams[0] = { ar: 1, dr: 0, sl: 0, sr: 0, rr: 1 };
    expect(formatPatch(p)).toBe("@tri .\n  triangle 0.5 1 0 1 0 0 0 1");
  });

  it("omits WS for saw even when ws is non-zero", () => {
    const p = { ...emptyPatch(), name: "sw" };
    p.slotWaves[0] = "saw";
    p.slotParams[0] = { tl: 0.5, ml: 1, fb: 0, ws: 9 };
    p.envParams[0] = { ar: 1, dr: 0, sl: 0, sr: 0, rr: 1 };
    expect(formatPatch(p)).toBe("@sw .\n  saw 0.5 1 0 1 0 0 0 1");
  });

  it("emits LFO preset comments above the patch for enabled LFOs", () => {
    const p = { ...emptyPatch(), name: "vib" };
    p.lfos[0]!.enabled = true;
    p.lfos[0]!.params = {
      target: "freq",
      size: { scale: 5, offset: 0 },
      wave: { sine: { freq: 5 } },
      trigger: "key_on",
      time_unit: "seconds",
      adjust: true,
    };
    p.lfos[1]!.enabled = true;
    p.lfos[1]!.params = {
      target: "pan",
      size: { scale: 0.25, offset: -0.5 },
      wave: { exp: { mul: -2 } },
      trigger: "none",
      time_unit: "seconds",
      adjust: false,
    };
    expect(formatPatch(p).split("\n").slice(0, 3)).toEqual([
      "; LFO preset: MT0,freq MS0,5,0 MW0,sine,5 MO0,key_on MA0,on",
      "; LFO preset: MT1,pan MS1,0.25,-0.5 MW1,exp,-2 MO1,none MA1,off",
      "@vib .",
    ]);
  });

  it("omits LFO preset comments when no LFO is enabled", () => {
    expect(formatPatch({ ...emptyPatch(), name: "quiet" }).split("\n")[0]).toBe("@quiet .");
  });
});

describe("insertPatch", () => {
  const before = [
    "@patch-1 0 1.",
    "  sine 0 0 0 0 0 0 0 0",
    "  sine 0 0 0 0 0 0 0 0",
    "",
    "@patch-2 0 1.",
    "  sine 0 0 0 0 0 0 0 0",
    "  sine 0 0 0 0 0 0 0 0",
    "",
    "A cdef ; <-- patch should be inserted before this line",
  ].join("\n");

  const patch = { ...emptyPatch(), name: "patch-3" };
  patch.connections.edges[0][1] = true;

  const expected = [
    "@patch-1 0 1.",
    "  sine 0 0 0 0 0 0 0 0",
    "  sine 0 0 0 0 0 0 0 0",
    "",
    "@patch-2 0 1.",
    "  sine 0 0 0 0 0 0 0 0",
    "  sine 0 0 0 0 0 0 0 0",
    "",
    "@patch-3 0 1.",
    "  sine 0 0 0 0 0 0 0 0",
    "  sine 0 0 0 0 0 0 0 0",
    "",
    "A cdef ; <-- patch should be inserted before this line",
  ].join("\n");

  it("inserts before the first non-continuation line after the last @ line", () => {
    expect(insertPatch(before, patch)).toBe(expected);
  });

  it("appends at end when only continuation lines follow the last @ line", () => {
    const src = "@a 0 1.\n  sine 1 1 0 1 0 0 0 1\n  sine 1 1 0 1 0 0 0 1";
    const out = insertPatch(src, patch);
    expect(out).toBe(
      "@a 0 1.\n  sine 1 1 0 1 0 0 0 1\n  sine 1 1 0 1 0 0 0 1\n@patch-3 0 1.\n  sine 0 0 0 0 0 0 0 0\n  sine 0 0 0 0 0 0 0 0\n\n",
    );
  });

  it("appends at end when there is no patch definition", () => {
    const src = "#title Test\nA cdef";
    const out = insertPatch(src, patch);
    expect(out).toBe(
      "#title Test\nA cdef\n@patch-3 0 1.\n  sine 0 0 0 0 0 0 0 0\n  sine 0 0 0 0 0 0 0 0\n\n",
    );
  });
});
