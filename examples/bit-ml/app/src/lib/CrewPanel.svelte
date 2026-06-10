<script>
  // §4.8 Crew panel — the FUN ORG CHART (founder, 2026-06-10). Opens from the
  // masthead ◉ crew toggle on every page as a slide-in right panel; ALSO renders
  // inline on /design as the specimen. Light, Notion-style surface now (no more
  // terminal skin): white card, soft lift shadow, OpenPeeps avatars.
  //
  //   desk sits at the TOP (it assigns) · three reports beneath ·
  //   thin connector lines between the tiers · each member carries an avatar,
  //   name, role, doing-now status line, a live badge, and a watch → link.
  //   Below the chart: THE WIRE (recent commits, avatar per row) + PIPELINE
  //   stat chips. Slide-in 150ms (§5: fast or absent).
  import Avatar from './Avatar.svelte';

  let {
    open = false,
    inline = false,
    filter = null,         // agent name the panel is scoped to (from a byline click)
    clock = '14:02:33',
    agents = [],
    wire = [],
    pipeline = '',
    specimen = false,   // honest flag: the crew runtime (/_activity) isn't wired yet
    onclose,
  } = $props();

  // org structure: desk leads (assignment), the rest are its reports.
  const lead = $derived(agents.find((a) => a.role === 'assignment') ?? agents[0]);
  const reports = $derived(agents.filter((a) => a !== lead));

  // wire rows want an avatar — look the committer up in the crew
  const seedOf = (who) => agents.find((a) => a.name === who)?.avatarSeed ?? who;

  // pipeline string → [{label, n}] chips
  const chips = $derived(
    pipeline
      .split('·')
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        const m = s.match(/^(.*?)\s+(\d+)$/);
        return m ? { label: m[1], n: m[2] } : { label: s, n: '' };
      })
  );
</script>

<aside
  class="crew"
  class:inline
  class:open={inline || open}
  aria-hidden={!(inline || open)}
