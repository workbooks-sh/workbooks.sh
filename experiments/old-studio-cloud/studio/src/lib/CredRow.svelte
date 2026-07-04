<script>
  // CredRow — one consistent row for a credential (a CLI token or an author device key): a tinted icon,
  // a clear title, a quiet fingerprint/meta line with an optional copy affordance, and a Revoke action
  // that only colours danger on hover. Shared by the CLI access + Devices & keys sections so the two
  // read identically (DRY) and the noisy raw did:key / token id stops being front-and-centre.
  import { iconSvgByName } from './icons.js'
  let { icon = 'key', tint = 'var(--color-dim)', title, meta = '', fingerprint = '', copyValue = '', badge = '', onRevoke } = $props()
  let copied = $state(false)
  async function copy() { try { await navigator.clipboard.writeText(copyValue); copied = true; setTimeout(() => (copied = false), 1200) } catch (_) {} }
</script>

<div class="group flex items-center gap-3 py-2.5 px-2 -mx-2 rounded-xl hover:bg-paper/50 transition">
  <span class="w-9 h-9 rounded-xl grid place-items-center flex-none [&>svg]:w-[17px] [&>svg]:h-[17px]"
    style="background:color-mix(in srgb,{tint} 14%,transparent);color:{tint}">{@html iconSvgByName(icon, 17)}</span>
  <div class="flex-1 min-w-0">
    <div class="flex items-center gap-2 min-w-0">
      <span class="text-[13.5px] font-semibold truncate">{title}</span>
      {#if badge}<span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:var(--color-mint);border:1px solid color-mix(in srgb,var(--color-mint) 45%,transparent)">{badge}</span>{/if}
    </div>
    <div class="flex items-center gap-1.5 mt-0.5 min-w-0 text-dim text-[11.5px]">
      {#if fingerprint}<code class="font-mono truncate">{fingerprint}</code>{/if}
      {#if copyValue}
        <button onclick={copy} title="Copy" class="flex-none text-dim/70 hover:text-ink transition [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName(copied ? 'check' : 'copy', 12)}</button>
      {/if}
      {#if meta}<span class="flex-none">· {meta}</span>{/if}
    </div>
  </div>
  <button onclick={onRevoke}
    class="flex-none px-2.5 py-1 rounded-md text-[12px] text-dim border border-line hover:text-[var(--color-bad)] hover:border-[color-mix(in_srgb,var(--color-bad)_45%,var(--color-line))] transition">Revoke</button>
</div>
