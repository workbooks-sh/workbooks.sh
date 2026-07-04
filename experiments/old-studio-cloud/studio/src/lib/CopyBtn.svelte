<script>
  // copy a value to the clipboard (DNS records, tokens, ids) with a toast confirmation
  import { copyText } from './adminkit.svelte.js'
  import { iconSvgByName } from './icons.js'
  let { text, label = 'Copied' } = $props()
</script>
<button onclick={(e) => { e.stopPropagation(); copyText(text, label) }} title="Copy"
  class="grid place-items-center text-dim hover:text-ink [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('copy', 13)}</button>
