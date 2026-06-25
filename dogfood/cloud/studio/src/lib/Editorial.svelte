<script>
  // The Briefing: one synthesized editorial drawn from seven expert reviews of Studio, presented as
  // a single rich reading with an integrated ElevenLabs narration. No raw reports — just the take.
  import { marked } from 'marked'
  import md from './editorial.md?raw'
  import { iconSvgByName } from './icons.js'

  const html = marked.parse(md, { mangle: false, headerIds: false })

  let audio = $state(null)
  let playing = $state(false)
  let cur = $state(0)
  let dur = $state(0)
  let hasAudio = $state(true)

  function toggle() { if (!audio) return; playing ? audio.pause() : audio.play() }
  function seek(e) { if (!audio || !dur) return; audio.currentTime = (e.target.value / 100) * dur }
  const fmt = (s) => (isNaN(s) ? '0:00' : `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`)
  const pct = $derived(dur ? (cur / dur) * 100 : 0)
</script>

<div class="h-full overflow-y-auto bg-paper">
  <!-- masthead + narration player, sticky -->
  <div class="sticky top-0 z-10 backdrop-blur bg-[color-mix(in_srgb,var(--color-paper)_88%,transparent)] border-b border-line">
    <div class="max-w-[760px] mx-auto px-8 py-3.5 flex items-center gap-4">
      <span class="text-[10px] font-mono uppercase tracking-[0.2em] text-dim flex-none">The Studio Briefing</span>
      <span class="flex-1"></span>
      {#if hasAudio}
        <div class="flex items-center gap-3 flex-none">
          <button onclick={toggle} aria-label={playing ? 'Pause narration' : 'Play narration'}
            class="w-9 h-9 rounded-full grid place-items-center bg-ink text-paper hover:opacity-90 transition [&>svg]:w-[17px] [&>svg]:h-[17px]">
            {@html iconSvgByName(playing ? 'pause-solid' : 'play-solid', 17)}
          </button>
          <div class="flex items-center gap-2 w-[220px]">
            <span class="text-[10.5px] font-mono text-dim tabular-nums w-9 text-right">{fmt(cur)}</span>
            <input type="range" min="0" max="100" value={pct} oninput={seek} aria-label="Seek"
              class="flex-1 h-1 accent-[var(--color-ink)] cursor-pointer" />
            <span class="text-[10.5px] font-mono text-dim tabular-nums w-9">{fmt(dur)}</span>
          </div>
          <span class="hidden md:flex items-center gap-1 text-[10px] font-mono text-dim/70 [&>svg]:w-3 [&>svg]:h-3">
            {@html iconSvgByName('sound-high', 12)} narrated
          </span>
        </div>
      {/if}
    </div>
  </div>

  <!-- the editorial -->
  <article class="prose-editorial max-w-[680px] mx-auto px-8 pt-10 pb-28">
    {@html html}
    <div class="mt-16 pt-6 border-t border-line text-[12px] text-dim font-mono leading-relaxed">
      Synthesized from seven independent expert reviews — strategy, product, design, engineering,
      developer experience, security &amp; QA — conducted with GStack skill agents.
      Narration generated with ElevenLabs.
    </div>
  </article>

  <audio bind:this={audio} src="/editorial.mp3" preload="metadata"
    onplay={() => (playing = true)} onpause={() => (playing = false)}
    ontimeupdate={() => (cur = audio.currentTime)}
    onloadedmetadata={() => (dur = audio.duration)}
    onerror={() => (hasAudio = false)}></audio>
</div>

<style>
  /* rich-text reading layout, tuned to the app's tokens */
  .prose-editorial :global(h1) {
    font-family: var(--font-display, inherit);
    font-size: 34px; line-height: 1.15; letter-spacing: -0.02em; font-weight: 700;
    color: var(--color-ink); margin: 0 0 6px;
  }
  .prose-editorial :global(h4) {
    font-size: 15px; font-weight: 500; color: var(--color-dim);
    margin: 0 0 30px; line-height: 1.5;
  }
  .prose-editorial :global(h2) {
    font-family: var(--font-display, inherit);
    font-size: 22px; font-weight: 700; letter-spacing: -0.01em;
    color: var(--color-ink); margin: 38px 0 14px;
  }
  .prose-editorial :global(h3) {
    font-size: 13px; font-weight: 600; color: var(--color-dim);
    margin: 26px 0 10px;
  }
  .prose-editorial :global(p) {
    font-size: 16.5px; line-height: 1.72; color: color-mix(in srgb, var(--color-ink) 92%, transparent);
    margin: 0 0 17px;
  }
  .prose-editorial :global(strong) { color: var(--color-ink); font-weight: 650; }
  .prose-editorial :global(em) { font-style: italic; color: color-mix(in srgb, var(--color-ink) 88%, transparent); }
  .prose-editorial :global(ul) { margin: 0 0 17px; padding-left: 0; list-style: none; }
  .prose-editorial :global(li) {
    position: relative; font-size: 16.5px; line-height: 1.65;
    color: color-mix(in srgb, var(--color-ink) 92%, transparent);
    margin: 0 0 12px; padding-left: 20px;
  }
  .prose-editorial :global(li::before) {
    content: ''; position: absolute; left: 2px; top: 11px;
    width: 6px; height: 6px; border-radius: 2px; background: var(--color-sky);
  }
  .prose-editorial :global(ol) { margin: 0 0 17px; padding-left: 22px; }
  .prose-editorial :global(ol li) { padding-left: 4px; }
  .prose-editorial :global(ol li::before) { display: none; }
  .prose-editorial :global(hr) {
    border: none; height: 1px; background: var(--color-line); margin: 34px 0;
  }
  .prose-editorial :global(code) {
    font-family: var(--font-mono); font-size: 0.88em;
    background: color-mix(in srgb, var(--color-ink) 7%, transparent);
    padding: 1px 5px; border-radius: 5px;
  }
  .prose-editorial :global(a) { color: var(--color-sky); text-decoration: underline; }
</style>
