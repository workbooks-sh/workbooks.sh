<script>
  // /design — the living styleguide (DESIGN.md is law; this stays the specimen
  // sheet). Every component from the real library renders live, labelled like a
  // type specimen. This is the page that PROVES the token system: the theme
  // toggle and the docked crew panel live in the shell, but the MarketStrip and
  // the inline crew specimen live here (the real front page omits the strip —
  // §4.6 forbids placeholder numbers).
  import WireLead from '../lib/WireLead.svelte';
  import Bite from '../lib/Bite.svelte';
  import MarketStrip from '../lib/MarketStrip.svelte';
  import Receipt from '../lib/Receipt.svelte';
  import CrewPanel from '../lib/CrewPanel.svelte';
  import Portal from '../lib/Portal.svelte';
  import Byline from '../lib/Byline.svelte';
  import { crewFeed, pipelineLine } from '../lib/feed.js';

  let { onagent } = $props();

  // specimen data drives the inline crew specimen + market strip
  const feed = crewFeed();
  const crew = feed.agents.map((a) => ({ ...a, state: a.live ? 'live' : 'idle' }));
  const pipeline = pipelineLine(feed.pipeline);

  const market = [
    { sym: 'NVDA', val: '+2.4', dir: 'up' },
    { sym: 'BTC',  val: '97,210', dir: 'down' },
    { sym: 'SOX',  val: '+1.1', dir: 'up' },
    { sym: 'TSMC', val: '−0.6', dir: 'down' },
  ];

  const tokens = [
    { name: '--paper', hex: '#ffffff', note: 'pure white' },
    { name: '--ink',   hex: '#000000', note: 'true black' },
    { name: '--wire',  hex: '#0a52e0', note: 'the one accent' },
    { name: '--up',    hex: '#0a7d4f', note: 'market: up' },
    { name: '--down',  hex: '#c4322e', note: 'market: down' },
    { name: '--rule',  hex: '#ededed', note: 'hairline' },
  ];
</script>

<p class="intro mono">
  bit.ml — design components. Every element below is rendered live from the
  real library. Captions name the component and the rule it embodies. The
  product itself lives at <a href="/">/</a>.
</p>

