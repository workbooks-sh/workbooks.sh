<script>
  // shared run prompt — used by both "Run now" (runs list) and "Test run" (editor). Collects the
  // trigger's inputs, can auto-fill demo data for a quick dev run, then hands the values back.
  import { demoInputValue } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  let { surface, test = false, onRun, onClose } = $props()
  const inputs = $derived(surface?.payload?.inputs || [])
  let values = $state({})

  function fillDemo() { for (const inp of inputs) values[inp.key] = demoInputValue(inp) }
  function pickFile(inp, e) { const f = e.target.files?.[0]; if (f) values[inp.key] = { name: f.name } }
  const missing = $derived(inputs.some((i) => i.required && !values[i.key]))

  function run() { onRun?.({ ...values }); onClose?.() }
</script>

<div class="fixed inset-0 z-50 grid place-items-center p-6" style="background:rgba(0,0,0,.5)" onclick={onClose} role="presentation">
  <div class="w-full max-w-md rounded-2xl border border-line bg-paper overflow-hidden" style="box-shadow:0 30px 80px rgba(0,0,0,.5)"
    onclick={(e) => e.stopPropagation()} role="dialog" tabindex="-1">

    <div class="flex items-center gap-2.5 px-5 h-[54px] border-b border-line">
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style="color:var(--color-mint)">{@html iconSvgByName(test ? 'flash' : 'play', 16)}</span>
      <div class="font-display font-semibold">{test ? 'Test run' : 'Run'} · {surface?.name}</div>
      <span class="flex-1"></span>
      <button onclick={onClose} class="grid place-items-center w-8 h-8 rounded-lg text-dim hover:text-ink hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('xmark', 15)}</button>
    </div>

    <div class="px-5 py-4 flex flex-col gap-3.5 max-h-[60vh] overflow-y-auto">
      {#if inputs.length}
        <div class="flex items-center justify-between">
          <span class="text-[11px] font-mono uppercase tracking-wider text-dim">Trigger inputs</span>
          <button onclick={fillDemo} class="flex items-center gap-1.5 text-[12px] text-dim hover:text-ink [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('sparks', 13)} Generate demo data</button>
        </div>

        {#each inputs as inp}
          <label class="flex flex-col gap-1">
            <span class="text-[12.5px] text-ink/85">{inp.label}{#if inp.required}<span style="color:var(--color-peach)"> *</span>{/if}{#if inp.optional}<span class="text-dim text-[11px]"> · optional</span>{/if}</span>

            {#if inp.type === 'choice'}
              <div class="flex gap-1.5">
                {#each inp.options as opt}
                  <button onclick={() => (values[inp.key] = opt)}
                    class="text-[12.5px] px-2.5 py-1.5 rounded-lg border {values[inp.key] === opt ? 'border-[color-mix(in_srgb,var(--color-mint)_60%,var(--color-line))] text-ink' : 'border-line text-dim'} hoverwash">{opt}</button>
                {/each}
              </div>
            {:else if inp.type === 'file'}
              {#if values[inp.key]}
                <div class="flex items-center gap-2 text-[12.5px] px-3 py-2 rounded-lg border border-line">
                  <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]" style="color:var(--color-sky)">{@html iconSvgByName('empty-page', 15)}</span>
                  <span class="flex-1 truncate">{values[inp.key].name}</span>
                  {#if values[inp.key].demo}<span class="text-dim text-[11px] font-mono">demo</span>{/if}
                  <button onclick={() => (values[inp.key] = null)} class="text-dim hover:text-ink grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('xmark', 13)}</button>
                </div>
              {:else}
                <label class="flex items-center gap-2 text-[12.5px] px-3 py-2 rounded-lg border border-dashed border-line text-dim hover:text-ink cursor-pointer [&>svg]:w-[15px] [&>svg]:h-[15px]">
                  {@html iconSvgByName('attachment', 15)} Attach {inp.accept || 'file'}
                  <input type="file" accept={inp.accept} class="hidden" onchange={(e) => pickFile(inp, e)} />
                </label>
              {/if}
            {:else if inp.type === 'date'}
              <input type="date" bind:value={values[inp.key]} class="bg-card border border-line rounded-lg px-3 py-2 text-[13px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
            {:else if inp.type === 'number'}
              <input type="number" bind:value={values[inp.key]} class="bg-card border border-line rounded-lg px-3 py-2 text-[13px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
            {:else}
              <input bind:value={values[inp.key]} placeholder={inp.placeholder || ''} class="bg-card border border-line rounded-lg px-3 py-2 text-[13px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
            {/if}
          </label>
        {/each}
      {:else}
        <div class="text-dim text-[13px] py-2">This trigger takes no inputs — it runs immediately.</div>
      {/if}
    </div>

    <div class="flex items-center gap-2 px-5 h-[58px] border-t border-line">
      <span class="text-dim text-[12px]">{test ? 'Runs against the current draft' : 'Starts a real run'}</span>
      <span class="flex-1"></span>
      <button onclick={onClose} class="text-[13px] px-3.5 py-1.5 rounded-lg border border-line hoverwash">Cancel</button>
      <button onclick={run} disabled={missing}
        class="flex items-center gap-1.5 text-[13px] px-3.5 py-1.5 rounded-lg text-ink disabled:opacity-40 [&>svg]:w-[14px] [&>svg]:h-[14px]"
        style="background:color-mix(in srgb,var(--color-mint) 26%,transparent)">{@html iconSvgByName(test ? 'flash' : 'play', 14)} {test ? 'Test run' : 'Run'}</button>
    </div>
  </div>
</div>
