<script>
  // Thread panel — the wired thread leaf action. Shows a root message and its replies (Nexus.Chat
  // single-level threads: parent → root), with a composer that posts replies via sendReply. Slides
  // in over the right edge like the media/settings panels.
  import { ui, messages, repliesOf, sendReply } from './data.svelte.js'
  import Message from './Message.svelte'
  import { iconSvgByName } from './icons.js'

  const root = $derived(messages.find((m) => m.id === ui.thread))
  const replies = $derived(root ? repliesOf(root.id) : [])
  let draft = $state('')

  function post() {
    if (!draft.trim()) return
    sendReply(root.id, draft)
    draft = ''
  }
  function onKey(e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); post() }
    if (e.key === 'Escape') ui.thread = null
  }
</script>

{#if root}
  <aside class="fixed top-0 right-0 h-screen w-[min(420px,92vw)] z-40 bg-paper border-l border-line shadow-2xl flex flex-col">
    <header class="flex items-center gap-2 px-4 h-[57px] border-b border-line flex-none">
      <span class="font-display font-semibold">Thread</span>
      <span class="text-dim text-[12px]">{replies.length} {replies.length === 1 ? 'reply' : 'replies'}</span>
      <span class="flex-1"></span>
      <button aria-label="Close thread" onclick={() => (ui.thread = null)}
        class="w-8 h-8 grid place-items-center text-dim hover:text-ink rounded-lg border border-line [&>svg]:w-4 [&>svg]:h-4">{@html iconSvgByName('xmark', 16)}</button>
    </header>

    <div class="flex-1 overflow-y-auto px-4 py-3.5 flex flex-col gap-3">
      <Message m={root} />
      {#if replies.length}
        <div class="flex items-center gap-2 text-[11px] text-dim my-1">
          <span class="h-px flex-1 bg-line"></span>{replies.length} {replies.length === 1 ? 'reply' : 'replies'}<span class="h-px flex-1 bg-line"></span>
        </div>
      {/if}
      {#each replies as r (r.id)}<Message m={r} />{/each}
    </div>

    <div class="p-3 border-t border-line flex-none">
      <textarea bind:value={draft} onkeydown={onKey} rows="1" placeholder="Reply…"
        class="w-full resize-none bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]"></textarea>
    </div>
  </aside>
{/if}
