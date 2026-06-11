<script>
  // THE FRONT PAGE — a real editorial newspaper front (DESIGN.md §4.4). Not a
  // uniform CMS feed: ZONES with intent, top→bottom, across the full --page-max
  // broadsheet width. Colorful banner images on the clean monochrome page — that
  // contrast IS the look.
  //
  //   1. THE LEAD       — live/newest feature as a dominant hero (big banner +
  //                       Newsreader display head) + a SECONDARY feature beside
  //                       it. Asymmetric two-up, not equal halves.
  //   2. MARKET BAND    — the MarketStrip (mono tickers) full-width under the lead.
  //   3. SECTION CLUSTERS — per desk (ai/markets/chips/policy): a section rule +
  //                       ONE imaged lead + a tight HEADLINE LIST of the rest.
  //                       One picture, many headlines. Laid 2-across on wide.
  //   4. ANALYSIS strip — 2-3 long-read stories in a quieter, byline-forward,
  //                       serif, image-less register (commentary furniture).
  //   5. THE WIRE       — the latest N stories as timestamped one-liners (mono).
  //   6. Footer         — the shell renders it.
  import WireLead from '../lib/WireLead.svelte';
  import FeatureCard from '../lib/FeatureCard.svelte';
  import MarketStrip from '../lib/MarketStrip.svelte';
  import SectionCluster from '../lib/SectionCluster.svelte';
  import AnalysisCard from '../lib/AnalysisCard.svelte';
  import WireRow from '../lib/WireRow.svelte';
  import {
    manifest, features, sectionCluster, analysisPicks, wireLatest, SECTION_ORDER,
  } from '../lib/stories.svelte.js';
  import { leadProps, bylineProps } from '../lib/bite-props.js';

  let { onagent } = $props();

  const rows = $derived(manifest());

  // 1 — the lead + secondary (the two biggest features, in manifest order)
  const feats = $derived(rows ? features() : []);
  const lead = $derived(feats[0] || null);
  const secondary = $derived(feats[1] || null);

  // slugs already spent up top — clusters/analysis won't repeat them
  const topSpent = $derived([lead?.slug, secondary?.slug].filter(Boolean));

  // 3 — one cluster per desk (lead picture + headline list), in editorial order
  const clusters = $derived(rows
    ? SECTION_ORDER.map((s) => ({ section: s, ...sectionCluster(s, topSpent) }))
        .filter((c) => c.lead || c.rest.length)
    : []);

  // slugs now used as cluster leads — keep them out of the analysis strip
  const clusterLeadSlugs = $derived(clusters.map((c) => c.lead?.slug).filter(Boolean));

  // 4 — analysis: the longest reads, in their quieter register
  const analysis = $derived(rows
    ? analysisPicks([...topSpent, ...clusterLeadSlugs], 3) : []);

  // 5 — the wire: the latest stories as a ticker
  const wire = $derived(rows ? wireLatest(8) : []);

  // a static SPECIMEN market strip (§4.6: flagged fake via the '· specimen' tag)
  const tickers = [
    { sym: 'NVDA', val: '+2.4', dir: 'up' },
    { sym: 'SOX',  val: '+1.1', dir: 'up' },
    { sym: 'TSM',  val: '+0.8', dir: 'up' },
    { sym: 'INTC', val: '-1.3', dir: 'down' },
    { sym: 'BTC',  val: '97,210', dir: 'down' },
    { sym: 'AI ETF', val: '+0.6', dir: 'up' },
  ];
</script>

