// Compute the minimal change that turns `from` into `to`. When an external
// value is pushed into the editor, replacing only the differing span keeps
// positions outside it (cursor, selection) intact instead of resetting them.
export function textDiff(from: string, to: string): { from: number; to: number; insert: string } {
  if (from === to) return { from: 0, to: 0, insert: "" };
  let start = 0;
  const shared = Math.min(from.length, to.length);
  while (start < shared && from.charCodeAt(start) === to.charCodeAt(start)) start++;
  let end = from.length;
  let end2 = to.length;
  while (end > start && end2 > start && from.charCodeAt(end - 1) === to.charCodeAt(end2 - 1)) {
    end--;
    end2--;
  }
  return { from: start, to: end, insert: to.slice(start, end2) };
}
