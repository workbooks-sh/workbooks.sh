<script lang="ts">
  /**
   * LineageTree — wb-u2o0.6.1.
   *
   * Renders a workbook's provenance trail visually: vertical timeline
   * with one card per chain link. The CURRENT claim is at the top
   * (annotated as "current"), then prior claims oldest-first below.
   *
   * Data: the active VerifyReport plus its claim_chain. Each card
   * shows signer (@handle resolved via Broker, fall back to short DID),
   * issued_at as relative time, claim_generator, asset_sha256 short
   * form. Forked links get a distinct icon + "forked from @X" annotation
   * inferred from the link's c2pa.action.forked assertion (TODO when
   * assertion-per-link lands — for now annotation comes from the
   * current claim's assertions only).
   */
  import { onMount } from "svelte";
  import {
    GitFork, GitCommitVertical, Clock, Hash,
  } from "@lucide/svelte";
  import {
    resolveDid, type IdentityView,
  } from "$lib/broker";
  import type { VerifyReport, ClaimRecord } from "$lib/verify";

  let {
    report,
  }: {
    report: VerifyReport;
  } = $props();

  // Resolved identities, keyed by DID. Populated lazily on mount.
  let resolved = $state<Record<string, IdentityView | null>>({});

  onMount(async () => {
    const dids = new Set<string>([
      report.issuer_did,
      ...report.claim_chain.map((c) => c.issuer_did),
    ]);
    for (const did of dids) {
      if (resolved[did] !== undefined) continue;
      try {
        const r = await resolveDid(did);
        resolved = { ...resolved, [did]: r };
      } catch {
        resolved = { ...resolved, [did]: null };
      }
    }
  });

  function shortDid(did: string): string {
    // did:key:z6Mk… short suffix
    const slug = did.replace(/^did:key:/, "");
    return slug.slice(0, 8) + "…" + slug.slice(-4);
  }

  function shortHash(hex: string): string {
    return hex.slice(0, 8) + "…";
  }

  function relativeTime(iso: string): string {
    try {
      const t = new Date(iso).getTime();
      const dt = Date.now() - t;
      if (dt < 0) return iso;
      const m = Math.floor(dt / 60000);
      if (m < 1) return "just now";
      if (m < 60) return `${m}m ago`;
      const h = Math.floor(m / 60);
      if (h < 24) return `${h}h ago`;
      const d = Math.floor(h / 24);
      if (d < 30) return `${d}d ago`;
      const mo = Math.floor(d / 30);
      if (mo < 12) return `${mo}mo ago`;
      const y = Math.floor(mo / 12);
      return `${y}y ago`;
    } catch {
      return iso;
    }
  }

  // Find a "forked from @handle" annotation in the current claim's
  // assertions. Chain links would carry their own assertions in a
  // future schema bump; for now only the active claim has assertions
  // surfaced in VerifyReport.
  const forkedFromHandle = $derived.by<string | null>(() => {
    const forked = report.assertions.find(
      (a) => a.type === "c2pa.action.forked",
    );
    if (!forked) return null;
    const upDid = (forked as { upstream_did?: string }).upstream_did;
    if (!upDid) return null;
    return resolved[upDid]?.handle ?? null;
  });

  // Build the rendering sequence: current claim first, then chain
  // (which is stored oldest-first → we want newest-prior-first below
  // the current marker, so reverse for display).
  type Row =
    | { kind: "current"; did: string; issued_at: string; generator: string; asset_sha256: string }
    | { kind: "prior"; link: ClaimRecord; index: number };

  const rows = $derived.by<Row[]>(() => {
    const out: Row[] = [
      {
        kind: "current",
        did: report.issuer_did,
        issued_at: report.issued_at,
        generator: report.claim_generator,
        asset_sha256: report.asset_sha256,
      },
    ];
    // chain[0] is genesis; render newest-prior first (just below
    // current), so reverse.
    for (let i = report.claim_chain.length - 1; i >= 0; i--) {
      out.push({ kind: "prior", link: report.claim_chain[i], index: i });
    }
    return out;
  });
</script>

