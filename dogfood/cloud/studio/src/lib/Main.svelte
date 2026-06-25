<script>
  // the main pane routes by the active surface's KIND: apps → a browser, workflows → a flow,
  // chats/agents → the chat view.
  import { ui, surfaceById } from './data.svelte.js'
  import Chat from './Chat.svelte'
  import AppView from './AppView.svelte'
  import Workflow from './Workflow.svelte'

  const s = $derived(surfaceById(ui.surfaceId))
</script>

{#if s?.kind === 'app'}
  {#key s.id}<AppView surfaceId={s.id} />{/key}
{:else if s?.kind === 'workflow'}
  {#key s.id}<Workflow surfaceId={s.id} />{/key}
{:else}
  <Chat />
{/if}
