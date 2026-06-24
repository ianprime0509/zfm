// Tiny localStorage wrappers used to persist the user's in-progress work
// (the track source and the patch bank) so it can be restored on the next
// load. All access is guarded: storage may be unavailable (private mode,
// SSR, etc.) or hold malformed data from an older version, so every read is
// defensive and falls back to the provided default.

const PREFIX = "zfm.";

function available(): boolean {
  try {
    return typeof localStorage !== "undefined";
  } catch {
    return false;
  }
}

/** Load a raw string, returning `fallback` when absent or inaccessible. */
export function loadString(key: string, fallback: string): string {
  if (!available()) return fallback;
  try {
    const v = localStorage.getItem(PREFIX + key);
    return v ?? fallback;
  } catch {
    return fallback;
  }
}

/** Save a raw string. Errors (e.g. quota) are swallowed. */
export function saveString(key: string, value: string): void {
  if (!available()) return;
  try {
    localStorage.setItem(PREFIX + key, value);
  } catch {
    // ignore
  }
}

/** Load and JSON-parse a value, returning `fallback` on any failure. */
export function loadJSON<T>(key: string, fallback: T): T {
  if (!available()) return fallback;
  try {
    const v = localStorage.getItem(PREFIX + key);
    if (v == null) return fallback;
    return JSON.parse(v) as T;
  } catch {
    return fallback;
  }
}

/** JSON-stringify and save a value. Errors are swallowed. */
export function saveJSON<T>(key: string, value: T): void {
  if (!available()) return;
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value));
  } catch {
    // ignore
  }
}
