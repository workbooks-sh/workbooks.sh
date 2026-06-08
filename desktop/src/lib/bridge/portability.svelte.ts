// files domain — portability bridge (Phase B, native/offline).
//
// Invokes the native Rust `workbook_check_portability` Tauri command
// (which runs `wb check --portability <workdir> --json`). The CLI emits
// the per-cell classification + the workbook's computed tier; we hold the
// last result in a reactive store and re-fetch on demand. No runtime /
// control-plane involvement — fully local.
//
// Defensive about CLI availability: the rust-agent ships the
// `--portability` verb under the same epic but may land before/after
// this UI. When the verb is missing, `refresh` records an
// "unavailable" state — the sidebar renders an empty/explanatory
// panel rather than blocking the editor.
//
// Read-only by design. The store NEVER mutates a workbook's source;
// it only displays what `wb check` reports.

import { invoke } from "@tauri-apps/api/core";

export type Tier = "browser" | "live-url" | "desktop";

export interface CellClassification {
  /** Path relative to the workdir passed to `refresh`. */
  file: string;
  /** 1-indexed line number of the SRC opener. */
  line: number;
  /** The cell's `:lang:` (or `#+BEGIN_SRC <lang>`). */
  lang: string;
  /** Minimum tier this cell requires. */
  tier_floor: Tier;
}

export interface PortabilityReport {
  cells: CellClassification[];
  /** The minimum tier the workbook qualifies for given its cell mix. */
  workbook_tier: Tier;
  /** Declared `:PORTABILITY:` from the spec, if present. */
  declared_tier: Tier | null;
}

export type PortabilityPhase = "idle" | "loading" | "ready" | "unavailable" | "error";

const TIER_RANK: Record<Tier, number> = {
  browser: 0,
  "live-url": 1,
  desktop: 2,
};

/** True if `declared` provides at least as much runtime as `required`. */
export function tierCoversRequired(declared: Tier, required: Tier): boolean {
  return TIER_RANK[declared] >= TIER_RANK[required];
}

/** Human label for the tier (used in tooltips + sidebar copy). */
export function tierLabel(tier: Tier): string {
  switch (tier) {
    case "browser":
      return "browser";
    case "live-url":
      return "live-url";
    case "desktop":
      return "desktop";
  }
}

/** One-line explanation that drops into a `title` tooltip. */
export function tierExplanation(tier: Tier): string {
  switch (tier) {
    case "browser":
      return "Browser-portable — runs in any browser.";
    case "live-url":
      return "Requires Live URL — needs the engine in a hosted VM.";
    case "desktop":
      return "Requires Workbooks Desktop — runs on the recipient's machine.";
  }
}

function isTier(v: unknown): v is Tier {
  return v === "browser" || v === "live-url" || v === "desktop";
}

/** Normalize an arbitrary value (likely from the Rust command's
 *  serde_json passthrough) into a typed Tier, defaulting to "browser". */
function asTier(v: unknown, fallback: Tier = "browser"): Tier {
  return isTier(v) ? v : fallback;
}

/** Parse the raw Rust response into our typed shape. The Rust side
 *  passes `cells` through as untyped JSON so the wb CLI can evolve its
 *  schema without breaking us; we coerce here.  */
function parseReport(raw: unknown): PortabilityReport {
  const obj = (raw ?? {}) as Record<string, unknown>;
  const rawCells = Array.isArray(obj.cells) ? obj.cells : [];
  const cells: CellClassification[] = rawCells.map((c) => {
    const r = (c ?? {}) as Record<string, unknown>;
    return {
      file: typeof r.file === "string" ? r.file : "",
      line: typeof r.line === "number" ? r.line : 0,
      lang: typeof r.lang === "string" ? r.lang : "",
      tier_floor: asTier(r.tier_floor),
    };
  });
  const declared = obj.declared_tier;
  return {
    cells,
    workbook_tier: asTier(obj.workbook_tier),
    declared_tier: isTier(declared) ? declared : null,
  };
}

class PortabilityStore {
  /** Latest report, or `null` while we haven't loaded anything. */
  report = $state<PortabilityReport | null>(null);
  phase = $state<PortabilityPhase>("idle");
  /** Last error message, or null. Surfaces in the sidebar for debugging. */
  lastError = $state<string | null>(null);
  /** The workdir the last successful report was for. */
  currentWorkdir = $state<string | null>(null);

  /** Cells grouped by tier_floor, sorted (most restrictive first). */
  cellsByTier = $derived.by<Record<Tier, CellClassification[]>>(() => {
    const out: Record<Tier, CellClassification[]> = {
      browser: [],
      "live-url": [],
      desktop: [],
    };
    for (const c of this.report?.cells ?? []) {
      out[c.tier_floor].push(c);
    }
    return out;
  });

  /** True if `:PORTABILITY:` was declared and is lower than the
   *  computed minimum. Drives the red "declared X, requires Y" chip. */
  declaredMismatch = $derived.by<{ declared: Tier; required: Tier } | null>(() => {
    const r = this.report;
    if (!r || !r.declared_tier) return null;
    if (tierCoversRequired(r.declared_tier, r.workbook_tier)) return null;
    return { declared: r.declared_tier, required: r.workbook_tier };
  });

  /** Cells the user would need to drop/replace to qualify for a
   *  tier strictly looser than the current minimum. */
  upgradeHint = $derived.by<{ targetTier: Tier; cellCount: number } | null>(() => {
    const r = this.report;
    if (!r) return null;
    if (r.workbook_tier === "browser") return null;
    const offending = r.cells.filter((c) => c.tier_floor !== "browser");
    if (offending.length === 0) return null;
    // Loosest reachable tier is the floor below the current one.
    const target: Tier = r.workbook_tier === "desktop" ? "live-url" : "browser";
    const cells =
      target === "browser"
        ? offending.length
        : r.cells.filter((c) => c.tier_floor === "desktop").length;
    if (cells === 0) return null;
    return { targetTier: target, cellCount: cells };
  });

  async refresh(workdir: string): Promise<void> {
    this.phase = "loading";
    this.lastError = null;
    try {
      const raw = await invoke<unknown>("workbook_check_portability", { workdir });
      this.report = parseReport(raw);
      this.currentWorkdir = workdir;
      this.phase = "ready";
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // The Rust side prefixes "classification_unavailable:" when the
      // wb CLI is missing the verb or the binary isn't on PATH — both
      // are non-fatal at this stage of the rollout.
      if (msg.includes("classification_unavailable")) {
        this.report = null;
        this.phase = "unavailable";
        this.lastError = msg;
        return;
      }
      this.report = null;
      this.phase = "error";
      this.lastError = msg;
    }
  }

  /** Test/dev hook — lets specs hydrate the store without hitting
   *  Tauri IPC. NOT called from production code paths. */
  _setReportForTests(report: PortabilityReport | null, phase: PortabilityPhase = "ready") {
    this.report = report;
    this.phase = phase;
  }
}

export const portability = new PortabilityStore();
