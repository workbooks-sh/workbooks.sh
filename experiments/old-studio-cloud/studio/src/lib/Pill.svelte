<script>
  // a small colored status/role pill (tinted background + colored text)
  let { label, color = 'var(--color-dim)' } = $props()
</script>
<span class="text-[10px] font-mono uppercase tracking-wider px-1.5 py-0.5 rounded-md whitespace-nowrap"
  style="color:{color};background:color-mix(in srgb,{color} 14%,transparent)">{label}</span>
