import { N_LFOS, N_SLOTS, clonePatch, type Patch } from "../patch/types.ts";

// TODO: replace this with some kind of code generation
/** Structural check that a deserialized patch has the expected shape, so a
 *  malformed or version-mismatched persisted bank is ignored rather than
 *  crashing the editor. `lfos` is optional: banks persisted before LFOs were
 *  stored on the patch are still accepted (clonePatch fills in defaults). */
function isPatchLike(v: unknown): v is Patch {
  if (typeof v !== "object" || v === null) return false;
  const p = v as Record<string, unknown>;
  if (typeof p.name !== "string") return false;
  const c = p.connections;
  if (typeof c !== "object" || c === null) return false;
  const edges = (c as { edges?: unknown }).edges;
  if (!Array.isArray(edges) || edges.length !== N_SLOTS) return false;
  if (!edges.every((r) => Array.isArray(r) && r.length === N_SLOTS)) return false;
  if (!Array.isArray(p.slotWaves) || p.slotWaves.length !== N_SLOTS) return false;
  if (!Array.isArray(p.slotParams) || p.slotParams.length !== N_SLOTS) return false;
  if (!Array.isArray(p.envParams) || p.envParams.length !== N_SLOTS) return false;
  if (p.lfos !== undefined && (!Array.isArray(p.lfos) || p.lfos.length !== N_LFOS)) return false;
  return true;
}

/** Validate a deserialized bank, returning only well-formed patches (and
 *  `undefined` when none survive, so the caller falls back to its default). */
export function sanitizeBank(b: unknown): Patch[] | undefined {
  if (!Array.isArray(b) || b.length === 0) return undefined;
  const patches = b.filter(isPatchLike).map((p) => clonePatch(p as Patch));
  return patches.length > 0 ? patches : undefined;
}
