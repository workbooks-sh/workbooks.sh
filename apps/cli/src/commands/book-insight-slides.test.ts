// Tests for the insight-slides verb's .org collector (wb-syjo / wb-zkp4).
// The mapper itself is tested in @brandnana/schema; here we cover the recursive
// file collection that feeds it.

import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectOrgFiles } from "./book.js";

describe("collectOrgFiles", () => {
  it("collects .org files recursively, sorted, ignoring non-org", () => {
    const root = mkdtempSync(join(tmpdir(), "bn-insight-"));
    writeFileSync(join(root, "voice.org"), "* x :insight:voice:");
    writeFileSync(join(root, "notes.txt"), "ignore me");
    mkdirSync(join(root, "ad-vision"));
    writeFileSync(join(root, "ad-vision", "creatives.org"), "* y :insight:ad-vision:");

    const files = collectOrgFiles(root);
    expect(files).toHaveLength(2);
    // sorted: ad-vision/creatives.org before voice.org
    expect(files[0]?.endsWith("ad-vision/creatives.org")).toBe(true);
    expect(files[1]?.endsWith("voice.org")).toBe(true);
  });

  it("returns [] for a missing directory", () => {
    expect(collectOrgFiles(join(tmpdir(), "definitely-not-here-bn"))).toEqual([]);
  });
});
