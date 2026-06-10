<script module>
  // Avatar — the crew are CHARACTERS (DESIGN.md §4.8a). Faces come from the
  // LOCAL open-peeps pack (CC0, B&W), rendered by the vendored open-avatars
  // engine — deterministic per seed, so desk/moss/wren/hale always render the
  // same face. No network: the engine + pack are vendored (src/vendor), so the
  // SVG is composed in-page and the workbook bundle is fully self-contained.
  //   engine: src/vendor/open-avatars.js  ·  pack: src/vendor/open-peeps.bundle.json
  //
  // The pack is monochrome by law (black ink on white). We don't recolor it;
  // crops drive how much of the figure shows:
  //   'circle' → round face-crop (default, small uses, byline + grid cards)
  //   'bust'   → head + shoulders (the profile reveal)
  //   'full'   → the whole peep (the deepest profile reveal)
  import { avatar } from '../vendor/open-avatars.js';
  import bundle from '../vendor/open-peeps.bundle.json';
</script>

<script>
  // Props (DESIGN §4.8a): {seed, name, size, crop, live}.
  //   crop ∈ 'circle' | 'bust' | 'full'  (default 'circle')
  // The SVG is a first-party string → rendered with {@html} (we vendor it).
  let { seed, name = seed, size = 'md', crop = 'circle', live = false } = $props();

  const px = { sm: 28, md: 44, lg: 64, xl: 132 };
  const dim = $derived(px[size] ?? px.md);

  // circle gets a --wash backplate (the B&W face wants a soft disc behind it);
  // bust/full sit on the surface directly (no plate — they bleed past a disc).
  const svg = $derived(
    avatar(bundle, seed ?? name, {
      crop,
      title: String(name ?? seed ?? ''),
      ...(crop === 'circle' ? { background: '#f5f5f5' } : {}),
    })
  );
</script>

<span class="av {size} {crop}" style="--dim:{dim}px">
  <span class="face" class:circle={crop === 'circle'} aria-hidden="true">{@html svg}</span>
  {#if live}<span class="badge" aria-label="live"></span>{/if}
</span>

<style>
  .av {
    position: relative; display: inline-block;
    width: var(--dim); height: var(--dim); flex: 0 0 auto;
  }
  /* bust/full are taller than wide — let the box grow vertically for them */
  .av.bust { height: calc(var(--dim) * 0.79); }
  .av.full { height: calc(var(--dim) * 1.35); }

  .face {
    display: block; width: 100%; height: 100%;
    background: var(--wash);            /* the circle backplate (§4.8a) */
  }
  .face.circle { border-radius: 999px; overflow: hidden; }
  .av.bust .face, .av.full .face { background: transparent; }

  .face :global(svg) { display: block; width: 100%; height: 100%; }

  .badge {
    position: absolute; right: 0; bottom: 0;
    width: 28%; height: 28%; min-width: 8px; min-height: 8px;
    max-width: 14px; max-height: 14px;
    border-radius: 999px;
    background: var(--wire);
    box-shadow: 0 0 0 2px var(--paper);   /* punch through the face cleanly */
    animation: breathe 2.4s ease-in-out infinite;
  }
  @keyframes breathe { 50% { opacity: .45; } }
</style>
