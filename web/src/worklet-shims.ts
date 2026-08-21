// Shims for stuff not available in worklets, such as TextEncoder/TextDecoder.

export function encodeBytes(str: string): Uint8Array {
  return Uint8Array.from(str, (c) => c.charCodeAt(0));
}

export function decodeBytes(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => String.fromCharCode(b)).join("");
}
