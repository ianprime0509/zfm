import initialBank from "virtual:zfm/initial-bank";
import { sanitizeBank } from "./sanitize.ts";
import type { Bank } from "./BankEditor.tsx";

// Default bank content: the full patches/patches.zfm bank, compiled to JSON
// by the Vite plugin at build time. Sanitized like any deserialized bank so
// the entries are validated and cloned into independent patch objects.
const sanitized = sanitizeBank(initialBank);

export const INITIAL_BANK: Bank = sanitized ?? initialBank;
