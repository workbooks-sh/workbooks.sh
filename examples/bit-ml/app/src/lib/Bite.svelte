<script>
  // §4.3 Bite card — the atomic unit. Scannable in five seconds, honest in
  // thirty. No card background, no border-radius, no shadow: the stack IS
  // rules and rhythm. Anatomy top→bottom:
  //   section tick+tag | timestamp+read-time (right)  ← mono row
  //   headline (Newsreader, ≤2 lines, sentence case)
  //   dek (Switzer, ≤2 sentences — the actual information)
  //   sources left · agent byline right                ← mono row
  //   hairline below
  // States: unread (full ink) · read (head→ink-2) ·
  //   live (wire-blue pulsing dot + head TYPES IN ~30cps — truthful motion).
  import { sectionOf } from './sections.js';
  import Byline from './Byline.svelte';

  let {
    section = 'AI',
    time = '',
    read = '',
    head = '',
    dek = '',
    sources = [],
    byline,
    state = 'unread',
    onagent,
  } = $props();

  const sec = $derived(sectionOf(section));

  // Type-in for the LIVE bite only (DESIGN §4.3/§5: the truthful-motion
  // exception, ~30cps). prefers-reduced-motion shows the full head at once.
  let typed = $state('');
  $effect(() => {
    if (state !== 'live') { typed = head; return; }
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (reduce) { typed = head; return; }
    typed = '';
    let i = 0;
    const id = setInterval(() => {
      i++;
      typed = head.slice(0, i);
      if (i >= head.length) clearInterval(id);
    }, 1000 / 30); // ~30 characters per second
    return () => clearInterval(id);
  });
</script>

<article class="bite {state}">
  <div class="top mono">
    <span class="sec">
      <span class="tick" style="background:{sec.color}"></span>
      <span class="tag" style="color:{sec.color}">{sec.tag}</span>
      {#if state === 'live'}<span class="live-dot" aria-label="live"></span><span class="live-word">live</span>{/if}
    </span>
    <span class="when">{time}{#if read} · {read} read{/if}</span>
  </div>

  <h2 class="head serif">{typed}{#if state === 'live' && typed.length < head.length}<span class="caret"></span>{/if}</h2>

  {#if dek}<p class="dek">{dek}</p>{/if}

  <div class="foot">
    <span class="sources mono">{#if sources.length}sources: {sources.join(' · ')}{/if}</span>
    {#if byline}<Byline {...byline} {onagent} />{/if}
  </div>
</article>
<hr class="hair" />

<style>
  .bite { padding: 22px 0 18px; }

  .top {
    display: flex; align-items: center; justify-content: space-between;
    gap: 12px; margin-bottom: 12px;
  }
  .sec { display: inline-flex; align-items: center; gap: 8px; }
  .tick { width: 2px; height: 12px; display: inline-block; }
  .tag {
    font-size: 11px; font-weight: 500; text-transform: uppercase;
    letter-spacing: 0.07em;
  }
  .when {
    font-size: 11px; color: var(--ink-3); letter-spacing: 0.04em;
    text-transform: uppercase; white-space: nowrap;
  }

  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 22px; line-height: 1.15; font-weight: 600;
    letter-spacing: -0.012em;
    color: var(--ink);
    text-wrap: balance;
  }

  .dek {
    margin: 8px 0 0;
    font-size: 16px; line-height: 1.5; color: var(--ink-2);
    letter-spacing: -0.008em;
    max-width: 56ch;
  }

  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin-top: 14px; flex-wrap: wrap;
  }
  .sources {
    font-size: 11px; color: var(--ink-3); letter-spacing: 0.01em;
  }

  /* — states — */
  .read .head { color: var(--ink-2); }

  .live-dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--wire); display: inline-block;
    box-shadow: 0 0 0 0 color-mix(in srgb, var(--wire) 50%, transparent);
    animation: pulse 1.8s ease-in-out infinite;
  }
  .live-word {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--wire); font-weight: 500;
  }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 color-mix(in srgb, var(--wire) 45%, transparent); }
    70%  { box-shadow: 0 0 0 6px color-mix(in srgb, var(--wire) 0%, transparent); }
    100% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--wire) 0%, transparent); }
  }

  /* type-in caret — a thin wire-blue bar that blinks while writing */
  .caret {
    display: inline-block; width: 2px; height: 0.92em;
    margin-left: 2px; vertical-align: -0.08em;
    background: var(--wire);
    animation: blink 1s steps(1) infinite;
  }
  @keyframes blink { 50% { opacity: 0; } }
</style>
