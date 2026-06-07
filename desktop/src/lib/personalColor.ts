/**
 * personalColor — resolve a consistent accent for a handle/avatar.
 *
 * Wraps iconAccent so every Network handle gets a color derived from its
 * avatar. When the avatar can't produce a saturated color (initials,
 * grayscale, empty), falls back to a deterministic hash-based hue so two
 * handles never collide on the default. Returns { ring, fill } — solid
 * accent + faint 10% tint for badges and chips.
 */

import { iconAccent, accentFill } from "./iconAccent.svelte";

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
  for (let i = 0; i < handle.length; i++) h = (h * 31 + handle.charCodeAt(i)) | 0;
  return Math.abs(h);
}

export function personalColor(handle: string, avatar: string | null): PersonalColor {
  const accent = avatar ? iconAccent(avatar) : null;
  if (accent) return { ring: accent, fill: accentFill(accent, 0.1) };
  const ring = FALLBACK_HUES[hashHandle(handle) % FALLBACK_HUES.length];
  return { ring, fill: accentFill(ring, 0.1) };
}
