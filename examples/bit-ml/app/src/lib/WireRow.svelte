<script>
  // §4.4 — THE WIRE row. The "latest" column: a dense, scannable one-liner per
  // story — mono, head only (plain, no brand marks in this terminal register) +
  // a relative timestamp + the section tag. Reads like a news ticker.
  import { sectionOf } from './sections.js';

  let { head = '', when = '', section = 'AI', href = null } = $props();

  const sec = $derived(sectionOf(String(section).toUpperCase()));
</script>

<a class="wire" href={href ?? undefined}>
  <span class="when mono">{when}</span>
  <span class="tag mono" style="color:{sec.color}">{sec.tag}</span>
  <span class="head">{head}</span>
</a>

<style>
  .wire {
    display: grid;
    grid-template-columns: 52px 64px 1fr;
    align-items: baseline; gap: 12px;
    padding: 9px 0;
    border-top: 1px solid var(--rule);
    color: inherit; text-decoration: none;
  }
  .wire:hover { text-decoration: none; }
  .wire:hover .head { color: var(--wire); }
  .when {
    font-size: 11px; color: var(--ink-3);
    letter-spacing: 0.02em; white-space: nowrap;
  }
  .tag {
    font-size: 10px; text-transform: uppercase; letter-spacing: 0.07em;
    white-space: nowrap;
  }
  .head {
    font-family: var(--mono);
    font-size: 13.5px; line-height: 1.35; color: var(--ink);
    letter-spacing: -0.01em;
    overflow: hidden; text-overflow: ellipsis;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
  }
  @media (max-width: 680px) {
    .wire { grid-template-columns: 46px 1fr; }
    .tag { display: none; }   /* keep the latest column tight on mobile */
  }
</style>
