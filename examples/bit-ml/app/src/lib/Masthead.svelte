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
  <a class="logo serif" href="#top">bit<span class="dot">.</span>ml</a>

  <nav class="nav mono" aria-label="sections">
    {#each sections as s}<a class="navlink" href="#{s.toLowerCase()}">{s}</a>{/each}
  </nav>

  <div class="right mono">
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
    padding: 18px 0 16px;
  }
  .logo {
    font-family: var(--serif); font-weight: 600; font-size: 22px;
    color: var(--ink); letter-spacing: -0.01em; line-height: 1;
    text-decoration: none;
  }
  .logo:hover { text-decoration: none; }
  .dot { color: var(--wire); }

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
    display: inline-flex; align-items: center; gap: 6px;
    background: none; border: 0; padding: 0;
    font-family: var(--mono); font-size: 11px;
    text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink-3); cursor: pointer;
  }
  .crew:hover, .crew.on { color: var(--wire); }
  .crew .glyph { font-size: 12px; line-height: 1; }
  .crew.on .glyph { color: var(--wire); }

  @media (max-width: 560px) {
    .nav { display: none; }
  }
</style>