{#if rows}
  <!-- ── ZONE 1: THE LEAD — dominant hero + secondary feature (asymmetric) ── -->
  {#if lead}
    <section class="zone lead-zone" class:two-up={!!secondary}>
      <div class="hero">
        <WireLead {...leadProps(lead)} href={`/story/${lead.slug}`} {onagent}
                  stacked hideRule />
      </div>
      {#if secondary}
        <aside class="secondary">
          <FeatureCard story={secondary} {onagent} />
        </aside>
      {/if}
    </section>
  {/if}

  <!-- ── ZONE 2: MARKET BAND — full-width tickers under the lead ── -->
  <section class="zone market-zone">
    <MarketStrip items={tickers} />
  </section>

  <!-- ── ZONE 3: SECTION CLUSTERS — one picture, many headlines, in a grid ── -->
  <section class="zone clusters">
    {#each clusters as c (c.section)}
      <SectionCluster section={c.section} lead={c.lead} rest={c.rest} {onagent} />
    {/each}
  </section>

  <!-- ── ZONE 4: ANALYSIS — bordered-off, byline-forward, serif, no images ── -->
  {#if analysis.length}
    <section class="zone analysis-zone">
      <header class="band-head">
        <span class="label mono">Analysis</span>
        <span class="rule"></span>
      </header>
      <div class="analysis-grid">
        {#each analysis as row (row.slug)}
          <AnalysisCard
            head={row.head} dek={row.dek} read={row.read}
            byline={bylineProps(row.byline)} {onagent}
            href={`/story/${row.slug}`} />
        {/each}
      </div>
    </section>
  {/if}

  <!-- ── ZONE 5: THE WIRE — the latest, as a timestamped ticker column ── -->
  {#if wire.length}
    <section class="zone wire-zone">
      <header class="band-head">
        <span class="label mono">The wire · latest</span>
        <span class="rule"></span>
      </header>
      <div class="wire-list">
        {#each wire as w (w.slug)}
          <WireRow head={w.head} when={w.when} section={w.section}
                   href={`/story/${w.slug}`} />
        {/each}
      </div>
    </section>
  {/if}
{/if}

<style>
  /* generous air between zones — the broadsheet rhythm (§4.4) */
  .zone { margin-top: 80px; }
  .lead-zone { margin-top: 8px; }
  .market-zone { margin-top: 36px; }

  /* ── ZONE 1: asymmetric two-up — hero dominant (1.55fr), secondary (1fr) ── */
  .lead-zone.two-up {
    display: grid;
    grid-template-columns: 1.55fr 1fr;
    gap: 56px;
    align-items: start;
  }
  .hero { min-width: 0; }
  .secondary {
    min-width: 0;
    padding-left: 56px;
    border-left: 1px solid var(--rule);   /* a hairline gutter, not a card */
    margin-left: -56px;                    /* keep the rule in the gap */
  }

  /* ── ZONE 3: clusters laid 2-across on wide — rhythm, not one column ── */
  .clusters {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 64px 72px;
  }

  /* shared band header (analysis + wire): a label + a hairline rule with air */
  .band-head {
    display: flex; align-items: center; gap: 16px;
    margin-bottom: 28px;
  }
  .band-head .label {
    font-size: 12px; font-weight: 500;
    text-transform: uppercase; letter-spacing: 0.1em; color: var(--ink);
    white-space: nowrap;
  }
  .band-head .rule { flex: 1; height: 1px; background: var(--rule); }

  /* ── ZONE 4: ANALYSIS — the one sanctioned subtle band (§4.4) ── */
  .analysis-zone {
    background: var(--surface);
    border-radius: var(--r);
    padding: 44px 48px;
  }
  .analysis-zone .band-head .label { color: var(--ink-2); }
  .analysis-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 40px;
  }
  /* divider rules between the analysis columns (commentary, set apart) */
  .analysis-grid > :global(* + *) {
    padding-left: 40px;
    border-left: 1px solid var(--rule);
    margin-left: -40px;
  }

  /* ── ZONE 5: THE WIRE — a dense ticker; two columns on wide ── */
  .wire-list {
    column-count: 2; column-gap: 56px;
  }
  .wire-list > :global(.wire) { break-inside: avoid; }

  /* ── MEDIUM (≤980px): clusters + analysis + wire to one column ── */
  @media (max-width: 980px) {
    .lead-zone.two-up { grid-template-columns: 1fr; gap: 40px; }
    .secondary {
      padding-left: 0; margin-left: 0;
      border-left: 0; border-top: 1px solid var(--rule);
      padding-top: 36px;
    }
    .clusters { grid-template-columns: 1fr; gap: 56px; }
    .analysis-grid { grid-template-columns: 1fr; gap: 32px; }
    .analysis-grid > :global(* + *) {
      padding-left: 0; margin-left: 0;
      border-left: 0; border-top: 1px solid var(--rule); padding-top: 28px;
    }
    .wire-list { column-count: 1; }
  }

  /* ── MOBILE (≤680px): one measured column, sensible reading order, no scroll ── */
  @media (max-width: 680px) {
    .zone { margin-top: 56px; }
    .analysis-zone { padding: 32px 24px; }
  }
</style>
