<script>
  import { toasts } from './toast.svelte.js'
  import { iconSvgByName } from './icons.js'
</script>

<div class="fixed bottom-4 right-4 z-[80] flex flex-col gap-2 items-end">
  {#each toasts as t (t.id)}
    <div class="flex items-center gap-2.5 px-3.5 py-2.5 rounded-xl border border-line max-w-[360px]"
      style="background:var(--color-card); box-shadow:0 14px 36px rgba(0,0,0,.3)">
      <span class="grid place-items-center text-bloomd [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('puzzle', 15)}</span>
      <span class="text-[12.5px] text-ink">{t.msg}</span>
    </div>
  {/each}
</div>
