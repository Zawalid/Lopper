export function one<T extends Element = HTMLElement>(selector: string, root: ParentNode = document): T | null {
  return root.querySelector<T>(selector);
}

export function all<T extends Element = HTMLElement>(selector: string, root: ParentNode = document): T[] {
  return Array.from(root.querySelectorAll<T>(selector));
}

export const clamp = (v: number, min = 0, max = 1): number => Math.min(max, Math.max(min, v));

export const isSmall = (): boolean => window.matchMedia('(max-width: 899px)').matches;

/**
 * Footage comes in 1920 and 2560 (the native capture) widths. Use the native file when the largest size
 * the footage is shown at, in device pixels, is more than the 1920 file holds. Phones always get 1920
 * to keep their download in check.
 */
export function footageWidth(largestCssWidth: number): 1920 | 2560 {
  if (isSmall()) return 1920;
  const dpr = Math.min(window.devicePixelRatio || 1, 3);
  return largestCssWidth * dpr > 1920 * 1.05 ? 2560 : 1920;
}
