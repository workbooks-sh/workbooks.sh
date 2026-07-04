<script>
  // Global confirm dialog — mounted once at the app root. Destructive actions ask via askConfirm() and get
  // a Promise<boolean>. A `typed` confirm requires the operator to type the target name (kick member, delete
  // domain/secret, org-level deletes) so a stray click can't fire an irreversible action.
  import { confirmState as c, resolveConfirm } from './adminkit.svelte.js'
  const ready = $derived(!c.typed || c.input.trim() === c.typed)
</script>

{#if c.open}
  <div class="fixed inset-0 z-[200] grid place-items-center px-4" style="background:rgba(0,0,0,.45)" onclick={() => resolveConfirm(false)} role="presentation">
    <div class="w-[420px] max-w-full rounded-2xl border border-line p-5" style="background:var(--color-card);box-shadow:0 24px 60px rgba(0,0,0,.4)"
      onclick={(e) => e.stopPropagation()} role="presentation">
      <div class="font-display font-semibold text-[16px] mb-1.5">{c.title}</div>
      {#if c.body}<div class="text-dim text-[13px] mb-4 leading-relaxed">{@html c.body}</div>{/if}
      {#if c.typed}
        <div class="text-[12px] text-dim mb-1.5">Type <span class="font-mono text-ink">{c.typed}</span> to confirm</div>
        <!-- svelte-ignore a11y_autofocus -->
        <input bind:value={c.input} autofocus onkeydown={(e) => { if (e.key === 'Enter' && ready) resolveConfirm(true) }}
          class="w-full bg-paper border border-line rounded-lg px-3 py-2 text-[13px] outline-none focus:border-ink mb-4" />
      {/if}
      <div class="flex justify-end gap-2">
        <button onclick={() => resolveConfirm(false)} class="px-3 py-1.5 rounded-lg text-[13px] text-dim hover:text-ink">Cancel</button>
        <button onclick={() => ready && resolveConfirm(true)} disabled={!ready}
          class="px-3.5 py-1.5 rounded-lg text-[13px] font-medium disabled:opacity-40"
          style="background:{c.danger ? 'var(--color-bad)' : 'var(--color-ink)'};color:var(--color-paper)">{c.confirmLabel}</button>
      </div>
    </div>
  </div>
{/if}