>
  <div class="phead">
    <span class="title mono">THE CREW</span>
    {#if specimen}<span class="spectag mono" title="the crew runtime is a parallel build (wb-wc0.2) — this feed is static for now">specimen data</span>{/if}
    <span class="time mono">{clock} UTC</span>
    {#if !inline}<button class="x" onclick={onclose} aria-label="close crew panel">×</button>{/if}
  </div>

  <!-- ── THE ORG CHART ─────────────────────────────────────────────── -->
  {#if lead}
    <div class="chart">
      <div class="tier lead">
        <div class="member" class:hit={filter === lead.name}>
          <Avatar seed={lead.avatarSeed ?? lead.name} name={lead.name} size="lg" live={lead.state !== 'idle'} />
          <span class="name">{lead.name}</span>
          <span class="role mono">{lead.role}</span>
          <span class="doing">{lead.doing}</span>
        </div>
      </div>

      <div class="connectors" aria-hidden="true">
        <span class="drop"></span>
        <span class="bus"></span>
        {#each reports as _, i}<span class="riser" style="--i:{i}; --n:{reports.length}"></span>{/each}
      </div>

      <div class="tier reports">
        {#each reports as a}
          <div class="member" class:dim={a.state === 'idle'} class:hit={filter === a.name}>
            <Avatar seed={a.avatarSeed ?? a.name} name={a.name} size="md" live={a.state !== 'idle'} />
            <span class="name">{a.name}</span>
            <span class="role mono">{a.role}</span>
            <span class="status mono" class:live={a.state !== 'idle'}>
              {a.state !== 'idle' ? '● live' : 'idle'}
            </span>
            <span class="doing">{a.doing}</span>
            {#if a.state !== 'idle'}<button class="watch mono">watch →</button>{/if}
          </div>
        {/each}
      </div>
    </div>
  {/if}

  <!-- ── THE WIRE ──────────────────────────────────────────────────── -->
  <div class="shead mono">THE WIRE <span class="sub">recent commits</span></div>
  <div class="commits">
    {#each wire as c}
      <div class="crow">
        <Avatar seed={seedOf(c.who)} name={c.who} size="sm" />
        <span class="ct mono">{c.time}</span>
        <span class="cw">{c.who}</span>
        <span class="cm">{c.msg}</span>
      </div>
    {/each}
  </div>

  <!-- ── PIPELINE — Notion-ish stat chips ──────────────────────────── -->
  <div class="shead mono">PIPELINE</div>
  <div class="chips">
    {#each chips as c}
      <span class="chip">
        <span class="cn">{c.n}</span>
        <span class="cl mono">{c.label}</span>
      </span>
    {/each}
  </div>
</aside>

<style>
  .crew {
    background: var(--paper);
    color: var(--ink);
    font-family: var(--sans);
    font-size: 13px; line-height: 1.5;
  }

  /* docked overlay (toggle) — a floating Notion surface, soft lift, no stroke */
  .crew:not(.inline) {
    position: fixed; top: 0; right: 0; z-index: 80;
    width: 380px; max-width: 90vw; height: 100vh;
    padding: 20px 22px 28px;
    overflow-y: auto;
    transform: translateX(100%);
    transition: transform .15s ease-out;   /* §4.8 slide-in 150ms */
    box-shadow: var(--shadow);
    border-radius: var(--r) 0 0 var(--r);
  }
  .crew:not(.inline).open { transform: none; }

  /* inline specimen — a card on the page */
  .crew.inline {
    width: 100%; padding: 24px 22px;
    border-radius: var(--r);
    box-shadow: var(--shadow);
  }

  .phead {
    display: flex; align-items: baseline; gap: 12px;
    margin-bottom: 28px;
  }
  .title { font-size: 11px; letter-spacing: 0.08em; color: var(--ink); font-weight: 500; }
  .spectag {
    font-size: 9.5px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--ink-3); background: var(--surface);
    border-radius: var(--r-s); padding: 3px 7px; align-self: center;
  }
  .time { font-size: 11px; color: var(--wire); margin-left: auto; font-variant-numeric: tabular-nums; letter-spacing: 0.04em; }
  .x {
    background: none; border: 0; color: var(--ink-3);
    font-size: 20px; line-height: 1; padding: 0 0 0 6px; cursor: pointer;
  }
  .x:hover { color: var(--ink); }

  /* ── the chart ── */
  .chart { margin-bottom: 30px; }
  .tier { display: flex; justify-content: center; }
  .tier.reports { gap: 6px; align-items: start; }

  .member {
    display: flex; flex-direction: column; align-items: center; text-align: center;
    gap: 4px; padding: 10px 8px; border-radius: var(--r);
    flex: 1 1 0; min-width: 0;
    transition: background .14s ease;
  }
  .member.hit { background: color-mix(in srgb, var(--wire) 8%, transparent); }
  .tier.lead .member { flex: 0 0 auto; max-width: 200px; }

  .name { font-size: 14px; font-weight: 600; color: var(--ink); margin-top: 4px; letter-spacing: -0.01em; }
  .role {
    font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.06em;
    color: var(--ink-3);
  }
  .status { font-size: 10.5px; letter-spacing: 0.04em; color: var(--ink-3); }
  .status.live { color: var(--wire); }
  .doing {
    font-size: 11.5px; color: var(--ink-2); line-height: 1.35;
    max-width: 14ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .tier.lead .doing { max-width: 22ch; }
  .member.dim .doing { color: var(--ink-3); }
  .watch {
    background: none; border: 0; padding: 2px 0 0; cursor: pointer;
    font-size: 11px; color: var(--wire); white-space: nowrap;
  }
  .watch:hover { text-decoration: underline; text-underline-offset: 2px; }

  /* thin connector lines (1px var(--rule)) drawn with borders/pseudo-elements */
  .connectors {
    position: relative; height: 22px;
    display: flex; justify-content: center;
  }
  .connectors .drop {
    position: absolute; top: 0; left: 50%; width: 1px; height: 11px;
    background: var(--rule);
  }
  .connectors .bus {
    position: absolute; top: 11px; left: 16.6%; right: 16.6%; height: 1px;
    background: var(--rule);
  }
  .connectors .riser {
    position: absolute; top: 11px; height: 11px; width: 1px;
    background: var(--rule);
    /* evenly distribute risers across the bus, centered over each report */
    left: calc(16.6% + (100% - 33.2%) * (var(--i) + 0.5) / var(--n));
  }

  /* ── the wire ── */
  .shead {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink); margin: 0 0 12px;
  }
  .shead .sub { color: var(--ink-3); text-transform: none; letter-spacing: 0.01em; margin-left: 4px; }
  .commits { display: flex; flex-direction: column; gap: 2px; margin-bottom: 30px; }
  .crow {
    display: grid; grid-template-columns: 28px 44px 44px 1fr; gap: 10px;
    align-items: center; padding: 7px 8px; margin: 0 -8px; border-radius: var(--r-s);
    font-size: 12.5px; transition: background .12s ease;
  }
  .crow:hover { background: var(--wash); }
  .ct { color: var(--ink-3); font-size: 11px; font-variant-numeric: tabular-nums; }
  .cw { color: var(--ink); font-weight: 600; }
  .cm { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* ── pipeline chips ── */
  .chips { display: flex; flex-wrap: wrap; gap: 8px; }
  .chip {
    display: inline-flex; align-items: baseline; gap: 6px;
    background: var(--surface); border-radius: var(--r-s);
    padding: 8px 12px;
  }
  .cn { font-size: 16px; font-weight: 600; color: var(--ink); font-variant-numeric: tabular-nums; }
  .cl { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3); }

  @media (max-width: 420px) {
    .doing { max-width: 11ch; }
  }
</style>
