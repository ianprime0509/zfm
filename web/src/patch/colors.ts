export interface SlotColor {
  accent: string;
  soft: string;
  text: string;
}

export function slotColor(n: number): SlotColor {
  return {
    accent: `var(--slot-${n}-accent)`,
    soft: `var(--slot-${n}-soft)`,
    text: `var(--slot-${n}-text)`,
  };
}
