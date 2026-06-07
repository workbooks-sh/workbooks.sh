/**
 * Resolve a personal accent color for a handle/avatar.
 *
 * Wraps the existing iconAccent system so every handle in the Network
 * surface gets a consistent color derived from its avatar (emoji or
 * image). When the avatar can't produce a saturated color (initials,
 * grayscale, empty), we fall back to a deterministic hash-based hue
 * so two different handles never collide on the default.
 *
 * Returns { ring, fill } — ring is the solid accent, fill is the
 * faint background tint (10% alpha) used for badges + chips.
 */

import { iconAccent, accentFill } from "$lib/ui/iconAccent.svelte";

export interface PersonalColor {
  ring: string;
  fill: string;
}

const FALLBACK_HUES = [
  "rgb(220, 75, 90)",
  "rgb(225, 130, 50)",
  "rgb(210, 175, 60)",
  "rgb(90, 175, 110)",
  "rgb(75, 145, 200)",
  "rgb(125, 110, 200)",
  "rgb(190, 95, 180)",
  "rgb(95, 175, 175)",
];

function hashHandle(handle: string): number {
  let h = 0;
  for (let i = 0; i < handle.length; i++) {
    h = (h * 31 + handle.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

export function personalColor(handle: string, avatar: string | null): PersonalColor {
  const accent = avatar ? iconAccent(avatar) : null;
  if (accent) {
    return { ring: accent, fill: accentFill(accent, 0.10) };
  }
  const ring = FALLBACK_HUES[hashHandle(handle) % FALLBACK_HUES.length];
  return { ring, fill: accentFill(ring, 0.10) };
}