<div class="tree">
  <div class="head">
    <GitCommitVertical size={14} strokeWidth={2.25} />
    <span>Provenance chain</span>
    <span class="muted">{report.claim_chain.length === 0 ? "genesis only" : `${report.claim_chain.length + 1} claims`}</span>
  </div>

  <ol class="rows">
    {#each rows as row, i}
      {@const isCurrent = row.kind === "current"}
      {@const isGenesis = !isCurrent && row.kind === "prior" && row.index === 0}
      {@const did = isCurrent ? row.did : row.link.issuer_did}
      {@const issuedAt = isCurrent ? row.issued_at : row.link.issued_at}
      {@const generator = isCurrent ? row.generator : row.link.claim_generator}
      {@const assetHash = isCurrent ? row.asset_sha256 : row.link.asset_sha256}
      {@const ident = resolved[did]}
      <li class="row" class:current={isCurrent} class:genesis={isGenesis}>
        <div class="rail">
          <div class="dot"></div>
          {#if i < rows.length - 1}<div class="line"></div>{/if}
        </div>
        <div class="card">
          <div class="card-head">
            <div class="who">
              {#if isCurrent && forkedFromHandle}
                <GitFork size={12} strokeWidth={2.25} class="fork-icon" />
              {/if}
              {#if ident}
                <span class="handle">@{ident.handle}</span>
                {#if ident.workos_display_name}
                  <span class="real-name">· {ident.workos_display_name}</span>
                {/if}
              {:else}
                <span class="did-short" title={did}>{shortDid(did)}</span>
              {/if}
              <span class="tag" class:current-tag={isCurrent} class:genesis-tag={isGenesis}>
                {isCurrent ? "current" : isGenesis ? "genesis" : `claim ${row.index! + 1}`}
              </span>
            </div>
            <div class="ts" title={issuedAt}>
              <Clock size={10} strokeWidth={2.25} />
              {relativeTime(issuedAt)}
            </div>
          </div>
          {#if isCurrent && forkedFromHandle}
            <div class="annotation">
              <GitFork size={11} strokeWidth={2.25} />
              forked from <strong>@{forkedFromHandle}</strong>
            </div>
          {/if}
          <div class="meta">
            <span class="gen">{generator}</span>
            <span class="hash" title={assetHash}>
              <Hash size={10} strokeWidth={2.25} />
              {shortHash(assetHash)}
            </span>
          </div>
        </div>
      </li>
    {/each}
  </ol>
</div>

<style>
  .tree {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px 12px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .head .muted {
    margin-left: auto;
    font-weight: 500;
    color: var(--color-fg-muted);
    font-size: 0.7rem;
  }
  .rows {
    margin: 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
  }
  .row {
    display: grid;
    grid-template-columns: 16px 1fr;
    gap: 8px;
    min-height: 50px;
  }
  .rail {
    position: relative;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding-top: 8px;
  }
  .dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--color-fg-muted);
    border: 2px solid var(--color-surface);
    box-shadow: 0 0 0 1px var(--color-border);
    z-index: 1;
  }
  .row.current .dot {
    background: rgb(34, 160, 105);
    box-shadow: 0 0 0 1px rgba(34, 160, 105, 0.4);
  }
  .row.genesis .dot {
    background: var(--color-fg);
  }
  .line {
    flex: 1;
    width: 1px;
    background: var(--color-border);
    margin-top: 1px;
  }
  .card {
    padding: 6px 8px 8px 8px;
    border-radius: 6px;
    background: var(--color-page);
    border: 1px solid var(--color-border);
    margin-bottom: 6px;
    transition: background 120ms ease;
  }
  .row.current .card {
    border-color: rgba(34, 160, 105, 0.35);
    background: rgba(34, 160, 105, 0.05);
  }
  .card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
  }
  .who {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 0.75rem;
    min-width: 0;
  }
  .handle {
    font-weight: 600;
    color: var(--color-fg);
  }
  .real-name {
    color: var(--color-fg-muted);
    font-weight: 500;
  }
  .did-short {
    color: var(--color-fg-muted);
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.72rem;
  }
  .tag {
    padding: 1.5px 6px;
    border-radius: 999px;
    font-size: 0.62rem;
    font-weight: 600;
    text-transform: lowercase;
    letter-spacing: 0.01em;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border);
  }
  .tag.current-tag {
    background: rgba(34, 160, 105, 0.12);
    color: rgb(20, 110, 70);
    border-color: rgba(34, 160, 105, 0.3);
  }
  .tag.genesis-tag {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }
  .ts {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    color: var(--color-fg-muted);
    font-size: 0.68rem;
    flex-shrink: 0;
  }
  .annotation {
    margin-top: 4px;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 7px;
    border-radius: 999px;
    background: rgba(125, 95, 200, 0.10);
    border: 1px solid rgba(125, 95, 200, 0.28);
    color: rgb(85, 60, 165);
    font-size: 0.68rem;
    font-weight: 500;
  }
  .meta {
    margin-top: 4px;
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--color-fg-muted);
    font-size: 0.68rem;
  }
  .gen {
    font-family: ui-monospace, SFMono-Regular, monospace;
  }
  .hash {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    font-family: ui-monospace, SFMono-Regular, monospace;
  }
  :global(.fork-icon) {
    color: rgb(85, 60, 165);
    flex-shrink: 0;
  }

  @media (prefers-color-scheme: dark) {
    .row.current .card {
      background: rgba(34, 160, 105, 0.10);
      border-color: rgba(34, 160, 105, 0.4);
    }
    .tag.current-tag {
      background: rgba(34, 160, 105, 0.20);
      color: rgb(120, 220, 165);
    }
    .annotation {
      background: rgba(155, 130, 220, 0.16);
      border-color: rgba(155, 130, 220, 0.40);
      color: rgb(195, 175, 240);
    }
  }
</style>
