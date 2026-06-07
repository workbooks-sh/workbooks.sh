// Unit tests for the creative-vision work pool (no network).
import { describe, expect, it } from "bun:test";
import { pool } from "./creative-vision.js";

describe("pool", () => {
  it("preserves order and processes every item", async () => {
    const items = Array.from({ length: 20 }, (_, i) => i);
    const out = await pool(items, 5, async (n) => n * 2);
    expect(out).toEqual(items.map((n) => n * 2));
  });

  it("bounds concurrency to the limit", async () => {
    let active = 0;
    let peak = 0;
    const items = Array.from({ length: 30 }, (_, i) => i);
    await pool(items, 4, async () => {
      active++;
      peak = Math.max(peak, active);
      await new Promise((r) => setTimeout(r, 5));
      active--;
    });
    expect(peak).toBeLessThanOrEqual(4);
    expect(peak).toBeGreaterThan(1);
  });

  it("handles an empty list", async () => {
    expect(await pool([], 8, async (x) => x)).toEqual([]);
  });
});