<!-- ── TOKENS ─────────────────────────────────────────────────────── -->
<section class="spec" id="tokens">
  <div class="spec-label">
    <span class="spec-name">tokens.css</span>
    <span class="spec-rule">paper, ink, one wire — light + [data-theme=terminal]</span>
  </div>
  <div class="swatches">
    {#each tokens as t}
      <div class="swatch">
        <span class="chip" style="background:{t.hex}; border-color: color-mix(in srgb, {t.hex} 70%, var(--rule))"></span>
        <span class="sw-name mono">{t.name}</span>
        <span class="sw-hex mono">{t.hex}</span>
        <span class="sw-note">{t.note}</span>
      </div>
    {/each}
  </div>
  <div class="hairdemo">
    <span class="hd-label mono">hairline — visible, never loud</span>
    <hr class="hair" />
  </div>
</section>

<!-- ── TYPE ───────────────────────────────────────────────────────── -->
<section class="spec" id="type">
  <div class="spec-label">
    <span class="spec-name">type</span>
    <span class="spec-rule">three voices: Newsreader · Switzer · Geist Mono</span>
  </div>
  <div class="type-opt">
    <div class="to-row"><span class="to-cap mono">Newsreader 44 / display</span><span class="serif n44">A model that runs on one TPU</span></div>
    <div class="to-row"><span class="to-cap mono">Newsreader 22 / story head</span><span class="serif n22">DeepMind's weather model beats the supercomputers</span></div>
    <div class="to-row"><span class="to-cap mono">Newsreader 17 / story body</span><span class="serif n17">Ten-day forecasts, drawn for screens.</span></div>
  </div>
  <p class="switzer-block">
    Switzer carries the deks and the body — a neutral grotesk with more jaw
    than Inter, set tight and never bold above 600. A reader who stops at the
    dek is informed, not teased.
  </p>
  <div class="meta-row mono">14:02 UTC · 40s read · sources: Nature · DeepMind blog</div>
  <div class="touch-demo">
    <span class="td-cap mono">the law — serif never touches mono</span>
    <div class="td-pair">
      <span class="serif td-serif">DeepMind weather</span>
      <span class="td-gap" aria-hidden="true"></span>
      <span class="mono td-mono">14:02 UTC</span>
    </div>
    <span class="td-note mono">↑ a hairline of whitespace between the voices — the contrast IS the brand</span>
  </div>
</section>

<!-- ── WIRE LEAD ──────────────────────────────────────────────────── -->
<section class="spec" id="wire">
  <div class="spec-label">
    <span class="spec-name">WireLead.svelte</span>
    <span class="spec-rule">the front-page lead, 44px Newsreader display</span>
  </div>
  <WireLead
    section="AI"
    dateline="14:02 UTC · today"
    head="DeepMind's new weather model beats the supercomputers it replaced"
    dek="Ten-day forecasts from a model that runs on one TPU — the paper, the caveats, and who loses a contract."
    sources={['Nature', 'DeepMind blog']}
    byline={{ writer: { name: 'wren', role: 'writer' }, research: ['moss'], editor: 'hale' }}
    onagent={onagent}
  />
</section>

<!-- ── THE STACK ──────────────────────────────────────────────────── -->
<section class="spec" id="stack">
  <div class="spec-label">
    <span class="spec-name">Bite.svelte × the stack</span>
    <span class="spec-rule">rules and rhythm — no cards; states unread / read / live; MarketStrip every 8th</span>
  </div>
  <Bite section="AI" time="14:02 UTC" read="40s" status="live"
    head="Anthropic ships a smaller model that holds the long-context crown"
    dek="The benchmark table, the price drop, and why the context window stopped being the headline number."
    sources={['paper', 'model card']}
    byline={{ writer: { name: 'wren', role: 'writer' }, research: ['moss'], editor: 'hale' }}
    onagent={onagent} />
  <Bite section="CHIPS" time="13:40 UTC" read="1m" status="unread"
    head="TSMC's Arizona fab clears its first leading-edge wafers"
    dek="Two years late, but running — what the yield numbers say about whether onshoring the leading node actually pencils out."
    sources={['TSMC', 'filing']}
    byline={{ writer: { name: 'wren', role: 'writer' }, research: ['moss'], editor: 'hale' }}
    onagent={onagent} />
  <MarketStrip items={market} />
  <Bite section="POLICY" time="11:58 UTC" read="2m" status="read"
    head="The EU's compute threshold for frontier models takes effect"
    dek="What the training-FLOP line actually triggers, who has to file, and the carve-out that open-weight labs lobbied for."
    sources={['Official Journal', 'analysis']}
    byline={{ writer: { name: 'wren', role: 'writer' }, research: ['moss'], editor: 'hale' }}
    onagent={onagent} />
</section>

<!-- ── RECEIPT ────────────────────────────────────────────────────── -->
<section class="spec" id="receipt">
  <div class="spec-label">
    <span class="spec-name">Receipt.svelte</span>
    <span class="spec-rule">the pipeline trail — terminal-skinned, dark on the light page</span>
  </div>
  <Receipt title="deepmind-weather.org — the run" rows={[
    { stage: 'assigned',   time: '13:40', note: 'desk · weather model', sha: 'a1c4e9' },
    { stage: 'researched', time: '13:51', note: 'moss · 6 sources',     sha: 'f72b08' },
    { stage: 'drafted',    time: '13:58', note: 'wren · 612 words',     sha: '3d9a17' },
    { stage: 'edited',     time: '14:02', note: 'hale · fact pass',     sha: 'be05c2' },
  ]} />
</section>

<!-- ── BYLINE ─────────────────────────────────────────────────────── -->
<section class="spec" id="byline">
  <div class="spec-label">
    <span class="spec-name">Byline.svelte</span>
    <span class="spec-rule">every story signs its machines — names link to the crew</span>
  </div>
  <Byline writer={{ name: 'wren', role: 'writer' }} research={['moss', 'desk']} editor="hale" onagent={onagent} />
</section>

<!-- ── CREW PANEL (inline specimen) ───────────────────────────────── -->
<section class="spec" id="crew">
  <div class="spec-label">
    <span class="spec-name">CrewPanel.svelte</span>
    <span class="spec-rule">always terminal skin — toggle it from the masthead, or read it here</span>
  </div>
  <CrewPanel inline agents={crew} wire={feed.wire} {pipeline} specimen clock="14:02:33" />
</section>

<!-- ── PORTAL ─────────────────────────────────────────────────────── -->
<section class="spec" id="portal">
  <div class="spec-label">
    <span class="spec-name">Portal.svelte</span>
    <span class="spec-rule">the one allowed gradient — the live-agent rim, thin</span>
  </div>
  <div class="portal-well">
    <Portal agent="wren" verb="drafting" target="deepmind-weather.org"
      thought="checking the TPU claim against the methods section before the lede goes out"
      excerpt={'  the model runs ten-day forecasts on a\n  single TPU — a result the authors frame\n  as the end of the supercomputer era for'} />
  </div>
</section>

<style>
  .intro {
    margin: 22px 0 4px;
    font-size: 11px; line-height: 1.7; color: var(--ink-3);
    max-width: 60ch; letter-spacing: 0.01em; text-transform: none;
  }
  .swatches { display: grid; grid-template-columns: repeat(2, 1fr); gap: 0; }
  .swatch { display: flex; align-items: center; gap: 12px; padding: 12px 4px; border-bottom: 1px solid var(--rule); }
  .chip { width: 26px; height: 26px; border: 1px solid var(--rule); flex: 0 0 auto; }
  .sw-name { font-size: 12px; color: var(--ink); min-width: 70px; }
  .sw-hex { font-size: 12px; color: var(--ink-3); min-width: 64px; }
  .sw-note { font-size: 13px; color: var(--ink-2); }
  .hairdemo { margin-top: 20px; }
  .hd-label { display: block; margin-bottom: 8px; color: var(--ink-3); }

  .type-opt { display: flex; flex-direction: column; gap: 16px; margin-bottom: 28px; }
  .to-row { display: flex; flex-direction: column; gap: 5px; }
  .to-cap { font-size: 10px; color: var(--ink-3); letter-spacing: 0.06em; text-transform: uppercase; }
  .n44 { font-size: 44px; line-height: 1.05; font-weight: 600; letter-spacing: -0.02em; font-optical-sizing: auto; }
  .n22 { font-size: 22px; line-height: 1.15; font-weight: 600; letter-spacing: -0.012em; }
  .n17 { font-size: 17px; line-height: 1.5; font-weight: 400; }

  .switzer-block { margin: 0 0 22px; font-size: 17px; line-height: 1.65; color: var(--ink-2); max-width: 60ch; letter-spacing: -0.01em; }
  .meta-row { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3); padding: 10px 0; border-top: 1px solid var(--rule); border-bottom: 1px solid var(--rule); }

  .touch-demo { margin-top: 28px; }
  .td-cap { display: block; font-size: 10px; color: var(--ink-3); letter-spacing: 0.06em; text-transform: uppercase; margin-bottom: 10px; }
  .td-pair { display: inline-flex; align-items: baseline; }
  .td-serif { font-size: 26px; font-weight: 600; letter-spacing: -0.012em; }
  .td-gap { width: 1px; align-self: stretch; margin: 2px 14px; background: var(--rule); }
  .td-mono { font-size: 13px; color: var(--ink-2); letter-spacing: 0.02em; }
  .td-note { display: block; margin-top: 10px; font-size: 10px; color: var(--ink-3); letter-spacing: 0.02em; }

  .portal-well { padding: 8px 0; }

  @media (max-width: 560px) { .swatches { grid-template-columns: 1fr; } }
</style>
