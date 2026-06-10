<script>
  // §4.1 Masthead. One hairline below. Left: bit.ml in Newsreader 600 — the
  // DOT in wire blue (the entire logo concept). Center: section nav, mono
  // uppercase 11px. Right: a REAL ticking UTC clock + the ◉ crew toggle
  // (always present, wired to open the CrewPanel). No hamburger until mobile.
  let { sections = ['AI', 'MARKETS', 'CHIPS', 'POLICY'], oncrew, crewOpen = false } = $props();

  let clock = $state(utc());
  function utc() {
    return new Date().toISOString().slice(11, 19); // HH:MM:SS, always UTC
  }
  $effect(() => {
    const id = setInterval(() => { clock = utc(); }, 1000);
    return () => clearInterval(id);
  });
</script>

<header class="mast">
  <a class="logo serif" href="/">bit<span class="dot">.</span>ml</a>

  <nav class="nav mono" aria-label="sections">
    {#each sections as s}<a class="navlink" href="/s/{s.toLowerCase()}">{s}</a>{/each}
  </nav>

  <div class="right mono">
    <span class="kbd" aria-hidden="true">⌘K</span>
    <span class="clock" aria-label="UTC clock">{clock} UTC</span>
    <button class="crew" class:on={crewOpen} onclick={oncrew} aria-pressed={crewOpen}>
      <span class="glyph">◉</span> crew
    </button>
  </div>
</header>
<hr class="hair" />

<style>
  .mast {
    display: flex; align-items: center; gap: 24px;
    padding: 14px 0 13px;
    position: sticky; top: 0; z-index: 30;
    background: color-mix(in srgb, var(--paper) 78%, transparent);
    backdrop-filter: blur(12px) saturate(1.1);
    -webkit-backdrop-filter: blur(12px) saturate(1.1);
  }
  .logo {
    font-family: var(--serif); font-weight: 600; font-size: 22px;
    color: var(--ink); letter-spacing: -0.01em; line-height: 1;
    text-decoration: none;
  }
  .logo:hover { text-decoration: none; }
  .dot { color: var(--wire); }

  .kbd {
    font-family: var(--mono); font-size: 10.5px; color: var(--ink-3);
    border: 1px solid var(--rule); border-radius: var(--r-s); padding: 3px 7px;
    background: color-mix(in srgb, var(--ink) 2%, transparent);
  }

  .nav { display: flex; align-items: center; gap: 18px; margin-left: 4px; }
  .navlink {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink-3); text-decoration: none;
  }
  .navlink:hover { color: var(--ink); text-decoration: none; }

  .right { display: flex; align-items: center; gap: 18px; margin-left: auto; }
  .clock {
    font-size: 11px; color: var(--ink-3); letter-spacing: 0.04em;
    font-variant-numeric: tabular-nums; white-space: nowrap;
  }
  .crew {
    /* a Linear pill: bordered, radiused, bg-shift on hover — product chrome */
    display: inline-flex; align-items: center; gap: 6px;
    border: 1px solid var(--rule); border-radius: 999px; padding: 5px 12px;
    background: color-mix(in srgb, var(--ink) 2%, transparent);
    font-family: var(--mono); font-size: 10.5px;
    text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink-2); cursor: pointer;
    transition: border-color .14s ease, background .14s ease, color .14s ease;
  }
  .crew:hover { border-color: color-mix(in srgb, var(--wire) 45%, var(--rule)); color: var(--ink); }
  .crew.on { border-color: var(--wire); color: var(--wire);
    background: color-mix(in srgb, var(--wire) 6%, transparent); }
  .crew .glyph { font-size: 12px; line-height: 1; }
  .crew.on .glyph { color: var(--wire); }

  @media (max-width: 560px) {
    .nav { display: none; }
  }
</style>
