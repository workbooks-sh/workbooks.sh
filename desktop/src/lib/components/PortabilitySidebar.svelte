<script lang="ts">
  /**
   * PortabilitySidebar — wb-unzn.25 P3.
   *
   * Side-rail panel that summarises a workbook's portability tier and
   * lists every cell that pins it there. Driven by the `portability`
   * reactive store; the caller is responsible for calling
   * `portability.refresh(workdir)` when the active workbook changes.
   *
   * Render states:
   *   - idle / unavailable / error  → empty-state explanation
   *   - ready + declared_mismatch   → red chip + offending cells
   *   - ready + no mismatch         → green/amber/red summary chip
   *
   * Read-only by design: this is a *display* of `work check` output,
   * never a mutation of the workbook source.
   */
  import {
    portability,
    type CellClassification,
    type Tier,
    tierLabel,
  } from "$lib/bridge/portability.svelte";
  import PortabilityBadge from "./PortabilityBadge.svelte";

  let {
    workdir = null,
  }: {
    /** If provided, the sidebar will refresh itself when this changes.
     *  Pass null to leave refresh control to the parent. */
    workdir?: string | null;
  } = $props();

  $effect(() => {
    if (workdir) {
      void portability.refresh(workdir);
    }
  });

  // Tier groups ordered most-restrictive first — the "what's blocking
  // me?" question matters more than the "what's already fine?" one.
  const TIER_ORDER: Tier[] = ["desktop", "live-url", "browser"];

  function groupHeading(tier: Tier, count: number): string {
    switch (tier) {
      case "desktop":
        return `Requires Workbooks Desktop (${count} cell${count === 1 ? "" : "s"})`;
      case "live-url":
        return `Requires Live URL (${count} cell${count === 1 ? "" : "s"})`;
      case "browser":
        return `Browser-portable (${count} cell${count === 1 ? "" : "s"})`;
    }
  }

  function cellLocator(c: CellClassification): string {
    return `${c.file}:${c.line}`;
  }
</script>

<aside class="sidebar" aria-label="Workbook portability">
  <header class="head">
    <h3>Portability</h3>
    {#if portability.report}
      <PortabilityBadge tier={portability.report.workbook_tier} compact />
    {/if}
  </header>

  {#if portability.phase === "loading"}
    <p class="status">Classifying cells…</p>
  {:else if portability.phase === "unavailable"}
    <p class="status">
      Classification unavailable —
      <code>work check --portability</code> hasn't shipped yet.
    </p>
  {:else if portability.phase === "error"}
    <p class="status err">
      {portability.lastError ?? "Failed to classify workbook."}
    </p>
  {:else if portability.phase === "idle" || !portability.report}
    <p class="status">No workbook selected.</p>
  {:else}
    {@const r = portability.report}
    {@const mismatch = portability.declaredMismatch}
    {@const hint = portability.upgradeHint}

    {#if r.declared_tier}
      <p class="lede">
        Declared <code>{r.declared_tier}</code>; computed <code>{r.workbook_tier}</code>.
      </p>
    {:else}
      <p class="lede">
        No <code>:PORTABILITY:</code> declared. Minimum tier
        <code>{r.workbook_tier}</code> inferred from cell mix.
      </p>
    {/if}

    {#if mismatch}
      <div class="chip-error" role="alert">
        Declared <code>{mismatch.declared}</code>,
        requires <code>{mismatch.required}</code>.
      </div>
    {/if}

    <ul class="tiers">
      {#each TIER_ORDER as t (t)}
        {@const cells = portability.cellsByTier[t]}
        {#if cells.length > 0}
          <li class="tier-group">
            <div class="tier-head">
              <PortabilityBadge tier={t} compact />
              <span class="tier-count">
                {groupHeading(t, cells.length)}
              </span>
            </div>
            <ul class="cell-list">
              {#each cells as c (cellLocator(c) + c.lang)}
                <li class="cell-row">
                  <span class="cell-loc" title={c.file}>{cellLocator(c)}</span>
                  <span class="cell-lang">{c.lang}</span>
                </li>
              {/each}
            </ul>
          </li>
        {/if}
      {/each}
    </ul>

    {#if hint}
      <p class="hint">
        Replace {hint.cellCount} cell{hint.cellCount === 1 ? "" : "s"}
        to qualify for <code>{tierLabel(hint.targetTier)}</code>.
      </p>
    {/if}
  {/if}
</aside>

<style>
  .sidebar {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 0.85rem 1rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    min-width: 0;
    font-size: 0.82rem;
    color: var(--color-fg);
  }
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
  }
  h3 {
    margin: 0;
    font-size: 0.85rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  .status {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    line-height: 1.45;
  }
  .status.err {
    color: var(--color-rose, #e11d48);
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.74rem;
    white-space: pre-wrap;
  }
  .lede {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    line-height: 1.45;
  }
  .lede code,
  .hint code,
  .status code,
  .chip-error code {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.74rem;
    padding: 0 0.25rem;
    border-radius: 3px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .chip-error {
    padding: 0.35rem 0.55rem;
    border-radius: 6px;
    font-size: 0.74rem;
    line-height: 1.35;
    color: var(--color-rose, #e11d48);
    background: color-mix(in srgb, var(--color-rose, #e11d48) 10%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-rose, #e11d48) 28%, transparent);
  }
  .tiers {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .tier-group {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .tier-head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.74rem;
    color: var(--color-fg-muted);
    text-transform: none;
  }
  .tier-count {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cell-list {
    list-style: none;
    margin: 0;
    padding: 0 0 0 0.5rem;
    border-left: 1px solid var(--color-border);
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
  }
  .cell-row {
    display: flex;
    align-items: baseline;
    gap: 0.6rem;
    font-size: 0.74rem;
    line-height: 1.3;
    font-family: ui-monospace, SFMono-Regular, monospace;
  }
  .cell-loc {
    color: var(--color-fg-muted);
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cell-lang {
    color: var(--color-fg-subtle);
    flex-shrink: 0;
  }
  .hint {
    margin: 0;
    padding-top: 0.35rem;
    border-top: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-size: 0.76rem;
    line-height: 1.4;
  }
</style>
