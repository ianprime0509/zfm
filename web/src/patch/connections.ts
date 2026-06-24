// Helpers for working with the slot routing graph.
//
// In the UI we store edges in the natural `from -> to` orientation:
//   edges[from][to] === true  <=>  slot `from` modulates slot `to`.
// The core stores the transpose (`deps[to].isSet(from)`); the two are
// equivalent and we never need to round-trip through the core here.

import { N_SLOTS, type Connections, type SlotIndex } from "./types.ts";

export type EdgeMatrix = boolean[][];

export function cloneEdges(edges: EdgeMatrix): EdgeMatrix {
  return edges.map((row) => [...row]);
}

export function isCarrier(edges: EdgeMatrix, slot: SlotIndex): boolean {
  for (let to = 0; to < N_SLOTS; to++) {
    if (edges[slot][to]) return false;
  }
  return true;
}

/** Transitive closure of the `from -> to` relation via Warshall's algorithm.
 *  reachable[from][to] === true  <=>  there is a path from `from` to `to`. */
export function reachable(edges: EdgeMatrix): boolean[][] {
  const r: boolean[][] = edges.map((row) => [...row]);
  for (let k = 0; k < N_SLOTS; k++) {
    for (let i = 0; i < N_SLOTS; i++) {
      if (!r[i][k]) continue;
      for (let j = 0; j < N_SLOTS; j++) {
        if (r[k][j]) r[i][j] = true;
      }
    }
  }
  return r;
}

/** Adding edge `from -> to` would create a cycle iff `to` can already reach
 *  `from` (which also covers the self-loop case from === to). */
export function wouldCycle(edges: EdgeMatrix, from: SlotIndex, to: SlotIndex): boolean {
  if (from === to) return true;
  return reachable(edges)[to][from];
}

export function toggleEdge(c: Connections, from: SlotIndex, to: SlotIndex): Connections {
  const edges = cloneEdges(c.edges);
  edges[from][to] = !edges[from][to];
  return { edges };
}

/** Structural equality of two edge matrices (same shape assumed). */
export function edgesEqual(a: EdgeMatrix, b: EdgeMatrix): boolean {
  for (let i = 0; i < N_SLOTS; i++) {
    for (let j = 0; j < N_SLOTS; j++) {
      if (a[i][j] !== b[i][j]) return false;
    }
  }
  return true;
}
